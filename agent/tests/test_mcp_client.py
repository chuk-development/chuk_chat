"""MCP client tests (§9). Real SDK, real protocol, no network.

``stdio`` spawns ``tests/fake_mcp_server.py`` as a subprocess. The streamable
HTTP path talks to a server that lives in this very process through
``httpx.ASGITransport``, so the HTTP transport is exercised without a socket.
"""

from __future__ import annotations

import json
import sys
import threading
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest

from cowork_agent.mcp_client import (
    AUTH_APP_SESSION,
    AUTH_OAUTH,
    HTTP,
    SSE,
    STDIO,
    MCPConnection,
    MCPManager,
    MCPServerConfig,
    _looks_unauthorized,
    _redact,
    configs_from_entries,
    load_mcp_config,
    parse_mcp_config,
    refresh_access_token,
    register_mcp_tools,
    token_expired,
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


def test_http_target_attaches_forwarded_auth_token(http_transport):
    """The forwarded ``auth_token`` (no token_provider) rides as a bearer header
    on the HTTP target — the per-session credential-forwarding path."""
    transport, url, seen_headers = http_transport
    connection = MCPConnection(
        MCPServerConfig(
            name="http-fake",
            transport=transport,
            url=url,
            auth_token="forwarded-abc",
            connect_timeout=30.0,
            call_timeout=30.0,
        ),
    )
    try:
        assert connection.start() is True, connection.error
        assert connection.call("shout", {"text": "hi"})["content"] == "HI"
        assert any(
            headers.get("authorization") == "Bearer forwarded-abc"
            for headers in seen_headers
        )
    finally:
        connection.close()


# -- forwarded mcp_servers -> configs (§10) -------------------------------


def test_configs_from_entries_selects_bearer_by_auth():
    configs, errors = configs_from_entries(
        [
            {"name": "github", "url": "https://api.example/v1/mcp/github",
             "transport": "http", "auth": AUTH_APP_SESSION},
            {"name": "tickets", "url": "https://mcp.acme.com/mcp",
             "transport": "http", "auth": AUTH_OAUTH, "access_token": "device-tok"},
            {"name": "public", "url": "https://mcp.pub.com/mcp", "auth": "none"},
        ],
        account_token="ACCOUNT-BEARER",
    )
    assert errors == []
    by_name = {c.name: c for c in configs}
    # appSession -> the executor's own account bearer, resolved server-side.
    assert by_name["github"].auth_token == "ACCOUNT-BEARER"
    assert by_name["github"].transport == HTTP
    # oauth -> the device's forwarded token.
    assert by_name["tickets"].auth_token == "device-tok"
    # none -> unauthenticated.
    assert by_name["public"].auth_token is None


def test_configs_from_entries_appsession_without_account_token_is_unauthed():
    configs, _ = configs_from_entries(
        [{"name": "github", "url": "https://x/mcp", "auth": AUTH_APP_SESSION}],
        account_token=None,
    )
    assert configs[0].auth_token is None


def test_configs_from_entries_skips_bad_entries_not_fatal():
    configs, errors = configs_from_entries(
        [
            {"name": "good", "url": "https://ok/mcp", "auth": "none"},
            {"url": "https://noname/mcp"},          # missing name
            {"name": "bad_url", "url": "ftp://nope"},
            "not-an-object",
            {"name": "no_target"},                   # neither url nor command
        ],
        account_token="t",
    )
    assert [c.name for c in configs] == ["good"]
    assert len(errors) == 4


def test_configs_from_entries_empty_is_silent():
    assert configs_from_entries(None) == ([], [])
    assert configs_from_entries([]) == ([], [])


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


# -- forwarded oauth block: the host renews its own tokens (§10, WS-5) -----
#
# The device signs in once, in a browser, and forwards the whole record. From
# then on the app may be closed for days while the run continues, so the
# executor mints its own access tokens from the refresh token. These tests are
# the contract for that.

FORWARD_FIXTURE = (
    Path(__file__).resolve().parents[2]
    / "app"
    / "test"
    / "fixtures"
    / "mcp_forward_payload.json"
)


def _far_future() -> str:
    return (datetime.now(UTC) + timedelta(hours=1)).isoformat()


def _long_past() -> str:
    return (datetime.now(UTC) - timedelta(hours=1)).isoformat()


def _oauth_config(name: str = "notion", **oauth) -> MCPServerConfig:
    block = {
        "token_endpoint": "https://auth.example/token",
        "client_id": "cid-1",
        "refresh_token": "rt-1",
        "resource": "https://mcp.example/mcp",
        "scope": "read write",
    }
    block.update(oauth)
    return MCPServerConfig(
        name=name,
        transport=HTTP,
        url="https://mcp.example/mcp",
        auth_token="at-old",
        oauth=block,
    )


class _FakeTokenServer:
    """Stands in for ``httpx.post`` against a token endpoint."""

    def __init__(self, *, status=200, payload=None, boom=False):
        self.status = status
        self.payload = payload if payload is not None else {
            "access_token": "at-new",
            "expires_in": 3600,
        }
        self.boom = boom
        self.calls: list[dict] = []

    def __call__(self, url, *, data=None, headers=None, auth=None, **kwargs):
        self.calls.append({"url": url, "data": dict(data or {}), "auth": auth})
        if self.boom:
            raise RuntimeError("network is down")
        server = self

        class _Response:
            status_code = server.status

            @staticmethod
            def json():
                return server.payload

        return _Response()


def test_the_frozen_forward_payload_parses_into_configs():
    """The fixture the Dart side asserts against is read here too, so the two
    languages cannot drift apart silently."""
    body = json.loads(FORWARD_FIXTURE.read_text(encoding="utf-8"))
    configs, errors = configs_from_entries(
        body["mcp_servers"], account_token="ACCOUNT-BEARER"
    )

    assert errors == []
    by_name = {c.name: c for c in configs}
    assert set(by_name) == {"Notion", "Legacy", "Brave", "GitHub"}

    notion = by_name["Notion"]
    assert notion.auth_token == "at-notion"
    assert notion.oauth["refresh_token"] == "rt-notion"
    assert notion.oauth["token_endpoint"] == "https://auth.notion.example/token"
    assert notion.oauth["client_id"] == "cid-notion"
    assert notion.oauth["resource"] == "https://mcp.notion.example/mcp"

    # Signed in by a build that had no oauth block: bearer only.
    assert by_name["Legacy"].auth_token == "at-legacy"
    assert by_name["Legacy"].oauth == {}

    # An API-key connector: credentials already on the URL, no bearer.
    assert by_name["Brave"].auth_token is None
    assert by_name["Brave"].url.endswith("?key=k-123")

    # appSession: the executor's own account bearer.
    assert by_name["GitHub"].auth_token == "ACCOUNT-BEARER"


def test_an_oauth_entry_with_only_refresh_material_is_kept():
    """The reported bug: the app was closed long enough for the bearer to die,
    so the entry arrives with a refresh token and no ``access_token``. It must
    stay a configured server, not silently become an unauthenticated one."""
    configs, errors = configs_from_entries(
        [
            {
                "name": "notion",
                "url": "https://mcp.notion.example/mcp",
                "auth": AUTH_OAUTH,
                "oauth": {
                    "token_endpoint": "https://auth.notion.example/token",
                    "client_id": "cid",
                    "refresh_token": "rt-notion",
                },
            }
        ]
    )

    assert errors == []
    assert configs[0].auth_token is None
    assert configs[0].oauth["refresh_token"] == "rt-notion"


def test_token_expired_reads_the_block():
    assert token_expired(None) is False
    # No stated expiry means no opinion, which reads as live.
    assert token_expired({"refresh_token": "rt"}) is False
    assert token_expired({"expires_at": _far_future()}) is False
    assert token_expired({"expires_at": _long_past()}) is True
    # Inside the skew window, so already treated as dead.
    soon = (datetime.now(UTC) + timedelta(seconds=5)).isoformat()
    assert token_expired({"expires_at": soon}) is True
    # A stamp with no zone is read as UTC rather than guessed at.
    naive = (datetime.now(UTC) + timedelta(hours=1)).replace(tzinfo=None)
    assert token_expired({"expires_at": naive.isoformat()}) is False
    assert token_expired({"expires_at": "not a date"}) is False


def test_refresh_access_token_mints_and_records_the_new_expiry(monkeypatch):
    server = _FakeTokenServer()
    monkeypatch.setattr("httpx.post", server)

    token, block = refresh_access_token(_oauth_config().oauth)

    assert token == "at-new"
    assert server.calls[0]["url"] == "https://auth.example/token"
    sent = server.calls[0]["data"]
    assert sent["grant_type"] == "refresh_token"
    assert sent["refresh_token"] == "rt-1"
    assert sent["client_id"] == "cid-1"
    assert sent["resource"] == "https://mcp.example/mcp"
    assert sent["scope"] == "read write"
    # No client secret was issued, so no Basic header.
    assert server.calls[0]["auth"] is None
    # The old refresh token survives a server that did not rotate it.
    assert block["refresh_token"] == "rt-1"
    assert token_expired(block) is False


def test_refresh_access_token_takes_a_rotated_refresh_token(monkeypatch):
    server = _FakeTokenServer(
        payload={
            "access_token": "at-new",
            "refresh_token": "rt-2",
            "expires_in": 60,
            "scope": "read",
        }
    )
    monkeypatch.setattr("httpx.post", server)

    token, block = refresh_access_token(_oauth_config().oauth)

    assert token == "at-new"
    assert block["refresh_token"] == "rt-2"
    assert block["scope"] == "read"


def test_refresh_access_token_sends_a_client_secret_as_basic_auth(monkeypatch):
    server = _FakeTokenServer()
    monkeypatch.setattr("httpx.post", server)

    refresh_access_token(_oauth_config(client_secret="shh").oauth)

    assert server.calls[0]["auth"] == ("cid-1", "shh")


@pytest.mark.parametrize(
    "server",
    [
        _FakeTokenServer(status=400),
        _FakeTokenServer(boom=True),
        _FakeTokenServer(payload={"error": "invalid_grant"}),
        _FakeTokenServer(payload="not an object"),
    ],
)
def test_refresh_access_token_never_raises(monkeypatch, server):
    monkeypatch.setattr("httpx.post", server)

    token, block = refresh_access_token(_oauth_config().oauth)

    assert token is None
    # The block comes back untouched, so the caller can still forward it.
    assert block["refresh_token"] == "rt-1"


def test_refresh_access_token_without_material_does_not_call_out(monkeypatch):
    server = _FakeTokenServer()
    monkeypatch.setattr("httpx.post", server)

    assert refresh_access_token(None) == (None, {})
    assert refresh_access_token({"token_endpoint": "https://x/token"})[0] is None
    assert refresh_access_token({"refresh_token": "rt"})[0] is None
    assert server.calls == []


def test_headers_use_the_forwarded_bearer_while_it_lives(monkeypatch):
    server = _FakeTokenServer()
    monkeypatch.setattr("httpx.post", server)
    connection = MCPConnection(_oauth_config(expires_at=_far_future()))

    headers = connection._http_headers()  # noqa: SLF001

    assert headers["Authorization"] == "Bearer at-old"
    assert server.calls == []


def test_headers_refresh_a_lapsed_bearer_and_write_it_back(monkeypatch):
    server = _FakeTokenServer()
    monkeypatch.setattr("httpx.post", server)
    config = _oauth_config(expires_at=_long_past())
    connection = MCPConnection(config)

    headers = connection._http_headers()  # noqa: SLF001

    assert headers["Authorization"] == "Bearer at-new"
    # Written back, so the next call in this task does not refresh again.
    assert config.auth_token == "at-new"
    assert token_expired(config.oauth) is False
    assert connection._http_headers()["Authorization"] == "Bearer at-new"  # noqa: SLF001
    assert len(server.calls) == 1


def test_headers_mint_a_bearer_when_the_payload_carried_none(monkeypatch):
    server = _FakeTokenServer()
    monkeypatch.setattr("httpx.post", server)
    config = _oauth_config()
    config.auth_token = None
    connection = MCPConnection(config)

    headers = connection._http_headers()  # noqa: SLF001

    assert headers["Authorization"] == "Bearer at-new"


def test_headers_fall_back_to_the_stale_bearer_when_the_refresh_fails(
    monkeypatch,
):
    monkeypatch.setattr("httpx.post", _FakeTokenServer(status=400))
    connection = MCPConnection(_oauth_config(expires_at=_long_past()))

    headers = connection._http_headers()  # noqa: SLF001

    # The server is the authority on whether the token is dead. Sending it and
    # getting a 401 beats sending nothing.
    assert headers["Authorization"] == "Bearer at-old"


def test_headers_send_nothing_when_there_is_nothing_to_send(monkeypatch):
    monkeypatch.setattr("httpx.post", _FakeTokenServer(status=400))
    config = _oauth_config(expires_at=_long_past())
    config.auth_token = None
    connection = MCPConnection(config)

    assert "Authorization" not in connection._http_headers()  # noqa: SLF001


def test_the_stash_still_wins_over_the_forwarded_material(monkeypatch):
    server = _FakeTokenServer()
    monkeypatch.setattr("httpx.post", server)
    connection = MCPConnection(
        _oauth_config(expires_at=_long_past()),
        token_provider=lambda name: "stash-token",
    )

    headers = connection._http_headers()  # noqa: SLF001

    assert headers["Authorization"] == "Bearer stash-token"
    assert server.calls == []


def test_a_forwarded_oauth_entry_renews_itself_against_a_real_server(
    http_transport, monkeypatch
):
    """End to end on a real socket: the bearer the app forwarded has lapsed, so
    the connection mints a new one before the handshake and the server sees it."""
    transport, url, seen_headers = http_transport
    server = _FakeTokenServer(
        payload={"access_token": "at-renewed", "expires_in": 3600}
    )
    monkeypatch.setattr("httpx.post", server)

    configs, errors = configs_from_entries(
        [
            {
                "name": "http-fake",
                "url": url,
                "transport": transport,
                "auth": AUTH_OAUTH,
                "access_token": "at-dead",
                "oauth": {
                    "token_endpoint": "https://auth.example/token",
                    "client_id": "cid-1",
                    "refresh_token": "rt-1",
                    "expires_at": _long_past(),
                },
            }
        ]
    )
    assert errors == []
    connection = MCPConnection(configs[0])
    try:
        assert connection.start() is True, connection.error
        assert connection.call("shout", {"text": "hi"})["content"] == "HI"
    finally:
        connection.close()

    assert len(server.calls) == 1
    assert any(
        headers.get("authorization") == "Bearer at-renewed"
        for headers in seen_headers
    )
    assert not any(
        headers.get("authorization") == "Bearer at-dead"
        for headers in seen_headers
    )


def test_a_refused_handshake_is_retried_once_with_a_fresh_token(monkeypatch):
    """A 401 on connect is the case the whole block exists for: nobody can open
    a browser, so the executor renews the token itself and dials again."""
    server = _FakeTokenServer()
    monkeypatch.setattr("httpx.post", server)
    config = _oauth_config(name="notion", expires_at=_far_future())
    attempts: list[str | None] = []

    class _Refusing(MCPConnection):
        def start(self) -> bool:
            attempts.append(self.config.auth_token)
            if self.config.auth_token == "at-new":
                self._error = None
                self._ready.set()
                self._session = object()
                self._thread = threading.current_thread()
                return True
            self._error = "McpError: HTTP 401 Unauthorized"
            return False

    manager = MCPManager([config], connection_factory=_Refusing)
    try:
        status = manager.start()
    finally:
        manager.close()

    assert status == {"notion": True}
    assert attempts == ["at-old", "at-new"]
    assert manager.errors == []


def test_a_failure_that_is_not_a_refused_token_is_not_retried(monkeypatch):
    server = _FakeTokenServer()
    monkeypatch.setattr("httpx.post", server)
    config = _oauth_config(name="notion", expires_at=_far_future())
    attempts: list[str | None] = []

    class _Missing(MCPConnection):
        def start(self) -> bool:
            attempts.append(self.config.auth_token)
            self._error = "HTTPStatusError: 404 Not Found"
            return False

    manager = MCPManager([config], connection_factory=_Missing)
    try:
        status = manager.start()
    finally:
        manager.close()

    assert status == {"notion": False}
    assert attempts == ["at-old"]
    # Refreshing a token a 404 never looked at would spend it for nothing.
    assert server.calls == []
    assert len(manager.errors) == 1


def test_a_refused_handshake_without_refresh_material_stays_failed(monkeypatch):
    server = _FakeTokenServer()
    monkeypatch.setattr("httpx.post", server)
    config = MCPServerConfig(
        name="legacy",
        transport=HTTP,
        url="https://mcp.example/mcp",
        auth_token="at-legacy",
    )

    class _Refusing(MCPConnection):
        def start(self) -> bool:
            self._error = "401 Unauthorized"
            return False

    manager = MCPManager([config], connection_factory=_Refusing)
    try:
        status = manager.start()
    finally:
        manager.close()

    assert status == {"legacy": False}
    assert server.calls == []
    assert "not available" in manager.errors[0]


# -- the whole chain on real sockets, no mocks -----------------------------


@pytest.fixture
def token_server():
    """A real OAuth token endpoint on loopback.

    The refresh path is what keeps a run alive after the app is gone, so it is
    worth exercising over an actual socket with the actual ``httpx`` call rather
    than a patched-out ``post``.
    """
    import http.server
    import threading as _threading
    import urllib.parse

    seen: list[dict[str, str]] = []

    class _Handler(http.server.BaseHTTPRequestHandler):
        def do_POST(self):  # noqa: N802 — the base class names it
            length = int(self.headers.get("content-length") or 0)
            body = self.rfile.read(length).decode()
            form = {
                k: v[0] for k, v in urllib.parse.parse_qs(body).items()
            }
            form["_authorization"] = self.headers.get("authorization") or ""
            seen.append(form)
            if form.get("refresh_token") != "rt-1":
                self.send_response(400)
                self.end_headers()
                self.wfile.write(b"invalid_grant")
                return
            payload = json.dumps(
                {
                    "access_token": "at-renewed",
                    "refresh_token": "rt-2",
                    "expires_in": 3600,
                }
            ).encode()
            self.send_response(200)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        def log_message(self, *args):  # noqa: A003 — silence the test output
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
    thread = _threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}/token", seen
    finally:
        server.shutdown()
        server.server_close()
        thread.join(5)


def test_refresh_over_a_real_socket_renews_and_rotates(token_server):
    endpoint, seen = token_server

    token, block = refresh_access_token(
        {
            "token_endpoint": endpoint,
            "client_id": "cid-1",
            "client_secret": "shh",
            "refresh_token": "rt-1",
            "resource": "https://mcp.example/mcp",
            "expires_at": _long_past(),
        }
    )

    assert token == "at-renewed"
    assert block["refresh_token"] == "rt-2"
    assert token_expired(block) is False
    assert seen[0]["grant_type"] == "refresh_token"
    assert seen[0]["resource"] == "https://mcp.example/mcp"
    assert seen[0]["_authorization"].startswith("Basic ")


def test_a_dead_refresh_token_over_a_real_socket_is_not_fatal(token_server):
    endpoint, _ = token_server

    token, block = refresh_access_token(
        {
            "token_endpoint": endpoint,
            "client_id": "cid-1",
            "refresh_token": "rt-revoked",
        }
    )

    assert token is None
    assert block["refresh_token"] == "rt-revoked"


def test_the_forwarded_payload_survives_the_whole_chain(
    http_transport, token_server
):
    """Device payload in, live MCP tool call out, with nothing mocked.

    The entry is exactly what ``McpStore.forwardPayloads`` puts on the wire for
    a connector whose bearer died while the app was closed: no ``access_token``
    at all, only the ``oauth`` block. The executor has to mint its own token
    against a real endpoint, hand it to a real MCP server and call a tool.
    """
    transport, url, seen_headers = http_transport
    endpoint, seen_tokens = token_server

    configs, errors = configs_from_entries(
        [
            {
                "name": "http-fake",
                "url": url,
                "transport": transport,
                "auth": AUTH_OAUTH,
                "oauth": {
                    "token_endpoint": endpoint,
                    "client_id": "cid-1",
                    "refresh_token": "rt-1",
                    "resource": "https://mcp.example/mcp",
                    "scope": "read",
                    "expires_at": _long_past(),
                },
            }
        ]
    )
    assert errors == []

    manager = MCPManager(configs)
    try:
        assert manager.start() == {"http-fake": True}, manager.errors
        registry = ToolRegistry()
        assert tool_name("http-fake", "shout") in manager.register(registry)
        result = manager.call("http-fake", "shout", {"text": "hi"})
    finally:
        manager.close()

    assert result["content"] == "HI"
    assert len(seen_tokens) == 1
    assert any(
        headers.get("authorization") == "Bearer at-renewed"
        for headers in seen_headers
    )
    # The rotated refresh token is on the config, so the executor forwards the
    # live one on and the old one is never spent twice.
    assert configs[0].oauth["refresh_token"] == "rt-2"
    assert configs[0].auth_token == "at-renewed"


# -- review follow-ups: a token that dies mid-run, and a manager that is reused


def _live(connection: MCPConnection) -> None:
    """Mark a fake connection as handshaken, without a transport."""
    connection._error = None  # noqa: SLF001
    connection._session = object()  # noqa: SLF001
    connection._thread = threading.current_thread()  # noqa: SLF001
    connection._connected_once = True  # noqa: SLF001
    connection._ready.set()  # noqa: SLF001


def test_a_401_from_a_live_session_is_renewed_and_the_call_retried(monkeypatch):
    """The case the whole feature exists for, and the one connect-time refresh
    does not cover: the run outlives its token.

    Headers are fixed when the transport is built, so a token that lapses
    mid-session cannot be swapped in place. The server answers the tool call
    with a 401 while the session stays up and looks healthy, so nothing else
    notices."""
    monkeypatch.setattr("httpx.post", _FakeTokenServer())
    config = _oauth_config(name="notion", expires_at=_far_future())
    seen: list[str | None] = []

    class _Lapsing(MCPConnection):
        def start(self) -> bool:
            _live(self)
            return True

        def call(self, tool, arguments=None):
            seen.append(self.config.auth_token)
            if self.config.auth_token != "at-new":
                return {
                    "ok": False,
                    "server": self.config.name,
                    "tool": tool,
                    "error": "McpError: HTTP 401 Unauthorized",
                }
            return {"ok": True, "server": self.config.name, "tool": tool,
                    "content": "HI"}

    manager = MCPManager([config], connection_factory=_Lapsing)
    try:
        assert manager.start() == {"notion": True}
        result = manager.call("notion", "shout", {"text": "hi"})
    finally:
        manager.close()

    assert result["ok"] is True
    assert seen == ["at-old", "at-new"]


def test_a_tool_error_that_is_not_a_401_is_returned_untouched(monkeypatch):
    server = _FakeTokenServer()
    monkeypatch.setattr("httpx.post", server)
    config = _oauth_config(name="notion", expires_at=_far_future())

    class _Failing(MCPConnection):
        def start(self) -> bool:
            _live(self)
            return True

        def call(self, tool, arguments=None):
            return {"ok": False, "server": self.config.name, "tool": tool,
                    "error": "ValueError: bad argument"}

    manager = MCPManager([config], connection_factory=_Failing)
    try:
        manager.start()
        result = manager.call("notion", "shout", {})
    finally:
        manager.close()

    assert result["error"] == "ValueError: bad argument"
    # Spending a refresh token on a plain tool error would be free damage on a
    # server that rotates them.
    assert server.calls == []


def test_a_dropped_session_is_redialed_on_the_next_task(monkeypatch):
    """A manager is cached per session and started again for every task. A
    server that died during the last task must get another chance, or its tools
    are missing from the prompt for the rest of the session."""
    monkeypatch.setattr("httpx.post", _FakeTokenServer())
    config = _oauth_config(name="notion", expires_at=_far_future())
    starts: list[int] = []

    class _Droppable(MCPConnection):
        def start(self) -> bool:
            starts.append(1)
            _live(self)
            return True

    manager = MCPManager([config], connection_factory=_Droppable)
    try:
        assert manager.start() == {"notion": True}
        first = manager.connections["notion"]
        # The transport thread went away between tasks.
        first._session = None  # noqa: SLF001
        assert first.alive() is False

        assert manager.start() == {"notion": True}
        assert manager.connections["notion"] is not first
    finally:
        manager.close()

    assert len(starts) == 2


def test_a_server_that_never_answered_is_not_redialed_every_task(monkeypatch):
    """The other half of the same rule: redialing a server that has never
    completed a handshake costs a full connect timeout on every task, and it
    has already had its chance."""
    monkeypatch.setattr("httpx.post", _FakeTokenServer())
    config = _oauth_config(name="notion", expires_at=_far_future())
    starts: list[int] = []

    class _Missing(MCPConnection):
        def start(self) -> bool:
            starts.append(1)
            self._error = "ConnectError: [Errno 111] Connection refused"
            return False

    manager = MCPManager([config], connection_factory=_Missing)
    try:
        assert manager.start() == {"notion": False}
        assert manager.start() == {"notion": False}
    finally:
        manager.close()

    assert len(starts) == 1


@pytest.mark.parametrize(
    "error",
    [
        "McpError: HTTP 401 Unauthorized",
        "401 unauthorized",
        "OAuthError: invalid_token",
        "OAuthError: invalid_grant",
    ],
)
def test_a_refused_credential_is_recognised(error):
    assert _looks_unauthorized(error) is True


@pytest.mark.parametrize(
    "error",
    [
        None,
        "",
        # A path segment that merely contains the digits.
        "HTTPStatusError: 404 for https://api.example/mcp/401k-planner",
        # A port number that contains them.
        "ConnectError: connection refused to 127.0.0.1:4010",
        "HTTPStatusError: 1401 unknown",
        "TimeoutError: connect timed out",
    ],
)
def test_an_error_that_is_not_a_refused_credential_is_left_alone(error):
    assert _looks_unauthorized(error) is False


def test_a_recorded_error_does_not_carry_an_api_key():
    """An apiKey connector's secret rides in the URL query, and transport errors
    quote the URL. ``MCPManager.status`` calls that string "what the operator
    sees"."""
    redacted = _redact(
        "ConnectError: failed for https://mcp.brave.example/mcp"
        "?key=SECRET-123&project=abc"
    )

    assert "SECRET-123" not in redacted
    assert "abc" not in redacted
    assert "mcp.brave.example" in redacted


def test_a_very_short_lived_token_is_not_refreshed_on_every_request(monkeypatch):
    """A token whose lifetime is inside the skew window is "expired" the moment
    it arrives. Without a floor every single request would mint another one."""
    server = _FakeTokenServer(
        payload={"access_token": "at-new", "expires_in": 5}
    )
    monkeypatch.setattr("httpx.post", server)
    connection = MCPConnection(_oauth_config(expires_at=_long_past()))

    for _ in range(3):
        assert connection._http_headers()["Authorization"] == "Bearer at-new"  # noqa: SLF001

    assert len(server.calls) == 1
    # A 401 still gets through the floor: the server has said the token is bad.
    assert connection.refresh_token(force=True) == "at-new"
    assert len(server.calls) == 2


def test_a_rotated_refresh_token_is_reported_to_the_listener(monkeypatch):
    """The hook the executor hangs the ``mcp_credentials`` frame on.

    The moment the provider hands back a different refresh token it has killed
    the old one, so the copy the device still holds is dead. Nobody but this
    process knows yet."""
    monkeypatch.setattr(
        "httpx.post",
        _FakeTokenServer(
            payload={
                "access_token": "at-new",
                "refresh_token": "rt-2",
                "expires_in": 3600,
            }
        ),
    )
    seen: list[tuple[str, str | None, str]] = []
    config = _oauth_config(name="notion", expires_at=_long_past())
    connection = MCPConnection(
        config,
        on_credentials_rotated=lambda name, cfg: seen.append(
            (name, cfg.auth_token, cfg.oauth["refresh_token"])
        ),
    )

    connection.refresh_token()

    assert seen == [("notion", "at-new", "rt-2")]


def test_a_refresh_without_rotation_reports_nothing(monkeypatch):
    """A server that only issues a new access token has told us nothing the app
    cannot work out for itself — a frame for that is pure noise."""
    monkeypatch.setattr("httpx.post", _FakeTokenServer())
    seen: list[str] = []
    connection = MCPConnection(
        _oauth_config(name="notion", expires_at=_long_past()),
        on_credentials_rotated=lambda name, cfg: seen.append(name),
    )

    assert connection.refresh_token() == "at-new"
    assert seen == []


def test_a_listener_that_throws_does_not_fail_the_call(monkeypatch):
    monkeypatch.setattr(
        "httpx.post",
        _FakeTokenServer(
            payload={"access_token": "at-new", "refresh_token": "rt-2"}
        ),
    )

    def _boom(name, config):
        raise RuntimeError("the relay is gone")

    connection = MCPConnection(
        _oauth_config(name="notion", expires_at=_long_past()),
        on_credentials_rotated=_boom,
    )

    assert connection.refresh_token() == "at-new"


def test_the_manager_hands_the_listener_to_every_connection(monkeypatch):
    monkeypatch.setattr(
        "httpx.post",
        _FakeTokenServer(
            payload={"access_token": "at-new", "refresh_token": "rt-2"}
        ),
    )
    seen: list[str] = []
    config = _oauth_config(name="notion", expires_at=_long_past())
    manager = MCPManager([config], on_credentials_rotated=lambda n, c: seen.append(n))
    try:
        manager.connections["notion"] = manager._factory(config)  # noqa: SLF001
        manager.connections["notion"].refresh_token()
    finally:
        manager.close()

    assert seen == ["notion"]
