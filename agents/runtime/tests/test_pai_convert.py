"""Stored rows <-> Pydantic AI messages, including sessions of the old loop."""

from __future__ import annotations

from pydantic_ai.messages import (
    ModelRequest,
    ModelResponse,
    TextPart,
    ToolCallPart,
    ToolReturnPart,
    ToolSearchCallPart,
    ToolSearchReturnPart,
)

from chuk_agents_runtime.pai.convert import messages_to_rows, rows_to_messages
from chuk_agents_runtime.prompt import upgrade_research_instructions
from chuk_agents_runtime.registry import ToolRegistry


def _call(call_id: str, name: str, args) -> dict:
    return {"id": call_id, "type": "function", "function": {"name": name, "arguments": args}}


def test_rows_round_trip_for_every_field_the_model_sees():
    rows = [
        {"role": "system", "content": "S"},
        {"role": "user", "content": "hi"},
        {"role": "assistant", "content": "ok", "tool_calls": [_call("c1", "echo", {"v": 1})]},
        {"role": "tool", "tool_call_id": "c1", "name": "echo", "content": {"x": 1}},
        {"role": "user", "content": "[memory recall] x"},
    ]
    assert messages_to_rows(rows_to_messages(rows)) == rows


def test_broken_json_arguments_in_an_old_row_become_an_empty_call():
    messages = rows_to_messages(
        [{"role": "user", "content": "q"}, {"role": "assistant", "tool_calls": [_call("c1", "t", '{"a": ')]}]
    )
    call = next(p for p in messages[1].parts if isinstance(p, ToolCallPart))
    assert call.args == {}


def test_an_old_tool_call_bridge_call_becomes_a_direct_call():
    rows = [
        {"role": "user", "content": "q"},
        {"role": "assistant", "tool_calls": [_call("c1", "tool_call", {"name": "mcp__gh__issue", "arguments": '{"title": "x"}'})]},
        {"role": "tool", "tool_call_id": "c1", "name": "tool_call", "content": {"ok": True}},
    ]
    response, request = rows_to_messages(rows)[1:]
    call = response.parts[0]
    assert (call.tool_name, call.args) == ("mcp__gh__issue", {"title": "x"})
    assert isinstance(request.parts[0], ToolReturnPart)
    assert request.parts[0].tool_name == "mcp__gh__issue"


def test_old_search_and_describe_calls_become_discoveries():
    rows = [
        {"role": "user", "content": "q"},
        {
            "role": "assistant",
            "tool_calls": [
                _call("s1", "tool_search", {"query": "issue"}),
                _call("d1", "tool_describe", {"name": "mcp__gh__close"}),
            ],
        },
        {"role": "tool", "tool_call_id": "s1", "name": "tool_search",
         "content": {"ok": True, "matches": [{"name": "mcp__gh__issue", "description": "x"}]}},
        {"role": "tool", "tool_call_id": "d1", "name": "tool_describe",
         "content": {"ok": True, "name": "mcp__gh__close", "documentation": "..."}},
    ]
    response, request = rows_to_messages(rows)[1:]
    assert all(isinstance(p, ToolSearchCallPart) for p in response.parts)
    assert response.parts[0].args == {"queries": ["issue"]}
    returns = [p for p in request.parts if isinstance(p, ToolSearchReturnPart)]
    assert [r.discovered_tools for r in returns] == [[{"name": "mcp__gh__issue"}], [{"name": "mcp__gh__close"}]]


def test_the_old_bridge_names_get_a_hint_when_called():
    result = ToolRegistry().dispatch("tool_search", {"query": "x"})
    assert "search_tools" in result["error"]


def test_any_stored_prompt_naming_the_old_bridge_is_rewritten():
    assert upgrade_research_instructions("Persona. Find tools with `tool_search`.") == (
        "Persona. Find tools with `search_tools`."
    )


def test_messages_to_rows_strips_the_answer_and_drops_whitespace_turns():
    rows = messages_to_rows([ModelRequest(parts=[]), ModelResponse(parts=[TextPart(content="  hi \n")])])
    assert rows == [{"role": "assistant", "content": "hi"}]
    assert messages_to_rows([ModelResponse(parts=[TextPart(content=" ")])]) == [{"role": "assistant"}]


def test_a_non_dict_entry_among_old_bridge_calls_is_ignored_safely():
    rows = [
        {"role": "user", "content": "q"},
        {"role": "assistant", "tool_calls": ["garbage", _call("s1", "tool_search", {"query": "x"})]},
        {"role": "tool", "tool_call_id": "s1", "name": "tool_search", "content": {"ok": True, "matches": []}},
    ]
    response = rows_to_messages(rows)[1]
    assert [p.tool_name for p in response.parts] == ["search_tools"]
