"""The monthly spending cap on the host (CHAT-181): per agent and for the
whole account, stored next to the weekly budget, set and read through the
permission frames, and handed to the executor through the budget bridge."""

from __future__ import annotations

import json

from chuk_agents_runtime.cost import ACCOUNT_CAP_KEY

from chuk_agents_host.agent_permissions import (
    FILE_NAME,
    AgentPermissionsStore,
    BudgetBridge,
    handle_permissions_frame,
)


def test_the_caps_persist_and_zero_clears_them(tmp_path):
    path = tmp_path / FILE_NAME
    store = AgentPermissionsStore(path)
    assert store.cap_monthly("a") == 0.0
    assert store.update_cap_monthly("a", 30.004) == 30.0
    store.update_cap_monthly(ACCOUNT_CAP_KEY, 100)
    doc = json.loads(path.read_text())
    assert doc["caps_monthly"] == {"a": 30.0, ACCOUNT_CAP_KEY: 100.0}
    again = AgentPermissionsStore(path)
    assert again.cap_monthly("a") == 30.0
    assert again.cap_monthly(ACCOUNT_CAP_KEY) == 100.0
    again.update_cap_monthly("a", 0)
    again.update_cap_monthly(ACCOUNT_CAP_KEY, 0)
    assert "caps_monthly" not in json.loads(path.read_text())


def test_a_bad_cap_entry_is_dropped_on_load(tmp_path):
    path = tmp_path / FILE_NAME
    path.write_text(json.dumps({"version": 1, "agents": {}, "caps_monthly": {"a": "lots", "b": 7}}))
    store = AgentPermissionsStore(path)
    assert store.cap_monthly("a") == 0.0
    assert store.cap_monthly("b") == 7.0


def test_the_frames_read_and_set_both_caps(tmp_path):
    store = AgentPermissionsStore(tmp_path / FILE_NAME)
    reply, _, _ = handle_permissions_frame(store, {"type": "agent_permissions_get", "agent_id": "a"})
    assert reply["cap_monthly"] == 0.0 and reply["account_cap_monthly"] == 0.0

    reply, before, after = handle_permissions_frame(
        store,
        {"type": "agent_permissions_set", "agent_id": "a", "cap_monthly": 20, "account_cap_monthly": 50},
    )
    assert "error" not in reply
    assert reply["cap_monthly"] == 20.0 and reply["account_cap_monthly"] == 50.0
    assert before is not None and after is not None
    assert store.cap_monthly("a") == 20.0 and store.cap_monthly(ACCOUNT_CAP_KEY) == 50.0

    # The same values again: no change.
    _, before, after = handle_permissions_frame(
        store, {"type": "agent_permissions_set", "agent_id": "a", "cap_monthly": 20.0}
    )
    assert before is None and after is None


def test_a_bad_cap_refuses_the_whole_set(tmp_path):
    store = AgentPermissionsStore(tmp_path / FILE_NAME)
    store.update_cap_monthly("a", 10)
    reply, before, after = handle_permissions_frame(
        store,
        {"type": "agent_permissions_set", "agent_id": "a", "budget_weekly": 3, "cap_monthly": -1},
    )
    assert "error" in reply and "cap_monthly" in reply["error"]
    assert before is None and after is None
    assert store.cap_monthly("a") == 10.0 and store.budget("a") == 0.0


def test_the_bridge_gives_the_agent_and_the_account_cap(tmp_path):
    store = AgentPermissionsStore(tmp_path / FILE_NAME)
    store.update_cap_monthly("host-agent", 12)
    store.update_cap_monthly(ACCOUNT_CAP_KEY, 40)
    bridge = BudgetBridge(store, lambda key: key if key.startswith("local:") else "host-agent")
    assert bridge.caps_monthly("default") == (12.0, 40.0)
    assert bridge.caps_monthly("local:amber:1") == (0.0, 40.0)
