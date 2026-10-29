"""End to end against a real local MCP + OAuth server (``fake_mcp_oauth``).

No mocks between the client and the server: real HTTP on loopback, a real
streamable-HTTP MCP session, a real token endpoint that rotates refresh tokens
the way Fastmail does (each refresh kills the old refresh token and the old
access token). Bead chuk_chat-meoz.
"""

from __future__ import annotations

import json
import threading
import time

import pytest
from chuk_agents_runtime import mcp_client
from chuk_agents_runtime.mcp_client import (
    HTTP,
    MCPConnection,
    MCPServerConfig,
    OAuthGrantStore,
)
from fake_mcp_oauth import FakeMcpOAuthServer


@pytest.fixture
def fake():
    server = FakeMcpOAuthServer(access_ttl=600).start()
    try:
        yield server
    finally:
        server.stop()


def _config(fake: FakeMcpOAuthServer, signed: dict, *, name: str = "Fake") -> MCPServerConfig:
    return MCPServerConfig(
        name=name,
        transport=HTTP,
        url=fake.mcp_url,
        auth_token=signed["access_token"],
        oauth=dict(signed["oauth"]),
        connector_id="fake-1",
        connect_timeout=10.0,
    )


def _call_text(connection: MCPConnection, tool: str, args: dict | None = None) -> str:
    result = connection.call(tool, args or {})
    assert result.get("ok") is not False, result
    return json.dumps(result)


def test_first_sign_in_lists_the_tools(fake):
    connection = MCPConnection(_config(fake, fake.sign_in()))
    try:
        assert connection.start() is True
        assert connection.error is None and connection.error_kind is None
        assert sorted(t.name for t in connection.tools) == ["echo", "whoami"]
        assert "Chuk Chat" in _call_text(connection, "whoami")
    finally:
        connection.close()
    assert fake.state.snapshot()["refreshes"] == 0


def test_a_lapsed_access_token_is_renewed_silently(fake):
    connection = MCPConnection(_config(fake, fake.sign_in()))
    try:
        assert connection.start() is True
        fake.expire_access()
        # The open session's bearer is refused; the call renews and goes on.
        assert "hello" in _call_text(connection, "echo", {"text": "hello"})
        assert connection.error is None
    finally:
        connection.close()
    snapshot = fake.state.snapshot()
    assert snapshot["refreshes"] == 1
    assert snapshot["invalid_grants"] == 0


def test_two_sessions_of_one_grant_never_both_refresh(fake):
    """The rotation case that killed Fastmail: two holders of one grant. With
    the shared grant store only one spends the refresh token; the other takes
    the result. No invalid_grant."""
    signed = fake.sign_in()
    first = MCPConnection(_config(fake, signed))
    second = MCPConnection(_config(fake, signed))
    try:
        assert first.start() and second.start()
        fake.expire_access()
        barrier = threading.Barrier(2)
        outcomes: list[dict] = []

        def run(connection):
            barrier.wait()
            outcomes.append(connection.call("echo", {"text": "x"}))

        threads = [threading.Thread(target=run, args=(c,)) for c in (first, second)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join(30)
        assert all(o.get("ok") is not False for o in outcomes), outcomes
    finally:
        first.close()
        second.close()
    snapshot = fake.state.snapshot()
    assert snapshot["invalid_grants"] == 0
    assert snapshot["refreshes"] == 1


def test_a_revoked_sign_in_is_auth_once_and_asks_the_provider_once(fake):
    notices: list[dict] = []
    mcp_client.GRANTS.dead_listeners.append(notices.append)
    signed = fake.sign_in()
    fake.revoke()

    connection = MCPConnection(_config(fake, signed))
    try:
        assert connection.start() is False
        assert connection.error_kind == "auth"
    finally:
        connection.close()
    assert fake.state.snapshot()["refreshes"] == 1

    # The next dial (the next task, the next probe) asks nobody again.
    again = MCPConnection(_config(fake, signed))
    try:
        assert again.start() is False
        assert again.error_kind == "auth"
    finally:
        again.close()
    assert fake.state.snapshot()["refreshes"] == 1
    assert len(notices) == 1
    assert notices[0]["name"] == "Fake"
    assert notices[0]["connector_id"] == "fake-1"


def test_signing_in_again_after_a_revoke_works_at_once(fake):
    signed = fake.sign_in()
    fake.revoke()
    dead = MCPConnection(_config(fake, signed))
    try:
        assert dead.start() is False
    finally:
        dead.close()

    fresh = MCPConnection(_config(fake, fake.sign_in()))
    try:
        assert fresh.start() is True
        assert fresh.error is None
    finally:
        fresh.close()


def test_the_keeper_renews_an_idle_grant_and_a_session_follows(fake, tmp_path):
    path = tmp_path / "mcp-grants.json"
    mcp_client.GRANTS.set_path(path)
    signed = fake.sign_in()
    connection = MCPConnection(_config(fake, signed))
    try:
        assert connection.start() is True
        later = time.time() + mcp_client.KEEPALIVE_INTERVAL + 1
        assert mcp_client.GRANTS.keep_alive(later) == 1
        # Rotation killed the session's access token; the session's next
        # request takes the keeper's new one from the store, no own refresh.
        assert "ok" in _call_text(connection, "echo", {"text": "ok"})
    finally:
        connection.close()
    snapshot = fake.state.snapshot()
    assert snapshot["refreshes"] == 1
    assert snapshot["invalid_grants"] == 0
    # The renewed refresh token is on disk (a restart keeps the grant alive).
    reread = OAuthGrantStore(path)
    assert reread.current(connection.config)["refresh_token"] == connection.config.oauth[
        "refresh_token"
    ]
