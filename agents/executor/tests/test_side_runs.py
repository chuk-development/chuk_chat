"""CHAT-80: no queue in an agent's thread, and one worker per agent.

A new message while the agent works is answered at once by a side run; the
work goes on. The side run's turn joins the thread after the work ends, so
the rows of the two runs never interleave. Two agents run at the same time.
"""

from __future__ import annotations

from chuk_agents_runtime import MockModelClient, StateStore

from test_heartbeat import _GatedModel, _rig

AGENT = "local:Mail:1:abc"


def _done(events):
    return [e for e in events if e.get("type") == "done"]


def test_a_new_message_is_answered_while_the_work_goes_on(tmp_path):
    work = _GatedModel()
    seen: list[list[dict]] = []

    class _Side(MockModelClient):
        def complete(self, messages):
            seen.append(list(messages))
            return super().complete(messages)

    executor, controller = _rig(
        tmp_path,
        lambda: work if not work.started.is_set() else _Side(["Ja, läuft noch."]),
    )
    executor.start()
    try:
        first = controller.send_task("sort my whole inbox", session_key=AGENT)
        assert work.started.wait(10.0)
        second = controller.send_task("bist du noch dran?", session_key=AGENT)
        # Answered while the first run is still blocked in its model call.
        side = controller.collect(second, timeout=15.0)
        assert _done(side) and _done(side)[-1]["final_answer"] == "Ja, läuft noch."
        assert not work._gate.is_set()
        # The side run knew about the background work.
        flat = " ".join(str(m.get("content")) for m in seen[0])
        assert "sort my whole inbox" in flat and "background" in flat
        work.release()
        assert _done(controller.collect(first, timeout=15.0))
    finally:
        work.release()
        executor.stop()
    store = StateStore(str(tmp_path / "state.db"))
    rows = store.get_conversation(store.route(AGENT))
    texts = [(m.role, m.content.get("content")) for m in rows if m.role in ("user", "assistant")]
    # The background turn first, then the side turn, never interleaved.
    assert texts[0] == ("user", "sort my whole inbox")
    assert texts[-2:] == [("user", "bist du noch dran?"), ("assistant", "Ja, läuft noch.")]


def test_two_agents_run_at_the_same_time(tmp_path):
    work = _GatedModel()
    executor, controller = _rig(
        tmp_path,
        lambda: work if not work.started.is_set() else MockModelClient(["other agent"]),
    )
    executor.start()
    try:
        first = controller.send_task("long job", session_key="local:A:1:x")
        assert work.started.wait(10.0)
        second = controller.send_task("quick", session_key="local:B:1:y")
        other = controller.collect(second, timeout=15.0)
        assert _done(other)[-1]["final_answer"] == "other agent"
        assert not work._gate.is_set()
        work.release()
        assert _done(controller.collect(first, timeout=15.0))
    finally:
        work.release()
        executor.stop()
