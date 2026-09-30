"""Tool Search / progressive disclosure tests (§7.2).

The load-bearing claims: under the threshold nothing changes, above it exactly
the deferrable tools stop being declared, core tools never do, and the loop's
toolset hands the hidden ones to Pydantic AI's ToolSearch as ``defer_loading``
tools (the search itself is Pydantic AI's; ``test_pai_gates.py`` gate 5 runs
it end to end).

"Declared" means the native OpenAI ``tools`` array — that is what the request
carries and what the model is billed for every round, so it is what the
threshold is measured on. ``render_tool_docs`` is used below only as the
readable view of that same offered set; the two share one filter.
"""

from __future__ import annotations

import json

from chuk_agents_runtime.context import estimate_tokens
from chuk_agents_runtime.prompt import render_tool_docs
from chuk_agents_runtime.registry import ToolRegistry
from chuk_agents_runtime.tool_search import (
    CORE_TOOLS,
    apply_tool_search,
    tool_doc_tokens,
)

CORE_SAMPLE = ("run_command", "write_file", "read_file", "list_dir", "memory", "skill")


def _core_schema(name: str) -> dict:
    return {
        "type": "object",
        "description": f"The core tool {name}. Always in the prompt.",
        "properties": {"x": {"type": "string", "description": "An argument."}},
        "required": ["x"],
    }


def _mcp_schema(server: str, index: int) -> dict:
    return {
        "type": "object",
        "description": (
            f"[MCP: {server}] Tool number {index} of {server}. It takes a query "
            "and a limit and returns a page of records from the remote system, "
            "with a cursor for the next page and the total count."
        ),
        "properties": {
            "query": {"type": "string", "description": "What to look for."},
            "limit": {"type": "integer", "description": "How many records.", "default": 20},
            "cursor": {"type": "string", "description": "Page cursor from a previous call."},
        },
        "required": ["query"],
    }


def build_registry(*, servers: int = 0, tools_per_server: int = 20) -> ToolRegistry:
    registry = ToolRegistry()
    for name in CORE_SAMPLE:
        registry.register(name, _core_schema(name), lambda **kw: {"ok": True, "core": True})
    for s in range(servers):
        server = f"server{s}"
        for t in range(tools_per_server):
            registry.register(
                f"mcp__{server}__tool{t}",
                _mcp_schema(server, t),
                lambda **kw: {"ok": True, "args": kw},
                deferrable=True,
            )
    return registry


# -- the threshold ---------------------------------------------------------


def test_below_the_threshold_every_tool_stays_declared():
    registry = build_registry(servers=1, tools_per_server=3)
    decision = apply_tool_search(registry, context_window=128_000, reserved_output=8_000)
    assert decision.active is False
    assert decision.deferred == []
    assert decision.saved_tokens == 0
    docs = render_tool_docs(registry)
    for name in CORE_SAMPLE:
        assert f"## {name}" in docs
    assert "## mcp__server0__tool0" in docs
    assert "tool_search" not in docs


def test_above_the_threshold_only_the_core_tools_remain_declared():
    registry = build_registry(servers=8, tools_per_server=20)
    decision = apply_tool_search(registry, context_window=128_000, reserved_output=8_000)
    assert decision.active is True
    assert len(decision.deferred) == 160
    docs = render_tool_docs(registry)
    for name in CORE_SAMPLE:
        assert f"## {name}" in docs, f"core tool {name} vanished"
    assert "mcp__server0__tool0" not in docs
    assert "mcp__server7__tool19" not in docs


def test_the_saving_is_real_and_large():
    registry = build_registry(servers=8, tools_per_server=20)
    before = tool_doc_tokens(registry)
    decision = apply_tool_search(registry, context_window=128_000, reserved_output=8_000)
    after = tool_doc_tokens(registry)
    assert decision.tokens_before == before
    assert decision.tokens_after == after
    # 160 MCP tools cost far more than the declared set keeps afterwards.
    assert after < before / 5
    assert decision.saved_tokens > 10_000
    # And the thing actually sent — the native `tools` array — shrank with it.
    untouched = build_registry(servers=8, tools_per_server=20)
    assert len(registry.openai_tools()) < len(untouched.openai_tools())
    assert len(json.dumps(registry.openai_tools())) < len(
        json.dumps(untouched.openai_tools())
    ) / 5


def test_the_cost_is_measured_on_the_native_schema_not_on_prose():
    """What the model is billed for is the `tools` array on every request, so
    that — compactly serialized, byte for byte — is what the threshold weighs.

    Measuring the old prompt-text rendering instead would defer at the wrong
    size, because the two are not the same length.
    """
    registry = build_registry(servers=1, tools_per_server=1)
    name = "mcp__server0__tool0"
    expected = estimate_tokens(
        json.dumps(registry.openai_tool(name), separators=(",", ":"))
    )
    assert tool_doc_tokens(registry, [name]) == expected
    # The whole visible surface is just the sum of the same per-tool measure.
    assert tool_doc_tokens(registry) == sum(
        tool_doc_tokens(registry, [n]) for n in registry.names()
    )


def test_threshold_is_measured_against_the_effective_budget():
    registry = build_registry(servers=2, tools_per_server=20)
    # A large window keeps 40 MCP tools under 10%.
    assert apply_tool_search(registry, context_window=1_000_000, reserved_output=8_000).active is False
    # The same tools against a small window trip it.
    assert apply_tool_search(registry, context_window=16_000, reserved_output=4_000).active is True


def test_decision_is_idempotent_and_recomputed_from_the_undeferred_state():
    registry = build_registry(servers=8, tools_per_server=20)
    first = apply_tool_search(registry, context_window=128_000, reserved_output=8_000)
    second = apply_tool_search(registry, context_window=128_000, reserved_output=8_000)
    assert first.tokens_before == second.tokens_before
    assert first.tokens_after == second.tokens_after
    assert first.deferred == second.deferred
    # And a bigger window puts them all back.
    third = apply_tool_search(registry, context_window=4_000_000, reserved_output=8_000)
    assert third.active is False
    assert registry.deferred_names() == []
    assert "mcp__server0__tool0" in render_tool_docs(registry)


# -- core tools can never be deferred -------------------------------------


def test_registry_refuses_to_defer_a_tool_that_did_not_opt_in():
    registry = build_registry()
    for name in CORE_SAMPLE:
        try:
            registry.defer(name)
        except ValueError as exc:
            assert "not deferrable" in str(exc)
        else:  # pragma: no cover - the failure we are guarding against
            raise AssertionError(f"{name} was deferrable")


def test_a_core_name_marked_deferrable_is_still_never_deferred():
    """The second belt: even a mis-registered core tool stays declared."""
    registry = build_registry(servers=8, tools_per_server=20)
    registry.register(
        "web_search",
        _core_schema("web_search"),
        lambda **kw: {"ok": True},
        deferrable=True,
    )
    assert "web_search" in CORE_TOOLS
    decision = apply_tool_search(registry, context_window=128_000, reserved_output=8_000)
    assert decision.active is True
    assert "web_search" not in decision.deferred
    assert "## web_search" in render_tool_docs(registry)


def test_unavailable_tools_are_not_counted_and_not_deferred():
    registry = build_registry(servers=8, tools_per_server=20)
    registry.register(
        "mcp__dead__thing",
        _mcp_schema("dead", 0),
        lambda **kw: {"ok": True},
        check_fn=lambda: False,
        deferrable=True,
    )
    decision = apply_tool_search(registry, context_window=128_000, reserved_output=8_000)
    assert "mcp__dead__thing" not in decision.deferred


# -- what the loop's toolset makes of it ---------------------------------


def deferred_registry() -> ToolRegistry:
    registry = build_registry(servers=8, tools_per_server=20)
    registry.register(
        "mcp__github__create_issue",
        {
            "type": "object",
            "description": "[MCP: github] Create an issue in a repository.",
            "properties": {
                "repo": {"type": "string", "description": "owner/name."},
                "title": {"type": "string", "description": "Issue title."},
            },
            "required": ["repo", "title"],
        },
        lambda repo, title: {"ok": True, "repo": repo, "title": title},
        deferrable=True,
    )
    apply_tool_search(registry, context_window=128_000, reserved_output=8_000)
    return registry


def test_deferred_tools_reach_pydantic_ai_as_defer_loading_tools():
    import asyncio

    from chuk_agents_runtime.pai.tools import RegistryToolset

    registry = deferred_registry()
    tools = asyncio.run(RegistryToolset(registry, deferred_mode="pai").get_tools(None))
    assert tools["mcp__github__create_issue"].tool_def.defer_loading is True
    assert tools["mcp__github__create_issue"].tool_def.description.startswith("[MCP: github]")
    for name in CORE_SAMPLE:
        assert tools[name].tool_def.defer_loading is False
    # No bridge tools any more: the search tool is Pydantic AI's.
    assert not {"tool_search", "tool_describe", "tool_call"} & set(tools)


def test_a_deferred_tool_is_still_dispatchable_directly():
    """Deferral is declaration-only: journaling, coercion and the error envelope
    stay on the one dispatch path."""
    registry = deferred_registry()
    assert registry.is_deferred("mcp__github__create_issue") is True
    direct = registry.dispatch(
        "mcp__github__create_issue", {"repo": "a/b", "title": "direct"}
    )
    assert direct["ok"] is True
