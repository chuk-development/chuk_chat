"""Model client (§7.4).

The real backend is the ChukChat account proxy. Chat runs over the multiplexed
``wss://api.chuk.chat/v2/ws`` socket (see :mod:`cowork_agent.backend`), which
returns assistant **text**; tool calls are embedded in that text as
``<tool_call>{json}</tool_call>`` blocks and parsed client-side. This is the ONE
tool-call protocol the runtime speaks — mock and real share :func:`extract_tool_calls`.

The runtime depends only on the ``ModelClient`` protocol, so the real WebSocket
impl is swappable for a mock in tests. An OpenAI-compatible HTTP client is kept
for reference / non-``/v2/ws`` deployments, but the ``<tool_call>``-in-content
protocol is authoritative.
"""

from __future__ import annotations

import json
import re
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


# -- <tool_call>-in-content protocol (the one wire format, matching chuk_chat) --

# Canonical block: `<tool_call>{json}</tool_call>`. Non-greedy, DOTALL,
# case-insensitive — mirrors `toolCallStart`/`toolCallEnd` in
# chuk_chat/lib/utils/tool_parser.dart.
_TOOL_CALL_BLOCK = re.compile(r"<tool_call>(.*?)</tool_call>", re.DOTALL | re.IGNORECASE)


def _repair_and_load(raw: str) -> dict | None:
    """Parse a tool-call JSON body, repairing the two mistakes models make most:
    a missing closing brace and a trailing comma. Mirrors ``tryParseToolJson``."""
    text = raw.strip()
    if not text:
        return None
    try:
        parsed = json.loads(text)
        return parsed if isinstance(parsed, dict) else None
    except json.JSONDecodeError:
        pass
    # Add missing closing braces (only counting those outside strings is overkill
    # here; a bounded add-and-retry is enough for the observed failures).
    opens = text.count("{")
    closes = text.count("}")
    if opens > closes:
        candidate = text + ("}" * (opens - closes))
        try:
            parsed = json.loads(candidate)
            if isinstance(parsed, dict):
                return parsed
        except json.JSONDecodeError:
            pass
    # Strip trailing commas before } or ].
    cleaned = re.sub(r",\s*([}\]])", r"\1", text)
    if cleaned != text:
        try:
            parsed = json.loads(cleaned)
            if isinstance(parsed, dict):
                return parsed
        except json.JSONDecodeError:
            pass
    return None


def extract_tool_calls(content: str | None) -> tuple[str, list[ToolCall]]:
    """Split assistant ``content`` into (visible_text, tool_calls).

    Parses every ``<tool_call>{"name":...,"arguments":{...}}</tool_call>`` block
    out of the text — the single tool-call wire format shared by the mock and the
    real backend. The blocks are stripped from the returned text so protocol XML
    never leaks into the final answer. Continue-vs-finish stays structural: a turn
    with parsed calls continues the loop; a bare-text turn is the final answer.
    """
    if not content:
        return "", []
    calls: list[ToolCall] = []
    for i, match in enumerate(_TOOL_CALL_BLOCK.finditer(content)):
        data = _repair_and_load(match.group(1))
        if data is None:
            continue
        name_raw = data.get("name")
        name = name_raw.strip() if isinstance(name_raw, str) else ""
        if not name:
            continue
        raw_args = data.get("arguments", data.get("args", {}))
        args = raw_args if isinstance(raw_args, dict) else {}
        calls.append(ToolCall(id=f"call_{i}", name=name, arguments=args))
    clean = _TOOL_CALL_BLOCK.sub("", content).strip()
    return clean, calls


def response_from_content(content: str | None, *, housekeeping: bool = False) -> ModelResponse:
    """Build a :class:`ModelResponse` from raw assistant text, routing tool calls
    through :func:`extract_tool_calls`. The single construction path for both the
    mock and the real backend."""
    clean, calls = extract_tool_calls(content)
    return ModelResponse(
        text=clean or None,
        tool_calls=calls,
        housekeeping=housekeeping,
        raw={"content": content} if content is not None else {},
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

    - a ``str`` — raw assistant content, parsed through the SAME
      :func:`extract_tool_calls` path the real backend uses, so a tool call is
      written as ``<tool_call>{"name":...,"arguments":{...}}</tool_call>`` in the
      text; or
    - a :class:`ModelResponse` — passed through unchanged, for turns that need a
      flag the content form cannot express (e.g. ``housekeeping``).
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
        # A raw content string -> the converged <tool_call>-in-content path.
        return response_from_content(item)
