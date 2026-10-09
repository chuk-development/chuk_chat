"""A payload too large for one relay frame goes out as ``fragment`` frames
(docs/WIRE_CONTRACT.md, "Fragments", bead chuk_chat-zhhd).

The cloud relay refuses a frame over 1 MiB. Before this change a ``file`` of
more than about 600 KB went out as one frame, the relay refused it, and the app
never saw the file: not live, and not in a replay, because the replay sent the
same oversized frame again. These tests hold the fix in place:

- a small payload is still one frame, byte-identical to before;
- a large payload is split, each frame stays under the relay cap, and the
  receiver gets the original payload back exactly once;
- a 1.6 MB ZIP sent with ``send_file_to_user`` reaches the controller whole,
  live and in a replay.
"""

from __future__ import annotations

import base64
import os

from chuk_agents_runtime import MockModelClient, StateStore, tool_call_response
from chuk_agents_sandbox import LocalEnvironment

from chuk_agents_executor import (
    FRAGMENT_CHUNK_BYTES,
    ControllerSession,
    Executor,
    FragmentAssembler,
    TYPE_FRAGMENT,
    decode_payload,
    encode_payload,
    fragment_plaintexts,
    loopback_pair,
)

from wiring import paired_channel

#: ``MAX_RELAY_FRAME_SIZE`` in the API server (routers/cowork/cowork_ws.py).
RELAY_FRAME_CAP = 1024 * 1024

#: The size of the ZIP in the live failure (run r2-p2, 2026-10-10).
ZIP_BYTES = 1_619_837


# -- the split and the join ---------------------------------------------------


def test_a_small_payload_is_one_unchanged_frame():
    encoded = encode_payload({"type": "delta", "text": "hi"})

    assert fragment_plaintexts(encoded) == [encoded]


def test_a_large_payload_splits_and_joins_back_exactly():
    payload = {"type": "file", "name": "a.zip", "data": "x" * (3 * FRAGMENT_CHUNK_BYTES)}
    encoded = encode_payload(payload)

    parts = [decode_payload(p) for p in fragment_plaintexts(encoded)]

    assert len(parts) == 4
    assert all(p["type"] == TYPE_FRAGMENT for p in parts)
    assert len({p["fragment_id"] for p in parts}) == 1
    assert [p["index"] for p in parts] == [0, 1, 2, 3]
    assert all(p["count"] == 4 and p["total_bytes"] == len(encoded) for p in parts)
    assembler = FragmentAssembler()
    results = [assembler.add(p) for p in parts]
    assert results[:-1] == [None, None, None]
    assert results[-1] == payload


def test_parts_join_in_any_order():
    payload = {"type": "file", "data": os.urandom(900_000).hex()}
    parts = [decode_payload(p) for p in fragment_plaintexts(encode_payload(payload))]

    assembler = FragmentAssembler()
    results = [assembler.add(p) for p in reversed(parts)]

    assert results[-1] == payload
    assert all(r is None for r in results[:-1])


def test_a_payload_that_is_not_a_fragment_passes_through():
    assembler = FragmentAssembler()
    payload = {"type": "delta", "text": "hi"}

    assert assembler.add(payload) is payload


def test_bad_parts_are_dropped_not_raised():
    assembler = FragmentAssembler()
    good = decode_payload(
        fragment_plaintexts(encode_payload({"type": "x", "d": "y" * 100}), chunk_bytes=40)[0]
    )

    assert assembler.add({**good, "data": "%%% not base64"}) is None
    assert assembler.add({**good, "index": 99}) is None
    assert assembler.add({**good, "count": 0}) is None
    assert assembler.add({**good, "total_bytes": 10**12}) is None
    assert assembler.add({"type": TYPE_FRAGMENT}) is None


def test_old_incomplete_payloads_are_evicted():
    def parts(fid: str) -> list[dict]:
        encoded = encode_payload({"type": fid, "d": fid * 100})
        return [
            decode_payload(p)
            for p in fragment_plaintexts(encoded, chunk_bytes=40, fragment_id=fid)
        ]

    a, b, c = parts("a"), parts("b"), parts("c")
    assembler = FragmentAssembler(max_pending=2)
    assembler.add(a[0])
    assembler.add(b[0])
    assembler.add(c[0])  # the third open payload evicts the oldest, "a"

    # "a" lost its first part, so its other parts never complete it.
    assert [assembler.add(p) for p in a[1:]][-1] is None
    # "c" is still open and completes.
    assert [assembler.add(p) for p in c[1:]][-1] == {"type": "c", "d": "c" * 100}


# -- end to end ---------------------------------------------------------------


def _record_wire(endpoint) -> list[int]:
    """Wrap ``endpoint.send`` so the test sees the size of every frame the
    executor puts on the wire."""
    sizes: list[int] = []
    send = endpoint.send

    def recording(data):
        sizes.append(len(data))
        return send(data)

    endpoint.send = recording
    return sizes


def _frame_sizes(sizes: list[int]) -> list[int]:
    return [s for s in sizes if s > 0]


def test_a_large_zip_reaches_the_controller_live_in_frames_under_the_cap(tmp_path):
    workspace = tmp_path / "ws"
    (workspace / "downloads").mkdir(parents=True)
    body = os.urandom(ZIP_BYTES)
    (workspace / "downloads" / "pi.zip").write_bytes(body)

    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    sizes = _record_wire(executor_ep)
    executor = Executor(
        name="filer",
        endpoint=executor_ep,
        opener=channel.executor.opener,
        sealer=channel.executor.sealer,
        environment=LocalEnvironment(workdir=str(workspace)),
        db_path=str(tmp_path / "state.db"),
        model_factory=lambda: MockModelClient(
            [
                tool_call_response(("send_file_to_user", {"path": "downloads/pi.zip"})),
                "sent",
            ]
        ),
        workspace=str(workspace),
    )
    controller = ControllerSession(
        endpoint=controller_ep,
        sealer=channel.controller.sealer,
        opener=channel.controller.opener,
    )
    executor.start()
    try:
        request_id = controller.send_task("zip it", session_key="t1")
        events = controller.collect(request_id, timeout=30.0)
    finally:
        executor.stop()

    files = [e for e in events if e["type"] == "file"]
    assert len(files) == 1, [e["type"] for e in events]
    assert files[0]["name"] == "pi.zip"
    assert base64.b64decode(files[0]["data"]) == body
    assert not [e for e in events if e["type"] == TYPE_FRAGMENT]
    assert events[-1]["type"] == "done"
    # Every frame fits the relay, with room for the cloud envelope around it.
    assert max(_frame_sizes(sizes)) < RELAY_FRAME_CAP * 0.65


def test_a_large_stored_file_replays_whole_in_frames_under_the_cap(tmp_path):
    db_path = str(tmp_path / "state.db")
    store = StateStore(db_path)
    sid = store.route("thread-1")
    store.append_message(sid, "user", {"role": "user", "content": "zip it"})
    body = os.urandom(ZIP_BYTES)
    store.append_event(
        sid,
        {
            "type": "file",
            "name": "raspberry-pi-5.zip",
            "mime_type": "application/zip",
            "size": len(body),
            "data": base64.b64encode(body).decode(),
        },
    )
    store.append_message(sid, "assistant", {"role": "assistant", "content": "done"})
    store.close()

    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    sizes = _record_wire(executor_ep)
    (tmp_path / "ws").mkdir()
    executor = Executor(
        name="replayer",
        endpoint=executor_ep,
        opener=channel.executor.opener,
        sealer=channel.executor.sealer,
        environment=LocalEnvironment(workdir=str(tmp_path / "ws")),
        db_path=db_path,
        model_factory=lambda: MockModelClient(["unused"]),
    )
    controller = ControllerSession(
        endpoint=controller_ep,
        sealer=channel.controller.sealer,
        opener=channel.controller.opener,
    )
    executor.start()
    try:
        rid = controller.send_payload({"type": "replay", "session_key": "thread-1"})
        events = controller.collect(rid, timeout=30.0)
    finally:
        executor.stop()

    kinds = [e["type"] for e in events]
    assert kinds == ["run_state", "user", "file", "delta", "done"]
    file = events[2]
    assert file["replay"] is True and file["mid"] > 0
    assert base64.b64decode(file["data"]) == body
    assert max(_frame_sizes(sizes)) < RELAY_FRAME_CAP * 0.65


def test_a_large_terminal_is_split_and_still_closes_the_stream(tmp_path):
    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    (tmp_path / "ws").mkdir()
    executor = Executor(
        name="t",
        endpoint=executor_ep,
        opener=channel.executor.opener,
        sealer=channel.executor.sealer,
        environment=LocalEnvironment(workdir=str(tmp_path / "ws")),
        db_path=str(tmp_path / "state.db"),
        model_factory=lambda: MockModelClient(["unused"]),
    )
    controller = ControllerSession(
        endpoint=controller_ep,
        sealer=channel.controller.sealer,
        opener=channel.controller.opener,
    )
    big = {"type": "done", "final_answer": "a" * (2 * FRAGMENT_CHUNK_BYTES + 7)}
    request_id = "req-big"
    # Register the id the way ``send_payload`` does, without a real request.
    from chuk_agents_manager import make_request

    controller._corr.register(make_request("run_task", {"x": 1}, request_id))
    executor._stop_beat = lambda rid: None  # type: ignore[method-assign]
    executor._terminal(request_id, big)

    events = controller.collect(request_id, timeout=10.0)

    assert events == [big]
