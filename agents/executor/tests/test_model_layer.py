"""CHAT-181 in the executor: the model per kind of work is stored with the
agent's own model, and the monthly spending cap stops new runs."""

from __future__ import annotations

from chuk_agents_runtime import StateStore
from chuk_agents_runtime.cost import BudgetNotices
from chuk_agents_runtime.model_routes import ModelRoute

from test_agent_model import FLASH, S, _executor
from test_cost_budget import _build, _done, _spend

MISTRAL = "mistralai/mistral-small-2603"


def test_routes_are_stored_kept_and_cleared(tmp_path):
    executor = _executor(tmp_path)
    stored = executor.set_agent_model(
        S, FLASH, routes={"browser": {"id": MISTRAL}, "aux": {"id": FLASH, "reasoning_effort": "none"}, "x": {"id": "y"}}
    )
    assert stored["routes"] == {"browser": {"id": MISTRAL}, "aux": {"id": FLASH, "reasoning_effort": "none"}}
    routes = executor._model_routes(S)
    assert routes.route("browser") == ModelRoute(MISTRAL)
    assert routes.route("aux") == ModelRoute(FLASH, None, "none")

    # A change of the own model without ``routes`` keeps them.
    assert executor.set_agent_model(S, MISTRAL)["routes"]["browser"] == {"id": MISTRAL}
    # Dropping the own model keeps the routes too: the agent follows the
    # task's model, the browser still runs on its route.
    assert executor.set_agent_model(S, None) is None
    assert executor._model_routes(S).route("browser") == ModelRoute(MISTRAL)
    # ``routes: null`` clears them.
    executor.set_agent_model(S, None, routes=None)
    store = StateStore(str(tmp_path / "s.db"))
    try:
        assert store.load_feature(S, "agent_model") is None
    finally:
        store.close()
    assert executor._model_routes(S).route("browser") is None


class _CapBridge:
    """The host's budget bridge with monthly caps, in memory."""

    def __init__(self, *, weekly: float = 0.0, agent_cap: float = 0.0, account_cap: float = 0.0) -> None:
        self.weekly = weekly
        self.caps = (agent_cap, account_cap)
        self.notices = BudgetNotices()
        self.sent: list[dict] = []

    def agent_key(self, session_key: str) -> str:
        return session_key.split("/")[0]

    def budget_weekly(self, session_key: str) -> float:
        return self.weekly

    def caps_monthly(self, session_key: str) -> tuple[float, float]:
        return self.caps

    def first_notice(self, agent_key: str, week: float, level: str) -> bool:
        return self.notices.first(agent_key, week, level)

    def notify(self, payload: dict) -> None:
        self.sent.append(payload)


def _run(tmp_path, bridge, *, override: bool = False):
    from chuk_agents_executor.protocol import task_payload

    executor, controller, calls = _build(tmp_path, budget=bridge)
    executor.start()
    try:
        payload = {**task_payload("hi", "amber")}
        if override:
            payload["budget_override"] = True
        events = controller.collect(controller.send_payload(payload), timeout=20.0)
    finally:
        executor.stop()
    return _done(events), events, calls


def test_the_agents_monthly_cap_stops_a_run_even_with_an_override(tmp_path):
    _spend(tmp_path, "amber/side", 3.0)
    bridge = _CapBridge(agent_cap=3.0)
    done, events, calls = _run(tmp_path, bridge, override=True)
    assert done["reason"] == "budget_exceeded"
    assert "monthly spending cap" in done["final_answer"]
    assert "3.00 of 3.00 EUR" in done["final_answer"]
    assert calls["models"] == 0
    # The weekly warning is not sent for the monthly cap.
    assert not [e for e in events if e.get("type") == "budget_warning"]
    assert bridge.sent == []


def test_the_account_cap_counts_every_agent(tmp_path):
    _spend(tmp_path, "other-agent", 5.0)
    done, _, calls = _run(tmp_path, _CapBridge(account_cap=4.0))
    assert done["reason"] == "budget_exceeded"
    assert done["final_answer"].startswith("All agents on this computer")
    assert calls["models"] == 0


def test_under_the_cap_the_run_goes(tmp_path):
    _spend(tmp_path, "amber", 1.0)
    done, _, calls = _run(tmp_path, _CapBridge(agent_cap=5.0, account_cap=5.0))
    assert done["reason"] == "finished"
    assert calls["models"] >= 1
