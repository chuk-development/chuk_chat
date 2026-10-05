"""Cost per run and weekly budget (docs/WIRE_CONTRACT.md, "Cost per run and
weekly budget", bead chuk_chat-qcbv): the ``cost`` block on ``done`` and on
``agent_status``, the 80 % warning, and the stop at 100 %."""

from __future__ import annotations

import threading
import time

import pytest

from chuk_agents_runtime import MockModelClient, StateStore
from chuk_agents_runtime.cost import BudgetNotices, PriceBook
from chuk_agents_runtime.model import ModelResponse
from chuk_agents_sandbox import LocalEnvironment

from chuk_agents_executor import ControllerSession, Executor, loopback_pair
from chuk_agents_executor.executor import _Run
from chuk_agents_executor.protocol import agent_status_request_payload, task_payload

from wiring import paired_channel

MODEL = "z-ai/glm-5.3-flash"
PRICES = PriceBook(
    [
        {
            "id": MODEL,
            "providers": [
                {
                    "slug": "deepinfra/fp4",
                    # 1e-6 / 1e-5 per token: 1000 prompt + 100 completion = 0.002 EUR
                    "pricing": {"prompt": 1e-06, "completion": 1e-05, "cache_read": 5e-07},
                }
            ],
        }
    ]
)
RUN_EUR = 1000 * 1e-06 + 100 * 1e-05


class _Model(MockModelClient):
    """A mock that names its model like a real client and reports usage."""

    model_id = MODEL
    provider_slug = "deepinfra/fp4"


def _answer(text: str = "done") -> ModelResponse:
    return ModelResponse(
        text=text,
        raw={"content": text, "usage": {"prompt_tokens": 1000, "completion_tokens": 100,
                                        "total_tokens": 1100}},
    )


class _Bridge:
    """The host's budget bridge, in memory."""

    def __init__(self, budget: float) -> None:
        self.budget = budget
        self.notices = BudgetNotices()
        self.sent: list[dict] = []

    def agent_key(self, session_key: str) -> str:
        # Two threads of one coworker: "amber" and "amber/side".
        return session_key.split("/")[0]

    def budget_weekly(self, session_key: str) -> float:
        return self.budget

    def first_notice(self, agent_key: str, week: float, level: str) -> bool:
        return self.notices.first(agent_key, week, level)

    def notify(self, payload: dict) -> None:
        self.sent.append(payload)


def _build(tmp_path, *, budget=None, prices=PRICES, on_run_finished=None):
    calls = {"models": 0}

    def factory():
        calls["models"] += 1
        return _Model([_answer()])

    workdir = tmp_path / "ws"
    workdir.mkdir(exist_ok=True)
    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    executor = Executor(
        name="agent",
        endpoint=executor_ep,
        opener=channel.executor.opener,
        sealer=channel.executor.sealer,
        environment=LocalEnvironment(workdir=str(workdir)),
        db_path=str(tmp_path / "state.db"),
        model_factory=factory,
        workspace=str(workdir),
        price_book=prices,
        budget=budget,
        on_run_finished=on_run_finished,
    )
    controller = ControllerSession(
        endpoint=controller_ep,
        sealer=channel.controller.sealer,
        opener=channel.controller.opener,
    )
    return executor, controller, calls


def _spend(tmp_path, session_key: str, eur: float) -> None:
    store = StateStore(str(tmp_path / "state.db"))
    try:
        store.add_usage_line(session_key=session_key, kind="run", model=MODEL,
                             prompt_tokens=1, completion_tokens=1, cost_eur=eur)
    finally:
        store.close()


def _status(controller, session_key: str) -> dict:
    events = controller.collect(
        controller.send_payload(agent_status_request_payload(session_key)), timeout=15.0
    )
    return [e for e in events if e.get("type") == "agent_status"][-1]


def _done(events: list[dict]) -> dict:
    return [e for e in events if e.get("type") == "done"][-1]


def test_done_carries_the_cost_of_the_run(tmp_path):
    executor, controller, _ = _build(tmp_path)
    executor.start()
    try:
        events = controller.collect(controller.send_task("hi", session_key="amber"), timeout=20.0)
    finally:
        executor.stop()
    cost = _done(events)["cost"]
    assert cost["currency"] == "EUR"
    assert cost["eur"] == pytest.approx(RUN_EUR)
    assert cost["input_tokens"] == 1000 and cost["output_tokens"] == 100
    (line,) = cost["lines"]
    assert line["kind"] == "run" and line["model"] == MODEL
    assert line["provider"] == "deepinfra/fp4"

    store = StateStore(str(tmp_path / "state.db"))
    try:
        row = store.latest_run("amber")
        assert row["cost_eur"] == pytest.approx(RUN_EUR)
        assert row["prompt_tokens"] == 1000 and row["completion_tokens"] == 100
        # The replayed done says the same.
        (replayed,) = store.run_terminals("amber")
        assert replayed["cost"]["eur"] == pytest.approx(RUN_EUR)
    finally:
        store.close()


def test_without_a_price_list_the_tokens_still_show_but_no_euro(tmp_path):
    executor, controller, _ = _build(tmp_path, prices=None)
    executor.start()
    try:
        events = controller.collect(controller.send_task("hi", session_key="amber"), timeout=20.0)
    finally:
        executor.stop()
    cost = _done(events)["cost"]
    assert "eur" not in cost
    assert cost["input_tokens"] == 1000


def test_a_housekeeping_call_is_its_own_line(tmp_path):
    executor, _controller, _ = _build(tmp_path)
    store = StateStore(str(tmp_path / "state.db"))
    try:
        store.begin_run("r1", store.route("amber"), "amber", "hi")
    finally:
        store.close()
    run = _Run(request_id="t", session_key="amber", prompt="hi", kill=None, run_id="r1")
    sink = executor._usage_sink(run)
    sink("aux", MODEL, None, {"prompt_tokens": 2000, "completion_tokens": 50})
    store = StateStore(str(tmp_path / "state.db"))
    try:
        (line,) = store.usage_lines("r1")
    finally:
        store.close()
    assert line["kind"] == "aux"
    assert line["cost_eur"] == pytest.approx(2000 * 1e-06 + 50 * 1e-05)


def test_status_reports_today_week_and_the_budget_per_coworker(tmp_path):
    bridge = _Bridge(budget=1.0)
    executor, controller, _ = _build(tmp_path, budget=bridge)
    _spend(tmp_path, "amber/side", 0.1)  # another thread of the same coworker
    _spend(tmp_path, "blue", 5.0)  # another coworker: not counted
    executor.start()
    try:
        controller.collect(controller.send_task("hi", session_key="amber"), timeout=20.0)
        status = _status(controller, "amber")
    finally:
        executor.stop()
    cost = status["cost"]
    assert cost["currency"] == "EUR"
    assert cost["session_total"] == pytest.approx(RUN_EUR)
    assert cost["last_run"] == pytest.approx(RUN_EUR)
    assert cost["today"] == pytest.approx(0.1 + RUN_EUR)
    assert cost["week"] == pytest.approx(0.1 + RUN_EUR)
    assert cost["week_starts_at"] <= time.time()
    assert cost["budget_weekly"] == 1.0
    assert cost["budget_state"] == "ok"


def test_a_session_that_never_spent_and_has_no_budget_has_no_cost_block(tmp_path):
    executor, controller, _ = _build(tmp_path, prices=None)
    executor.start()
    try:
        status = _status(controller, "fresh")
    finally:
        executor.stop()
    assert "cost" not in status


def test_crossing_80_percent_warns_once(tmp_path):
    bridge = _Bridge(budget=0.01)
    _spend(tmp_path, "amber", 0.0075)  # the run's 0.002 makes 0.0095: 95 %
    executor, controller, _ = _build(tmp_path, budget=bridge)
    executor.start()
    try:
        first = controller.collect(controller.send_task("one", session_key="amber"), timeout=20.0)
        second = controller.collect(controller.send_task("two", session_key="amber"), timeout=20.0)
    finally:
        executor.stop()
    warnings = [e for e in first if e.get("type") == "budget_warning"]
    assert len(warnings) == 1
    warning = warnings[0]
    assert warning["level"] == "warning" and warning["agent_id"] == "amber"
    assert warning["spent_eur"] == pytest.approx(0.0095)
    assert warning["budget_eur"] == 0.01
    # Before the run's done, so the app can show it in the thread.
    types = [e.get("type") for e in first]
    assert types.index("budget_warning") < types.index("done")
    # The second run crosses 100 %: one exceeded warning, no second "warning".
    levels = [e["level"] for e in second if e.get("type") == "budget_warning"]
    assert levels == ["exceeded"]
    assert [p["level"] for p in bridge.sent] == ["warning", "exceeded"]


def test_over_budget_an_app_task_is_refused_before_it_spends(tmp_path):
    bridge = _Bridge(budget=1.0)
    _spend(tmp_path, "amber", 1.5)
    executor, controller, calls = _build(tmp_path, budget=bridge)
    executor.start()
    try:
        events = controller.collect(controller.send_task("hi", session_key="amber"), timeout=20.0)
    finally:
        executor.stop()
    done = _done(events)
    assert done["reason"] == "budget_exceeded"
    assert "Run anyway" in done["final_answer"]
    assert "cost" not in done
    assert calls["models"] == 0
    assert [e["level"] for e in events if e.get("type") == "budget_warning"] == ["exceeded"]
    store = StateStore(str(tmp_path / "state.db"))
    try:
        row = store.latest_run("amber")
    finally:
        store.close()
    assert row["state"] == "finished" and row["reason"] == "budget_exceeded"


def test_the_user_may_run_over_the_budget_once(tmp_path):
    bridge = _Bridge(budget=1.0)
    _spend(tmp_path, "amber", 1.5)
    executor, controller, calls = _build(tmp_path, budget=bridge)
    executor.start()
    try:
        events = controller.collect(
            controller.send_payload(
                {**task_payload("hi", "amber"), "budget_override": True}
            ),
            timeout=20.0,
        )
    finally:
        executor.stop()
    done = _done(events)
    assert done["reason"] == "finished"
    assert calls["models"] >= 1


def test_over_budget_an_automation_is_skipped(tmp_path):
    bridge = _Bridge(budget=1.0)
    _spend(tmp_path, "amber", 1.0)
    finished: list[dict] = []
    ended = threading.Event()

    def on_finished(summary: dict) -> None:
        finished.append(summary)
        ended.set()

    executor, _controller, calls = _build(tmp_path, budget=bridge, on_run_finished=on_finished)
    executor.start()
    try:
        # Even a task that claims the override: only the user's own task frame
        # may go over.
        executor.submit_task("amber", "[automation x fired: y]", {"automation_id": "x"})
        assert ended.wait(15.0)
    finally:
        executor.stop()
    (summary,) = finished
    assert summary["reason"] == "budget_exceeded"
    assert summary["origin"] == "automation"
    assert "skipped" in summary["final_answer"]
    assert calls["models"] == 0
    assert [p["level"] for p in bridge.sent] == ["exceeded"]


def test_no_budget_means_no_gate(tmp_path):
    bridge = _Bridge(budget=0.0)
    _spend(tmp_path, "amber", 100.0)
    executor, controller, _ = _build(tmp_path, budget=bridge)
    executor.start()
    try:
        events = controller.collect(controller.send_task("hi", session_key="amber"), timeout=20.0)
    finally:
        executor.stop()
    assert _done(events)["reason"] == "finished"
    assert not [e for e in events if e.get("type") == "budget_warning"]
    assert bridge.sent == []
