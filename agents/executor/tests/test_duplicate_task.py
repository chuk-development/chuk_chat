"""One question, one run. The host refuses a copy of what it is already asking.

From this user's own ``runs`` table on 2026-09-13::

    05:14:04  RUNNING  offne bitt die ergebniss seite im browser ok
    05:13:01  RUNNING  offne bitt die ergebniss seite im browser ok
    05:12:00  RUNNING  offne bitt die ergebniss seite im browser ok

He typed it once. Each of those is a real run — history loaded, 44-62k prompt
tokens estimated, model streaming — so one question was paid for three times at
the provider, and the three copies worked the same session's history at once.

The trigger was on the app side: ``startStreamingPass`` retries a whole pass on
a stream error it classes as reconnectable, and a retry re-sends the task. On
that build the 60-second idle timeout raised exactly such an error ("no response
received" / "server may be overloaded"), which is why the copies are 61 and 63
seconds apart. The host had never stopped working on the first one.

The client half of that is fixed too, but the client can never be the whole
answer: it cannot know whether a copy already arrived, and an older build — the
one on his phone — does not know about any of this. So the rule lives here,
where the truth is. The identity is the pair (session key, prompt): nobody asks
the identical question twice while the first is still running, and a different
follow-up still queues normally.
"""

from __future__ import annotations

import threading

import pytest
from chuk_agents_sandbox import LocalEnvironment

from chuk_agents_executor import ControllerSession, Executor, loopback_pair
from chuk_agents_runtime import MockModelClient

from wiring import paired_channel

PROMPT = "offne bitt die ergebniss seite im browser ok"


class _BlockingModel(MockModelClient):
    """A model that holds the run open until the test lets it finish.

    It must block in ``complete``: that is the one method the agent loop calls.
    It used to override ``chat``, which nothing calls, so the run was never held
    and finished at once; the tests only passed when the disk was slow enough
    to keep the first run registered while the second task arrived.
    """

    gate = threading.Event()

    def complete(self, messages):  # type: ignore[override]
        self.gate.wait(timeout=20.0)
        return super().complete(messages)


@pytest.fixture
def rig(tmp_path):
    (tmp_path / "ws").mkdir()
    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    _BlockingModel.gate.clear()
    executor = Executor(
        name="worker",
        endpoint=executor_ep,
        opener=channel.executor.opener,
        sealer=channel.executor.sealer,
        environment=LocalEnvironment(workdir=str(tmp_path / "ws")),
        db_path=str(tmp_path / "state.db"),
        model_factory=lambda: _BlockingModel(["done"]),
    )
    controller = ControllerSession(
        endpoint=controller_ep,
        sealer=channel.controller.sealer,
        opener=channel.controller.opener,
    )
    executor.start()
    try:
        yield controller, executor
    finally:
        _BlockingModel.gate.set()
        executor.stop()


def test_the_same_question_twice_runs_once(rig):
    """The second copy is refused, and told which run is answering it."""
    controller, executor = rig

    first = controller.send_task(PROMPT, session_key="thread-1")
    # Wait until the first run is registered, which is what makes it "in flight".
    for _ in range(200):
        if executor._run_in_flight("thread-1", PROMPT) is not None:
            break
        threading.Event().wait(0.05)
    live = executor._run_in_flight("thread-1", PROMPT)
    assert live is not None, "the first task never became a run"

    second = controller.send_task(PROMPT, session_key="thread-1")
    events = controller.collect(second, timeout=10.0)

    kinds = [event["type"] for event in events]
    assert kinds[-1] == "done"
    assert events[-1]["reason"] == "duplicate"
    assert events[-1]["run_id"] == live.run_id, "the copy must name the live run"
    # And the sender is told the run is in flight, so the app can adopt it
    # rather than sit behind a spinner with nothing to point at.
    states = [event for event in events if event["type"] == "run_state"]
    assert states and states[0]["state"] == "running"
    assert states[0]["run_id"] == live.run_id

    # Exactly one run exists for the thread: the copy was never enqueued.
    with executor._runs_lock:
        for_thread = [r for r in executor._runs.values() if r.session_key == "thread-1"]
    assert len(for_thread) == 1

    _BlockingModel.gate.set()
    assert controller.collect(first, timeout=20.0)[-1]["reason"] == "finished"


def test_a_different_question_on_the_same_thread_still_queues(rig):
    """The guard is about copies, not about a busy thread."""
    controller, executor = rig

    controller.send_task(PROMPT, session_key="thread-1")
    for _ in range(200):
        if executor._run_in_flight("thread-1", PROMPT) is not None:
            break
        threading.Event().wait(0.05)

    controller.send_task("etwas ganz anderes", session_key="thread-1")
    for _ in range(200):
        with executor._runs_lock:
            count = len(
                [r for r in executor._runs.values() if r.session_key == "thread-1"]
            )
        if count == 2:
            break
        threading.Event().wait(0.05)
    assert count == 2, "a genuine follow-up must still be accepted"

    _BlockingModel.gate.set()
