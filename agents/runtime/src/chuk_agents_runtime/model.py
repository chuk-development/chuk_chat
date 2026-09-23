"""Model client (§7.4).

The real backend is the ChukChat account proxy. Chat runs over the multiplexed
``wss://api.chuk.chat/v2/ws`` socket (see :mod:`chuk_agents_runtime.backend`).

**Native tool calling is the one and only protocol.** The runtime declares its
tools as an OpenAI ``tools`` array (:meth:`chuk_agents_runtime.registry.ToolRegistry.openai_tools`)
and the provider answers with structured ``tool_calls`` — a list of
``{id, type, function:{name, arguments}}`` objects — which arrive on their own
frame, never inside the assistant text. There is no text/markdown fallback: a
turn is a tool-call turn only if the server sent tool calls, and assistant
content is always plain prose for the user.

The runtime depends only on the ``ModelClient`` protocol, so the real WebSocket
impl is swappable for a mock in tests. An OpenAI-compatible HTTP client is kept
for reference / non-``/v2/ws`` deployments; it speaks the same native shape
through :func:`parse_openai_response`.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from typing import Any, Protocol, runtime_checkable

import httpx


@dataclass
class ToolCall:
    id: str
    name: str
    arguments: dict


@dataclass
class ModelResponse:
    """One model turn. Continue-vs-finish is structural: a turn with tool calls
    continues the loop; a bare-text turn is the final answer (§7.1)."""

    text: str | None = None
    tool_calls: list[ToolCall] = field(default_factory=list)
    # Marks a preflight / housekeeping round so the loop refunds the iteration
    # budget instead of burning the model's real thinking allowance (§7.1).
    housekeeping: bool = False
    raw: dict = field(default_factory=dict)

    @property
    def has_tool_calls(self) -> bool:
        return bool(self.tool_calls)


@runtime_checkable
class ModelClient(Protocol):
    def complete(self, messages: list[dict]) -> ModelResponse: ...


# -- native tool calls (the one wire format, matching chuk_chat) --------------


def tool_call_response(
    *calls: tuple[str, dict],
    text: str | None = None,
    housekeeping: bool = False,
) -> ModelResponse:
    """Build a native tool-calling turn from ``(name, arguments)`` pairs.

    A convenience for tests and scripted runs: it produces exactly the
    :class:`ModelResponse` the backend builds from a server ``tool_calls`` frame,
    with sequential ``call_0``, ``call_1``… ids — the ids the loop echoes back as
    ``tool_call_id``. ``text`` is the assistant's (optional) interim prose for
    the same turn.
    """
    return ModelResponse(
        text=text,
        tool_calls=[
            ToolCall(id=f"call_{i}", name=name, arguments=dict(arguments or {}))
            for i, (name, arguments) in enumerate(calls)
        ],
        housekeeping=housekeeping,
    )


def parse_openai_response(data: dict) -> ModelResponse:
    """Map an OpenAI-compatible chat completion into a ``ModelResponse``."""
    choices = data.get("choices") or [{}]
    message = choices[0].get("message", {}) or {}
    raw_calls = message.get("tool_calls") or []
    calls: list[ToolCall] = []
    for i, call in enumerate(raw_calls):
        fn = call.get("function", {}) or {}
        raw_args = fn.get("arguments", "{}")
        if isinstance(raw_args, str):
            try:
                args = json.loads(raw_args) if raw_args.strip() else {}
            except json.JSONDecodeError:
                args = {}
        elif isinstance(raw_args, dict):
            args = raw_args
        else:
            args = {}
        calls.append(
            ToolCall(
                id=call.get("id", f"call_{i}"),
                name=fn.get("name", ""),
                arguments=args,
            )
        )
    return ModelResponse(
        text=message.get("content"),
        tool_calls=calls,
        raw=data,
    )


class OpenAICompatModelClient:
    """Calls an OpenAI-compatible ``/chat/completions`` endpoint over httpx.

    ``base_url`` and ``token`` are injected — the backend proxy and account
    token. No provider keys ever live here.
    """

    def __init__(
        self,
        base_url: str,
        token: str,
        model: str,
        *,
        tools: list[dict] | None = None,
        timeout: float = 120.0,
        http_client: httpx.Client | None = None,
    ) -> None:
        self._base_url = base_url.rstrip("/")
        self._token = token
        self._model = model
        self._tools = tools
        self._client = http_client or httpx.Client(timeout=timeout)

    def complete(self, messages: list[dict]) -> ModelResponse:
        payload: dict[str, Any] = {"model": self._model, "messages": messages}
        if self._tools:
            payload["tools"] = self._tools
        resp = self._client.post(
            f"{self._base_url}/chat/completions",
            json=payload,
            headers={"Authorization": f"Bearer {self._token}"},
        )
        resp.raise_for_status()
        return parse_openai_response(resp.json())

    def close(self) -> None:
        self._client.close()


class MockModelClient:
    """A scripted ``ModelClient`` for tests and the end-to-end wiring.

    Emits a fixed list of scripted turns in order and records every ``messages``
    list it was called with. Each scripted item is either

    - a ``str`` — a bare-text turn, i.e. the model's final answer. Strings are
      NEVER scanned for tool calls: with native tool calling, assistant content
      is prose and nothing else; or
    - a :class:`ModelResponse` — passed through unchanged. This is how a tool
      call is scripted, most readably via :func:`tool_call_response`.
    """

    def __init__(self, responses: list[ModelResponse | str]) -> None:
        self._responses = list(responses)
        self.calls: list[list[dict]] = []

    def complete(self, messages: list[dict]) -> ModelResponse:
        self.calls.append([dict(m) for m in messages])
        if not self._responses:
            # Nothing scripted left — end the run with a bare-text turn.
            return ModelResponse(text="(mock exhausted)")
        item = self._responses.pop(0)
        if isinstance(item, ModelResponse):
            return item
        # A plain string is a final answer, not a protocol to parse.
        return ModelResponse(text=item or None, raw={"content": item})
