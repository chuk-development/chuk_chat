"""``network: false`` withholds the host-side internet tools
(docs/WIRE_CONTRACT.md, "Agent permissions").

The sandbox gets ``--network none``, but some tools fetch from the HOST
process on the agent's behalf. With the permission off none of them may be
offered: not ``web_fetch``, ``web_search``, the here.now publish or the browser
fallback, and no MCP server from the workspace ``mcp.json`` (those run on the
host or on the internet).
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from types import SimpleNamespace

from chuk_agents_runtime.herenow import HereNowConfig
from chuk_agents_runtime.model import MockModelClient
from chuk_agents_runtime.runtime import HOST_NETWORK_TOOLS, build_runtime, network_allowed

# The runtime reads the policy by duck typing (it does not depend on the
# sandbox package): anything with a ``network`` attribute.
DEFAULT_POLICY = SimpleNamespace(network=True)


def SandboxPolicy(network: bool = True):  # noqa: N802 — the sandbox's name
    return SimpleNamespace(network=network)


FAKE_SERVER = str(Path(__file__).parent / "fake_mcp_server.py")


class _Session:
    access_token = "token"

    def refresh(self) -> None:
        pass


def _build(tmp_path: Path, policy):
    workspace = tmp_path / "ws"
    (workspace / ".agents").mkdir(parents=True, exist_ok=True)
    (workspace / ".agents" / "mcp.json").write_text(
        json.dumps(
            {
                "mcpServers": {
                    "records": {
                        "command": sys.executable,
                        "args": [FAKE_SERVER],
                        "env": {"FAKE_MCP_EXTRA_TOOLS": "0"},
                        "connect_timeout": 30,
                    }
                }
            }
        )
    )
    return build_runtime(
        MockModelClient(["ok"]),
        db_path=str(tmp_path / "state.db"),
        workspace=str(workspace),
        version_workspace=False,
        enable_memory=False,
        enable_chat_search=False,
        session=_Session(),
        herenow_config=HereNowConfig(enabled=True, approval="auto"),
        browser_model=MockModelClient(["ok"]),
        policy=policy,
    )


def _offered(loop) -> set[str]:
    return {t["function"]["name"] for t in loop.registry.openai_tools()}


def test_network_on_keeps_the_web_tools(tmp_path):
    loop = _build(tmp_path, DEFAULT_POLICY)
    try:
        registered = set(loop.registry.names())
        for name in ("web_fetch", "web_search", "herenow_publish", "browser_task"):
            assert name in registered, name
        assert loop.mcp is not None  # the workspace mcp.json was read
    finally:
        if loop.mcp is not None:
            loop.mcp.close()


def test_network_off_withholds_every_host_side_internet_tool(tmp_path):
    loop = _build(tmp_path, SandboxPolicy(network=False))
    try:
        registered = set(loop.registry.names())
        assert not registered & set(HOST_NETWORK_TOOLS)
        assert not _offered(loop) & set(HOST_NETWORK_TOOLS)
        # No MCP server from the workspace: stdio runs on the host.
        assert loop.mcp is None
        assert not any(name.startswith("mcp__") for name in registered)
        # A call to a withheld tool is an unknown tool, not a fetch.
        result = loop.registry.dispatch("web_fetch", {"url": "https://example.com"})
        assert "unknown tool" in result["error"]
        # The sandbox tools stay.
        assert {"run_command", "read_file", "write_file"} <= registered
    finally:
        if loop.mcp is not None:
            loop.mcp.close()


def test_no_policy_is_the_old_behaviour():
    assert network_allowed(None)
    assert network_allowed(DEFAULT_POLICY)
    assert not network_allowed(SandboxPolicy(network=False))


def test_no_network_means_no_mcp_sign_in_tool_even_for_a_passed_manager(tmp_path):
    """The executor may pass a manager (``mcp=``); an exchange-form server in
    it must not bring ``mcp_oauth_connect`` back when the network is off."""
    from chuk_agents_runtime.mcp_client import HTTP, MCPManager, MCPServerConfig

    def build(policy):
        manager = MCPManager(
            [
                MCPServerConfig(
                    name="crm",
                    transport=HTTP,
                    url="http://127.0.0.1:1/mcp",  # refused at once; no traffic leaves
                    connect_timeout=2.0,
                    oauth={"token_url": "https://auth.example/token", "client_id": "cid"},
                )
            ]
        )
        loop = build_runtime(
            MockModelClient(["ok"]),
            db_path=str(tmp_path / f"state-{policy.network}.db"),
            workspace=str(tmp_path / "ws2"),
            version_workspace=False,
            session=_Session(),
            mcp=manager,
            policy=policy,
        )
        manager.close()
        return loop

    assert "mcp_oauth_connect" in build(SandboxPolicy(network=True)).registry.names()
    assert "mcp_oauth_connect" not in build(SandboxPolicy(network=False)).registry.names()
