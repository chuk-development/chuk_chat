"""A model that reaches for the browser must learn what to reach for instead.

Bead cowork-3i5c: with the browser off, ``mcp__playwright__browser_navigate``
came back as a bare "unknown tool". The model has no way to read that as "use
another tool", so it retried the same name and the user's errand failed. The
error now names the tool that is actually there.
"""

from __future__ import annotations

from cowork_agent.registry import ToolRegistry, unknown_tool_message


def test_a_browser_tool_name_points_at_browser_task():
    message = unknown_tool_message("mcp__playwright__browser_navigate")
    assert "unknown tool" in message
    assert "browser_task" in message


def test_any_other_name_stays_a_plain_unknown_tool():
    assert unknown_tool_message("frobnicate") == "unknown tool: frobnicate"


def test_dispatch_carries_the_hint():
    registry = ToolRegistry()
    result = registry.dispatch("mcp__playwright__browser_click", {"ref": "x"})
    assert "browser_task" in result["error"]


def test_the_deferred_bridge_carries_it_too():
    from cowork_agent.tool_search import make_tool_call_handler

    registry = ToolRegistry()
    tool_call = make_tool_call_handler(registry)
    result = tool_call("mcp__playwright__browser_navigate", {"url": "https://x"})
    assert result["ok"] is False
    assert "browser_task" in result["error"]
