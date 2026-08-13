"""MCP client tests (§9). Real SDK, real protocol, no network.

``stdio`` spawns ``tests/fake_mcp_server.py`` as a subprocess. The streamable
HTTP path talks to a server that lives in this very process through
``httpx.ASGITransport``, so the HTTP transport is exercised without a socket.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

from cowork_agent.mcp_client import (
    HTTP,
    SSE,
    STDIO,
    MCPConnection,
    MCPManager,
    MCPServerConfig,
    load_mcp_config,
    parse_mcp_config,
    register_mcp_tools,
    tool_name,
)
from cowork_agent.prompt import render_tool_docs
from cowork_agent.registry import ToolRegistry

FAKE_SERVER = str(Path(__file__).parent / "fake_mcp_server.py")


def stdio_config(name: str = "fake", **kwargs) -> MCPServerConfig:
    return MCPServerConfig(
        name=name,
        transport=STDIO,
        command=sys.executable,
        args=[FAKE_SERVER],
        connect_timeout=30.0,
        call_timeout=30.0,
        **kwargs,
    )


@pytest.fixture
def connection():
    conn = MCPConnection(stdio_config())
    try:
        yield conn
    finally:
        conn.close()


# -- configuration ---------------------------------------------------------


def test_parse_config_infers_transports():
    configs, errors = parse_mcp_config(
        json.dumps(
            {
                "mcpServers": {
                    "local": {"command": "uvx", "args": ["thing"], "env": {"A": "1"}},
                    "remote": {"url": "https://mcp.example.com/mcp"},
                    "legacy": {"url": "https://mcp.example.com/sse"},
                    "explicit": {"url": "https://x/y", "transport": "streamable-http"},
                }
            }
        )
    )
    assert errors == []
    by_name = {c.name: c for c in configs}
    assert by_name["local"].transport == STDIO
    assert by_name["local"].env == {"A": "1"}
    assert by_name["remote"].transport == HTTP
    assert by_name["legacy"].transport == SSE
    assert by_name["explicit"].transport == HTTP


def test_parse_config_keeps_good_entries_when_one_is_broken():
    configs, errors = parse_mcp_config(
        json.dumps(
            {
                "mcpServers": {
                    "good": {"command": "true"},
                    "no_command": {"args": ["x"]},
                    "bad_url": {"url": "ftp://nope"},
                    "not_an_object": 5,
                }
            }
        )
    )
    assert [c.name for c in configs] == ["good"]
    assert len(errors) == 3


def test_parse_config_rejects_garbage():
    assert parse_mcp_config("not json")[1]
    assert parse_mcp_config("[]")[1]
    assert parse_mcp_config("{}")[1]


def test_load_config_from_workspace(tmp_path):
    (tmp_path / ".cowork").mkdir()
    (tmp_path / ".cowork" / "mcp.json").write_text(
        json.dumps({"mcpServers": {"a": {"command": "true"}}})
    )
    configs, errors = load_mcp_config(str(tmp_path))
    assert [c.name for c in configs] == ["a"]
    assert errors == []


def test_load_config_without_file_is_silent(tmp_path):
    assert load_mcp_config(str(tmp_path)) == ([], [])
    assert load_mcp_config(None) == ([], [])


# -- stdio: the real protocol ---------------------------------------------


def test_stdio_connects_and_lists_tools_with_schema(connection):
    assert connection.start() is True, connection.error
    assert connection.error is None
    names = {tool.name for tool in connection.tools}
    assert {"shout", "calls", "add", "explode"} <= names
    add = next(tool for tool in connection.tools if tool.name == "add")
    assert add.schema["properties"]["a"]["type"] == "integer"
    assert set(add.schema.get("required", [])) == {"a", "b"}


def test_registration_puts_mcp_tools_in_the_registry_with_schema():
    registry = ToolRegistry()
    manager = MCPManager([stdio_config("papers")])
    try:
        registered = register_mcp_tools(registry, manager)
        assert tool_name("papers", "shout") in registered
        spec = registry.spec("mcp__papers__shout")
        assert spec.deferrable is True
        assert spec.schema["properties"]["text"]["type"] == "string"
        assert "[MCP: papers]" in spec.schema["description"]
        # The call goes through the registry, so coercion and journaling apply.
        result = registry.dispatch("mcp__papers__shout", {"text": "hello"})
        assert result["ok"] is True
        assert result["content"] == "HELLO"
        # Stringy args are coerced against the server's own schema.
        assert registry.dispatch("mcp__papers__add", {"a": "2", "b": "3"})["content"] == "5"
    finally:
        manager.close()


def test_persistent_session_is_reused_across_calls():
    """Two calls, one session: the server-side counter increments instead of
    restarting at 1, and the pid is the same subprocess."""
    manager = MCPManager([stdio_config("counter")])
    try:
        assert manager.start() == {"counter": True}
        first = json.loads(manager.call("counter", "calls", {})["content"])
        second = json.loads(manager.call("counter", "calls", {})["content"])
        assert second["calls"] == first["calls"] + 1
        assert second["pid"] == first["pid"]
    finally:
        manager.close()


def test_tool_error_is_bounded():
    manager = MCPManager([stdio_config("boom")])
    registry = ToolRegistry()
    try:
        register_mcp_tools(registry, manager)
        result = registry.dispatch("mcp__boom__explode", {"size": 500_000})
        assert result["ok"] is False
        # The registry caps an *error envelope* at 2048 chars; a tool that
        # returns a huge error body is capped by this module first.
        assert len(json.dumps(result)) < 25_000
        assert result["error"].endswith("…[truncated]")
    finally:
        manager.close()


def test_registry_error_envelope_stays_bounded_for_unknown_mcp_tool():
    registry = ToolRegistry()
    manager = MCPManager([stdio_config("srv")])
    try:
        register_mcp_tools(registry, manager)
        result = manager.call("srv", "does_not_exist", {})
        assert result["ok"] is False
        assert "does_not_exist" in result["error"]
    finally:
        manager.close()


def test_close_ends_the_session_and_tools_drop_out_of_the_prompt():
    registry = ToolRegistry()
    manager = MCPManager([stdio_config("temp")])
    register_mcp_tools(registry, manager)
    assert registry.available("mcp__temp__shout") is True
    manager.close()
    assert registry.available("mcp__temp__shout") is False
    assert "mcp__temp__shout" not in render_tool_docs(registry)
    # Still dispatchable — and answers with an error, not an exception.
    assert registry.dispatch("mcp__temp__shout", {"text": "x"})["error"]


# -- a broken server must not break the start -----------------------------


def test_unreachable_server_is_recorded_and_registers_nothing():
    registry = ToolRegistry()
    manager = MCPManager(
        [
            MCPServerConfig(
                name="ghost",
                transport=STDIO,
                command="/definitely/not/a/binary",
                connect_timeout=5.0,
            ),
            stdio_config("working"),
        ]
    )
    try:
        status = manager.start()
        assert status["ghost"] is False
        assert status["working"] is True
        assert any("ghost" in error for error in manager.errors)
        registered = manager.register(registry)
        assert all("ghost" not in name for name in registered)
        assert any("working" in name for name in registered)
        docs = render_tool_docs(registry)
        assert "ghost" not in docs
        assert "mcp__working__shout" in docs
    finally:
        manager.close()


def test_server_that_exits_immediately_is_not_fatal():
    manager = MCPManager(
        [
            MCPServerConfig(
                name="quitter",
                transport=STDIO,
                command=sys.executable,
                args=["-c", "raise SystemExit(1)"],
                connect_timeout=10.0,
            )
        ]
    )
    try:
        assert manager.start() == {"quitter": False}
        assert manager.connections["quitter"].error
        assert manager.register(ToolRegistry()) == []
    finally:
        manager.close()


def test_invalid_config_fails_the_check_not_the_process():
    connection = MCPConnection(MCPServerConfig(name="x", transport=HTTP, url=None))
    assert connection.start() is False
    assert connection.alive() is False
    assert "url" in (connection.error or "")


def test_status_reports_every_configured_server():
    manager = MCPManager(
        [stdio_config("up"), MCPServerConfig(name="off", command="true", enabled=False)]
    )
    try:
        manager.start()
        rows = {row["server"]: row for row in manager.status()}
        assert rows["up"]["connected"] is True
        assert rows["up"]["tools"] >= 4
        assert rows["off"]["connected"] is False
        assert rows["off"]["error"] == "disabled"
    finally:
        manager.close()


# -- streamable HTTP, in-process ------------------------------------------


@pytest.fixture(params=[HTTP, SSE])
def http_transport(request):
    """The same fake server behind its HTTP transports, on a loopback port.

    Loopback only — nothing leaves the machine — but a real socket, a real ASGI
    server and the SDK's real HTTP client code, which an in-process shim would
    not exercise (the streamable-HTTP session manager only starts under an ASGI
    lifespan).
    """
    import socket
    import threading
    import time

    import uvicorn

    from fake_mcp_server import build_server

    server_app = build_server("http-fake")
    transport = request.param
    if transport == HTTP:
        app, path = server_app.streamable_http_app(), "/mcp"
    else:
        app, path = server_app.sse_app(), "/sse"

    seen_headers: list[dict[str, str]] = []

    async def record(scope, receive, send):
        if scope["type"] == "http":
            seen_headers.append(
                {k.decode(): v.decode() for k, v in scope.get("headers", [])}
            )
        await app(scope, receive, send)

    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 0))
    port = listener.getsockname()[1]
    server = uvicorn.Server(uvicorn.Config(record, log_level="error"))
    thread = threading.Thread(
        target=lambda: server.run(sockets=[listener]), daemon=True
    )
    thread.start()
    deadline = time.monotonic() + 30
    while not server.started and time.monotonic() < deadline:
        time.sleep(0.05)
    assert server.started, "test http server did not start"
    try:
        yield transport, f"http://127.0.0.1:{port}{path}", seen_headers
    finally:
        server.should_exit = True
        thread.join(15)


def test_http_transports_round_trip(http_transport):
    """Both HTTP transports: handshake, tool list, call — and the stash token
    arriving as a bearer header and nowhere else."""
    transport, url, seen_headers = http_transport
    connection = MCPConnection(
        MCPServerConfig(
            name="http-fake",
            transport=transport,
            url=url,
            connect_timeout=30.0,
            call_timeout=30.0,
        ),
        token_provider=lambda server: "secret-token",
    )
    try:
        assert connection.start() is True, connection.error
        assert {tool.name for tool in connection.tools} >= {"shout", "calls"}
        assert connection.call("shout", {"text": "via http"})["content"] == "VIA HTTP"
        assert any(
            headers.get("authorization") == "Bearer secret-token"
            for headers in seen_headers
        )
    finally:
        connection.close()


def test_http_server_that_is_not_listening_fails_cleanly():
    connection = MCPConnection(
        MCPServerConfig(
            name="down",
            transport=HTTP,
            # Port 1 on loopback: refused immediately, no traffic leaves the host.
            url="http://127.0.0.1:1/mcp",
            connect_timeout=5.0,
        )
    )
    try:
        assert connection.start() is False
        assert connection.error
        assert connection.alive() is False
    finally:
        connection.close()


def test_reconnect_swaps_the_session_under_registered_tools():
    registry = ToolRegistry()
    manager = MCPManager([stdio_config("rc")])
    try:
        register_mcp_tools(registry, manager)
        before = json.loads(registry.dispatch("mcp__rc__calls", {})["content"])
        assert manager.reconnect("rc") is True
        after = json.loads(registry.dispatch("mcp__rc__calls", {})["content"])
        # A new process: the counter restarts, and the already registered tool
        # still works because it routes through the manager.
        assert after["pid"] != before["pid"]
        assert after["calls"] == 1
    finally:
        manager.close()
