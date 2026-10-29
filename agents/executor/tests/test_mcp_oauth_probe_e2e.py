"""The probe path against a real local MCP + OAuth server (bead chuk_chat-meoz).

The executor builds the session's real MCPManager from the forwarded entry and
dials ``fake_mcp_oauth`` (agents/runtime/tests) over loopback.
"""

from __future__ import annotations

import sys
import threading
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "runtime" / "tests"))

from chuk_agents_runtime import mcp_client
from fake_mcp_oauth import FakeMcpOAuthServer
from test_mcp_tools_frame import _executor


@pytest.fixture(autouse=True)
def _fresh_grants():
    mcp_client.GRANTS.reset()
    yield
    mcp_client.GRANTS.reset()


@pytest.fixture
def fake():
    server = FakeMcpOAuthServer(access_ttl=600).start()
    try:
        yield server
    finally:
        server.stop()


def _entry(fake, signed, *, connector_id="conn-fake"):
    return {
        "id": connector_id,
        "name": "Fake",
        "url": fake.mcp_url,
        "auth": "oauth",
        "access_token": signed["access_token"],
        "oauth": dict(signed["oauth"]),
    }


def _probe(executor, monkeypatch, entries, request_id="req-1"):
    frames: list[tuple[str, dict]] = []
    done = threading.Event()
    monkeypatch.setattr(executor, "_event", lambda rid, p: frames.append(("event", p)))

    def terminal(rid, payload):
        frames.append(("terminal", payload))
        done.set()

    monkeypatch.setattr(executor, "_terminal", terminal)
    executor._handle_mcp_probe(
        request_id, {"type": "mcp_probe", "session_key": "s", "mcp_servers": entries}
    )
    assert done.wait(30), "the probe never answered"
    return frames


def test_a_probe_lists_the_tools_and_names_the_client(tmp_path, monkeypatch, fake):
    executor = _executor(tmp_path)
    signed = fake.sign_in()
    frames = _probe(executor, monkeypatch, [_entry(fake, signed)])
    entry = frames[-1][1]["servers"][0]
    assert entry["connected"] is True
    assert {t["name"] for t in entry["tools"]} == {"echo", "whoami"}
    assert entry["client_id"] == signed["oauth"]["client_id"]
    assert "error" not in entry


def test_a_revoked_grant_reports_auth_and_one_refresh(tmp_path, monkeypatch, fake):
    executor = _executor(tmp_path)
    signed = fake.sign_in()
    fake.revoke()
    first = _probe(executor, monkeypatch, [_entry(fake, signed)], "req-1")
    second = _probe(executor, monkeypatch, [_entry(fake, signed)], "req-2")
    for frames in (first, second):
        entry = frames[-1][1]["servers"][0]
        assert entry["error_kind"] == "auth"
        assert entry["connected"] is False
    assert fake.state.snapshot()["refreshes"] == 1


def test_a_token_the_host_renewed_goes_back_to_the_app(tmp_path, monkeypatch, fake):
    """The host is the one refresher. After it renewed (here: the keeper, with
    no session open), the next probe hands the new tokens back to the app."""
    executor = _executor(tmp_path)
    signed = fake.sign_in()
    _probe(executor, monkeypatch, [_entry(fake, signed)], "req-1")
    assert mcp_client.GRANTS.keep_alive(time.time() + mcp_client.KEEPALIVE_INTERVAL + 1) == 1

    # The app still forwards what it has (now dead at the provider).
    frames = _probe(executor, monkeypatch, [_entry(fake, signed)], "req-2")
    credentials = [p for kind, p in frames if p.get("type") == "mcp_credentials"]
    assert credentials, frames
    sent = credentials[-1]
    assert sent["id"] == "conn-fake"
    assert sent["oauth"]["refresh_token"] != signed["oauth"]["refresh_token"]
    assert sent["access_token"] and sent["access_token"] != signed["access_token"]
    entry = frames[-1][1]["servers"][0]
    assert entry["connected"] is True
    snapshot = fake.state.snapshot()
    assert snapshot["invalid_grants"] == 0
    assert snapshot["refreshes"] == 1

    # The app took them and forwards them: nothing more to hand back.
    adopted = _entry(fake, {"access_token": sent["access_token"], "oauth": sent["oauth"]})
    frames = _probe(executor, monkeypatch, [adopted], "req-3")
    assert not [p for kind, p in frames if p.get("type") == "mcp_credentials"]


def test_signing_out_forgets_the_grant_on_the_host(tmp_path, monkeypatch, fake):
    executor = _executor(tmp_path)
    signed = fake.sign_in()
    _probe(executor, monkeypatch, [_entry(fake, signed)], "req-1")
    block = signed["oauth"]
    probe_config = mcp_client.MCPServerConfig(name="Fake", transport="http", url=fake.mcp_url, oauth=block)
    assert mcp_client.GRANTS.current(probe_config) is not None
    assert executor._mcp_managers

    # The device removed its last connector and says so with an empty probe.
    frames = _probe(executor, monkeypatch, [], "req-2")
    assert frames[-1][1]["servers"] == []
    assert mcp_client.GRANTS.current(probe_config) is None
    assert not executor._mcp_managers
    # Nothing renews a removed sign-in any more.
    assert mcp_client.GRANTS.keep_alive(time.time() + mcp_client.KEEPALIVE_INTERVAL + 1) == 0

    # Signing in again afterwards works at once.
    again = fake.sign_in()
    frames = _probe(executor, monkeypatch, [_entry(fake, again)], "req-3")
    assert frames[-1][1]["servers"][0]["connected"] is True
