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


def _wait_until(check, timeout=10.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if check():
            return True
        time.sleep(0.05)
    return False


def test_signing_out_forgets_that_grant_on_the_host(tmp_path, monkeypatch, fake):
    executor = _executor(tmp_path)
    signed = fake.sign_in()
    other = fake.sign_in()
    _probe(
        executor,
        monkeypatch,
        [_entry(fake, signed), _entry(fake, other, connector_id="conn-other") | {"name": "Other"}],
        "req-1",
    )
    gone = mcp_client.MCPServerConfig(name="Fake", transport="http", url=fake.mcp_url, oauth=signed["oauth"])
    kept = mcp_client.MCPServerConfig(name="Other", transport="http", url=fake.mcp_url, oauth=other["oauth"])
    assert mcp_client.GRANTS.current(gone) is not None

    # The device signed out of "Fake": the probe names that sign-in only.
    out = {"token_endpoint": signed["oauth"]["token_endpoint"], "client_id": signed["oauth"]["client_id"]}
    terminals: list = []
    monkeypatch.setattr(executor, "_terminal", lambda rid, p: terminals.append(p))
    executor._handle_mcp_probe("req-2", {"type": "mcp_probe", "mcp_servers": [], "mcp_signed_out": [out]})

    assert _wait_until(lambda: bool(terminals))
    assert mcp_client.GRANTS.current(gone) is None
    assert mcp_client.GRANTS.current(kept) is not None
    assert terminals[0]["servers"] == []
    # The answer acknowledges it, so the device drops it from its outbox.
    assert terminals[0]["signed_out_ack"] == [out]

    # The device re-sends until it saw the ack: a repeat is harmless.
    terminals.clear()
    executor._handle_mcp_probe("req-2b", {"type": "mcp_probe", "mcp_servers": [], "mcp_signed_out": [out]})
    assert _wait_until(lambda: bool(terminals))
    assert terminals[0]["signed_out_ack"] == [out]
    assert mcp_client.GRANTS.current(kept) is not None

    # Signing in again afterwards works at once.
    again = fake.sign_in()
    frames = _probe(executor, monkeypatch, [_entry(fake, again)], "req-3")
    assert frames[-1][1]["servers"][0]["connected"] is True


def test_a_probe_without_a_sign_out_list_prunes_nothing(tmp_path, monkeypatch, fake):
    """A missing, malformed or empty ``mcp_servers`` (an older app, another
    device with fewer connectors) must never wipe grants."""
    executor = _executor(tmp_path)
    signed = fake.sign_in()
    _probe(executor, monkeypatch, [_entry(fake, signed)], "req-1")
    config = mcp_client.MCPServerConfig(name="Fake", transport="http", url=fake.mcp_url, oauth=signed["oauth"])
    monkeypatch.setattr(executor, "_terminal", lambda rid, p: None)

    for payload in (
        {"type": "mcp_probe"},
        {"type": "mcp_probe", "mcp_servers": "garbage"},
        {"type": "mcp_probe", "mcp_servers": []},
        {"type": "mcp_probe", "mcp_servers": [], "mcp_signed_out": "garbage"},
        {"type": "mcp_probe", "mcp_servers": [], "mcp_signed_out": [{"client_id": ""}]},
    ):
        executor._handle_mcp_probe("req-x", payload)
    time.sleep(0.3)
    assert mcp_client.GRANTS.current(config) is not None
    assert executor._mcp_managers


def test_a_sign_out_sent_with_connectors_is_acknowledged_too(tmp_path, monkeypatch, fake):
    """The outbox rides on every probe, also one that lists connectors."""
    executor = _executor(tmp_path)
    removed = fake.sign_in()
    kept = fake.sign_in()
    _probe(executor, monkeypatch, [_entry(fake, removed)], "req-1")
    out = {"token_endpoint": removed["oauth"]["token_endpoint"], "client_id": removed["oauth"]["client_id"]}
    frames: list = []
    done = threading.Event()
    monkeypatch.setattr(executor, "_event", lambda rid, p: None)

    def terminal(rid, payload):
        frames.append(payload)
        done.set()

    monkeypatch.setattr(executor, "_terminal", terminal)
    executor._handle_mcp_probe(
        "req-2",
        {"type": "mcp_probe", "mcp_servers": [_entry(fake, kept)], "mcp_signed_out": [out]},
    )
    assert done.wait(30)
    assert frames[0]["signed_out_ack"] == [out]
    assert frames[0]["servers"][0]["connected"] is True
    config = mcp_client.MCPServerConfig(name="Fake", transport="http", url=fake.mcp_url, oauth=removed["oauth"])
    assert mcp_client.GRANTS.current(config) is None
