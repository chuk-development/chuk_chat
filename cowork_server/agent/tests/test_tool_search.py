"""Tool Search / progressive disclosure tests (§7.2).

The load-bearing claims: under the threshold nothing changes, above it exactly
the deferrable tools leave the prompt, core tools never do, and the three bridge
tools can find, describe and run what was hidden.
"""

from __future__ import annotations

from cowork_agent.prompt import build_system_prompt, render_tool_docs
from cowork_agent.registry import ToolRegistry
from cowork_agent.tool_search import (
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


def test_below_the_threshold_every_tool_stays_in_the_prompt():
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


def test_above_the_threshold_only_the_bridge_and_the_core_tools_remain():
    registry = build_registry(servers=8, tools_per_server=20)
    decision = apply_tool_search(registry, context_window=128_000, reserved_output=8_000)
    assert decision.active is True
    assert len(decision.deferred) == 160
    docs = render_tool_docs(registry)
    for name in CORE_SAMPLE:
        assert f"## {name}" in docs, f"core tool {name} vanished"
    for name in ("tool_search", "tool_describe", "tool_call"):
        assert f"## {name}" in docs
    assert "mcp__server0__tool0" not in docs
    assert "mcp__server7__tool19" not in docs


def test_the_saving_is_real_and_large():
    registry = build_registry(servers=8, tools_per_server=20)
    before = tool_doc_tokens(registry)
    decision = apply_tool_search(registry, context_window=128_000, reserved_output=8_000)
    after = tool_doc_tokens(registry)
    assert decision.tokens_before == before
    assert decision.tokens_after == after
    # 160 MCP tools cost far more than the whole prompt keeps afterwards.
    assert after < before / 5
    assert decision.saved_tokens > 10_000
    # And the prompt itself shrank by the same order.
    assert len(build_system_prompt(registry)) < len(
        build_system_prompt(build_registry(servers=8, tools_per_server=20))
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
    """The second belt: even a mis-registered core tool stays in the prompt."""
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


# -- the three bridge tools -----------------------------------------------


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


def test_tool_search_finds_a_deferred_tool():
    registry = deferred_registry()
    result = registry.dispatch("tool_search", {"query": "create issue github"})
    assert result["ok"] is True
    assert result["matches"][0]["name"] == "mcp__github__create_issue"
    assert result["total_available"] == 161


def test_tool_search_reports_no_match_without_inventing_one():
    registry = deferred_registry()
    result = registry.dispatch("tool_search", {"query": "zzzzq unrelated"})
    assert result["matches"] == []
    assert "No match" in result["hint"]


def test_tool_describe_returns_the_schema_the_prompt_would_have_carried():
    registry = deferred_registry()
    result = registry.dispatch("tool_describe", {"name": "mcp__github__create_issue"})
    assert result["ok"] is True
    assert "Create an issue" in result["documentation"]
    assert "`repo` (string, required)" in result["documentation"]
    assert result["schema"]["required"] == ["repo", "title"]
    # Character-for-character what render_tool_docs would have written.
    from cowork_agent.prompt import render_tool_block

    assert result["documentation"] == render_tool_block(
        "mcp__github__create_issue", result["schema"]
    )


def test_tool_describe_rejects_an_unknown_name():
    registry = deferred_registry()
    assert registry.dispatch("tool_describe", {"name": "nope"})["ok"] is False


def test_tool_call_runs_a_deferred_tool():
    registry = deferred_registry()
    result = registry.dispatch(
        "tool_call",
        {
            "name": "mcp__github__create_issue",
            "arguments": {"repo": "a/b", "title": "it broke"},
        },
    )
    assert result == {"ok": True, "repo": "a/b", "title": "it broke"}


def test_tool_call_accepts_arguments_sent_as_a_json_string():
    registry = deferred_registry()
    result = registry.dispatch(
        "tool_call",
        {
            "name": "mcp__github__create_issue",
            "arguments": '{"repo": "a/b", "title": "stringy"}',
        },
    )
    assert result["title"] == "stringy"


def test_tool_call_refuses_a_visible_tool_and_says_why():
    registry = deferred_registry()
    result = registry.dispatch("tool_call", {"name": "run_command", "arguments": {"x": "1"}})
    assert result["ok"] is False
    assert "call it directly" in result["error"]


def test_tool_call_of_an_unknown_tool_is_a_bounded_error():
    registry = deferred_registry()
    assert registry.dispatch("tool_call", {"name": "ghost"})["ok"] is False


def test_a_deferred_tool_is_still_dispatchable_directly():
    """Deferral is prompt-only: journaling, coercion and the error envelope stay
    on the one dispatch path."""
    registry = deferred_registry()
    assert registry.is_deferred("mcp__github__create_issue") is True
    direct = registry.dispatch(
        "mcp__github__create_issue", {"repo": "a/b", "title": "direct"}
    )
    assert direct["ok"] is True
