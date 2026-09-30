"""Model access for the Pydantic AI loop (docs/PYDANTIC_AI_LOOP.md, section 5).

Two ways to get a :class:`pydantic_ai.models.Model`:

- :func:`chuk_chat_model` — the production path. The stock
  :class:`~pydantic_ai.models.openai.OpenAIChatModel` against the
  OpenAI-compatible ``POST /v1/chat/completions`` route of ``api.chuk.chat``.
  The bearer is the Supabase access token of the account session, set per
  request by :class:`SupabaseJwtAuth`, so a token that expires in the middle of
  a long run is refreshed before the next request and never baked into a
  client. The thinking arrives as ``delta.reasoning_content`` and Pydantic AI
  turns it into ``ThinkingPart`` deltas by itself.
- :class:`LegacyClientModel` — any blocking :class:`~chuk_agents_runtime.model.ModelClient`
  (the scripted ``MockModelClient`` of the tests, a subagent child's wrapper)
  behind the Pydantic AI model interface. The client keeps its own callbacks
  (``on_delta`` / ``on_reasoning``), so the loop does not map stream events for
  it.

No provider key ever lives here: the only credential is the account JWT.
"""

from __future__ import annotations

import json
import logging
import time
from collections.abc import AsyncGenerator, Callable, Generator
from dataclasses import dataclass, field
from typing import Any

import anyio
import httpx2
from pydantic_ai.messages import (
    ModelMessage,
    ModelResponse,
    TextPart,
    ThinkingPart,
    ToolCallPart,
)
from pydantic_ai.models import Model
from pydantic_ai.models.function import AgentInfo, FunctionModel
from pydantic_ai.models.openai import OpenAIChatModel, OpenAIChatModelSettings
from pydantic_ai.profiles.openai import OpenAIModelProfile
from pydantic_ai.providers.openai import OpenAIProvider
from pydantic_ai.tools import ToolDefinition
from pydantic_ai.usage import RequestUsage

from . import disable_banner
from ..model import ModelClient
from ..model import ModelResponse as LegacyResponse
from .convert import messages_to_rows

logger = logging.getLogger(__name__)

#: The OpenAI-compatible route of the account proxy. ``/v1`` is part of the
#: base URL; the OpenAI SDK appends ``/chat/completions``.
DEFAULT_OPENAI_PATH = "/v1"

#: Key under ``ModelResponse.provider_details`` that carries what only the
#: legacy client knows: the raw usage dict, the retry timing and the
#: housekeeping flag. The loop reads it for the iteration refund, the token
#: budget and the run timings.
LEGACY_DETAILS_KEY = "chuk_legacy"


# -- the JWT -------------------------------------------------------------------


class SupabaseJwtAuth(httpx2.Auth):
    """Sets ``Authorization: Bearer <access token>`` on every request.

    ``session`` is duck-typed on :class:`~chuk_agents_runtime.backend.SupabaseSession`:
    ``access_token``, ``is_expired()`` and ``refresh(reason=, seen_token=)``.
    The refresh is blocking (it may wait for the app to re-provision the
    token), so it runs on a worker thread and never stalls the event loop.

    - Before a request: an expired token is refreshed first.
    - After a ``401``: the token that was rejected is refreshed once and the
      request is sent again. ``seen_token`` makes the refresh a no-op when
      another caller already replaced the pair.
    """

    def __init__(self, session: Any) -> None:
        self._session = session

    def _bearer(self, request: httpx2.Request) -> str:
        token = str(self._session.access_token or "")
        request.headers["Authorization"] = f"Bearer {token}"
        return token

    def sync_auth_flow(
        self, request: httpx2.Request
    ) -> Generator[httpx2.Request, httpx2.Response, None]:
        if self._session.is_expired():
            self._session.refresh(reason="token_expired")
        token = self._bearer(request)
        response = yield request
        if response.status_code == 401:
            _trace_auth_retry()
            self._session.refresh(reason="auth_rejected", seen_token=token)
            self._bearer(request)
            yield request

    async def async_auth_flow(
        self, request: httpx2.Request
    ) -> AsyncGenerator[httpx2.Request, httpx2.Response]:
        session = self._session
        if await anyio.to_thread.run_sync(session.is_expired):
            await anyio.to_thread.run_sync(
                lambda: session.refresh(reason="token_expired")
            )
        token = self._bearer(request)
        response = yield request
        if response.status_code == 401:
            await response.aread()
            _trace_auth_retry()
            await anyio.to_thread.run_sync(
                lambda: session.refresh(reason="auth_rejected", seen_token=token)
            )
            self._bearer(request)
            yield request


def _trace_auth_retry() -> None:
    """A request the route rejected is sent twice; the second one is a cost
    and a latency the run trace names (``retry``, ``auth_rejected``)."""
    from ..telemetry import get_tracer

    logger.warning("model call retried: reason=auth_rejected")
    tracer = get_tracer()
    if tracer.enabled:
        tracer.emit("retry", reason="auth_rejected", attempt=2)


# -- the production model ----------------------------------------------------


@dataclass
class ChukModelSpec:
    """What a task runs on: the three optional fields a ``task`` frame carries
    (model, provider, reasoning effort), plus optional output settings."""

    model_id: str
    provider_slug: str | None = None
    reasoning_effort: str | None = None
    #: ``None`` sends nothing: the provider's default. The WebSocket route
    #: ignored sampling fields, so the old client's 2048 / 0.7 never reached
    #: the model; the HTTP route forwards them, and 2048 output tokens would
    #: cut a long answer (or a big ``write_file``) short.
    max_tokens: int | None = None
    temperature: float | None = None
    #: Extra JSON fields for the request body (the route's own options).
    extra_body: dict[str, Any] = field(default_factory=dict)


def chuk_profile(*, send_back_thinking: bool = False) -> OpenAIModelProfile:
    """The model profile for the account proxy.

    The proxy serves open models (DeepSeek, Kimi, Qwen, ...) behind one
    OpenAI-compatible surface: thinking comes in ``reasoning_content``. The
    native loop never sent the thinking back, so the default keeps that
    (``send_back_thinking=False``); the history converter drops it as well.
    """
    return OpenAIModelProfile(
        openai_chat_thinking_field="reasoning_content",
        openai_chat_send_back_thinking_parts="field" if send_back_thinking else False,
        # The proxy forwards tool schemas as they are. OpenAI strict mode
        # rewrites them, and most upstreams reject strict anyway.
        openai_supports_strict_tool_definition=False,
    )


def chuk_model_settings(spec: ChukModelSpec) -> OpenAIChatModelSettings:
    """Per-request settings for one spec. The provider pin travels in the
    route's ``provider`` extension field (the ``/v2/ws`` ``provider_slug``);
    without it the server pins the cheapest healthy provider. The reasoning
    effort is the standard OpenAI field. Pydantic AI always asks for usage on
    the stream, which the token budget and the context ladder read."""
    extra: dict[str, Any] = dict(spec.extra_body)
    if spec.provider_slug:
        extra.setdefault("provider", spec.provider_slug)
    settings: OpenAIChatModelSettings = {}
    if spec.max_tokens is not None:
        settings["max_tokens"] = spec.max_tokens
    if spec.temperature is not None:
        settings["temperature"] = spec.temperature
    if spec.reasoning_effort:
        settings["openai_reasoning_effort"] = spec.reasoning_effort  # type: ignore[typeddict-item]
    if extra:
        settings["extra_body"] = extra
    return settings


#: SDK retries per request (connection errors, 5xx, 429). The route already
#: retries and fails over upstream (``x-should-retry: false``), and every
#: attempt is paid for and waited on; one retry is the ceiling.
MAX_RETRIES = 1


class RequestLog:
    """Counts the HTTP requests of one model call (an ``httpx2`` request
    hook): SDK retries and a resend after a ``401`` are attempts the run row
    records (``retries`` / ``retry_ms``)."""

    def __init__(self, clock: Callable[[], float] = time.monotonic) -> None:
        self._clock = clock
        self.times: list[float] = []

    def reset(self) -> None:
        self.times = []

    async def on_request(self, request: httpx2.Request) -> None:
        self.times.append(self._clock())

    def retries(self) -> tuple[int, float]:
        """``(extra attempts, ms spent before the last one)``."""
        if len(self.times) < 2:
            return 0, 0.0
        return len(self.times) - 1, (self.times[-1] - self.times[0]) * 1000


def chuk_chat_model(
    session: Any,
    spec: ChukModelSpec,
    *,
    base_url: str = "https://api.chuk.chat",
    transport: httpx2.AsyncBaseTransport | None = None,
    timeout: float = 600.0,
    send_back_thinking: bool = False,
) -> tuple[OpenAIChatModel, OpenAIChatModelSettings]:
    """The model and its settings for one task.

    The HTTP client always carries :class:`SupabaseJwtAuth`; ``transport`` is
    only for tests (an ``httpx2.MockTransport``), so the auth path under test
    is the production one. The model carries its :class:`RequestLog` as
    ``model.request_log``. The client belongs to one event loop: build one
    model per run and close ``model.client`` when the run ends.
    """
    from openai import AsyncOpenAI

    log = RequestLog()
    client = httpx2.AsyncClient(
        auth=SupabaseJwtAuth(session),
        timeout=timeout,
        transport=transport,
        event_hooks={"request": [log.on_request]},
    )
    openai_client = AsyncOpenAI(
        base_url=base_url.rstrip("/") + DEFAULT_OPENAI_PATH,
        # The SDK insists on a key; the real bearer is set by the auth flow on
        # every request and overrides this header.
        api_key="account-jwt",
        http_client=client,
        max_retries=MAX_RETRIES,
    )
    model = OpenAIChatModel(
        spec.model_id,
        provider=OpenAIProvider(openai_client=openai_client),
        profile=chuk_profile(send_back_thinking=send_back_thinking),
    )
    model.request_log = log  # type: ignore[attr-defined]
    return model, chuk_model_settings(spec)


# -- the legacy adapter --------------------------------------------------------


def tool_definition_to_openai(tool: ToolDefinition) -> dict:
    """A Pydantic AI tool definition as OpenAI function-tool JSON — the same
    bytes :meth:`~chuk_agents_runtime.registry.ToolRegistry.openai_tool` makes."""
    return {
        "type": "function",
        "function": {
            "name": tool.name,
            "description": tool.description or "",
            "parameters": tool.parameters_json_schema
            or {"type": "object", "properties": {}},
        },
    }


def _usage_from_raw(raw: dict | None) -> RequestUsage:
    usage = (raw or {}).get("usage") if isinstance(raw, dict) else None
    if not isinstance(usage, dict):
        return RequestUsage()

    def first(*keys: str) -> int:
        for key in keys:
            value = usage.get(key)
            if isinstance(value, (int, float)) and not isinstance(value, bool):
                return int(value)
        return 0

    return RequestUsage(
        input_tokens=first("prompt_tokens", "input_tokens"),
        output_tokens=first("completion_tokens", "output_tokens"),
    )


def legacy_to_response(response: LegacyResponse) -> ModelResponse:
    """A legacy :class:`~chuk_agents_runtime.model.ModelResponse` as a Pydantic
    AI response. The thinking comes first, the text second, the calls last —
    the order the model produced them in."""
    parts: list[Any] = []
    raw = response.raw or {}
    reasoning = raw.get("reasoning") if isinstance(raw, dict) else None
    if isinstance(reasoning, str) and reasoning.strip():
        parts.append(ThinkingPart(content=reasoning))
    if response.text:
        parts.append(TextPart(content=response.text))
    for call in response.tool_calls:
        args = call.arguments
        parts.append(
            ToolCallPart(
                tool_name=call.name,
                args=args if isinstance(args, (dict, str)) else json.dumps(args),
                tool_call_id=call.id,
            )
        )
    details: dict[str, Any] = {
        "housekeeping": bool(response.housekeeping),
        "usage": raw.get("usage") if isinstance(raw, dict) else None,
        "timing": raw.get("timing") if isinstance(raw, dict) else None,
        "tps": raw.get("tps") if isinstance(raw, dict) else None,
        "empty": not parts,
    }
    if not parts:
        # A turn with no text and no call is a legal legacy answer ("done,
        # nothing to say"). Pydantic AI needs at least one part to end a run
        # on text, so it is an empty text part.
        parts.append(TextPart(content=""))
    return ModelResponse(
        parts=parts,
        usage=_usage_from_raw(raw),
        provider_details={LEGACY_DETAILS_KEY: details},
    )


class LegacyClientModel(FunctionModel):
    """Any :class:`~chuk_agents_runtime.model.ModelClient` as a Pydantic AI model.

    Each request converts the (already processed) messages to the stored-row
    shape, hands the tool definitions to the client's ``set_tools`` seam when it
    has one, and calls the blocking ``complete`` on a worker thread (Pydantic AI
    runs a sync ``FunctionModel`` function in its executor). The reply comes
    back as a :class:`ModelResponse` whose ``provider_details`` keeps the legacy
    extras under :data:`LEGACY_DETAILS_KEY`.
    """

    def __init__(self, client: ModelClient, *, model_name: str | None = None) -> None:
        self.client = client
        self._last_tools: list[dict] | None = None
        #: Bumped per request, with the reply it produced. A Stop cancels the
        #: awaiting task, but the blocking ``complete`` still returns on its
        #: thread; the loop keeps that turn when it did (the native loop kept
        #: an answered turn the user stopped).
        self.requests = 0
        self.last_reply: tuple[int, ModelResponse] | None = None
        super().__init__(self._call, model_name=model_name or _client_name(client))

    def _call(self, messages: list[ModelMessage], info: AgentInfo) -> ModelResponse:
        rows = messages_to_rows(messages)
        set_tools: Callable[[list[dict] | None], None] | None = getattr(
            self.client, "set_tools", None
        )
        tools = [tool_definition_to_openai(t) for t in info.function_tools]
        if callable(set_tools) and tools != self._last_tools:
            set_tools(tools or None)
            self._last_tools = tools
        self.requests += 1
        number = self.requests
        reply = legacy_to_response(self.client.complete(rows))
        self.last_reply = (number, reply)
        return reply


def _client_name(client: Any) -> str:
    inner = getattr(client, "_inner", None)
    target = inner if inner is not None else client
    name = getattr(target, "_model_id", None)
    return str(name) if name else f"legacy:{type(target).__name__}"


def is_legacy(model: Model) -> bool:
    return isinstance(model, LegacyClientModel)


disable_banner()

__all__ = [
    "DEFAULT_OPENAI_PATH",
    "LEGACY_DETAILS_KEY",
    "ChukModelSpec",
    "LegacyClientModel",
    "SupabaseJwtAuth",
    "chuk_chat_model",
    "chuk_model_settings",
    "chuk_profile",
    "is_legacy",
    "legacy_to_response",
    "tool_definition_to_openai",
]
