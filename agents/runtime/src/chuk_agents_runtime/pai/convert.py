"""Stored rows <-> Pydantic AI messages (docs/PYDANTIC_AI_LOOP.md, section 9).

The ``messages`` table of :class:`~chuk_agents_runtime.state.StateStore` stays
the source of truth, in the OpenAI-style shape the native loop always wrote:

- ``{"role": "system", "content": str}``
- ``{"role": "user", "content": str}`` (a skill body, a memory recall and a
  job result are user-role rows too; only the row label differs)
- ``{"role": "assistant", "content": str | None, "reasoning": str?,
  "tool_calls": [{"id", "type": "function", "function": {"name", "arguments"}}]}``
- ``{"role": "tool", "tool_call_id": str, "name": str, "content": Any}``

The replay, the chat search, the transcript export and the app all read these
rows, so the Pydantic AI loop writes the same rows. There is therefore no data
migration: an old session is converted on read, every round, by
:func:`rows_to_messages`. :func:`messages_to_rows` is the other direction,
used by the legacy-client adapter and by the loop when it persists a turn.

The conversion is lossless for every field the model sees. The stored
``reasoning`` of an assistant row is dropped on the way to the model unless
the caller asks for it: the native loop never sent it back either.
"""

from __future__ import annotations

import json
from collections.abc import Iterable, Sequence
from typing import Any

from pydantic_ai.messages import (
    ModelMessage,
    ModelRequest,
    ModelRequestPart,
    ModelResponse,
    ModelResponsePart,
    RetryPromptPart,
    SystemPromptPart,
    TextPart,
    ThinkingPart,
    ToolCallPart,
    ToolReturnPart,
    ToolSearchCallPart,
    ToolSearchReturnPart,
    UserPromptPart,
)


#: The name Pydantic AI's ToolSearch capability gives its local search tool.
#: Its calls and results are stored as ordinary rows; on the way back they
#: become the typed parts again, because Pydantic AI reads which tools the
#: model already discovered from exactly those parts.
SEARCH_TOOLS_NAME = "search_tools"


def content_text(content: Any) -> str:
    """A stored ``content`` as the text the model gets. A string passes
    through; ``None`` is empty; anything else is compact JSON. Same rule as the
    native wire mapping (``backend._content_to_str``)."""
    if isinstance(content, str):
        return content
    if content is None:
        return ""
    try:
        return json.dumps(content, separators=(",", ":"))
    except (TypeError, ValueError):
        return str(content)


def _user_content(content: Any) -> str | list[Any]:
    """User content: a string, or an OpenAI content list flattened to its text
    parts. Image parts only appear in the browser fallback, which does not run
    on this loop, so they are kept as their JSON text instead of dropped."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        texts: list[str] = []
        for part in content:
            if isinstance(part, dict) and part.get("type") == "text":
                texts.append(str(part.get("text", "")))
            else:
                texts.append(content_text(part))
        return "\n".join(texts)
    return content_text(content)


def _call_args(raw: Any) -> dict[str, Any] | str:
    """Stored arguments are a dict (the old loop parsed them). A string is
    parsed; one that is not a JSON object becomes ``{}``."""
    if isinstance(raw, dict):
        return raw
    if isinstance(raw, str):
        if not raw.strip():
            return {}
        try:
            parsed = json.loads(raw)
        except json.JSONDecodeError:
            # Broken JSON (a call cut off mid-stream in an old row) would make
            # a strict provider reject the whole history: an empty call, as
            # the old client parsed it.
            return {}
        return parsed if isinstance(parsed, dict) else {}
    if raw is None:
        return {}
    return content_text(raw)


def row_to_response(row: dict, *, include_reasoning: bool = False) -> ModelResponse:
    """One stored assistant row as a :class:`ModelResponse`."""
    parts: list[ModelResponsePart] = []
    reasoning = row.get("reasoning")
    if include_reasoning and isinstance(reasoning, str) and reasoning.strip():
        parts.append(ThinkingPart(content=reasoning))
    content = row.get("content")
    if content is not None and content != "":
        parts.append(TextPart(content=content_text(content)))
    for index, call in enumerate(row.get("tool_calls") or []):
        if not isinstance(call, dict):
            continue
        fn = call.get("function") or {}
        name = str(fn.get("name", ""))
        args = _call_args(fn.get("arguments"))
        call_id = str(call.get("id") or f"call_{index}")
        if name == SEARCH_TOOLS_NAME and isinstance(args, dict):
            parts.append(ToolSearchCallPart(args=args, tool_call_id=call_id))  # type: ignore[arg-type]
        else:
            parts.append(ToolCallPart(tool_name=name, args=args, tool_call_id=call_id))
    return ModelResponse(parts=parts)


def row_to_request_part(row: dict) -> ModelRequestPart | None:
    """One stored request-side row (system, user, tool) as a request part.
    ``None`` for a row the model never sees (an unknown role)."""
    role = row.get("role")
    if role == "system":
        return SystemPromptPart(content=content_text(row.get("content")))
    if role == "user":
        return UserPromptPart(content=_user_content(row.get("content")))
    if role == "tool":
        content = row.get("content")
        if (
            row.get("name") == SEARCH_TOOLS_NAME
            and isinstance(content, dict)
            and isinstance(content.get("discovered_tools"), list)
        ):
            return ToolSearchReturnPart(
                content=content,  # type: ignore[arg-type]
                tool_call_id=str(row.get("tool_call_id") or ""),
            )
        return ToolReturnPart(
            tool_name=str(row.get("name") or ""),
            content=row.get("content"),
            tool_call_id=str(row.get("tool_call_id") or ""),
        )
    return None


#: The tool-search bridge of the old loop. Its calls live on in old sessions;
#: the model must not learn to call tools that no longer exist.
_BRIDGE_TOOLS = ("tool_search", "tool_describe", "tool_call")


def _rewrite_bridge(rows: Iterable[dict]) -> list[dict]:
    """Old sessions, as the new loop would have written them.

    - ``tool_call(name, arguments)`` becomes a direct call of ``name``;
    - ``tool_search(query)`` and ``tool_describe(name)`` become ``search_tools``
      calls whose results name the tools they revealed — so those tools stay
      discovered, exactly as the model already knew them.
    """
    rows = [row for row in rows if isinstance(row, dict)]
    renamed: dict[str, tuple[str, Any]] = {}
    for index, row in enumerate(rows):
        calls = row.get("tool_calls") if row.get("role") == "assistant" else None
        if not calls or not any(
            isinstance(c, dict) and (c.get("function") or {}).get("name") in _BRIDGE_TOOLS for c in calls
        ):
            continue
        new_calls = []
        for call in calls:
            fn = (call.get("function") or {}) if isinstance(call, dict) else {}
            name = fn.get("name")
            args = _call_args(fn.get("arguments"))
            args = args if isinstance(args, dict) else {}
            call_id = str(call.get("id") or "") if isinstance(call, dict) else ""
            if name == "tool_call":
                target = str(args.get("name") or "")
                inner = _call_args(args.get("arguments"))
                renamed[call_id] = ("call", target)
                fn = {"name": target, "arguments": inner if isinstance(inner, dict) else {}}
            elif name == "tool_search":
                renamed[call_id] = ("search", None)
                fn = {"name": SEARCH_TOOLS_NAME, "arguments": {"queries": [str(args.get("query") or "")]}}
            elif name == "tool_describe":
                target = str(args.get("name") or "")
                renamed[call_id] = ("describe", target)
                fn = {"name": SEARCH_TOOLS_NAME, "arguments": {"queries": [target]}}
            new_calls.append({**call, "function": fn} if isinstance(call, dict) else call)
        rows[index] = {**row, "tool_calls": new_calls}
    if not renamed:
        return rows
    for index, row in enumerate(rows):
        if row.get("role") != "tool":
            continue
        kind, target = renamed.get(str(row.get("tool_call_id") or ""), (None, None))
        if kind is None:
            continue
        content = row.get("content")
        if kind == "call":
            rows[index] = {**row, "name": target}
            continue
        if kind == "search":
            matches = content.get("matches") if isinstance(content, dict) else None
            names = [str(m.get("name")) for m in matches or [] if isinstance(m, dict) and m.get("name")]
        else:
            ok = isinstance(content, dict) and content.get("ok") is not False
            names = [target] if ok and target else []
        rows[index] = {
            **row,
            "name": SEARCH_TOOLS_NAME,
            "content": {"discovered_tools": [{"name": n} for n in names]},
        }
    return rows


def rows_to_messages(
    rows: Iterable[dict], *, include_reasoning: bool = False
) -> list[ModelMessage]:
    """The stored conversation as Pydantic AI messages.

    Consecutive request-side rows (system, user, tool) fold into one
    :class:`ModelRequest`, each assistant row is one :class:`ModelResponse`.
    The order of the rows is kept exactly, so the tool results of one turn stay
    in the request that follows it.
    """
    out: list[ModelMessage] = []
    pending: list[ModelRequestPart] = []

    def flush() -> None:
        if pending:
            out.append(ModelRequest(parts=list(pending)))
            pending.clear()

    for row in _rewrite_bridge(rows):
        if row.get("role") == "assistant":
            flush()
            out.append(row_to_response(row, include_reasoning=include_reasoning))
            continue
        part = row_to_request_part(row)
        if part is not None:
            pending.append(part)
    flush()
    return out


# -- the other direction ------------------------------------------------------


def response_to_row(response: ModelResponse) -> dict:
    """A model turn as the assistant row the native loop wrote: the text (all
    text parts joined), the thinking as ``reasoning`` (a stored field for the
    replay; it is not sent back), and the tool calls with dict arguments."""
    texts: list[str] = []
    thinking: list[str] = []
    calls: list[dict] = []
    for part in response.parts:
        if isinstance(part, TextPart):
            texts.append(part.content)
        elif isinstance(part, ThinkingPart):
            if part.content:
                thinking.append(part.content)
        elif isinstance(part, ToolCallPart):
            calls.append(
                {
                    "id": part.tool_call_id,
                    "type": "function",
                    "function": {"name": part.tool_name, "arguments": tool_call_args(part)},
                }
            )
    row: dict[str, Any] = {"role": "assistant"}
    # Stripped, as the old client stored it: a reply of only whitespace (Kimi
    # opens tool turns with a space) is a turn with no text.
    text = "".join(texts).strip()
    if text:
        row["content"] = text
    reasoning = "".join(thinking)
    if reasoning.strip():
        row["reasoning"] = reasoning
    if calls:
        row["tool_calls"] = calls
    return row


def tool_call_args(part: ToolCallPart) -> dict[str, Any] | str:
    """The arguments of a tool call as a dict, the shape the rows and the
    ``tool`` frames carry. A string that is not a JSON object stays a string."""
    args = part.args
    if isinstance(args, dict):
        return args
    return _call_args(args)


def request_to_rows(request: ModelRequest) -> list[dict]:
    """A request as rows. A retry prompt becomes a tool row (it answers a tool
    call) or a user row (it answers text), so no call is left without a
    result."""
    rows: list[dict] = []
    for part in request.parts:
        if isinstance(part, SystemPromptPart):
            rows.append({"role": "system", "content": part.content})
        elif isinstance(part, UserPromptPart):
            content = part.content
            if not isinstance(content, str):
                content = _flatten_user(content)
            rows.append({"role": "user", "content": content})
        elif isinstance(part, ToolReturnPart):
            rows.append(
                {
                    "role": "tool",
                    "tool_call_id": part.tool_call_id,
                    "name": part.tool_name,
                    "content": part.content,
                }
            )
        elif isinstance(part, RetryPromptPart):
            text = part.model_response()
            if part.tool_name and part.tool_call_id:
                rows.append(
                    {
                        "role": "tool",
                        "tool_call_id": part.tool_call_id,
                        "name": part.tool_name,
                        "content": text,
                    }
                )
            else:
                rows.append({"role": "user", "content": text})
    return rows


def _flatten_user(content: Sequence[Any]) -> str:
    return "\n".join(item if isinstance(item, str) else str(item) for item in content)


def messages_to_rows(messages: Iterable[ModelMessage]) -> list[dict]:
    """Pydantic AI messages as stored rows (the inverse of
    :func:`rows_to_messages`)."""
    rows: list[dict] = []
    for message in messages:
        if isinstance(message, ModelResponse):
            rows.append(response_to_row(message))
        elif isinstance(message, ModelRequest):
            rows.extend(request_to_rows(message))
    return rows


__all__ = [
    "SEARCH_TOOLS_NAME",
    "content_text",
    "messages_to_rows",
    "request_to_rows",
    "response_to_row",
    "row_to_request_part",
    "row_to_response",
    "rows_to_messages",
    "tool_call_args",
]
