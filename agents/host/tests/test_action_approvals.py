"""Per-action approvals on the host (docs/WIRE_CONTRACT.md, "Per-action
approvals", bead chuk_chat-mxxm): the policy is stored with the per-agent
permissions, rides the same two frames, and a lasting decision from a run is
stored and announced to every device."""

from __future__ import annotations

import json

import pytest

from chuk_agents_runtime.action_policy import ActionPolicy

from chuk_agents_host import LocalHost
from chuk_agents_host.agent_permissions import (
    APPROVALS_CAPABILITY,
    FILE_NAME,
    ActionApprovalsBridge,
    AgentPermissionsStore,
    handle_permissions_frame,
)
from chuk_agents_host.coworker_names import host_agent_id
from chuk_agents_host.notification_text import RunLabels, approval_text


def test_approvals_persist_next_to_the_permissions(tmp_path):
    path = tmp_path / FILE_NAME
    store = AgentPermissionsStore(path)
    store.update("a", {"network": False})
    store.update_approvals("a", {"classes": {"browser_act": "ask"}})
    assert store.remember_approval("a", "browser_act", "always_this_site", "https://www.shop.example/x")
    assert store.remember_approval("a", "send_external", "always_this_agent")
    # once / deny / an already covered site change nothing.
    assert store.remember_approval("a", "send_external", "once") is None
    assert store.remember_approval("a", "send_external", "deny") is None
    assert store.remember_approval("a", "browser_act", "always_this_site", "m.shop.example") is None
    assert store.remember_approval("a", "payments", "always_this_agent") is None

    doc = json.loads(path.read_text())
    assert doc["agents"] == {"a": {"network": False}}
    assert doc["approvals"] == {
        "a": {
            "classes": {"browser_act": "ask", "send_external": "allow"},
            "sites": {"browser_act": ["shop.example"]},
        }
    }
    again = AgentPermissionsStore(path)
    policy = again.approvals("a")
    assert policy.evaluate("browser_act", "shop.example") == "allow"
    assert policy.evaluate("browser_act", "other.example") == "ask"
    assert policy.evaluate("send_external") == "allow"
    assert again.approvals("b") == ActionPolicy()
    assert again.get("a").network is False


def test_a_bad_approvals_entry_is_dropped_on_load(tmp_path):
    path = tmp_path / FILE_NAME
    path.write_text(
        json.dumps(
            {
                "version": 1,
                "agents": {},
                "approvals": {"a": {"classes": {"send_external": "sometimes"}}, "b": {"classes": {"publish": "deny"}}},
            }
        )
    )
    logs: list[str] = []
    store = AgentPermissionsStore(path, log=logs.append)
    assert store.approvals("a") == ActionPolicy()
    assert store.approvals("b").mode("publish") == "deny"
    assert any("dropped the approvals" in line for line in logs)


def test_get_carries_the_approvals(tmp_path):
    store = AgentPermissionsStore(tmp_path / FILE_NAME)
    reply, _b, _a = handle_permissions_frame(store, {"type": "agent_permissions_get", "agent_id": "a"})
    assert reply["approvals"] == {
        "classes": {"publish": "ask", "send_external": "ask", "mcp_destructive": "ask", "browser_act": "allow"},
        "sites": {"browser_act": []},
        "defaults": {"publish": "ask", "send_external": "ask", "mcp_destructive": "ask", "browser_act": "allow"},
        "applies_from": "next_action",
    }


def test_an_approvals_only_set_changes_the_policy_and_counts_as_a_change(tmp_path):
    store = AgentPermissionsStore(tmp_path / FILE_NAME)
    reply, before, after = handle_permissions_frame(
        store,
        {
            "type": "agent_permissions_set",
            "agent_id": "a",
            "approvals": {"classes": {"mcp_destructive": "deny"}, "sites": {"browser_act": ["GitHub.com"]}},
        },
    )
    assert "error" not in reply
    assert reply["approvals"]["classes"]["mcp_destructive"] == "deny"
    assert reply["approvals"]["sites"] == {"browser_act": ["github.com"]}
    assert reply["permissions"]["network"] is True
    assert before is not None and after is not None  # the host tells its other devices
    # The same set again changes nothing.
    _r, before, after = handle_permissions_frame(
        store,
        {"type": "agent_permissions_set", "agent_id": "a", "approvals": {"classes": {"mcp_destructive": "deny"}}},
    )
    assert before is None and after is None


@pytest.mark.parametrize(
    "payload",
    [
        {"permissions": {"network": False}, "approvals": {"classes": {"send_external": "never"}}},
        {"permissions": {"network": "off"}, "approvals": {"classes": {"send_external": "allow"}}},
        {"approvals": {"sites": {"browser_act": ["not a site"]}}},
        {"approvals": "allow everything"},
    ],
)
def test_a_bad_set_changes_neither_half(tmp_path, payload):
    store = AgentPermissionsStore(tmp_path / FILE_NAME)
    reply, before, after = handle_permissions_frame(
        store, {"type": "agent_permissions_set", "agent_id": "a", **payload}
    )
    assert reply["error"]
    assert before is None and after is None
    assert store.get("a").network is True
    assert store.approvals("a") == ActionPolicy()
    assert reply["approvals"]["classes"]["send_external"] == "ask"
    assert not (tmp_path / FILE_NAME).exists()


def test_the_bridge_maps_the_session_and_reports_a_change(tmp_path):
    store = AgentPermissionsStore(tmp_path / FILE_NAME)
    changes: list = []
    bridge = ActionApprovalsBridge(
        store,
        lambda key: key if key.startswith("local:") else "host-agent",
        on_change=lambda key, policy: changes.append((key, policy.mode("send_external"))),
    )
    bridge.remember("telegram:123", "send_external", "always_this_agent")
    bridge.remember("telegram:123", "send_external", "always_this_agent")  # no change
    bridge.remember("local:amber:1", "send_external", "once")
    assert changes == [("host-agent", "allow")]
    assert bridge.policy_for("default").mode("send_external") == "allow"
    assert bridge.policy_for("local:amber:1").mode("send_external") == "ask"


def _host(tmp_path) -> LocalHost:
    return LocalHost(
        port=0,
        workspace_dir=str(tmp_path / "state"),
        channel_id="testchannel",
        agent_name="pytest-agent",
        model_factory_override=lambda: None,
    )


def test_the_host_stores_a_decision_and_tells_every_device(tmp_path):
    host = _host(tmp_path)
    sent: list[dict] = []
    host._send_host_payload = lambda payload: sent.append(payload) or True
    host._coworker_names.upsert("local:amber:1", "amber", created_by_app=True)
    try:
        host._on_agent_frame({"type": "agent_list"})
        route = [p for p in sent if p["type"] == "host_route"][-1]
        assert APPROVALS_CAPABILITY in route["capabilities"]
        sent.clear()
        bridge = host._action_approvals
        # A coworker's own thread is its own policy ...
        bridge.remember("local:amber:1", "browser_act", "always_this_site", "shop.example")
        assert sent[-1]["type"] == "agent_permissions"
        assert sent[-1]["agent_id"] == "local:amber:1"
        assert sent[-1]["approvals"]["sites"]["browser_act"] == ["shop.example"]
        # ... every other session is the host's own coworker, under its app id.
        bridge.remember("default", "send_external", "always_this_agent")
        assert sent[-1]["agent_id"] == host_agent_id(host._device_id)
        assert sent[-1]["approvals"]["classes"]["send_external"] == "allow"
        got = host._on_agent_frame({"type": "agent_permissions_get", "agent_id": sent[-1]["agent_id"]})
        assert got["approvals"]["classes"]["send_external"] == "allow"
        assert host._action_approvals.policy_for("local:amber:1").mode("send_external") == "ask"
    finally:
        host._roster.close()
        host._coworker_names.close()


def test_the_push_names_the_class_never_the_content():
    labels = RunLabels(coworker="Amber")
    assert approval_text(labels) == ("Amber needs your approval", "Open the app to allow or deny the publish.")
    assert approval_text(labels, action_class="send_external")[1] == "Open the app to allow or deny sending a mail."
    assert approval_text(labels, action_class="browser_act", site="shop.example")[1] == (
        "Open the app to allow or deny a browser action on shop.example."
    )
    assert approval_text(labels, action_class="mcp_destructive")[1] == (
        "Open the app to allow or deny a connector action."
    )
