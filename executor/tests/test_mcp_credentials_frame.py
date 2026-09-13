"""The ``mcp_credentials`` back-channel (docs/WIRE_CONTRACT.md).

When the host refreshes a connector and the provider rotates the refresh token,
the device's copy is dead; the executor must bring the new one home. mcp_client
fires ``on_credentials_rotated(name, config)`` exactly on a rotation; the
executor turns it into a sealed ``mcp_credentials`` frame on the running task,
parks it as pending, re-sends it at task start / replay until the device
forwards the rotated token back, and never echoes ``client_secret``. Managers
are built, never started: no network.
"""

from __future__ import annotations

import copy
import json
from pathlib import Path

from chuk_agents_sandbox import LocalEnvironment

from chuk_agents_executor import Executor, loopback_pair
from chuk_agents_executor.protocol import mcp_credentials_payload

from wiring import paired_channel

FIXTURE = Path(__file__).resolve().parents[2] / "app/test/fixtures/mcp_forward_payload.json"


def _servers() -> list[dict]:
    return json.loads(FIXTURE.read_text(encoding="utf-8"))["mcp_servers"]


def _executor(tmp_path) -> Executor:
    workspace = tmp_path / "ws"
    workspace.mkdir(exist_ok=True)
    channel = paired_channel()
    _controller_ep, executor_ep = loopback_pair()
    return Executor(
        name="e",
        endpoint=executor_ep,
        opener=channel.executor.opener,
        sealer=channel.executor.sealer,
        environment=LocalEnvironment(workdir=str(workspace)),
        db_path=str(tmp_path / "s.db"),
        model_factory=lambda: None,
    )


def _capture(executor: Executor, monkeypatch) -> list[tuple[str, dict]]:
    sent: list[tuple[str, dict]] = []
    monkeypatch.setattr(executor, "_event", lambda rid, payload: sent.append((rid, payload)))
    return sent


def _config(manager, name: str):
    return next(c for c in manager.configs if c.name == name)


def test_payload_shape_never_carries_the_client_secret():
    payload = mcp_credentials_payload(
        session_key="s",
        connector_id="conn-1",
        name="Notion",
        url="https://mcp.notion.example/mcp",
        access_token="at-2",
        oauth={
            "refresh_token": "rt-2",
            "expires_at": "2030-01-01T00:00:00Z",
            "token_endpoint": "https://auth.example/token",
            "client_id": "cid",
            "client_secret": "SECRET",
            "scope": "read",
        },
        rotated_at="2026-09-05T10:00:00Z",
    )
    assert payload["type"] == "mcp_credentials"
    assert payload["id"] == "conn-1"
    assert payload["session_key"] == "s"
    assert payload["access_token"] == "at-2"
    assert payload["oauth"]["refresh_token"] == "rt-2"
    assert payload["oauth"]["client_id"] == "cid"
    assert "client_secret" not in payload["oauth"]
    assert payload["rotated_at"] == "2026-09-05T10:00:00Z"
    # No id -> no key (old client), no access token -> no key.
    bare = mcp_credentials_payload(session_key="s", name="X", url="u", oauth={"refresh_token": "r"})
    assert "id" not in bare and "access_token" not in bare


def test_a_rotation_is_sent_on_the_live_task_and_parked_as_pending(tmp_path, monkeypatch):
    executor = _executor(tmp_path)
    sent = _capture(executor, monkeypatch)
    servers = _servers()
    next(e for e in servers if e["name"] == "Notion")["id"] = "conn-notion"  # new client
    manager = executor._session_mcp_manager("s", servers)
    executor._mcp_active_request["s"] = "req-1"  # a task is running

    # What refresh_token() does before it fires the hook: config already updated.
    config = _config(manager, "Notion")
    config.oauth["refresh_token"] = "rt-rotated"
    config.oauth["expires_at"] = "2031-01-01T00:00:00Z"
    config.auth_token = "at-minted"
    executor._mcp_rotation_listener("s")("Notion", config)

    assert len(sent) == 1
    rid, payload = sent[0]
    assert rid == "req-1"
    assert payload["type"] == "mcp_credentials"
    assert payload["id"] == "conn-notion"  # echoed verbatim
    assert payload["name"] == "Notion"
    assert payload["url"] == "https://mcp.notion.example/mcp"
    assert payload["access_token"] == "at-minted"
    assert payload["oauth"]["refresh_token"] == "rt-rotated"
    assert "client_secret" not in payload["oauth"]
    # Parked until the device acknowledges by forwarding the new token.
    assert "Notion" in executor._mcp_pending_credentials["s"]


def test_pending_frames_are_resent_until_the_device_forwards_the_token_back(tmp_path, monkeypatch):
    executor = _executor(tmp_path)
    sent = _capture(executor, monkeypatch)
    servers = _servers()
    manager = executor._session_mcp_manager("s", servers)
    config = _config(manager, "Notion")
    config.oauth["refresh_token"] = "rt-rotated"
    executor._mcp_rotation_listener("s")("Notion", config)  # no active task: parked only
    assert sent == []

    # Next task start / replay: re-sent.
    executor._flush_pending_mcp_credentials("s", "req-2")
    assert [rid for rid, _ in sent] == ["req-2"]
    executor._flush_pending_mcp_credentials("s", "req-3")
    assert [rid for rid, _ in sent] == ["req-2", "req-3"]

    # The device forwards the rotated token back -> that is the ack.
    acked = copy.deepcopy(servers)
    next(e for e in acked if e["name"] == "Notion")["oauth"]["refresh_token"] = "rt-rotated"
    assert executor._session_mcp_manager("s", acked) is manager
    assert "Notion" not in executor._mcp_pending_credentials["s"]
    executor._flush_pending_mcp_credentials("s", "req-4")
    assert [rid for rid, _ in sent] == ["req-2", "req-3"]  # nothing more


def test_a_device_re_sign_in_also_clears_the_pending_frame(tmp_path, monkeypatch):
    executor = _executor(tmp_path)
    _capture(executor, monkeypatch)
    servers = _servers()
    manager = executor._session_mcp_manager("s", servers)
    config = _config(manager, "Notion")
    config.oauth["refresh_token"] = "rt-rotated"
    executor._mcp_rotation_listener("s")("Notion", config)
    assert "Notion" in executor._mcp_pending_credentials["s"]

    reauth = copy.deepcopy(servers)
    next(e for e in reauth if e["name"] == "Notion")["oauth"]["refresh_token"] = "rt-brand-new"
    executor._session_mcp_manager("s", reauth)
    # The rotated token belongs to a registration the device replaced; obsolete.
    assert "Notion" not in executor._mcp_pending_credentials["s"]


def test_a_raising_relay_never_reaches_the_tool_call(tmp_path, monkeypatch):
    executor = _executor(tmp_path)
    servers = _servers()
    manager = executor._session_mcp_manager("s", servers)
    executor._mcp_active_request["s"] = "req-1"

    def boom(rid, payload):
        raise RuntimeError("relay down")

    monkeypatch.setattr(executor, "_event", boom)
    executor._mcp_rotation_listener("s")("Notion", _config(manager, "Notion"))  # must not raise
