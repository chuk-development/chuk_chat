"""A connector whose sign-in lapsed answers ``auth_required`` (CHAT-77).

Before, a server whose dial failed with ``kind=auth`` contributed no tools:
the model never saw Fastmail, never got an error, and searched another way
for minutes. Now its tools stay offered (from the tool cache, or one
stand-in) and a call answers at once with a structured ``auth_required``.
"""

from __future__ import annotations

from chuk_agents_runtime.mcp_client import (
    ERROR_KIND_AUTH,
    ERROR_KIND_NETWORK,
    MCPManager,
    MCPServerConfig,
    MCPToolCache,
    MCPToolInfo,
)
from chuk_agents_runtime.registry import ToolRegistry


class _Refused:
    """A connection whose handshake failed."""

    kind = ERROR_KIND_AUTH
    seeded: list[MCPToolInfo] = []

    def __init__(self, config: MCPServerConfig) -> None:
        self.config = config
        self.tools = list(self.seeded)
        self.error = "401 Unauthorized"
        self.error_kind = self.kind
        self.connected_once = False
        self.pending = False
        self.calls = 0

    def start(self) -> bool:
        return False

    def alive(self) -> bool:
        return False

    def usable(self) -> bool:
        return False

    def call(self, tool, arguments):
        self.calls += 1
        return {"ok": False, "error": "should not be called"}

    def close(self) -> None:
        pass


def _manager(kind: str = ERROR_KIND_AUTH, seeded=None, cache=None) -> MCPManager:
    _Refused.kind = kind
    _Refused.seeded = list(seeded or [])
    manager = MCPManager(
        [MCPServerConfig(name="Fastmail", transport="http", url="https://api.fastmail.example/mcp", connector_id="fastmail")],
        connection_factory=_Refused,
        tool_cache=cache,
    )
    manager.start(lazy=False)
    return manager


def test_a_lapsed_sign_in_keeps_the_tools_and_answers_auth_required():
    tool = MCPToolInfo("list_mailboxes", "List mailboxes", {"type": "object", "properties": {}})
    manager = _manager(seeded=[tool])
    registry = ToolRegistry()
    names = manager.register(registry)
    assert len(names) == 1 and names[0].endswith("list_mailboxes")

    result = manager.call("Fastmail", "list_mailboxes", {})
    assert result["ok"] is False
    assert result["error"] == "auth_required"
    assert result["auth_required"] == {
        "server": "Fastmail",
        "connector_id": "fastmail",
        "url": "https://api.fastmail.example/mcp",
    }
    assert "Fastmail" in result["message"]
    assert manager.connections["Fastmail"].calls == 0


def test_tools_come_from_the_cache_when_the_connection_has_none(tmp_path):
    cache = MCPToolCache(tmp_path / "cache.json")
    config = MCPServerConfig(name="Fastmail", transport="http", url="https://api.fastmail.example/mcp")
    cache.put(config, [MCPToolInfo("search", "", {"type": "object", "properties": {}})])
    manager = _manager(cache=cache)
    names = manager.register(ToolRegistry())
    assert len(names) == 1 and names[0].endswith("search")


def test_with_no_known_tools_one_stand_in_is_offered():
    manager = _manager()
    names = manager.register(ToolRegistry())
    assert len(names) == 1 and names[0].endswith("sign_in_required")
    assert manager.call("Fastmail", "sign_in_required", {})["error"] == "auth_required"


def test_a_network_failure_still_offers_nothing():
    tool = MCPToolInfo("list_mailboxes", "", {"type": "object", "properties": {}})
    manager = _manager(kind=ERROR_KIND_NETWORK, seeded=[tool])
    assert manager.register(ToolRegistry()) == []
    assert manager.auth_required("Fastmail") is False
