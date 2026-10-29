"""One OAuth grant, many connections (bead chuk_chat-mj2o).

Fastmail rotates with a ratchet: each refresh issues a new refresh token AND a
new access token, and both old ones stop working at once. The host keeps one
MCPManager per session plus one per probe. Before the shared grant store each
of them refreshed its own copy, so they killed each other, and the probe's
rotated token never reached the app. These tests use a fake token endpoint
that behaves like Fastmail.
"""

from __future__ import annotations

import http.server
import json
import threading
from datetime import UTC, datetime, timedelta

import pytest

from chuk_agents_runtime import mcp_client
from chuk_agents_runtime.mcp_client import (
    AUTH_REFUSED_ERROR,
    HTTP,
    MCPConnection,
    MCPServerConfig,
    OAuthGrantStore,
)


def _future() -> str:
    return (datetime.now(UTC) + timedelta(hours=1)).isoformat()


def _past() -> str:
    return (datetime.now(UTC) - timedelta(hours=1)).isoformat()


class _Ratchet:
    """A token endpoint like Fastmail's: only the newest refresh token works,
    and each refresh makes every earlier token invalid."""

    def __init__(self) -> None:
        self.ratchet = 1
        self.calls = 0
        self.refused = 0

    @property
    def refresh_token(self) -> str:
        return f"rt-{self.ratchet}"

    @property
    def access_token(self) -> str:
        return f"at-{self.ratchet}"

    def __call__(self, url, *, data=None, **_kwargs):
        self.calls += 1
        server = self

        class _Response:
            def __init__(self, status, payload):
                self.status_code = status
                self._payload = payload

            def json(self):
                return self._payload

        if (data or {}).get("refresh_token") != self.refresh_token:
            server.refused += 1
            return _Response(400, {"error": "invalid_grant"})
        self.ratchet += 1
        return _Response(
            200,
            {
                "access_token": self.access_token,
                "refresh_token": self.refresh_token,
                "expires_in": 3600,
            },
        )


def _forwarded(refresh_token: str, access_token: str, *, expires_at: str | None = None) -> MCPServerConfig:
    """The ``Fastmail`` entry as the app forwards it."""
    return MCPServerConfig(
        name="Fastmail",
        transport=HTTP,
        url="https://api.fastmail.example/mcp",
        auth_token=access_token,
        oauth={
            "token_endpoint": "https://api.fastmail.example/oauth/refresh",
            "client_id": "961641ae",
            "refresh_token": refresh_token,
            "expires_at": expires_at or _future(),
            "scope": "offline_access mcp",
        },
    )


@pytest.fixture
def ratchet(monkeypatch):
    server = _Ratchet()
    monkeypatch.setattr("httpx.post", server)
    return server


def test_a_refresh_in_one_session_does_not_kill_the_other_session(ratchet):
    """The Mail session and the probe hold the same grant. The probe refreshes.
    The Mail session must use the probe's token, not refresh its dead copy."""
    mail = MCPConnection(_forwarded("rt-1", "at-1"))
    probe = MCPConnection(_forwarded("rt-1", "at-1", expires_at=_past()))

    assert probe._http_headers()["Authorization"] == "Bearer at-2"  # noqa: SLF001
    assert ratchet.calls == 1

    # The Mail session still holds at-1, which the provider no longer accepts.
    # Its next request already carries the current token.
    assert mail._http_headers()["Authorization"] == "Bearer at-2"  # noqa: SLF001
    assert mail.config.oauth["refresh_token"] == "rt-2"
    # A 401 for the old bearer returns the current token without a refresh.
    assert mail.refresh_token(force=True, seen_token="at-1") == "at-2"
    assert ratchet.calls == 1
    assert ratchet.refused == 0


def test_a_forced_refresh_after_a_real_401_moves_every_copy_forward(ratchet):
    first = MCPConnection(_forwarded("rt-1", "at-1"))
    second = MCPConnection(_forwarded("rt-1", "at-1"))

    assert first.refresh_token(force=True, seen_token="at-1") == "at-2"
    assert second.refresh_token(force=True, seen_token="at-1") == "at-2"
    # The next real 401 (for at-2) spends the newest refresh token, once.
    assert second.refresh_token(force=True, seen_token="at-2") == "at-3"
    assert first._http_headers()["Authorization"] == "Bearer at-3"  # noqa: SLF001
    assert ratchet.calls == 2
    assert ratchet.refused == 0


def test_a_stale_device_copy_does_not_replace_the_host_state(ratchet):
    """After a host refresh the device still forwards its old token (it never
    got the rotation, or it is the other device). The new session must start
    from the grant's current state."""
    host = MCPConnection(_forwarded("rt-1", "at-1"))
    assert host.refresh_token(force=True) == "at-2"

    late = MCPConnection(_forwarded("rt-1", "at-1"))

    assert late.config.oauth["refresh_token"] == "rt-2"
    assert late.config.auth_token == "at-2"
    assert ratchet.calls == 1


def test_a_new_sign_in_from_the_device_is_taken(ratchet):
    """A token the grant never had is a new sign-in (or a refresh the device
    did itself): the device wins."""
    host = MCPConnection(_forwarded("rt-1", "at-1"))
    assert host.refresh_token(force=True) == "at-2"
    # The device refreshed with rt-2 on its own.
    assert ratchet(None, data={"refresh_token": "rt-2"}).status_code == 200

    fresh = MCPConnection(_forwarded("rt-3", "at-3"))

    assert fresh.config.oauth["refresh_token"] == "rt-3"
    assert host._http_headers()["Authorization"] == "Bearer at-3"  # noqa: SLF001


def test_the_grant_survives_a_host_restart(ratchet, tmp_path):
    path = tmp_path / "mcp-grants.json"
    mcp_client.GRANTS.set_path(path)
    host = MCPConnection(_forwarded("rt-1", "at-1"))
    assert host.refresh_token(force=True) == "at-2"

    # The restart: a new store reads the file. The first task forwards the
    # device's old copy.
    restarted = OAuthGrantStore(path)
    late = MCPConnection(_forwarded("rt-1", "at-1"), grants=restarted)

    assert late.config.oauth["refresh_token"] == "rt-2"
    # The access token is never on disk: the stale bearer is dropped, and the
    # first request mints a new one from the current refresh token.
    assert late.config.auth_token == ""
    assert late._http_headers()["Authorization"] == "Bearer at-3"  # noqa: SLF001
    assert path.stat().st_mode & 0o777 == 0o600
    # The file keeps hashes of earlier refresh tokens, never the tokens, and
    # never an access token.
    raw = json.loads(path.read_text())
    record = next(iter(raw.values()))
    assert "rt-1" not in json.dumps(record["seen"])
    assert "access_token" not in record
    assert "at-" not in path.read_text()


_KEY = bytes(range(32))


def test_a_sealed_grant_file_holds_no_token_in_the_clear(ratchet, tmp_path):
    path = tmp_path / "mcp-grants.json"
    mcp_client.GRANTS.set_key(_KEY)
    mcp_client.GRANTS.set_path(path)
    host = MCPConnection(_forwarded("rt-1", "at-1"))
    assert host.refresh_token(force=True) == "at-2"

    text = path.read_text()
    assert path.stat().st_mode & 0o777 == 0o600
    assert set(json.loads(text)) == {"version", "nonce", "ciphertext"}
    for secret in ("rt-1", "rt-2", "at-1", "at-2"):
        assert secret not in text

    # The restart with the same key: the grant is back, the stale copy loses.
    restarted = OAuthGrantStore(path, key=_KEY)
    late = MCPConnection(_forwarded("rt-1", "at-1"), grants=restarted)
    assert late.config.oauth["refresh_token"] == "rt-2"

    # Another key (a new host identity) opens nothing.
    foreign = OAuthGrantStore(path, key=bytes(32))
    assert foreign.current(late.config) is None


def test_an_old_plaintext_grant_file_is_read_once_and_sealed(ratchet, tmp_path):
    path = tmp_path / "mcp-grants.json"
    # An older build wrote the records in the clear, access token included.
    old = OAuthGrantStore(path)
    host = MCPConnection(_forwarded("rt-1", "at-1"), grants=old)
    assert host.refresh_token(force=True) == "at-2"
    legacy = json.loads(path.read_text())
    for record in legacy.values():
        record["access_token"] = "at-2"
    path.write_text(json.dumps(legacy))

    store = OAuthGrantStore(path, key=_KEY)
    late = MCPConnection(_forwarded("rt-1", "at-1"), grants=store)

    # The plaintext grant was taken ...
    assert late.config.oauth["refresh_token"] == "rt-2"
    # ... and the file is sealed now, with no token in the clear.
    text = path.read_text()
    assert set(json.loads(text)) == {"version", "nonce", "ciphertext"}
    assert "rt-2" not in text and "at-2" not in text
    assert OAuthGrantStore(path, key=_KEY).current(late.config)["current"]


def test_set_key_seals_a_file_that_is_already_there(ratchet, tmp_path):
    path = tmp_path / "mcp-grants.json"
    mcp_client.GRANTS.set_path(path)
    host = MCPConnection(_forwarded("rt-1", "at-1"))
    assert host.refresh_token(force=True) == "at-2"
    assert "rt-2" in path.read_text()

    mcp_client.GRANTS.set_key(_KEY)

    text = path.read_text()
    assert "rt-2" not in text
    assert set(json.loads(text)) == {"version", "nonce", "ciphertext"}
    assert mcp_client.GRANTS.current(host.config)["refresh_token"] == "rt-2"


def test_an_entry_without_refresh_material_is_not_shared(ratchet):
    config = MCPServerConfig(
        name="plain", transport=HTTP, url="https://x.example/mcp", auth_token="k"
    )
    connection = MCPConnection(config)
    assert connection._http_headers()["Authorization"] == "Bearer k"  # noqa: SLF001
    assert mcp_client.GRANTS.current(config) is None


# -- the error the user sees ----------------------------------------------


@pytest.fixture
def refusing_server():
    """An MCP endpoint that refuses every bearer, like Fastmail after the
    grant moved on: 401 with a problem+json body."""

    class _Handler(http.server.BaseHTTPRequestHandler):
        def _refuse(self):
            length = int(self.headers.get("content-length") or 0)
            if length:
                self.rfile.read(length)
            body = json.dumps(
                {"title": "Unauthorized", "detail": "No session found via bearer token"}
            ).encode()
            self.send_response(401)
            self.send_header("content-type", "application/problem+json")
            self.send_header("www-authenticate", "Bearer")
            self.send_header("content-length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        do_POST = _refuse  # noqa: N815
        do_GET = _refuse  # noqa: N815
        do_DELETE = _refuse  # noqa: N815

        def log_message(self, *args):  # noqa: A003
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{server.server_port}/mcp"
    finally:
        server.shutdown()
        server.server_close()
        thread.join(5)


def test_a_refused_sign_in_says_reconnect(ratchet, refusing_server):
    """The SDK reports a 401 only as "Server returned an error response". The
    connector error must name the cause and the fix."""
    config = _forwarded("rt-dead", "at-dead")
    config.url = refusing_server
    config.connect_timeout = 10.0
    connection = MCPConnection(config)
    try:
        assert connection.start() is False
    finally:
        connection.close()

    assert connection.error == AUTH_REFUSED_ERROR
    assert connection.error_kind == "auth"
    assert "Reconnect" in connection.error
    # It tried to renew once with the refresh token it had.
    assert ratchet.calls >= 1
