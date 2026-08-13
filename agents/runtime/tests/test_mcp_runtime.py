"""MCP + Tool Search through the real runtime wiring (§7.2 / §9 / §10).

The unit tests prove each part. This one proves the assembly: a workspace with an
``mcp.json``, a real MCP server behind it, and the prompt that comes out —
including the measured token saving on a realistic tool surface.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

from cowork_agent.context import LadderConfig
from cowork_agent.model import MockModelClient
from cowork_agent.prompt import render_tool_docs
from cowork_agent.runtime import build_runtime
from cowork_agent.tool_search import tool_doc_tokens

FAKE_SERVER = str(Path(__file__).parent / "fake_mcp_server.py")


def write_config(workspace: Path, *, extra_tools: int) -> None:
    (workspace / ".cowork").mkdir(parents=True, exist_ok=True)
    (workspace / ".cowork" / "mcp.json").write_text(
        json.dumps(
            {
                "mcpServers": {
                    "records": {
                        "command": sys.executable,
                        "args": [FAKE_SERVER],
                        "env": {"FAKE_MCP_EXTRA_TOOLS": str(extra_tools)},
                        "connect_timeout": 30,
                    }
                }
            }
        )
    )


@pytest.fixture
def workspace(tmp_path):
    root = tmp_path / "ws"
    root.mkdir()
    return root


def build(workspace: Path, *, context_length: int = 128_000, **kwargs):
    return build_runtime(
        MockModelClient(["done"]),
        db_path=str(workspace.parent / "state.db"),
        workspace=str(workspace),
        version_workspace=False,
        enable_chat_search=False,
        context_config=LadderConfig(context_length=context_length, reserved_output=8_000),
        **kwargs,
    )


def test_no_config_means_no_servers_and_no_bridge(workspace):
    loop = build(workspace)
    try:
        assert loop.mcp is not None
        assert loop.mcp.configs == []
        assert loop.tool_search.active is False
        assert "tool_search" not in render_tool_docs(loop.registry)
    finally:
        loop.mcp.close()


def test_small_server_stays_visible_in_the_prompt(workspace):
    write_config(workspace, extra_tools=0)
    loop = build(workspace)
    try:
        docs = render_tool_docs(loop.registry)
        assert "## mcp__records__shout" in docs
        assert loop.tool_search.active is False
        assert "## run_command" in docs
    finally:
        loop.mcp.close()


def test_big_server_is_deferred_and_the_saving_is_measured(workspace):
    """A 64-tool MCP server against a 32k window: the schemas pass 10% of the
    effective budget, so they leave the prompt and the bridge takes over."""
    write_config(workspace, extra_tools=60)
    loop = build(workspace, context_length=32_000)
    try:
        decision = loop.tool_search
        assert decision.active is True
        assert len(decision.deferred) >= 60
        assert decision.saved_tokens > 3_000
        registry = loop.registry
        assert tool_doc_tokens(registry) == decision.tokens_after

        docs = render_tool_docs(registry)
        # The MCP surface is gone...
        assert "mcp__records__records_0" not in docs
        # ...the bridge is there...
        for name in ("tool_search", "tool_describe", "tool_call"):
            assert f"## {name}" in docs
        # ...and every core tool is still there.
        for name in ("run_command", "write_file", "read_file", "list_dir"):
            assert f"## {name}" in docs

        # The bridge really reaches the server, over the same live session.
        found = registry.dispatch("tool_search", {"query": "records collection 3"})
        assert any(m["name"] == "mcp__records__records_3" for m in found["matches"])
        described = registry.dispatch(
            "tool_describe", {"name": "mcp__records__records_3"}
        )
        assert "`query` (string" in described["documentation"]
        ran = registry.dispatch(
            "tool_call",
            {
                "name": "mcp__records__records_3",
                "arguments": {"query": "abc", "limit": 5},
            },
        )
        assert ran["ok"] is True
        assert '"tool": 3' in ran["content"]
    finally:
        loop.mcp.close()


def test_a_dead_server_in_the_config_does_not_stop_the_runtime(workspace):
    (workspace / ".cowork").mkdir(parents=True)
    (workspace / ".cowork" / "mcp.json").write_text(
        json.dumps(
            {
                "mcpServers": {
                    "ghost": {"command": "/definitely/not/a/binary", "connect_timeout": 5}
                }
            }
        )
    )
    loop = build(workspace)
    try:
        docs = render_tool_docs(loop.registry)
        assert "## run_command" in docs
        assert "ghost" not in docs
        assert any("ghost" in error for error in loop.mcp.errors)
    finally:
        loop.mcp.close()


def test_oauth_tool_is_registered_only_with_a_session_and_a_server(workspace):
    class Session:
        access_token = "token"

        def refresh(self) -> None:
            pass

    write_config(workspace, extra_tools=0)
    with_session = build(workspace, session=Session())
    try:
        assert with_session.registry.has("mcp_oauth_connect")
    finally:
        with_session.mcp.close()

    without = build(workspace)
    try:
        assert not without.registry.has("mcp_oauth_connect")
    finally:
        without.mcp.close()
