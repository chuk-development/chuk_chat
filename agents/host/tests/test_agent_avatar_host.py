"""The host side of ``agent_avatar_set`` and of the toast icon
(docs/agents/NOTIFICATIONS.md, CHAT-128)."""

from __future__ import annotations

import base64

from chuk_agents_host import LocalHost
from chuk_agents_host.avatars import PNG_SIGNATURE
from chuk_agents_host.coworker_names import host_agent_id

PNG = PNG_SIGNATURE + b"\x00" * 24


def _host(tmp_path) -> LocalHost:
    return LocalHost(
        port=0,
        workspace_dir=str(tmp_path / "state"),
        channel_id="testchannel",
        agent_name="pytest-agent",
        model_factory_override=lambda: None,
    )


def _close(host: LocalHost) -> None:
    host._roster.close()
    host._coworker_names.close()


def test_the_agent_hook_stores_the_avatar_in_the_workspace(tmp_path):
    host = _host(tmp_path)
    try:
        reply = host._on_agent_frame(
            {"type": "agent_avatar_set", "agent_id": "local:amber:1",
             "png_b64": base64.b64encode(PNG).decode()}
        )
        assert reply == {"type": "agent_avatar", "agent_id": "local:amber:1", "ok": True}
        assert (tmp_path / "state" / "avatars" / "local_amber_1.png").read_bytes() == PNG
        bad = host._on_agent_frame(
            {"type": "agent_avatar_set", "agent_id": "../x", "png_b64": base64.b64encode(PNG).decode()}
        )
        assert bad["ok"] is False
    finally:
        _close(host)


def test_a_thread_maps_to_its_agent_for_the_icon_and_the_seal(tmp_path):
    host = _host(tmp_path)
    host._coworker_names.upsert("local:amber:1", "amber", created_by_app=True)
    try:
        assert host._app_agent_id("local:amber:1") == "local:amber:1"
        # Any other key is the host's own agent.
        own = host_agent_id(host._device_id)
        assert host._app_agent_id("default") == own
        assert host._app_agent_id("thread-nobody-registered") == own
    finally:
        _close(host)


def test_the_stored_trusts_are_the_pairing_of_this_host(tmp_path):
    host = _host(tmp_path)
    try:
        trusts = host._stored_trusts()
        assert all(len(t.channel_key) == 32 for t in trusts)
        assert [t.channel_id for t in trusts] == ([host._trust.channel_id] if host._trust else [])
    finally:
        _close(host)
