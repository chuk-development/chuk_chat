"""The weekly budget per coworker on the host (docs/WIRE_CONTRACT.md, "Cost
per run and weekly budget", bead chuk_chat-qcbv): stored with the
permissions, set and read through the same two frames, handed to the
executor through a bridge, and pushed once per level and week."""

from __future__ import annotations

import json

import httpx

from chuk_agents_runtime import SupabaseSession

from chuk_agents_host import LocalHost
from chuk_agents_host.agent_permissions import (
    BUDGET_CAPABILITY,
    FILE_NAME,
    AgentPermissionsStore,
    BudgetBridge,
    handle_permissions_frame,
)
from chuk_agents_host.notification_text import RunLabels, budget_text
from chuk_agents_host.notify import KIND_BUDGET, SupabaseNotifier


def test_the_budget_persists_next_to_the_permissions(tmp_path):
    path = tmp_path / FILE_NAME
    store = AgentPermissionsStore(path)
    assert store.budget("a") == 0.0
    assert store.update_budget("a", 12.345) == 12.35
    store.update("a", {"network": False})
    doc = json.loads(path.read_text())
    assert doc["budgets"] == {"a": 12.35}
    again = AgentPermissionsStore(path)
    assert again.budget("a") == 12.35
    assert again.get("a").network is False
    # 0 clears it, and the file forgets it.
    again.update_budget("a", 0)
    assert "budgets" not in json.loads(path.read_text())


def test_a_bad_budget_entry_is_dropped_on_load(tmp_path):
    path = tmp_path / FILE_NAME
    path.write_text(json.dumps({"version": 1, "agents": {}, "budgets": {"a": "lots", "b": 3}}))
    logs: list[str] = []
    store = AgentPermissionsStore(path, log=logs.append)
    assert store.budget("a") == 0.0
    assert store.budget("b") == 3.0
    assert any("dropped the budget" in line for line in logs)


def test_the_frames_read_and_set_the_budget(tmp_path):
    store = AgentPermissionsStore(tmp_path / FILE_NAME)
    reply, _, _ = handle_permissions_frame(store, {"type": "agent_permissions_get", "agent_id": "a"})
    assert reply["budget_weekly"] == 0.0

    reply, before, after = handle_permissions_frame(
        store, {"type": "agent_permissions_set", "agent_id": "a", "budget_weekly": 5}
    )
    assert reply["budget_weekly"] == 5.0 and "error" not in reply
    # A change: the host tells every device (before / after are set).
    assert before is not None and after is not None
    assert store.budget("a") == 5.0

    # The same value again is no change.
    _, before, after = handle_permissions_frame(
        store, {"type": "agent_permissions_set", "agent_id": "a", "budget_weekly": 5.0}
    )
    assert before is None and after is None


def test_a_bad_budget_refuses_the_whole_set(tmp_path):
    store = AgentPermissionsStore(tmp_path / FILE_NAME)
    store.update_budget("a", 2)
    for bad in (True, "5", -1, 20_000):
        reply, before, after = handle_permissions_frame(
            store,
            {
                "type": "agent_permissions_set",
                "agent_id": "a",
                "permissions": {"network": False},
                "budget_weekly": bad,
            },
        )
        assert "error" in reply and "budget_weekly" in reply["error"]
        assert reply["budget_weekly"] == 2.0
        assert before is None and after is None
    # Nothing changed: neither the budget nor the switch in the same frame.
    assert store.budget("a") == 2.0
    assert store.get("a").network is True


def test_an_unknown_agent_gets_no_budget_field(tmp_path):
    store = AgentPermissionsStore(tmp_path / FILE_NAME)
    reply, _, _ = handle_permissions_frame(
        store, {"type": "agent_permissions_get", "agent_id": "ghost"}, key_for=lambda _id: None
    )
    assert "error" in reply and "budget_weekly" not in reply


def test_the_bridge_maps_a_thread_to_its_coworker(tmp_path):
    store = AgentPermissionsStore(tmp_path / FILE_NAME)
    store.update_budget("host-agent", 7)
    warnings: list[dict] = []
    bridge = BudgetBridge(
        store,
        lambda key: key if key.startswith("local:") else "host-agent",
        on_warning=warnings.append,
    )
    assert bridge.budget_weekly("default") == 7.0
    assert bridge.budget_weekly("local:amber:1") == 0.0
    assert bridge.agent_key("default") == "host-agent"
    assert bridge.first_notice("host-agent", 1.0, "warning")
    assert not bridge.first_notice("host-agent", 1.0, "warning")
    bridge.notify({"level": "warning", "session_key": "default"})
    assert warnings == [{"level": "warning", "session_key": "default"}]


def test_the_push_names_the_coworker_and_no_amount():
    title, body = budget_text(RunLabels(coworker="Nova"), level="warning")
    assert title == "Nova: weekly budget"
    assert "80 %" in body
    _, body = budget_text(RunLabels(), level="exceeded")
    assert "reached" in body and "€" not in body


def _host(tmp_path) -> LocalHost:
    return LocalHost(
        port=0,
        workspace_dir=str(tmp_path / "state"),
        channel_id="testchannel",
        agent_name="pytest-agent",
        model_factory_override=lambda: None,
    )


def test_the_host_names_the_capability_and_wires_the_bridge(tmp_path):
    host = _host(tmp_path)
    sent: list[dict] = []
    host._send_host_payload = lambda payload: sent.append(payload) or True
    host._coworker_names.upsert("local:amber:1", "amber", created_by_app=True)
    try:
        host._on_agent_frame({"type": "agent_list"})
        route = [p for p in sent if p["type"] == "host_route"][-1]
        assert BUDGET_CAPABILITY in route["capabilities"]
        reply = host._on_permissions_frame(
            {"type": "agent_permissions_set", "agent_id": "local:amber:1", "budget_weekly": 3}
        )
        assert reply["budget_weekly"] == 3.0
        # A coworker's own thread reads its own budget; the host's other
        # sessions read the host agent's (none set).
        assert host._budget.budget_weekly("local:amber:1") == 3.0
        assert host._budget.budget_weekly("default") == 0.0
        # A budget change goes to every device, like a switch.
        assert sent[-1]["type"] == "agent_permissions"
        assert sent[-1]["budget_weekly"] == 3.0
        # No price list before a provisioning.
        assert host._price_book is None
    finally:
        host.stop()


class _Cloud:
    def __init__(self) -> None:
        self.rows: list[dict] = []

    def handler(self, request: httpx.Request) -> httpx.Response:
        if request.url.path.endswith("/rest/v1/cowork_run_notifications"):
            data = json.loads(request.content.decode())
            self.rows.extend(data if isinstance(data, list) else [data])
            return httpx.Response(201, json=[{"id": "n-1"}])
        if request.url.path.endswith("/functions/v1/notify-run"):
            return httpx.Response(200, json={"sent": 1})
        return httpx.Response(404)


def test_the_notifier_sends_one_row_per_level_and_week(tmp_path):
    cloud = _Cloud()
    client = httpx.Client(transport=httpx.MockTransport(cloud.handler))
    session = SupabaseSession(
        access_token="good", refresh_token="r1", supabase_url="https://sb.example",
        anon_key="anon", http_client=client,
    )
    notifier = SupabaseNotifier(
        session_provider=lambda: session,
        user_id_provider=lambda: "user-1",
        agent_provider=lambda: ("agent-1", "Ada"),
        db_path=str(tmp_path / "state.db"),
        http_client=client,
        background=False,
        ntfy_topic="",
        webhook_url="",
    )
    try:
        notifier.notify_budget(
            {"session_key": "local:amber:1", "level": "exceeded", "week_starts_at": 1759701600.0,
             "spent_eur": 4.2, "budget_eur": 4.0}
        )
    finally:
        notifier.close()
    (row,) = cloud.rows
    assert row["kind"] == KIND_BUDGET
    assert row["run_id"] == "budget:local:amber:1:1759701600:exceeded"
    assert row["session_key"] == "local:amber:1"
    assert "4.2" not in row["body"] and "4.0" not in row["body"]
