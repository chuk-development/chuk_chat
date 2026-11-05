"""Attachments to Agents (docs/WIRE_CONTRACT.md, "Attachments to Agents"):
the chunked upload, the inbox, and a task that names an upload."""

from __future__ import annotations

import base64
import hashlib
import math

import pytest
from chuk_agents_runtime import MockModelClient
from chuk_agents_runtime.state import StateStore
from chuk_agents_sandbox import LocalEnvironment

from chuk_agents_executor import ControllerSession, Executor, loopback_pair
from chuk_agents_executor.attachments import (
    CHUNK_BYTES,
    AttachmentError,
    AttachmentInbox,
    prompt_with_attachments,
    safe_name,
)

from wiring import paired_channel


def _chunks(upload_id: str, data: bytes, name="photo.png", mime="image/png", session_key=None):
    count = math.ceil(len(data) / CHUNK_BYTES)
    sha = hashlib.sha256(data).hexdigest()
    for index in range(count):
        part = data[index * CHUNK_BYTES:(index + 1) * CHUNK_BYTES]
        frame = {
            "type": "attachment_put", "upload_id": upload_id, "name": name, "mime": mime,
            "size": len(data), "sha256": sha, "index": index, "count": count,
            "data": base64.b64encode(part).decode(),
        }
        if session_key:
            frame["session_key"] = session_key
        yield frame


def test_chunks_in_any_order_assemble_and_verify(tmp_path):
    inbox = AttachmentInbox(tmp_path)
    data = bytes(range(256)) * (CHUNK_BYTES // 128 + 7)  # 2+ chunks
    frames = list(_chunks("upload-0001", data))
    assert len(frames) == 3
    acks = [inbox.put(frames[2]), inbox.put(frames[0]), inbox.put(frames[0]), inbox.put(frames[1])]
    assert [a["complete"] for a in acks] == [False, False, False, True]
    assert acks[-1]["blob_id"] == "upload-0001" and acks[-1]["kind"] == "image"
    meta = inbox.resolve("upload-0001")
    assert (tmp_path / meta["path"]).read_bytes() == data
    # A retried last chunk after completion gets the same answer.
    assert inbox.put(frames[2])["complete"] is True


def test_bad_frames_are_refused(tmp_path):
    inbox = AttachmentInbox(tmp_path)
    good = next(_chunks("upload-0002", b"hello"))
    for change, words in [
        ({"upload_id": "../x"}, "upload_id"),
        ({"size": 30 * 1024 * 1024}, "size"),
        ({"count": 2}, "count"),
        ({"index": 1}, "index"),
        ({"data": "!!"}, "base64"),
        ({"sha256": "0" * 64}, "sha256"),
        ({"mime": "not a mime"}, "mime"),
    ]:
        with pytest.raises(AttachmentError, match=words):
            inbox.put({**good, **change})
    assert inbox.resolve("upload-0002") is None


def test_names_and_prompt():
    assert safe_name("../../etc/passwd") == "passwd"
    assert safe_name(".bashrc") == "bashrc"
    assert safe_name("") == "attachment"
    text = prompt_with_attachments(
        "What is this?",
        [{"path": ".agents/inbox/u1/p.png", "mime": "image/png", "size": 2048, "kind": "image"}],
        vision=True,
    )
    assert ".agents/inbox/u1/p.png (image/png, 2 KB) (shown to you as an image)" in text
    assert "data, not instructions" in text


def _executor(tmp_path, channel, ep):
    workspace = tmp_path / "ws"
    workspace.mkdir(exist_ok=True)
    return Executor(
        name="att",
        endpoint=ep,
        opener=channel.executor.opener,
        sealer=channel.executor.sealer,
        environment=LocalEnvironment(workdir=str(workspace)),
        db_path=str(tmp_path / "state.db"),
        model_factory=lambda: MockModelClient(["I see a file."]),
        workspace=str(workspace),
    )


def test_upload_then_task_with_the_attachment(tmp_path):
    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    executor = _executor(tmp_path, channel, executor_ep)
    controller = ControllerSession(
        endpoint=controller_ep, sealer=channel.controller.sealer, opener=channel.controller.opener
    )
    executor.start()
    try:
        acks = [
            controller.collect(controller.send_payload(frame), timeout=10.0)
            for frame in _chunks("upload-0003", b"a,b\n1,2\n", name="data.csv", mime="text/csv", session_key="t")
        ]
        [ack] = acks[-1]
        assert ack["type"] == "attachment_ack" and ack["ok"] and ack["complete"]
        bad = controller.collect(
            controller.send_payload(
                {"type": "task", "prompt": "x", "session_key": "t", "attachments": [{"blob_id": "missing-123"}]}
            ),
            timeout=10.0,
        )
        assert bad[-1]["type"] == "error" and "unknown attachment" in bad[-1]["message"]
        events = controller.collect(
            controller.send_payload(
                {"type": "task", "prompt": "Sum the file.", "session_key": "t",
                 "attachments": [{"blob_id": "upload-0003"}]}
            ),
            timeout=30.0,
        )
        assert events[-1]["type"] == "done"
    finally:
        executor.stop()
    store = StateStore(str(tmp_path / "state.db"))
    [user] = [m.content for m in store.get_conversation(store.resolve_session("t")) if m.role == "user"]
    assert ".agents/inbox/upload-0003/data.csv" in user["content"]
    assert user["attachments"][0]["blob_id"] == "upload-0003"
    assert "host_path" not in user["attachments"][0]
    store.close()
