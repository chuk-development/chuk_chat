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
- :class:`BackendModelClient` — a :class:`~cowork_agent.model.ModelClient` that
  drives ``wss://api.chuk.chat/v2/ws``: auth handshake with the access token,
  chat request, accumulate the streamed ``content``/``reasoning``, surface
  ``error``, end on ``done``. Credits are consumed server-side, tied to the JWT.
  Tool calls are parsed from the assistant *content* as ``<tool_call>`` blocks —
  the one wire format, via :func:`~cowork_agent.model.extract_tool_calls`.
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
  ``data`` (string), ``usage``/``meta`` carry ``data`` (object), ``tps`` a number,
  ``error`` carries ``detail``+``code``, ``done`` closes the stream
  (multiplex_connection.dart:289-368).
- payload fields: ``message``, ``model_id``, ``provider_slug``, ``max_tokens``,
  ``temperature``, optional ``system_prompt``, ``history``, ``reasoning_effort``
  (websocket_chat_service.dart:101-124).
"""

from __future__ import annotations

import json
import time
import uuid
from collections.abc import Callable
from dataclasses import dataclass, field
from typing import Any

import httpx
from websockets.exceptions import ConnectionClosed
from websockets.sync.client import connect as _ws_connect

from .model import ModelClient, ModelResponse, extract_tool_calls

# The single default backend. Callers may override.
DEFAULT_BASE_URL = "https://api.chuk.chat"
# The default model. It MUST be one whose tool calls survive the backend, which
# streams only `content` + `reasoning` and drops anything the provider parsed
# into structured `tool_calls`. Measured live (tests/live_sweep.py):
#
#   works: deepseek-v4-flash, qwen3-32b, kimi-k2.6, minimax-m2.7,
#          llama-3.3-70b, mistral-small-2603
#   silent: gpt-oss-20b/120b (Harmony channels), qwen3.5/3.6-35b-a3b (content
#           comes back empty), glm-5.1 (its own arg-key format)
#
# gpt-oss-20b was the old default and is exactly the failure the user hit: the
# model says "I'll use write_file" in its reasoning and then prints the file.
# Cheapest of the working set, and it emits the block reliably.
DEFAULT_MODEL_ID = "deepseek/deepseek-v4-flash"

# Models proven to emit a parseable `<tool_call>` block, cheapest first. Kept as
# data so a fallback chain can walk it when the preferred model is unavailable.
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

    def is_expired(self, *, skew: float = 30.0) -> bool:
        """True when the access token is expired (or within ``skew`` seconds of
        it). No ``expires_at`` -> assume valid; an ``auth_error`` frame is the
        backstop."""
        if self.expires_at is None:
            return False
        return time.time() >= (self.expires_at - skew)

    def refresh(self) -> None:
        """Mint a new access token from the refresh token via GoTrue. Rotates the
        refresh token too (GoTrue single-use refresh tokens)."""
        data = _gotrue(
            self.supabase_url,
            self.anon_key,
            "refresh_token",
            {"refresh_token": self.refresh_token},
            self.http_client,
        )
        self._absorb(data)

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


def _assistant_text(message: dict) -> str:
    """Reconstruct an assistant turn as canonical text: its content plus any
    structured tool calls re-serialised as ``<tool_call>`` blocks, so the backend
    model sees its own prior calls in the one wire format."""
    parts: list[str] = []
    content = message.get("content")
    if isinstance(content, str) and content:
        parts.append(content)
    for call in message.get("tool_calls") or []:
        fn = call.get("function", {}) if isinstance(call, dict) else {}
        name = fn.get("name")
        args = fn.get("arguments", {})
        if name:
            parts.append(
                "<tool_call>"
                + json.dumps({"name": name, "arguments": args}, separators=(",", ":"))
                + "</tool_call>"
            )
    return "\n".join(parts)


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
        # Set by ``cancel`` so a socket we closed ourselves is not mistaken for a
        # dropped idle connection and retried.
        self._cancelled = False

    # -- ModelClient -----------------------------------------------------

    def complete(self, messages: list[dict]) -> ModelResponse:
        payload = self._messages_to_payload(messages)
        # A cancel only applies to the call it interrupted. Clearing it here is
        # what lets one client serve the next task after a stopped one.
        self._cancelled = False
        try:
            return self._chat_once(payload)
        except _AuthRejected:
            # Token expired or the socket was rejected: refresh, reconnect, retry once.
            self._close()
            self._session.refresh()
            return self._chat_once(payload)
        except ConnectionClosed:
            if self._cancelled:
                # We closed this socket on purpose (§7.1 Stop). Retrying would
                # spend the account's credits on an answer nobody is waiting for.
                raise BackendModelError("cancelled", code="cancelled") from None
            # Idle socket dropped by an LB: reconnect and retry once.
            self._close()
            return self._chat_once(payload)

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
        self._close()

    # -- payload mapping -------------------------------------------------

    def _messages_to_payload(self, messages: list[dict]) -> dict[str, Any]:
        system_prompt: str | None = None
        turns: list[dict[str, str]] = []
        for message in messages:
            role = message.get("role")
            if role == "system":
                system_prompt = _content_to_str(message.get("content"))
                continue
            if role == "assistant":
                turns.append({"role": "assistant", "content": _assistant_text(message)})
            elif role == "tool":
                # Fold the tool result into a text turn the model can read back.
                name = message.get("name", "tool")
                turns.append(
                    {
                        "role": "tool",
                        "content": f"<tool_result name=\"{name}\">"
                        + _content_to_str(message.get("content"))
                        + "</tool_result>",
                    }
                )
            else:
                turns.append({"role": "user", "content": _content_to_str(message.get("content"))})

        message_text = turns[-1]["content"] if turns else ""
        history = turns[:-1]

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
        return payload

    # -- transport -------------------------------------------------------

    def _ensure_connected(self) -> None:
        if self._ws is not None:
            return
        if self._session.is_expired():
            self._session.refresh()
        ws = self._connect(self._ws_url, open_timeout=self._auth_timeout)
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
        self._ensure_connected()
        ws = self._ws
        assert ws is not None
        req_id = uuid.uuid4().hex
        ws.send(json.dumps({"req_id": req_id, "type": "chat", "payload": payload}))

        content_parts: list[str] = []
        reasoning_parts: list[str] = []
        usage: dict | None = None
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
            if kind == "content":
                data = frame.get("data")
                if isinstance(data, str):
                    content_parts.append(data)
            elif kind == "reasoning":
                data = frame.get("data")
                if isinstance(data, str):
                    reasoning_parts.append(data)
            elif kind == "usage":
                data = frame.get("data")
                if isinstance(data, dict):
                    usage = data
            elif kind in ("meta", "tps"):
                continue
            elif kind == "error":
                detail = str(frame.get("detail", "unknown error"))
                code = frame.get("code")
                code = str(code) if code is not None else None
                if _is_auth_code(code, detail):
                    raise _AuthRejected(detail)
                raise BackendModelError(detail, code=code)
            elif kind == "done":
                break

        content = "".join(content_parts)
        clean, tool_calls = extract_tool_calls(content)
        return ModelResponse(
            text=clean or None,
            tool_calls=tool_calls,
            raw={
                "content": content,
                "reasoning": "".join(reasoning_parts),
                "usage": usage,
            },
        )

    def _close(self) -> None:
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
