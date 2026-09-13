"""Real model access over the ChukChat account (§7.4, backend wiring).

The steady state is **token-only**: the executor holds a Supabase *session*
(``access_token`` + ``refresh_token``), never the login credentials. The backend
(``api.chuk.chat``) only ever sees the access token. When the token expires the
executor refreshes it directly against Supabase GoTrue — the token is revocable,
so a lost executor cannot keep talking to the account forever.

Three pieces:

- :class:`SupabaseSession` — the token holder. ``refresh()`` mints a new access
  token from the refresh token via GoTrue. ``login()`` is a bootstrap helper that
  trades email+password for a session ONCE (directly with GoTrue, never with
  ``api.chuk.chat``); after that the credentials are dropped and only the token
  travels.
- :class:`BackendModelClient` — a :class:`~chuk_agents_runtime.model.ModelClient` that
  drives ``wss://api.chuk.chat/v2/ws``: auth handshake with the access token,
  chat request, accumulate the streamed ``content``/``reasoning``, surface
  ``error``, end on ``done``. Credits are consumed server-side, tied to the JWT.
  Tool calls are **native**: the client sends an OpenAI ``tools`` array and the
  server answers on its own ``tool_calls`` frame. Assistant content is prose;
  it is never scanned for a tool-call protocol.
- :func:`fetch_models_info` / :func:`resolve_model` — read ``/v1/models_info``
  with the token and pick a default model + provider slug.

The confirmed ``/v2/ws`` protocol (source of truth: chuk_chat Dart client):

- handshake: client -> ``{"type":"auth","token":<access_token>}``; server ->
  ``{"type":"auth_ok"}`` or ``{"type":"auth_error","detail":...}``
  (multiplex_connection.dart:153-166, 208).
- keepalive: client -> ``{"type":"ping"}``; server -> ``{"type":"pong"}`` (ignored)
  (multiplex_connection.dart:268, 290).
- chat: client -> ``{"req_id":<id>,"type":"chat","payload":{...}}``
  (multiplex_connection.dart:430-434).
- frames: routed by ``req_id`` + ``kind`` — ``content``/``reasoning`` carry
  ``data`` (string), ``tool_calls`` carries ``data`` (a list of OpenAI call
  objects), ``usage``/``meta`` carry ``data`` (object), ``tps`` a number,
  ``error`` carries ``detail``+``code``, ``done`` closes the stream
  (multiplex_connection.dart:289-368).
- payload fields: ``message``, ``model_id``, ``provider_slug``, ``max_tokens``,
  ``temperature``, optional ``system_prompt``, ``history``, ``reasoning_effort``,
  ``tools`` (websocket_chat_service.dart:101-124).
"""

from __future__ import annotations

import base64
import json
import logging
import threading
import time
import uuid
from collections.abc import Callable
from dataclasses import dataclass, field
from typing import Any

import httpx

from .connection_pool import BackendConnectionPool
from websockets.exceptions import ConnectionClosed
from websockets.sync.client import connect as _ws_connect

from .model import ModelClient, ModelResponse, ToolCall
from .trace import DEFAULT_TOKEN_GAP_MS, get_tracer

logger = logging.getLogger(__name__)

# The single default backend. Callers may override.
DEFAULT_BASE_URL = "https://api.chuk.chat"
# The default model. It MUST be one that actually calls tools when it is handed
# a `tools` array. Measured live (tests/live_sweep.py):
#
#   works: deepseek-v4-flash, qwen3-32b, kimi-k2.6, minimax-m2.7,
#          llama-3.3-70b, mistral-small-2603
#   silent: gpt-oss-20b/120b (Harmony channels), qwen3.5/3.6-35b-a3b (content
#           comes back empty), glm-5.1 (its own arg-key format)
#
# gpt-oss-20b was the old default and is exactly the failure the user hit: the
# model says "I'll use write_file" in its reasoning and then prints the file.
# Cheapest of the working set, and it calls tools reliably.
DEFAULT_MODEL_ID = "deepseek/deepseek-v4-flash"

# Models proven to emit usable tool calls, cheapest first. Kept as data so a
# fallback chain can walk it when the preferred model is unavailable.
TOOL_CALL_CAPABLE_MODELS = (
    "deepseek/deepseek-v4-flash",
    "meta-llama/llama-3.3-70b-instruct",
    "qwen/qwen3-32b",
    "mistralai/mistral-small-2603",
    "minimax/minimax-m2.7",
    "moonshotai/kimi-k2.6",
)


class SupabaseAuthError(Exception):
    """A GoTrue login or refresh failed."""


class BackendModelError(Exception):
    """The backend returned an ``error`` frame or the transport died."""

    def __init__(self, detail: str, *, code: str | None = None) -> None:
        super().__init__(detail if code is None else f"[{code}] {detail}")
        self.detail = detail
        self.code = code


class _AuthRejected(Exception):
    """Internal: the ``/v2/ws`` handshake was rejected — retryable after a refresh."""


class _FirstFrameStalled(Exception):
    """Internal: the request was sent and the socket then said *nothing at all*
    for :attr:`BackendModelClient._first_frame_timeout` seconds.

    Never escapes :meth:`BackendModelClient.complete` — the retry it triggers
    runs with the first-frame budget disarmed, so a provider that is genuinely
    slow to produce its first byte is never cut off twice."""

    def __init__(self, waited_ms: float) -> None:
        super().__init__(f"no frame within {waited_ms:.0f} ms of the request")
        self.waited_ms = waited_ms


#: How long a sent request may produce *no frame of any kind* before the socket
#: is treated as dead. Armed at the instant ``ws.send`` of the chat frame
#: returns — the connection and the auth handshake are already done by then, so
#: this window contains only the backend's own dispatch plus the provider's
#: queue and prefill.
#:
#: 45 s is chosen from the live record: the median whole model call on this
#: account is under 7 s and a healthy 46k-token call streams its first byte in
#: a small number of seconds, so 45 s is ~6x the normal whole-call time and
#: cannot be tripped by prefill on a large prompt. It also sits below every
#: common load-balancer idle timeout (ALB 60 s, Cloudflare 100 s), so we notice
#: a dead socket on our own terms and log it, instead of being dropped silently
#: and late. Tunable per client — raise it for a provider that really does
#: queue longer.
DEFAULT_FIRST_FRAME_TIMEOUT = 45.0

#: The overall backstop: the whole stream must finish within this many seconds
#: of the request. Unchanged; the first-frame budget sits inside it.
DEFAULT_RECV_TIMEOUT = 180.0


# -- session / token holding --------------------------------------------------


def _gotrue(
    supabase_url: str,
    anon_key: str,
    grant_type: str,
    body: dict[str, Any],
    http_client: httpx.Client | None,
) -> dict[str, Any]:
    """POST to GoTrue's token endpoint. ``apikey`` is the anon key; the URL is the
    Supabase project — NEVER ``api.chuk.chat``."""
    url = f"{supabase_url.rstrip('/')}/auth/v1/token"
    client = http_client or httpx.Client(timeout=30.0)
    try:
        resp = client.post(
            url,
            params={"grant_type": grant_type},
            headers={"apikey": anon_key, "Content-Type": "application/json"},
            json=body,
        )
    finally:
        if http_client is None:
            client.close()
    if resp.status_code != 200:
        raise SupabaseAuthError(f"gotrue {grant_type} failed: {resp.status_code}")
    return resp.json()


def _access_token_expiry(access_token: str | None) -> float | None:
    """The ``exp`` claim of a JWT, as a POSIX timestamp, or None when the token
    is absent or does not carry one.

    The payload is read, not verified: this decides only when to refresh, and
    the relay and PostgREST still verify the signature. A token this cannot read
    is treated as one without a deadline.
    """
    if not isinstance(access_token, str) or access_token.count(".") != 2:
        return None
    payload = access_token.split(".")[1]
    payload += "=" * (-len(payload) % 4)
    try:
        claims = json.loads(base64.urlsafe_b64decode(payload))
    except Exception:  # noqa: BLE001 — an unreadable token simply has no deadline
        return None
    exp = claims.get("exp") if isinstance(claims, dict) else None
    if isinstance(exp, (int, float)) and not isinstance(exp, bool):
        return float(exp)
    return None


@dataclass
class SupabaseSession:
    """The authentication the executor holds: a token pair, refreshable directly
    against Supabase. NOT the login credentials."""

    access_token: str
    refresh_token: str
    supabase_url: str
    anon_key: str
    expires_at: float | None = None  # epoch seconds
    http_client: httpx.Client | None = None

    # -- who is allowed to refresh (bead cowork-c91) ------------------------
    # Supabase ROTATES the refresh token on every use. The app and the host held
    # the SAME pair, so whichever side refreshed killed the other's token; the
    # host then failed its next refresh with SupabaseAuthError and the task loop
    # died. Rule now: while a controller (the app) is attached, the APP is the
    # token source — the host never spends the refresh token itself; it asks the
    # app to re-provision (``request_reprovision``) and waits for the fresh pair
    # to be written into this object (``mark_reprovisioned``). Only with no
    # controller attached does the host refresh via GoTrue on its own, and then
    # it reports the rotated pair back through ``on_self_refreshed`` so the app
    # can adopt it (docs/WIRE_CONTRACT.md ``account_session_rotated``).
    # All three hooks are set by the host; standalone use (probes, tests) leaves
    # them None and refreshes directly, as before.
    may_self_refresh: Callable[[], bool] | None = field(default=None, repr=False, compare=False)
    request_reprovision: Callable[[str], None] | None = field(
        default=None, repr=False, compare=False
    )
    on_self_refreshed: Callable[["SupabaseSession"], None] | None = field(
        default=None, repr=False, compare=False
    )
    #: How long a refresh waits for the app's ``account_authentication`` frame
    #: before giving up with SupabaseAuthError (-> the task's error terminal).
    reprovision_timeout: float = 20.0
    # Single-flight: concurrent refreshers (the loop's client and the hero clone
    # share this session) serialize here, and a late-comer sees the fresh token
    # instead of spending a second, now-invalid refresh.
    _flight: threading.Lock = field(default_factory=threading.Lock, repr=False, compare=False)
    _cond: threading.Condition = field(
        default_factory=threading.Condition, repr=False, compare=False
    )
    _generation: int = field(default=0, repr=False, compare=False)

    @property
    def generation(self) -> int:
        """Bumped every time the pair changes (self-refresh or re-provision)."""
        return self._generation

    def mark_reprovisioned(self) -> None:
        """The host wrote a fresh pair into this object (a later
        ``account_authentication`` frame). Wakes every refresh waiting for it."""
        with self._cond:
            self._generation += 1
            self._cond.notify_all()

    def is_expired(self, *, skew: float = 30.0) -> bool:
        """True when the access token is expired (or within ``skew`` seconds of
        it).

        A caller that builds this session from a token frame may not pass
        ``expires_at`` — and a session that believes it never expires never
        refreshes. That is how a host ended up redialling the relay for a day
        with a dead JWT (bead cowork-fm8w): nothing was attached to tell it
        otherwise. So the deadline is read from the access token itself when the
        caller left it out. Only then, with neither, is the token assumed valid
        and the ``auth_error`` frame the backstop.
        """
        if self.expires_at is None:
            self.expires_at = _access_token_expiry(self.access_token)
        if self.expires_at is None:
            return False
        return time.time() >= (self.expires_at - skew)

    def refresh(
        self, *, reason: str = "token_expired", seen_token: str | None = None
    ) -> None:
        """Get a fresh access token — from the app when it is attached, from
        GoTrue only when it is not. Single-flight; see the field notes above.

        ``seen_token`` is the access token the caller just saw REJECTED. If it is
        no longer the current one, another refresher (the hero clone, a prior
        turn, the app's own re-provision) already replaced the pair and this call
        returns at once instead of spending a second refresh on a token that is
        not stale anymore. Without it, only refreshes that overlap are folded.

        Raises :class:`SupabaseAuthError` when the app does not re-provision
        within ``reprovision_timeout`` (attached) or GoTrue rejects the refresh
        (detached). The caller (``BackendModelClient.complete``) retries once
        after a successful refresh, so a refresh that returns means the retry
        carries a token that was just issued or just handed over.
        """
        entry = self._generation
        with self._flight:
            if self._generation != entry:
                return  # another refresher already replaced the pair while we waited
            if seen_token is not None and self.access_token != seen_token:
                return  # the token that failed is already gone; nothing to refresh
            if self.may_self_refresh is None or self.may_self_refresh():
                # Nobody attached (or standalone): the host is on its own. This
                # ROTATES the pair — GoTrue refresh tokens are single-use — so
                # the app's copy is now dead; report the new pair back to it.
                data = _gotrue(
                    self.supabase_url,
                    self.anon_key,
                    "refresh_token",
                    {"refresh_token": self.refresh_token},
                    self.http_client,
                )
                self._absorb(data)
                with self._cond:
                    self._generation += 1
                    self._cond.notify_all()
                if self.on_self_refreshed is not None:
                    try:
                        self.on_self_refreshed(self)
                    except Exception:  # noqa: BLE001 — reporting must not fail the refresh
                        pass
                return
            # The app is attached: it owns the token. Ask it and wait for the
            # fresh pair to land (``mark_reprovisioned``); do NOT touch GoTrue,
            # that would kill the app's token.
            if self.request_reprovision is not None:
                try:
                    self.request_reprovision(reason)
                except Exception:  # noqa: BLE001 — a failed ask still leaves the wait
                    pass
            deadline = time.monotonic() + self.reprovision_timeout
            with self._cond:
                while self._generation == entry:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        raise SupabaseAuthError(
                            f"the app did not re-provision within "
                            f"{self.reprovision_timeout:g}s ({reason})"
                        )
                    self._cond.wait(remaining)

    def _absorb(self, data: dict[str, Any]) -> None:
        token = data.get("access_token")
        if not token:
            raise SupabaseAuthError("gotrue response missing access_token")
        self.access_token = token
        # GoTrue rotates the refresh token; keep the old one only if none returned.
        self.refresh_token = data.get("refresh_token") or self.refresh_token
        expires_at = data.get("expires_at")
        if expires_at is not None:
            self.expires_at = float(expires_at)
        elif data.get("expires_in") is not None:
            self.expires_at = time.time() + float(data["expires_in"])


def login(
    email: str,
    password: str,
    *,
    supabase_url: str,
    anon_key: str,
    http_client: httpx.Client | None = None,
) -> SupabaseSession:
    """Bootstrap ONLY: trade email+password for a token pair, directly with
    Supabase GoTrue (never ``api.chuk.chat``). The steady state is token-only —
    after this call the credentials are dropped and only the returned session's
    tokens are used or persisted."""
    data = _gotrue(
        supabase_url,
        anon_key,
        "password",
        {"email": email, "password": password},
        http_client,
    )
    session = SupabaseSession(
        access_token="",
        refresh_token="",
        supabase_url=supabase_url,
        anon_key=anon_key,
        http_client=http_client,
    )
    session._absorb(data)
    if not session.refresh_token:
        session.refresh_token = data.get("refresh_token", "")
    return session


# -- model / provider resolution ---------------------------------------------


@dataclass
class ResolvedModel:
    model_id: str
    provider_slug: str


def fetch_models_info(
    session: SupabaseSession,
    *,
    base_url: str = DEFAULT_BASE_URL,
    http_client: httpx.Client | None = None,
) -> list[dict[str, Any]]:
    """GET ``/v1/models_info`` with the account token. Returns the raw model list
    (each entry: ``id``, ``name``, ``providers``:[{``slug``,``pricing``,...}], ...)."""
    client = http_client or httpx.Client(timeout=30.0)
    try:
        resp = client.get(
            f"{base_url.rstrip('/')}/v1/models_info",
            headers={"Authorization": f"Bearer {session.access_token}"},
        )
    finally:
        if http_client is None:
            client.close()
    resp.raise_for_status()
    data = resp.json()
    return [e for e in data if isinstance(e, dict)] if isinstance(data, list) else []


def _cheapest_provider(providers: list[dict]) -> str | None:
    """Pick the provider with the lowest completion price — the app's "Auto"
    preset (model_selection_dropdown.dart:599-614). Falls back to the first slug."""
    best_slug: str | None = None
    best_price = float("inf")
    first_slug: str | None = None
    for entry in providers:
        if not isinstance(entry, dict):
            continue
        slug = entry.get("slug")
        if not slug:
            continue
        if first_slug is None:
            first_slug = slug
        pricing = entry.get("pricing") or {}
        try:
            price = float(pricing.get("completion", 0.0) or 0.0)
        except (TypeError, ValueError):
            price = 0.0
        if price < best_price:
            best_price = price
            best_slug = slug
    return best_slug or first_slug


def resolve_model(
    models: list[dict[str, Any]],
    *,
    preferred_model_id: str | None = None,
    preferred_provider: str | None = None,
    default_model_id: str = DEFAULT_MODEL_ID,
) -> ResolvedModel:
    """Pick a (model_id, provider_slug) from a ``/v1/models_info`` list.

    Model: ``preferred_model_id`` if present, else ``default_model_id`` if present,
    else the first entry. Provider: ``preferred_provider`` if the model offers it,
    else the cheapest-by-completion provider.
    """
    if not models:
        raise BackendModelError("no models available from /v1/models_info")

    by_id = {m.get("id"): m for m in models if m.get("id")}
    chosen: dict[str, Any] | None = None
    for candidate in (preferred_model_id, default_model_id):
        if candidate and candidate in by_id:
            chosen = by_id[candidate]
            break
    if chosen is None:
        chosen = models[0]

    providers = chosen.get("providers") or []
    if not isinstance(providers, list) or not providers:
        raise BackendModelError(f"model {chosen.get('id')!r} has no providers")

    slug: str | None = None
    if preferred_provider:
        for entry in providers:
            if isinstance(entry, dict) and entry.get("slug") == preferred_provider:
                slug = preferred_provider
                break
    if slug is None:
        slug = _cheapest_provider(providers)
    if slug is None:
        raise BackendModelError(f"model {chosen.get('id')!r} has no usable provider")

    return ResolvedModel(model_id=chosen["id"], provider_slug=slug)


#: Every graded reasoning token the chat API knows, weakest to strongest. Only
#: the ORDER is fixed here; which tokens a model accepts is the catalogue's
#: ``supported_efforts`` list, never this ladder.
REASONING_LADDER: tuple[str, ...] = (
    "none", "minimal", "low", "medium", "high", "xhigh", "max",
)


def supported_efforts(models: list[dict[str, Any]], model_id: str) -> list[str]:
    """The catalogue's ``supported_efforts`` for ``model_id`` (empty when the
    model is unknown or the catalogue does not say)."""
    for entry in models:
        if entry.get("id") != model_id:
            continue
        raw = entry.get("supported_efforts") or entry.get("reasoning_supported_efforts")
        if isinstance(raw, list):
            return [e for e in raw if isinstance(e, str) and e]
        return []
    return []


def clamp_reasoning_effort(
    models: list[dict[str, Any]], model_id: str, effort: str | None
) -> str | None:
    """Clamp a requested ``reasoning_effort`` to what the catalogue says the
    model accepts.

    The backend answers a level a model does not support by simply sending no
    ``reasoning`` frames (proved live 2026-09-05: glm-5.3-flash accepts only
    low/high/max; ``medium`` gave zero thinking, ``high`` streamed it). So the
    host never forwards an unsupported level:

    - an exact match, an unknown model, or a catalogue without the list -> as is;
    - ``none`` on a model whose list has no ``none`` (reasoning mandatory) -> the
      weakest allowed level, because the server rejects "off" there;
    - ``on`` -> ``on`` when the model is binary, else the model's default effort
      when allowed, else ranked like ``medium``;
    - any other graded level -> the next STRONGER allowed level (``medium`` ->
      ``high``), else the strongest weaker one (-> ``low``), so the user's
      intent to think is honoured, never silently dropped.
    """
    if effort is None:
        return None
    allowed = supported_efforts(models, model_id)
    if not allowed or effort in allowed:
        return effort
    # A binary model (``none`` / ``on``): any intent to think is "on".
    if "on" in allowed and effort != "none":
        return "on"
    ranked = [e for e in allowed if e in REASONING_LADDER]
    if not ranked:
        return allowed[0]
    weakest = min(ranked, key=REASONING_LADDER.index)
    if effort == "none":
        return weakest
    want = effort
    if effort == "on":
        if "on" in allowed:
            return "on"
        default = _default_effort(models, model_id)
        if default in allowed:
            return default
        want = "medium"
    if want not in REASONING_LADDER:
        default = _default_effort(models, model_id)
        return default if default in allowed else weakest
    rank = REASONING_LADDER.index(want)
    stronger = [e for e in ranked if REASONING_LADDER.index(e) > rank]
    if stronger:
        return min(stronger, key=REASONING_LADDER.index)
    weaker = [e for e in ranked if REASONING_LADDER.index(e) < rank and e != "none"]
    if weaker:
        return max(weaker, key=REASONING_LADDER.index)
    return weakest


def _default_effort(models: list[dict[str, Any]], model_id: str) -> str | None:
    for entry in models:
        if entry.get("id") == model_id:
            value = entry.get("reasoning_default_effort")
            return value if isinstance(value, str) and value else None
    return None


# -- the /v2/ws model client --------------------------------------------------


def _ws_url_from_base(base_url: str) -> str:
    """`https://api.chuk.chat` -> `wss://api.chuk.chat/v2/ws` (matches
    multiplex_connection.dart:250-260)."""
    base = base_url.rstrip("/")
    if base.startswith("https://"):
        return "wss://" + base[len("https://") :] + "/v2/ws"
    if base.startswith("http://"):
        return "ws://" + base[len("http://") :] + "/v2/ws"
    if base.startswith(("ws://", "wss://")):
        return base + "/v2/ws"
    return "wss://" + base + "/v2/ws"


def _content_to_str(content: Any) -> str:
    """Coerce a stored message ``content`` (str or a tool-result dict) to the text
    the backend history carries."""
    if isinstance(content, str):
        return content
    if content is None:
        return ""
    return json.dumps(content, separators=(",", ":"))


def _wire_tool_call(call: dict) -> dict:
    """One stored assistant tool call as the backend's native OpenAI shape. The
    loop stores ``function.arguments`` as a dict (loop.py); on the wire it MUST be
    a JSON *string* (chuk_chat sends it pre-encoded) or the upstream 400s / sees
    empty args."""
    fn = call.get("function", {}) if isinstance(call, dict) else {}
    args = fn.get("arguments", {})
    if not isinstance(args, str):
        args = json.dumps(args, separators=(",", ":"))
    return {
        "id": str(call.get("id", "")),
        "type": "function",
        "function": {"name": str(fn.get("name", "")), "arguments": args},
    }


def _assistant_turn(message: dict) -> dict[str, Any]:
    """A stored assistant turn as a native history entry: its text (``None`` when
    the turn was tool-calls only, like chuk) plus any structured ``tool_calls``
    passed through in OpenAI shape — never flattened into text."""
    content = message.get("content")
    if isinstance(content, str) or content is None:
        text: str | None = content
    else:
        text = _content_to_str(content)
    turn: dict[str, Any] = {"role": "assistant", "content": text}
    calls = message.get("tool_calls") or []
    if calls:
        turn["tool_calls"] = [_wire_tool_call(c) for c in calls]
    return turn


def _native_calls_from_frame(data: list, offset: int) -> list[ToolCall]:
    """Parse a ``tool_calls`` frame (a list of OpenAI call objects) into
    :class:`ToolCall`. ``function.arguments`` is a JSON *string* on the wire;
    decode it defensively (providers emit malformed/truncated JSON — fall back to
    ``{}``). ``offset`` seeds a synthetic id for a call missing one, so a turn
    split across several frames keeps unique ids. The server's real ``id`` is kept
    when present — it must match the ``tool_call_id`` we echo back."""
    out: list[ToolCall] = []
    for i, call in enumerate(data):
        if not isinstance(call, dict):
            continue
        fn = call.get("function", {}) or {}
        raw_args = fn.get("arguments", "")
        if isinstance(raw_args, dict):
            args = raw_args
        elif isinstance(raw_args, str) and raw_args.strip():
            try:
                args = json.loads(raw_args)
            except json.JSONDecodeError:
                args = {}
        else:
            args = {}
        if not isinstance(args, dict):
            args = {}
        out.append(
            ToolCall(
                id=str(call.get("id") or f"call_{offset + i}"),
                name=str(fn.get("name") or ""),
                arguments=args,
            )
        )
    return out


class BackendModelClient:
    """A ``ModelClient`` backed by ``wss://api.chuk.chat/v2/ws``.

    One client owns one socket, reused across turns. The socket is (re)opened and
    authenticated lazily; a rejected handshake or an expired token triggers a
    single refresh + reconnect. Every ``complete`` consumes the account's credits
    server-side (tied to the JWT).
    """

    def __init__(
        self,
        session: SupabaseSession,
        *,
        model_id: str,
        provider_slug: str,
        base_url: str = DEFAULT_BASE_URL,
        max_tokens: int = 2048,
        temperature: float = 0.7,
        reasoning_effort: str | None = None,
        connect: Callable[..., Any] | None = None,
        auth_timeout: float = 15.0,
        recv_timeout: float = DEFAULT_RECV_TIMEOUT,
        first_frame_timeout: float | None = DEFAULT_FIRST_FRAME_TIMEOUT,
        token_gap_ms: float = DEFAULT_TOKEN_GAP_MS,
        clock: Callable[[], float] = time.monotonic,
        connection_pool: BackendConnectionPool | None = None,
    ) -> None:
        self._session = session
        self._model_id = model_id
        self._provider_slug = provider_slug
        self._ws_url = _ws_url_from_base(base_url)
        self._max_tokens = max_tokens
        self._temperature = temperature
        self._reasoning_effort = reasoning_effort
        self._connect = connect or _ws_connect
        self._auth_timeout = auth_timeout
        self._recv_timeout = recv_timeout
        # Two deadlines, not one (see DEFAULT_FIRST_FRAME_TIMEOUT): a short
        # budget for "the socket said nothing at all", and the long backstop for
        # the whole stream. ``None`` disables the short one.
        self._first_frame_timeout = first_frame_timeout
        self._token_gap_ms = token_gap_ms
        self._clock = clock
        # The live timing dict of the attempt in flight. Kept on the instance so
        # a call that DIES still has its first-frame / first-token numbers to
        # log — an error line without them is the line that tells you nothing.
        self._last_timing: dict[str, Any] = {}
        self._ws: Any | None = None
        self._connection_pool = connection_pool
        self._connection_key: tuple[str, str] | None = None
        self._reusable = False
        # Set by ``cancel`` so a socket we closed ourselves is not mistaken for a
        # dropped idle connection and retried.
        self._cancelled = False
        # Optional per-chunk callback: fired with each ``content`` delta as it
        # arrives off the wire, so the UI streams token-by-token instead of the
        # whole answer landing at ``done``. Settable by the executor's
        # StreamingModelClient. ``None`` -> no live streaming (the caller may fall
        # back to one delta at the end).
        self.on_delta: Callable[[str], None] | None = None
        # Same seam for the model's thinking: fired with each ``reasoning`` delta
        # as it arrives, so the UI streams the thinking block live instead of
        # the whole reasoning only landing in ``raw["reasoning"]`` at ``done``.
        # ``None`` -> reasoning is accumulated only (the caller may emit it once
        # at the end). Not copied by ``cheap_clone``: housekeeping turns run
        # with reasoning off and must never narrate into the thread.
        self.on_reasoning: Callable[[str], None] | None = None
        # The OpenAI-format ``tools`` array for native tool calling, or ``None``.
        # Set once per run by ``build_runtime`` via :meth:`set_tools` after the
        # registry is assembled. When present it is sent on every ``chat``
        # payload, which is what switches the backend into native function
        # calling (§ native tool calls); the server then streams a ``tool_calls``
        # frame. Deliberately NOT copied by ``cheap_clone`` — housekeeping turns
        # want no tools.
        self._tools: list[dict] | None = None

    @property
    def reasoning_effort(self) -> str | None:
        """The level this client sends on every ``chat`` payload (after any
        catalogue clamp by the executor's selector); ``None`` = server default."""
        return self._reasoning_effort

    # -- ModelClient -----------------------------------------------------

    def complete(self, messages: list[dict]) -> ModelResponse:
        clock = self._clock
        tracer = get_tracer()
        started = clock()
        payload = self._messages_to_payload(messages)
        prepared = clock()
        prompt_tokens_est = _estimate_payload_tokens(payload)
        # A cancel only applies to the call it interrupted. Clearing it here is
        # what lets one client serve the next task after a stopped one.
        self._cancelled = False
        self._received_output = False
        seen_token = self._session.access_token
        # Attempt bookkeeping (§ retry accounting). A thrown-away attempt is
        # paid for twice at the provider, so it is counted, timed and named —
        # never swallowed.
        attempts = 1
        retry_reason: str | None = None
        wasted_ms = 0.0
        attempt_started = clock()
        try:
            response = self._chat_once(payload, first_frame_timeout=self._first_frame_timeout)
        except _AuthRejected:
            if self._received_output:
                self._close()
                self._fail_record(
                    tracer, started, prepared, prompt_tokens_est, attempts,
                    retry_reason, wasted_ms, "stream_interrupted",
                )
                raise BackendModelError(
                    "Model stream interrupted after output; retry the turn explicitly",
                    code="stream_interrupted",
                ) from None
            # Token expired or the socket was rejected: get a fresh pair (from
            # the app while it is attached, from GoTrue otherwise — see
            # SupabaseSession.refresh), reconnect, retry once. ``seen_token``
            # folds the case where the pair was already replaced meanwhile.
            self._close()
            attempts += 1
            retry_reason = "auth_rejected"
            wasted_ms = (clock() - attempt_started) * 1000
            self._note_retry(tracer, retry_reason, wasted_ms, attempts, prompt_tokens_est)
            self._session.refresh(seen_token=seen_token)
            attempt_started = clock()
            response = self._chat_once(payload, first_frame_timeout=self._first_frame_timeout)
        except ConnectionClosed:
            if self._cancelled:
                # We closed this socket on purpose (§7.1 Stop). Retrying would
                # spend the account's credits on an answer nobody is waiting for.
                raise BackendModelError("cancelled", code="cancelled") from None
            if self._received_output:
                self._close()
                self._fail_record(
                    tracer, started, prepared, prompt_tokens_est, attempts,
                    retry_reason, wasted_ms, "stream_interrupted",
                )
                raise BackendModelError(
                    "Model stream interrupted after output; retry the turn explicitly",
                    code="stream_interrupted",
                ) from None
            # Idle socket dropped by an LB: reconnect and retry once.
            self._close()
            attempts += 1
            retry_reason = "connection_closed"
            wasted_ms = (clock() - attempt_started) * 1000
            self._note_retry(tracer, retry_reason, wasted_ms, attempts, prompt_tokens_est)
            attempt_started = clock()
            response = self._chat_once(payload, first_frame_timeout=self._first_frame_timeout)
        except _FirstFrameStalled as stalled:
            # Nothing at all came back inside the short budget. The socket looks
            # dead: reconnect and ask again — but with the first-frame budget
            # DISARMED, so a provider that really does need minutes for its
            # first byte still gets the full backstop on the second attempt and
            # this can never become a new way to fail a working run.
            self._close()
            attempts += 1
            retry_reason = "first_frame_stalled"
            wasted_ms = stalled.waited_ms
            self._note_retry(tracer, retry_reason, wasted_ms, attempts, prompt_tokens_est)
            attempt_started = clock()
            response = self._chat_once(payload, first_frame_timeout=None)
        timing = response.raw.setdefault("timing", {})
        timing["prepare_ms"] = (prepared - started) * 1000
        timing["total_ms"] = (clock() - started) * 1000
        # Part 2: the attempt count and why one was thrown away travel WITH the
        # response, so a caller (the loop, the run record) can bill it.
        timing["attempts"] = attempts
        timing["retry_reason"] = retry_reason
        timing["wasted_ms"] = wasted_ms
        record = self._call_record(
            timing, prompt_tokens_est, response.raw.get("usage"), ok=True, error_code=None
        )
        _log_model_call(record)
        if tracer.enabled:
            tracer.emit("model_call", **record)
        return response

    # -- observability ---------------------------------------------------

    def _note_retry(
        self,
        tracer: Any,
        reason: str,
        wasted_ms: float,
        attempt: int,
        prompt_tokens_est: int,
    ) -> None:
        """A thrown-away attempt is a cost signal, not only a latency one: the
        prompt is sent — and paid for — a second time."""
        logger.warning(
            "model call retried: reason=%s dead_attempt_ms=%.0f attempt=%d "
            "prompt_tokens_est=%d model=%s",
            reason, wasted_ms, attempt, prompt_tokens_est, self._model_id,
        )
        if tracer.enabled:
            tracer.emit(
                "retry",
                reason=reason,
                dead_ms=round(wasted_ms, 3),
                attempt=attempt,
                prompt_tokens_est=prompt_tokens_est,
                model=self._model_id,
            )

    def _fail_record(
        self,
        tracer: Any,
        started: float,
        prepared: float,
        prompt_tokens_est: int,
        attempts: int,
        retry_reason: str | None,
        wasted_ms: float,
        error_code: str,
    ) -> None:
        """The same line a successful call writes, for a call that died.

        The first-token time is exactly what separates "the model is slow" from
        "the socket stalled", so it must be on the error line too — that is the
        line someone reads when a turn failed after four minutes.
        """
        timing = dict(self._last_timing)
        timing["prepare_ms"] = (prepared - started) * 1000
        timing["total_ms"] = (self._clock() - started) * 1000
        timing["attempts"] = attempts
        timing["retry_reason"] = retry_reason
        timing["wasted_ms"] = wasted_ms
        record = self._call_record(
            timing, prompt_tokens_est, None, ok=False, error_code=error_code
        )
        _log_model_call(record)
        if tracer.enabled:
            tracer.emit("model_call", **record)

    def _call_record(
        self,
        timing: dict[str, Any],
        prompt_tokens_est: int,
        usage: dict | None,
        *,
        ok: bool,
        error_code: str | None,
    ) -> dict[str, Any]:
        """The ONE description of a finished model call. Built once and used
        twice — the info log line and the trace line — so the two can never
        drift apart."""
        usage = usage if isinstance(usage, dict) else {}
        first_frame = timing.get("first_frame_ms")
        first_content = timing.get("first_content_ms")
        first_reasoning = timing.get("first_reasoning_ms")
        # The earliest generated token of either kind. Reasoning tokens are
        # tokens: when they arrive first, they are the proof the provider has
        # started, so taking content alone would overstate the wait.
        first_token = _earliest(first_content, first_reasoning)
        record: dict[str, Any] = {
            "model": self._model_id,
            "provider": self._provider_slug,
            "ok": ok,
            "prepare_ms": _ms(timing.get("prepare_ms")),
            "connect_ms": _ms(timing.get("connection_ms")),
            "auth_ms": _ms(timing.get("auth_ms")),
            "first_frame_ms": _ms(first_frame),
            "first_reasoning_ms": _ms(first_reasoning),
            "first_content_ms": _ms(first_content),
            "first_token_ms": _ms(first_token),
            "stream_ms": _ms(timing.get("stream_ms")),
            "total_ms": _ms(timing.get("total_ms")),
            "attempts": int(timing.get("attempts") or 1),
            "retry_reason": timing.get("retry_reason"),
            "wasted_ms": _ms(timing.get("wasted_ms")),
            "prompt_tokens_est": prompt_tokens_est,
            "prompt_tokens": usage.get("prompt_tokens"),
            "completion_tokens": usage.get("completion_tokens"),
            "total_tokens": usage.get("total_tokens"),
        }
        if error_code:
            record["error_code"] = error_code
        # The backend reports its own timing block; keep it and fold it in
        # rather than shadowing it with our guess at the same number.
        server = timing.get("server")
        if isinstance(server, dict) and server:
            record["server"] = server
        return record

    def cheap_clone(self, *, max_tokens: int = 512) -> "BackendModelClient":
        """A "hero"/aux twin of this client: the SAME model, on the SAME account
        session, but with reasoning turned OFF and a smaller output cap (§7.3).

        This is what makes the default aux client cheap without a second model or
        a second login. The compaction summary and the mem0 fact-extraction are
        housekeeping, not the frontier thinking the run is paid for, so they run
        on the same model with ``reasoning_effort="none"`` — the weakest level the
        chat API accepts (the app's own "reasoning off"), which skips the reasoning
        pass entirely — and a 512-token output ceiling, since a summary is short.

        The **session object is shared** (``self._session``), so the token and its
        auto-refresh are the one already in use — no second GoTrue login. The clone
        still owns its own socket (opened lazily, like any client), because the two
        clients each run their own blocking ``recv`` loop and a shared socket would
        cross their frames; the backend endpoint, connector and timeouts are copied
        so the twin talks to exactly the same place.
        """
        clone = BackendModelClient(
            self._session,
            model_id=self._model_id,
            provider_slug=self._provider_slug,
            max_tokens=max_tokens,
            temperature=self._temperature,
            reasoning_effort="none",
            connect=self._connect,
            auth_timeout=self._auth_timeout,
            recv_timeout=self._recv_timeout,
            first_frame_timeout=self._first_frame_timeout,
            token_gap_ms=self._token_gap_ms,
            clock=self._clock,
            connection_pool=self._connection_pool,
        )
        # The base_url is not stored, only the derived ws url; copy it so a clone
        # of a non-default backend still points at that backend.
        clone._ws_url = self._ws_url
        return clone

    def cancel(self) -> None:
        """Abandon the turn in flight (§7.1): close the socket so the blocking
        ``recv`` returns at once instead of waiting out ``recv_timeout``.

        Called from the thread that pressed Stop, not from the one inside
        ``complete``. The reader then sees ``ConnectionClosed`` and, because
        ``_cancelled`` is set, fails the turn instead of reconnecting and asking
        the model the same question twice. The loop turns that failure into
        ``StopReason.INTERRUPTED`` because its kill switch is set.
        """
        self._cancelled = True
        self._close()

    def close(self) -> None:
        if self._connection_pool is not None and self._reusable and self._ws is not None:
            ws, self._ws = self._ws, None
            assert self._connection_key is not None
            self._connection_pool.put(self._connection_key, ws)
            self._reusable = False
        else:
            self._close()

    def set_tools(self, tools: list[dict] | None) -> None:
        """Declare the native tool set for this client (OpenAI ``tools`` JSON).

        Called once per run after the registry is built. ``None`` or ``[]`` sends
        no ``tools`` on the wire, so the model gets no tools at all — that is the
        housekeeping case (compaction, fact extraction), not a fallback protocol.
        Mirrors the settable ``on_delta`` seam so the executor's streaming
        wrappers can forward it to the inner client without knowing its concrete
        type.
        """
        self._tools = tools or None

    @property
    def traced_tools(self) -> list[dict] | None:
        """The ``tools`` array as it goes on the wire, for the trace's
        tool-schema token count. Read-only; the setter is :meth:`set_tools`."""
        return self._tools

    # -- payload mapping -------------------------------------------------

    def _messages_to_payload(self, messages: list[dict]) -> dict[str, Any]:
        system_prompt: str | None = None
        turns: list[dict[str, Any]] = []
        for message in messages:
            role = message.get("role")
            if role == "system":
                system_prompt = _content_to_str(message.get("content"))
                continue
            if role == "assistant":
                # Native pass-through: content + structured tool_calls (chuk shape).
                turns.append(_assistant_turn(message))
            elif role == "tool":
                # Native tool result: a role:"tool" turn keyed by tool_call_id, the
                # id the server issued for the matching assistant call. content is
                # a string (dict results are stringified) like chuk's sanitized
                # result. No more <tool_result> text folding.
                turns.append(
                    {
                        "role": "tool",
                        "tool_call_id": str(message.get("tool_call_id", "")),
                        "content": _content_to_str(message.get("content")),
                    }
                )
            else:
                turns.append({"role": "user", "content": _content_to_str(message.get("content"))})

        # The `message` field is the newest USER text. When we are looping after a
        # tool call the conversation ends with an assistant tool_calls turn and its
        # tool results — those stay in `history` and `message` is empty; the tool
        # results are the model's next input (chuk sends message:"" here). Only a
        # trailing user turn is lifted out as `message`.
        if turns and turns[-1].get("role") == "user":
            message_text = str(turns[-1].get("content", ""))
            history = turns[:-1]
        else:
            message_text = ""
            history = turns

        payload: dict[str, Any] = {
            "message": message_text,
            "model_id": self._model_id,
            "provider_slug": self._provider_slug,
            "max_tokens": self._max_tokens,
            "temperature": self._temperature,
        }
        if system_prompt:
            payload["system_prompt"] = system_prompt
        if history:
            payload["history"] = history
        if self._reasoning_effort is not None:
            payload["reasoning_effort"] = self._reasoning_effort
        # Presence of `tools` is what turns on native function calling upstream.
        if self._tools:
            payload["tools"] = self._tools
        return payload

    # -- transport -------------------------------------------------------

    def _ensure_connected(self, timing: dict[str, Any] | None = None) -> None:
        tracer = get_tracer()
        clock = self._clock
        if self._ws is not None:
            return
        if self._session.is_expired():
            self._session.refresh()
        self._connection_key = (self._ws_url, self._session.access_token)
        if self._connection_pool is not None:
            self._ws = self._connection_pool.take(self._connection_key)
            if self._ws is not None:
                if tracer.enabled:
                    tracer.emit("connect_open", ms=0.0, pooled=True)
                return
        if tracer.enabled:
            tracer.emit("connect_start", url=_redact_ws_url(self._ws_url))
        dial_started = clock()
        # Protocol pings maintain liveness during long-running tools without
        # spending model tokens. Make the library defaults explicit.
        ws = self._connect(self._ws_url, open_timeout=self._auth_timeout,
                           ping_interval=20, ping_timeout=20)
        opened = clock()
        if timing is not None:
            timing["connection_ms"] = (opened - dial_started) * 1000
        if tracer.enabled:
            tracer.emit("connect_open", ms=round((opened - dial_started) * 1000, 3), pooled=False)
        try:
            ws.send(json.dumps({"type": "auth", "token": self._session.access_token}))
            raw = ws.recv(timeout=self._auth_timeout)
        except (ConnectionClosed, TimeoutError) as exc:
            _safe_close(ws)
            raise _AuthRejected(str(exc)) from exc
        frame = _load_frame(raw)
        kind = frame.get("type")
        if kind == "auth_ok":
            self._ws = ws
            auth_ms = (clock() - opened) * 1000
            if timing is not None:
                timing["auth_ms"] = auth_ms
            if tracer.enabled:
                tracer.emit("auth_ok", ms=round(auth_ms, 3))
            return
        _safe_close(ws)
        if kind == "auth_error":
            raise _AuthRejected(frame.get("detail", "auth_error"))
        raise BackendModelError(f"unexpected handshake frame: {kind!r}")

    def _chat_once(
        self, payload: dict[str, Any], *, first_frame_timeout: float | None = None
    ) -> ModelResponse:
        clock = self._clock
        tracer = get_tracer()
        started = clock()
        timing: dict[str, Any] = {}
        self._last_timing = timing
        self._ensure_connected(timing)
        ws = self._ws
        assert ws is not None
        req_id = uuid.uuid4().hex
        blob = json.dumps({"req_id": req_id, "type": "chat", "payload": payload})
        timing.setdefault("connection_ms", (clock() - started) * 1000)
        self._reusable = False
        ws.send(blob)
        # The first-frame window starts HERE — the instant the request is fully
        # written to an already-open, already-authenticated socket. Everything
        # before it (dial, TLS, handshake) is timed separately above, and
        # everything after it is the backend plus the provider.
        sent = clock()
        if tracer.enabled:
            tracer.emit("request_sent", bytes=len(blob), tools=len(self._tools or ()))

        content_parts: list[str] = []
        reasoning_parts: list[str] = []
        native_calls: list[ToolCall] = []
        usage: dict | None = None
        meta: dict | None = None
        tps: float | None = None
        frames = 0
        first_frame_at: float | None = None
        last_frame_at = sent
        deadline = sent + self._recv_timeout
        first_deadline = (
            sent + first_frame_timeout if first_frame_timeout is not None else None
        )
        while True:
            now = clock()
            remaining = deadline - now
            if remaining <= 0:
                raise BackendModelError("timed out waiting for done", code="timeout")
            # Two budgets. Until the first frame of THIS request has landed the
            # short one applies; afterwards only the backstop does. A stream
            # that keeps sending frames — however slowly — is never cut off by
            # the short budget, because the budget is already disarmed.
            if first_deadline is not None:
                remaining = min(remaining, max(0.0, first_deadline - now))
                if remaining <= 0:
                    raise _FirstFrameStalled((now - sent) * 1000)
            try:
                raw = ws.recv(timeout=remaining)
            except TimeoutError:
                if first_deadline is not None and clock() >= first_deadline:
                    raise _FirstFrameStalled((clock() - sent) * 1000) from None
                raise BackendModelError(
                    "timed out waiting for done", code="timeout"
                ) from None
            frame = _load_frame(raw)
            if frame.get("type") == "pong":
                continue
            if frame.get("req_id") != req_id:
                continue
            frames += 1
            now = clock()
            if first_frame_at is None:
                first_frame_at = now
                # Disarm: the socket has spoken, so this request is being
                # served. Only the overall deadline governs from here.
                first_deadline = None
                timing["first_frame_ms"] = (now - sent) * 1000
                if tracer.enabled:
                    tracer.emit(
                        "first_frame",
                        kind=str(frame.get("kind") or ""),
                        ms=round(timing["first_frame_ms"], 3),
                    )
            kind = frame.get("kind")
            # Once generation has reached us it is no longer safe to replay
            # the prompt transparently: UI deltas cannot be rolled back and
            # the first request may already have incurred usage. Keep idle
            # socket recovery only for a connection with no model output.
            if kind in ("content", "reasoning", "tool_calls") and frame.get("data"):
                self._received_output = True
            if f"first_{kind}_ms" not in timing:
                timing[f"first_{kind}_ms"] = (now - sent) * 1000
                if tracer.enabled and kind in ("content", "reasoning"):
                    tracer.emit(
                        f"first_{kind}", ms=round(timing[f"first_{kind}_ms"], 3)
                    )
            gap_ms = (now - last_frame_at) * 1000
            last_frame_at = now
            if tracer.enabled and gap_ms >= self._token_gap_ms and frames > 1:
                tracer.emit("token_gap", kind=str(kind or ""), ms=round(gap_ms, 3))
            if kind == "content":
                data = frame.get("data")
                if isinstance(data, str):
                    content_parts.append(data)
                    # Live stream this chunk to the UI as it arrives.
                    if self.on_delta is not None and data:
                        try:
                            self.on_delta(data)
                        except Exception:  # noqa: BLE001 — a UI sink error must not abort the turn
                            pass
            elif kind == "reasoning":
                data = frame.get("data")
                if isinstance(data, str):
                    reasoning_parts.append(data)
                    # Live stream the thinking chunk to the UI as it arrives.
                    if self.on_reasoning is not None and data:
                        try:
                            self.on_reasoning(data)
                        except Exception:  # noqa: BLE001 — a UI sink error must not abort the turn
                            pass
            elif kind == "usage":
                data = frame.get("data")
                if isinstance(data, dict):
                    usage = data
                    if tracer.enabled:
                        tracer.emit(
                            "usage",
                            prompt_tokens=data.get("prompt_tokens"),
                            completion_tokens=data.get("completion_tokens"),
                            total_tokens=data.get("total_tokens"),
                        )
            elif kind == "tool_calls":
                # Native function calling: the server accumulates the provider's
                # streamed tool-call fragments and relays complete OpenAI calls
                # ({id,type,function:{name,arguments}}) in this frame. arguments is
                # a JSON *string* — parse it defensively (providers emit truncated
                # JSON). Several such frames may arrive; append, do not replace.
                data = frame.get("data")
                if isinstance(data, list):
                    native_calls.extend(_native_calls_from_frame(data, len(native_calls)))
            elif kind == "meta" and isinstance(frame.get("data"), dict):
                meta = frame["data"]
            elif kind == "tps" and isinstance(frame.get("data"), (int, float)):
                tps = frame["data"]
            elif kind == "timing" and isinstance(frame.get("data"), dict):
                timing["server"] = frame["data"]
            elif kind == "error":
                detail = str(frame.get("detail", "unknown error"))
                code = frame.get("code")
                code = str(code) if code is not None else None
                if _is_auth_code(code, detail):
                    raise _AuthRejected(detail)
                raise BackendModelError(detail, code=code)
            elif kind == "done":
                self._reusable = True
                break

        closed = clock()
        timing["stream_ms"] = (closed - (first_frame_at or sent)) * 1000
        timing["recv_ms"] = (closed - sent) * 1000
        content = "".join(content_parts)
        if tracer.enabled:
            tracer.emit(
                "stream_closed",
                ms=round(timing["stream_ms"], 3),
                frames=frames,
                content_chars=len(content),
                reasoning_chars=sum(len(p) for p in reasoning_parts),
                tool_calls=len(native_calls),
                tps=tps,
            )
        # Native tool calls are the ONE protocol, exactly like chuk_chat: a turn
        # is a tool-call turn only when the server sent a `tool_calls` frame, and
        # the content is then the assistant's (optional) interim text. With no
        # such frame the content is a bare-text final answer — it is never
        # scanned for an in-band call format.
        return ModelResponse(
            text=content.strip() or None,
            tool_calls=native_calls,
            raw={
                "content": content,
                "reasoning": "".join(reasoning_parts),
                "usage": usage,
                "native": bool(native_calls),
                "timing": timing,
                "meta": meta,
                "tps": tps,
            },
        )

    def _close(self) -> None:
        self._reusable = False
        if self._ws is not None:
            _safe_close(self._ws)
            self._ws = None


def _ms(value: Any) -> float | None:
    """Round a millisecond figure for a log/trace field; ``None`` stays ``None``
    so a missing measurement is visibly missing instead of a fake zero."""
    if value is None:
        return None
    try:
        return round(float(value), 3)
    except (TypeError, ValueError):
        return None


def _earliest(*values: Any) -> Any:
    present = [v for v in values if v is not None]
    return min(present) if present else None


def _estimate_payload_tokens(payload: dict[str, Any]) -> int:
    """A cheap prompt-size estimate for the log line: the serialised payload at
    ~4 characters per token. Deliberately not the ladder's estimator — this must
    cost nothing and must also cover the tool schemas, which are on the wire."""
    try:
        return len(json.dumps(payload, default=str)) // 4
    except (TypeError, ValueError):
        return 0


def _redact_ws_url(url: str) -> str:
    """Host + path only. A URL is not supposed to carry the token here, but a
    trace file must not be the place that proves otherwise."""
    head, _, _ = url.partition("?")
    return head


def _log_model_call(record: dict[str, Any]) -> None:
    """One info line per model call.

    ``first_token_ms`` is the field that separates "the model is slow" from
    "the socket stalled", so it is always present — including on a call that
    ended in an error, where it is the only thing that says how far the call
    got.
    """
    logger.info(
        "model call %s model=%s provider=%s attempts=%d retry=%s "
        "prepare_ms=%s connect_ms=%s first_frame_ms=%s first_token_ms=%s "
        "stream_ms=%s total_ms=%s wasted_ms=%s prompt_tokens=%s "
        "prompt_tokens_est=%d completion_tokens=%s",
        "ok" if record.get("ok") else f"failed[{record.get('error_code')}]",
        record.get("model"),
        record.get("provider"),
        record.get("attempts", 1),
        record.get("retry_reason") or "-",
        _fmt(record.get("prepare_ms")),
        _fmt(record.get("connect_ms")),
        _fmt(record.get("first_frame_ms")),
        _fmt(record.get("first_token_ms")),
        _fmt(record.get("stream_ms")),
        _fmt(record.get("total_ms")),
        _fmt(record.get("wasted_ms")),
        record.get("prompt_tokens") if record.get("prompt_tokens") is not None else "-",
        record.get("prompt_tokens_est", 0),
        record.get("completion_tokens") if record.get("completion_tokens") is not None else "-",
    )


def _fmt(value: Any) -> str:
    return "-" if value is None else f"{float(value):.0f}"


def _safe_close(ws: Any) -> None:
    try:
        ws.close()
    except Exception:
        pass


def _load_frame(raw: Any) -> dict[str, Any]:
    if isinstance(raw, bytes):
        raw = raw.decode("utf-8")
    try:
        data = json.loads(raw)
    except (json.JSONDecodeError, TypeError) as exc:
        raise BackendModelError(f"unparseable frame: {exc}") from exc
    if not isinstance(data, dict):
        raise BackendModelError("frame was not a JSON object")
    return data


def _is_auth_code(code: str | None, detail: str) -> bool:
    """Recognise an auth-rejected error frame (token expired mid-session) so the
    caller refreshes instead of failing the turn."""
    haystack = f"{code or ''} {detail}".lower()
    return any(k in haystack for k in ("auth", "token", "unauthor", "401", "expired"))


_ModelClientCheck: type[ModelClient] = BackendModelClient  # structural conformance
