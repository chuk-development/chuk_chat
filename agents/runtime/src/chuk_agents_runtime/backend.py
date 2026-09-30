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
- :class:`BackendModelClient` — what a task runs on: the session, the model,
  the provider pin and the reasoning effort. The agent loop reads it with
  :meth:`~BackendModelClient.chat_spec` and streams through Pydantic AI's
  ``OpenAIChatModel`` against ``POST /v1/chat/completions``
  (docs/PYDANTIC_AI_LOOP.md). Its own blocking :meth:`~BackendModelClient.complete`
  uses the same route, non-streaming, for the housekeeping calls (context
  summary, memory extraction, browser steps) and subagent children. Credits are
  consumed server-side, tied to the JWT.
- :func:`fetch_models_info` / :func:`resolve_model` — read ``/v1/models_info``
  with the token and pick a default model + provider slug.

The route (source of truth: api_server ``docs/openai_chat_completions.md``):
``Authorization: Bearer <access token>``; the OpenAI Chat Completions request
schema plus the ``provider`` extension (the old ``/v2/ws`` ``provider_slug``);
``reasoning_content`` carries the thinking; errors are the OpenAI error shape
``{"error": {"message", "type", "param", "code"}}``; ``401 invalid_api_key``
means the token is expired or invalid.
"""

from __future__ import annotations

import base64
import json
import logging
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from typing import Any

import httpx

from .model import ModelResponse, ToolCall
from .telemetry import get_tracer

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
    """A GoTrue login or refresh failed.

    ``status`` is GoTrue's HTTP status when it answered at all. A 400/401/403 on
    a refresh means the refresh token is dead for good; the host reads it to
    tell a dead credential from a network blip.
    """

    def __init__(self, message: str = "", *, status: int | None = None) -> None:
        super().__init__(message)
        self.status = status


class BackendModelError(Exception):
    """The backend returned an ``error`` frame or the transport died."""

    def __init__(self, detail: str, *, code: str | None = None) -> None:
        super().__init__(detail if code is None else f"[{code}] {detail}")
        self.detail = detail
        self.code = code


#: The whole-call backstop. The server holds the status for up to 30 s and
#: then keeps a slow stream alive; a housekeeping call is small.
DEFAULT_TIMEOUT = 600.0


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
        raise SupabaseAuthError(
            f"gotrue {grant_type} failed: {resp.status_code}", status=resp.status_code
        )
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
    #: Called with the error when a self-refresh against GoTrue fails, before
    #: it is raised. The host uses it to notice a dead refresh token at once,
    #: whoever triggered the refresh (a model call, the relay dial).
    on_refresh_failed: Callable[[Exception], None] | None = field(
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
                try:
                    data = _gotrue(
                        self.supabase_url,
                        self.anon_key,
                        "refresh_token",
                        {"refresh_token": self.refresh_token},
                        self.http_client,
                    )
                except Exception as exc:
                    if self.on_refresh_failed is not None:
                        try:
                            self.on_refresh_failed(exc)
                        except Exception:  # noqa: BLE001 — a listener must not mask the error
                            pass
                    raise
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


def _error_code(exc: Exception) -> tuple[str, str | None]:
    """A model error as ``(message, code)``: the route's OpenAI error body
    when there is one, the status or the exception name otherwise."""
    body = getattr(exc, "body", None)
    status = getattr(exc, "status_code", None)
    if isinstance(body, dict):
        error = body.get("error") if isinstance(body.get("error"), dict) else body
        message = str(error.get("message") or exc)
        code = error.get("code") or (str(status) if status else None)
        return message, code
    return str(exc), (str(status) if status else type(exc).__name__)


class BackendModelClient:
    """What one task runs on, and a blocking client for the housekeeping calls.

    The agent loop streams through Pydantic AI (``chat_spec()`` -> the stock
    ``OpenAIChatModel``, docs/PYDANTIC_AI_LOOP.md); the executor's streaming
    wrapper sets ``on_delta`` / ``on_reasoning`` here and the loop takes them
    over. :meth:`complete` is the blocking path for the rest — the context
    summary, the memory extraction, a browser step, a subagent child — through
    the same model and the same auth (:class:`~chuk_agents_runtime.pai.model.SupabaseJwtAuth`:
    an expired token is refreshed first, a ``401`` refreshes once and retries).
    There is one wire implementation for every model call: Pydantic AI's.
    """

    def __init__(
        self,
        session: SupabaseSession,
        *,
        model_id: str,
        provider_slug: str | None = None,
        base_url: str = DEFAULT_BASE_URL,
        max_tokens: int | None = None,
        temperature: float | None = None,
        reasoning_effort: str | None = None,
        transport: Any = None,
        timeout: float = DEFAULT_TIMEOUT,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self._session = session
        self._model_id = model_id
        self._provider_slug = provider_slug
        self._base_url = base_url.rstrip("/")
        self._max_tokens = max_tokens
        self._temperature = temperature
        self._reasoning_effort = reasoning_effort
        #: An ``httpx2`` transport, for tests only (a ``MockTransport``).
        self._transport = transport
        self._timeout = timeout
        self._clock = clock
        self._lock = threading.Lock()
        self._inflight: tuple[Any, Any] | None = None
        self._cancelled = False
        # The executor's streaming wrapper sets these; the agent loop takes
        # them over as its delta / reasoning sinks. ``complete`` fires them
        # once per call, with the whole text.
        self.on_delta: Callable[[str], None] | None = None
        self.on_reasoning: Callable[[str], None] | None = None
        self._tools: list[dict] | None = None

    @property
    def reasoning_effort(self) -> str | None:
        """The level this client asks for (after any catalogue clamp by the
        executor's selector); ``None`` = the server default."""
        return self._reasoning_effort

    def chat_spec(self) -> dict[str, Any]:
        """What this client runs on, for the agent loop's streaming model
        (``chuk_agents_runtime.pai.wiring``)."""
        return {
            "session": self._session,
            "model_id": self._model_id,
            "provider_slug": self._provider_slug,
            "reasoning_effort": self._reasoning_effort,
            "base_url": self._base_url,
        }

    # -- ModelClient -----------------------------------------------------

    def complete(self, messages: list[dict]) -> ModelResponse:
        import asyncio

        started = self._clock()
        loop = asyncio.new_event_loop()
        task = loop.create_task(self._request(messages))
        with self._lock:
            # A Stop that landed before this call was published is not lost:
            # the cancel is sticky for this client (one client per task).
            if self._cancelled:
                task.cancel()
            self._inflight = (loop, task)
        try:
            reply = loop.run_until_complete(task)
        except asyncio.CancelledError:
            self._record(started, None, error_code="cancelled")
            raise BackendModelError("cancelled", code="cancelled") from None
        except Exception as exc:  # noqa: BLE001 — every model failure is one error type
            auth = _auth_error_in(exc)
            if auth is not None or getattr(exc, "status_code", None) == 401:
                self._record(started, None, error_code="auth")
                raise auth or SupabaseAuthError(_error_code(exc)[0], status=401) from exc
            message, code = _error_code(exc)
            self._record(started, None, error_code=code or "error")
            raise BackendModelError(message, code=code) from exc
        finally:
            with self._lock:
                self._inflight = None
            loop.close()
        return self._to_response(reply, started)

    async def _request(self, messages: list[dict]) -> Any:
        from pydantic_ai.direct import model_request
        from pydantic_ai.models import ModelRequestParameters
        from pydantic_ai.tools import ToolDefinition

        from .pai.convert import rows_to_messages
        from .pai.model import ChukModelSpec, chuk_chat_model

        model, settings = chuk_chat_model(
            self._session,
            ChukModelSpec(
                model_id=self._model_id,
                provider_slug=self._provider_slug,
                reasoning_effort=self._reasoning_effort,
                max_tokens=self._max_tokens,
                temperature=self._temperature,
            ),
            base_url=self._base_url,
            transport=self._transport,
            timeout=self._timeout,
        )
        tools = [
            ToolDefinition(
                name=t["function"]["name"],
                description=t["function"].get("description") or "",
                parameters_json_schema=t["function"].get("parameters")
                or {"type": "object", "properties": {}},
                strict=False,
            )
            for t in (self._tools or [])
            if isinstance(t, dict) and isinstance(t.get("function"), dict)
        ]
        try:
            return await model_request(
                model,
                rows_to_messages(messages),
                model_settings=settings,
                model_request_parameters=ModelRequestParameters(
                    function_tools=tools, allow_text_output=True
                ),
            )
        finally:
            await model.client.close()

    def _to_response(self, reply: Any, started: float) -> ModelResponse:
        from pydantic_ai.messages import TextPart, ThinkingPart, ToolCallPart

        text = "".join(p.content for p in reply.parts if isinstance(p, TextPart)).strip()
        reasoning = "".join(p.content for p in reply.parts if isinstance(p, ThinkingPart) and p.content)
        calls = [
            ToolCall(id=p.tool_call_id, name=p.tool_name, arguments=_safe_args(p))
            for p in reply.parts
            if isinstance(p, ToolCallPart)
        ]
        usage = None
        if reply.usage.input_tokens or reply.usage.output_tokens:
            usage = {
                "prompt_tokens": reply.usage.input_tokens,
                "completion_tokens": reply.usage.output_tokens,
                "total_tokens": reply.usage.input_tokens + reply.usage.output_tokens,
            }
        timing = self._record(started, usage, error_code=None)
        if reasoning and self.on_reasoning is not None:
            _safe_sink(self.on_reasoning, reasoning)
        if text and self.on_delta is not None:
            _safe_sink(self.on_delta, text)
        return ModelResponse(
            text=text or None,
            tool_calls=calls,
            raw={
                "content": text,
                "reasoning": reasoning,
                "usage": usage,
                "timing": timing,
                "finish_reason": reply.finish_reason,
            },
        )

    def _record(self, started: float, usage: dict | None, *, error_code: str | None) -> dict[str, Any]:
        """The one description of a finished call: the info log line, the
        trace line and the ``timing`` the loop reads. A token refresh after a
        ``401`` has its own ``retry`` trace line (``SupabaseJwtAuth``)."""
        total_ms = (self._clock() - started) * 1000
        usage = usage or {}
        record: dict[str, Any] = {
            "model": self._model_id,
            "provider": self._provider_slug,
            "ok": error_code is None,
            "first_frame_ms": _ms(total_ms),
            "stream_ms": 0.0,
            "total_ms": _ms(total_ms),
            "attempts": 1,
            "prompt_tokens": usage.get("prompt_tokens"),
            "completion_tokens": usage.get("completion_tokens"),
            "total_tokens": usage.get("total_tokens"),
        }
        if error_code:
            record["error_code"] = error_code
        _log_model_call(record)
        tracer = get_tracer()
        if tracer.enabled:
            tracer.emit("model_call", **record)
        return {"total_ms": total_ms, "attempts": 1}

    # -- clones, tools, lifecycle ------------------------------------------

    def cheap_clone(self, *, max_tokens: int = 512) -> "BackendModelClient":
        """The same model on the same session, reasoning off and a small
        output cap: the housekeeping client (context summary, memory
        extraction) that must not spend frontier thinking."""
        return BackendModelClient(
            self._session,
            model_id=self._model_id,
            provider_slug=self._provider_slug,
            base_url=self._base_url,
            max_tokens=max_tokens,
            reasoning_effort="none",
            transport=self._transport,
            timeout=self._timeout,
            clock=self._clock,
        )

    def cancel(self) -> None:
        """Abandon the call in flight (§7.1), from the thread that pressed
        Stop: the request task is cancelled on its own event loop, so the
        blocking :meth:`complete` returns at once with ``cancelled``. Sticky:
        a call that starts after this is cancelled before it sends anything."""
        with self._lock:
            self._cancelled = True
            inflight = self._inflight
        if inflight is not None:
            loop, task = inflight
            try:
                loop.call_soon_threadsafe(task.cancel)
            except RuntimeError:  # the loop already closed: nothing in flight
                pass

    def close(self) -> None:
        """Nothing is held between calls (each call opens and closes its own
        client), so there is nothing to release."""

    def set_tools(self, tools: list[dict] | None) -> None:
        """The OpenAI ``tools`` array for :meth:`complete` (``None`` / ``[]``:
        no tools — the housekeeping case)."""
        self._tools = tools or None

    @property
    def traced_tools(self) -> list[dict] | None:
        return self._tools


def _auth_error_in(exc: BaseException) -> SupabaseAuthError | None:
    """A failed token refresh inside the HTTP stack arrives wrapped (the SDK
    reports it as a connection error); find it in the cause chain."""
    seen: set[int] = set()
    current: BaseException | None = exc
    while current is not None and id(current) not in seen:
        if isinstance(current, SupabaseAuthError):
            return current
        seen.add(id(current))
        current = current.__cause__ or current.__context__
    return None


def _safe_args(part: Any) -> dict:
    try:
        args = part.args_as_dict()
    except Exception:  # noqa: BLE001 — bad JSON from the model is an empty call
        return {}
    if not isinstance(args, dict) or set(args) == {"INVALID_JSON"}:
        return {}
    return args


def _safe_sink(sink: Callable[[str], None], text: str) -> None:
    try:
        sink(text)
    except Exception:  # noqa: BLE001 — a UI sink must not fail the call
        pass


def _ms(value: Any) -> float | None:
    """Round a millisecond figure for a log/trace field; ``None`` stays ``None``
    so a missing measurement is visibly missing instead of a fake zero."""
    if value is None:
        return None
    try:
        return round(float(value), 3)
    except (TypeError, ValueError):
        return None


def _log_model_call(record: dict[str, Any]) -> None:
    """One info line per model call.

    Written for a call that failed too: the error line is the one someone
    reads when a turn failed after minutes.
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


