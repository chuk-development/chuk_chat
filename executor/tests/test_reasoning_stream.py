"""The model's thinking reaches the app (bead cowork-0ia).

A thinking model (``reasoning_effort`` set, the Fast/Thinking pill) streams its
reasoning on its own channel. The executor forwards it as a ``reasoning`` frame
(docs/WIRE_CONTRACT.md), separate from ``delta``: live per chunk through the
backend client's ``on_reasoning`` seam, once per turn for a client that only
accumulates it, and on replay from the stored assistant row.
"""

from __future__ import annotations

from cowork_agent import MockModelClient, ModelResponse, StateStore, tool_call_response
from cowork_sandbox import LocalEnvironment

from cowork_executor import ControllerSession, Executor, loopback_pair
from cowork_executor.executor import StreamingModelClient
from cowork_executor.protocol import reasoning_payload

from wiring import paired_channel


# -- StreamingModelClient unit ------------------------------------------------


class _StreamingInner:
    """An inner client with both seams, like the real backend client: it
    streams the chunks itself and reports the accumulated turn."""

    def __init__(self) -> None:
        self.on_delta = None
        self.on_reasoning = None

    def complete(self, messages):
        for chunk in ("think ", "hard"):
            self.on_reasoning(chunk)
        for chunk in ("ans", "wer"):
            self.on_delta(chunk)
        return ModelResponse(text="answer", raw={"reasoning": "think hard"})


class _AccumulatingInner:
    """An inner client without seams (the mock): the wrapper emits the whole
    turn once, reasoning first."""

    def complete(self, messages):
        return ModelResponse(text="answer", raw={"reasoning": "think hard"})


def test_wire_shape_of_a_reasoning_frame():
    assert reasoning_payload("hmm") == {"type": "reasoning", "text": "hmm"}


def test_streaming_inner_gets_both_seams_and_nothing_is_emitted_twice():
    seen: list[tuple[str, str]] = []
    inner = _StreamingInner()
    client = StreamingModelClient(
        inner,
        on_delta=lambda t: seen.append(("delta", t)),
        on_reasoning=lambda t: seen.append(("reasoning", t)),
    )
    response = client.complete([])
    assert response.text == "answer"
    assert seen == [
        ("reasoning", "think "),
        ("reasoning", "hard"),
        ("delta", "ans"),
        ("delta", "wer"),
    ]


def test_accumulating_inner_falls_back_to_one_reasoning_then_one_delta():
    seen: list[tuple[str, str]] = []
    client = StreamingModelClient(
        _AccumulatingInner(),
        on_delta=lambda t: seen.append(("delta", t)),
        on_reasoning=lambda t: seen.append(("reasoning", t)),
    )
    client.complete([])
    assert seen == [("reasoning", "think hard"), ("delta", "answer")]


def test_a_turn_without_reasoning_emits_no_reasoning_frame():
    seen: list[tuple[str, str]] = []
    client = StreamingModelClient(
        MockModelClient(["plain"]),
        on_delta=lambda t: seen.append(("delta", t)),
        on_reasoning=lambda t: seen.append(("reasoning", t)),
    )
    client.complete([])
    assert seen == [("delta", "plain")]


def test_no_reasoning_sink_means_the_seam_is_left_alone():
    inner = _StreamingInner()
    seen: list[str] = []
    StreamingModelClient(inner, on_delta=seen.append)
    assert inner.on_reasoning is None
    assert inner.on_delta is not None


# -- end to end: a task streams its thinking; a replay brings it back ---------


def _thinking_model() -> MockModelClient:
    call = tool_call_response(("run_command", {"command": "echo hi > f.txt"}))
    call.raw["reasoning"] = "I will write the file first"
    final = ModelResponse(text="done", raw={"reasoning": "the file exists now"})
    return MockModelClient([call, final])


def _executor(tmp_path, db_path, channel, executor_ep, model_factory) -> Executor:
    workspace = tmp_path / "ws"
    workspace.mkdir(exist_ok=True)
    return Executor(
        name="thinker",
        endpoint=executor_ep,
        opener=channel.executor.opener,
        sealer=channel.executor.sealer,
        environment=LocalEnvironment(workdir=str(workspace)),
        db_path=db_path,
        model_factory=model_factory,
    )


def _controller(channel, controller_ep) -> ControllerSession:
    return ControllerSession(
        endpoint=controller_ep,
        sealer=channel.controller.sealer,
        opener=channel.controller.opener,
    )


def test_task_streams_reasoning_frames_before_each_turns_output(tmp_path):
    db_path = str(tmp_path / "state.db")
    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    executor = _executor(tmp_path, db_path, channel, executor_ep, _thinking_model)
    controller = _controller(channel, controller_ep)

    executor.start()
    try:
        rid = controller.send_task("write hi", session_key="thread-r")
        events = controller.collect(rid, timeout=15.0)
    finally:
        executor.stop()

    kinds = [e["type"] for e in events]
    # The tool turn's reasoning precedes its tool event; the final turn's
    # reasoning precedes its answer text. Reasoning is never inside a delta.
    assert kinds.index("reasoning") < kinds.index("tool")
    reasonings = [e["text"] for e in events if e["type"] == "reasoning"]
    assert reasonings == ["I will write the file first", "the file exists now"]
    deltas = [e["text"] for e in events if e["type"] == "delta"]
    assert deltas == ["done"]
    second_reasoning = [i for i, k in enumerate(kinds) if k == "reasoning"][1]
    assert second_reasoning < kinds.index("delta")
    assert events[-1]["type"] == "done"
    # A live reasoning frame is not a replay.
    assert all(not e.get("replay") for e in events if e["type"] == "reasoning")

    # Persisted for replay: both assistant rows carry their reasoning.
    store = StateStore(db_path)
    sid = store.route("thread-r")
    assistant = [m for m in store.get_conversation(sid) if m.role == "assistant"]
    assert [m.content["reasoning"] for m in assistant] == [
        "I will write the file first",
        "the file exists now",
    ]
    store.close()


def test_replay_brings_the_thinking_block_back_marked_replay(tmp_path):
    db_path = str(tmp_path / "state.db")
    store = StateStore(db_path)
    sid = store.route("thread-r")
    store.append_message(sid, "user", {"role": "user", "content": "why?"})
    store.append_message(
        sid,
        "assistant",
        {"role": "assistant", "reasoning": "log says boom", "content": "because boom"},
    )
    store.close()

    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    executor = _executor(
        tmp_path, db_path, channel, executor_ep, lambda: MockModelClient(["unused"])
    )
    controller = _controller(channel, controller_ep)

    executor.start()
    try:
        rid = controller.send_payload({"type": "replay", "session_key": "thread-r"})
        events = controller.collect(rid, timeout=10.0)
    finally:
        executor.stop()

    kinds = [e["type"] for e in events]
    assert kinds == ["run_state", "user", "reasoning", "delta", "done"]
    _, user, reasoning, delta, done = events
    assert reasoning["text"] == "log says boom"
    assert reasoning["replay"] is True
    # Same row as its answer: the app's replay cursor sees one turn.
    assert reasoning["mid"] == delta["mid"] > user["mid"]
    assert delta["text"] == "because boom"
    assert done["reason"] == "replay"
