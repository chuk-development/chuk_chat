"""Retry replaces the last answer instead of asking the same question again.

The app's Retry button re-sends the prompt it already sent. Without a marker the
executor cannot tell that apart from the reader asking twice, so it appended a
second identical user turn: the transcript then replayed the question once per
attempt, and the model was handed a history in which the reader asked the same
thing four times and it answered four times (bead cowork-bkw).

``regenerate: true`` on the task frame (docs/WIRE_CONTRACT.md) says "replace",
and the executor drops the turn being retried before it stores the prompt.
"""

from __future__ import annotations

from cowork_agent import MockModelClient
from cowork_agent.state import StateStore
from cowork_sandbox import LocalEnvironment

from cowork_executor import ControllerSession, Executor, loopback_pair

from wiring import paired_channel


class _Answers:
    """The answer the next run gets.

    The executor builds a SECOND factory client per task for the browser
    fallback, which never runs — so an iterator that pops per factory call would
    hand the loop every other answer. The test advances this itself, once per
    completed run, which is the thing being counted.
    """

    def __init__(self, answers: list[str]) -> None:
        self._answers = answers
        self.index = 0

    def client(self) -> MockModelClient:
        return MockModelClient([self._answers[self.index]])

    def next_run(self) -> None:
        self.index += 1


def _wire(tmp_path, answers: list[str]):
    workspace = tmp_path / "ws"
    workspace.mkdir(exist_ok=True)
    db_path = str(tmp_path / "s.db")
    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    scripted = _Answers(answers)
    executor = Executor(
        name="e",
        endpoint=executor_ep,
        opener=channel.executor.opener,
        sealer=channel.executor.sealer,
        environment=LocalEnvironment(workdir=str(workspace)),
        db_path=db_path,
        model_factory=scripted.client,
    )
    controller = ControllerSession(
        endpoint=controller_ep,
        sealer=channel.controller.sealer,
        opener=channel.controller.opener,
    )
    return executor, controller, db_path, scripted


def _conversation(db_path: str, session_key: str) -> list[tuple[str, str]]:
    store = StateStore(db_path)
    try:
        session_id = store.route(session_key)
        return [
            (m.role, str(m.content.get("content")))
            for m in store.get_conversation(session_id)
            if m.role in ("user", "assistant")
        ]
    finally:
        store.close()


def test_a_retry_replaces_the_turn(tmp_path):
    executor, controller, db_path, scripted = _wire(tmp_path, ["five", "four"])
    executor.start()
    try:
        first = controller.send_task("what is 2+2", session_key="s")
        controller.collect(first, timeout=15.0)
        scripted.next_run()
        again = controller.send_task("what is 2+2", session_key="s", regenerate=True)
        controller.collect(again, timeout=15.0)
    finally:
        executor.stop()

    assert _conversation(db_path, "s") == [
        ("user", "what is 2+2"),
        ("assistant", "four"),
    ]


def test_without_the_marker_a_resend_is_a_new_question(tmp_path):
    """The old behaviour, kept for a reader who really does ask twice."""
    executor, controller, db_path, scripted = _wire(tmp_path, ["one", "two"])
    executor.start()
    try:
        for run in range(2):
            if run:
                scripted.next_run()
            rid = controller.send_task("again", session_key="s")
            controller.collect(rid, timeout=15.0)
    finally:
        executor.stop()

    assert _conversation(db_path, "s") == [
        ("user", "again"),
        ("assistant", "one"),
        ("user", "again"),
        ("assistant", "two"),
    ]


def test_four_retries_replay_the_question_once(tmp_path):
    """The reported symptom: four Retries, four user bubbles."""
    executor, controller, db_path, scripted = _wire(tmp_path, ["a", "b", "c", "d", "e"])
    executor.start()
    try:
        rid = controller.send_task("why", session_key="s")
        controller.collect(rid, timeout=15.0)
        for _ in range(4):
            scripted.next_run()
            rid = controller.send_task("why", session_key="s", regenerate=True)
            controller.collect(rid, timeout=15.0)
    finally:
        executor.stop()

    store = StateStore(db_path)
    try:
        events = store.replay_events(store.route("s"))
    finally:
        store.close()

    assert [e for e in events if e["type"] == "user"] == [
        {"type": "user", "text": "why", "replay": True, "mid": events[0]["mid"]}
    ]
    assert [e["text"] for e in events if e["type"] == "delta"] == ["e"]


def test_a_retry_on_an_empty_session_still_runs(tmp_path):
    executor, controller, db_path, _ = _wire(tmp_path, ["hi"])
    executor.start()
    try:
        rid = controller.send_task("hello", session_key="fresh", regenerate=True)
        events = controller.collect(rid, timeout=15.0)
    finally:
        executor.stop()

    assert any(e.get("type") == "done" for e in events)
    assert _conversation(db_path, "fresh") == [("user", "hello"), ("assistant", "hi")]
