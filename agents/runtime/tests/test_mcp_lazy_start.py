"""MCP start latency (bead chuk_chat-4xc5).

The first task of a session used to dial every forwarded MCP server one after
the other and wait for each tool list: five connectors cost ~8.5 s before the
first model call. These tests pin the two fixes:

- the handshakes run in parallel, so a start costs the slowest server;
- with a known tool list (:class:`MCPToolCache`), a server is not waited for at
  all: its cached tools are offered and the handshake finishes in the
  background. A call to such a tool waits for the handshake.

The connections are real :class:`MCPConnection` objects whose transport task
is replaced by a timed fake, so no subprocess and no socket is needed.
"""

from __future__ import annotations

import asyncio
import json
import time

from chuk_agents_runtime.mcp_client import (
    HTTP,
    MCPConnection,
    MCPManager,
    MCPServerConfig,
    MCPToolCache,
    MCPToolInfo,
    register_mcp_tools,
    tool_name,
)
from chuk_agents_runtime.registry import ToolRegistry


def _config(name: str, *, token: str | None = None) -> MCPServerConfig:
    return MCPServerConfig(
        name=name,
        transport=HTTP,
        url=f"https://{name}.example/mcp",
        auth_token=token,
        headers={"X-Api-Key": "header-secret"},
        connect_timeout=5.0,
    )


class _Session:
    """The bit of a toolset that :meth:`MCPConnection.call` touches."""

    def __init__(self, name: str) -> None:
        self.client = self
        self.name = name

    async def call_tool(self, tool, arguments, timeout=None, raise_on_error=False):
        return {"server": self.name, "tool": tool, "arguments": arguments}


def _timed(delay: float, tools: list[str], *, fail: bool = False):
    """A connection class whose handshake takes ``delay`` seconds."""

    class _Timed(MCPConnection):
        async def _session_task(self) -> None:
            self._loop = asyncio.get_running_loop()
            self._stop = asyncio.Event()
            await asyncio.sleep(delay)
            if fail:
                self._error = "HTTPStatusError: 401"
                return
            self._tools = [
                MCPToolInfo(name=t, description=f"{t} tool", schema={"type": "object"})
                for t in tools
            ]
            self._session = _Session(self.config.name)
            self._error = None
            self._connected_once = True
            self._ready.set()
            if self.on_listed is not None:
                self.on_listed(self)
            await self._stop.wait()

    return _Timed


def test_new_servers_are_dialed_in_parallel():
    slow = _timed(0.5, ["ping"])
    manager = MCPManager(
        [_config("a"), _config("b"), _config("c")], connection_factory=slow
    )
    try:
        started = time.monotonic()
        status = manager.start()
        elapsed = time.monotonic() - started
    finally:
        manager.close()
    assert status == {"a": True, "b": True, "c": True}
    # Three 0.5 s handshakes one after the other would take 1.5 s.
    assert elapsed < 1.2, elapsed


def test_a_cached_server_is_not_waited_for_and_its_tools_are_offered(tmp_path):
    cache = MCPToolCache(tmp_path / "mcp-tools.json")
    config = _config("canva")
    cache.put(config, [MCPToolInfo(name="search", description="find", schema={"type": "object"})])
    manager = MCPManager(
        [config],
        connection_factory=_timed(1.0, ["search", "create"]),
        tool_cache=MCPToolCache(tmp_path / "mcp-tools.json"),
    )
    try:
        started = time.monotonic()
        status = manager.start()
        assert time.monotonic() - started < 0.5
        assert status == {"canva": True}
        assert manager.pending() == ["canva"]
        registry = ToolRegistry()
        names = manager.register(registry)
        assert names == [tool_name("canva", "search")]
        # The tool's check passes while the handshake runs.
        assert manager.is_alive("canva")
        # A call waits for the handshake and then runs on the live session.
        result = manager.call("canva", "search", {"q": "x"})
        assert result.get("ok") is not False, result
        assert manager.pending() == []
        # The live list replaced the cached one (on the next task's register).
        assert [t.name for t in manager.connections["canva"].tools] == ["search", "create"]
    finally:
        manager.close()
    # ...and the cache file now holds the live list.
    fresh = MCPToolCache(tmp_path / "mcp-tools.json").get(config)
    assert [t.name for t in fresh] == ["search", "create"]


def test_an_unknown_server_is_waited_for_and_then_cached(tmp_path):
    path = tmp_path / "mcp-tools.json"
    manager = MCPManager(
        [_config("notion")],
        connection_factory=_timed(0.2, ["query"]),
        tool_cache=MCPToolCache(path),
    )
    try:
        assert manager.start() == {"notion": True}
        assert manager.pending() == []
        assert manager.register(ToolRegistry()) == [tool_name("notion", "query")]
    finally:
        manager.close()
    assert [t.name for t in MCPToolCache(path).get(_config("notion"))] == ["query"]


def test_register_mcp_tools_returns_before_a_cached_server_is_up(tmp_path):
    cache = MCPToolCache(tmp_path / "t.json")
    configs = [_config(f"s{i}") for i in range(5)]
    for config in configs:
        cache.put(config, [MCPToolInfo(name="t", description="", schema={})])
    manager = MCPManager(configs, connection_factory=_timed(1.5, ["t"]), tool_cache=cache)
    try:
        started = time.monotonic()
        names = register_mcp_tools(ToolRegistry(), manager)
        assert time.monotonic() - started < 0.5
        assert len(names) == 5
    finally:
        manager.close()


def test_the_probe_waits_for_every_server_even_a_cached_one(tmp_path):
    cache = MCPToolCache(tmp_path / "t.json")
    config = _config("slack")
    cache.put(config, [MCPToolInfo(name="old", description="", schema={})])
    manager = MCPManager([config], connection_factory=_timed(0.4, ["new"]), tool_cache=cache)
    try:
        manager.start()  # lazy: returns at once
        assert manager.pending() == ["slack"]
        assert manager.start(lazy=False) == {"slack": True}
        assert manager.pending() == []
        assert [t.name for t in manager.connections["slack"].tools] == ["new"]
    finally:
        manager.close()


def test_a_cached_server_that_fails_in_the_background_drops_its_tools(tmp_path):
    cache = MCPToolCache(tmp_path / "t.json")
    config = _config("gmail")
    cache.put(config, [MCPToolInfo(name="send", description="", schema={})])
    manager = MCPManager(
        [config], connection_factory=_timed(0.2, [], fail=True), tool_cache=cache
    )
    try:
        assert manager.start() == {"gmail": True}
        result = manager.call("gmail", "send", {})
        assert result["ok"] is False
        assert "401" in result["error"]
        assert not manager.is_alive("gmail")
        assert manager.register(ToolRegistry()) == []
    finally:
        manager.close()


def test_the_cache_stores_no_credentials(tmp_path):
    path = tmp_path / "t.json"
    cache = MCPToolCache(path)
    config = _config("drive", token="SECRET-BEARER")
    cache.put(config, [MCPToolInfo(name="list", description="d", schema={"type": "object"})])
    text = path.read_text(encoding="utf-8")
    assert "SECRET-BEARER" not in text
    assert "header-secret" not in text
    assert "drive.example" not in text  # the key is a hash, not the url
    assert (path.stat().st_mode & 0o777) == 0o600
    # A rotated bearer is the same server: the same entry.
    assert [t.name for t in cache.get(_config("drive", token="OTHER"))] == ["list"]
    assert json.loads(text)


def test_a_broken_cache_file_is_ignored(tmp_path):
    path = tmp_path / "t.json"
    path.write_text("{not json", encoding="utf-8")
    cache = MCPToolCache(path)
    assert cache.get(_config("x")) == []
    cache.put(_config("x"), [MCPToolInfo(name="a", description="", schema={})])
    assert [t.name for t in MCPToolCache(path).get(_config("x"))] == ["a"]


# -- servers that fail (bead chuk_chat-l16i) --------------------------------
#
# After a host restart the first task still waited ~3 s for MCP: two of five
# connectors failed on every handshake, so they never got a tool list in the
# cache, and every new manager waited for them to fail again.


def test_a_server_that_failed_is_not_waited_for_after_a_restart(tmp_path):
    path = tmp_path / "t.json"
    good = _config("github")
    bad = _config("broken")
    # First host life: nothing is known, so the start waits for both, and the
    # broken server is marked.
    manager = MCPManager(
        [good, bad],
        connection_factory=lambda c: _timed(0.3, ["t"], fail=c.name == "broken")(c),
        tool_cache=MCPToolCache(path),
    )
    try:
        assert manager.start() == {"github": True, "broken": False}
    finally:
        manager.close()
    stored = json.loads(path.read_text(encoding="utf-8"))
    assert sorted(type(v).__name__ for v in stored.values()) == ["dict", "list"]
    assert MCPToolCache(path).failed(bad)
    assert not MCPToolCache(path).failed(good)

    # Second host life: a new cache object on the same file. The broken server
    # takes 2 s to fail; the start does not wait for it, nor for the good one.
    manager = MCPManager(
        [good, bad],
        connection_factory=lambda c: _timed(
            2.0 if c.name == "broken" else 1.0, ["t"], fail=c.name == "broken"
        )(c),
        tool_cache=MCPToolCache(path),
    )
    try:
        started = time.monotonic()
        status = manager.start()
        assert time.monotonic() - started < 0.2
        assert status == {"github": True, "broken": False}
        assert sorted(manager.pending()) == ["broken", "github"]
        # Only the known tools are offered; nothing is recorded as an error
        # while the broken server is still connecting.
        assert manager.register(ToolRegistry()) == [tool_name("github", "t")]
        assert manager.errors == []
        # The next task of the same session does not wait for it either.
        started = time.monotonic()
        assert manager.start()["broken"] is False
        assert time.monotonic() - started < 0.2
    finally:
        manager.close()


def test_a_marked_server_that_answers_again_gets_its_tools_back(tmp_path):
    path = tmp_path / "t.json"
    config = _config("notion")
    MCPToolCache(path).put_failed(config)
    manager = MCPManager(
        [config], connection_factory=_timed(0.2, ["query"]), tool_cache=MCPToolCache(path)
    )
    try:
        assert manager.start() == {"notion": False}  # not waited for
        manager.connections["notion"].await_start()
        # The next task of the session offers the tools...
        assert manager.start() == {"notion": True}
        assert manager.register(ToolRegistry()) == [tool_name("notion", "query")]
    finally:
        manager.close()
    # ...and the next host life has them at once: the list replaced the mark.
    fresh = MCPToolCache(path)
    assert not fresh.failed(config)
    assert [t.name for t in fresh.get(config)] == ["query"]


def test_a_failure_never_replaces_a_known_tool_list(tmp_path):
    path = tmp_path / "t.json"
    cache = MCPToolCache(path)
    config = _config("gmail")
    cache.put(config, [MCPToolInfo(name="send", description="", schema={})])
    manager = MCPManager(
        [config], connection_factory=_timed(0.1, [], fail=True), tool_cache=cache
    )
    try:
        manager.start(lazy=False)
    finally:
        manager.close()
    fresh = MCPToolCache(path)
    assert not fresh.failed(config)
    assert [t.name for t in fresh.get(config)] == ["send"]


def test_a_server_that_fails_every_time_writes_the_file_once(tmp_path):
    path = tmp_path / "t.json"
    config = _config("dead")
    for _ in range(2):
        manager = MCPManager(
            [config],
            connection_factory=_timed(0.05, [], fail=True),
            tool_cache=MCPToolCache(path),
        )
        try:
            manager.start(lazy=False)
        finally:
            manager.close()
        if _ == 0:
            first = path.stat().st_mtime_ns
            marked = json.loads(path.read_text(encoding="utf-8"))
    assert path.stat().st_mtime_ns == first
    assert json.loads(path.read_text(encoding="utf-8")) == marked


def test_a_closed_handshake_is_not_a_failure(tmp_path):
    path = tmp_path / "t.json"
    config = _config("slow")
    manager = MCPManager(
        [config], connection_factory=_timed(5.0, ["t"]), tool_cache=MCPToolCache(path)
    )
    connection = manager._factory(config)
    manager._wire_cache(config, connection)
    connection.begin()
    connection.close()
    assert not MCPToolCache(path).failed(config)
