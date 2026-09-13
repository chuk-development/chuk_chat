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
        recv_timeout: float = 180.0,
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
        started = time.monotonic()
        payload = self._messages_to_payload(messages)
        prepared = time.monotonic()
        # A cancel only applies to the call it interrupted. Clearing it here is
        # what lets one client serve the next task after a stopped one.
        self._cancelled = False
        self._received_output = False
        seen_token = self._session.access_token
        try:
            response = self._chat_once(payload)
        except _AuthRejected:
            if self._received_output:
                self._close()
                raise BackendModelError(
                    "Model stream interrupted after output; retry the turn explicitly",
                    code="stream_interrupted",
                ) from None
            # Token expired or the socket was rejected: get a fresh pair (from
            # the app while it is attached, from GoTrue otherwise — see
            # SupabaseSession.refresh), reconnect, retry once. ``seen_token``
            # folds the case where the pair was already replaced meanwhile.
            self._close()
            self._session.refresh(seen_token=seen_token)
            response = self._chat_once(payload)
        except ConnectionClosed:
            if self._cancelled:
                # We closed this socket on purpose (§7.1 Stop). Retrying would
                # spend the account's credits on an answer nobody is waiting for.
                raise BackendModelError("cancelled", code="cancelled") from None
            if self._received_output:
                self._close()
                raise BackendModelError(
                    "Model stream interrupted after output; retry the turn explicitly",
                    code="stream_interrupted",
                ) from None
            # Idle socket dropped by an LB: reconnect and retry once.
            self._close()
            response = self._chat_once(payload)
        timing = response.raw.setdefault("timing", {})
        timing["prepare_ms"] = (prepared - started) * 1000
        timing["total_ms"] = (time.monotonic() - started) * 1000
        return response

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

    def _ensure_connected(self) -> None:
        if self._ws is not None:
            return
        if self._session.is_expired():
            self._session.refresh()
        self._connection_key = (self._ws_url, self._session.access_token)
        if self._connection_pool is not None:
            self._ws = self._connection_pool.take(self._connection_key)
            if self._ws is not None:
                return
        # Protocol pings maintain liveness during long-running tools without
        # spending model tokens. Make the library defaults explicit.
        ws = self._connect(self._ws_url, open_timeout=self._auth_timeout,
                           ping_interval=20, ping_timeout=20)
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
            return
        _safe_close(ws)
        if kind == "auth_error":
            raise _AuthRejected(frame.get("detail", "auth_error"))
        raise BackendModelError(f"unexpected handshake frame: {kind!r}")

    def _chat_once(self, payload: dict[str, Any]) -> ModelResponse:
        started = time.monotonic()
        self._ensure_connected()
        ws = self._ws
        assert ws is not None
        req_id = uuid.uuid4().hex
        sent = time.monotonic()
        timing: dict[str, Any] = {"connection_ms": (sent - started) * 1000}
        self._reusable = False
        ws.send(json.dumps({"req_id": req_id, "type": "chat", "payload": payload}))

        content_parts: list[str] = []
        reasoning_parts: list[str] = []
        native_calls: list[ToolCall] = []
        usage: dict | None = None
        meta: dict | None = None
        tps: float | None = None
        deadline = time.monotonic() + self._recv_timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise BackendModelError("timed out waiting for done", code="timeout")
            raw = ws.recv(timeout=remaining)
            frame = _load_frame(raw)
            if frame.get("type") == "pong":
                continue
            if frame.get("req_id") != req_id:
                continue
            kind = frame.get("kind")
            # Once generation has reached us it is no longer safe to replay
            # the prompt transparently: UI deltas cannot be rolled back and
            # the first request may already have incurred usage. Keep idle
            # socket recovery only for a connection with no model output.
            if kind in ("content", "reasoning", "tool_calls") and frame.get("data"):
                self._received_output = True
            timing.setdefault(f"first_{kind}_ms", (time.monotonic() - sent) * 1000)
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

        content = "".join(content_parts)
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
