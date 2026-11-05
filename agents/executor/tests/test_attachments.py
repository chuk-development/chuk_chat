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


# -- H1: the agent can write its workspace; the host must not follow its links


def _inbox(tmp_path):
    ws = tmp_path / "ws"
    ws.mkdir()
    return ws, AttachmentInbox(ws, state_dir=tmp_path / "host-state")


def _upload(inbox, upload_id, data, **kw):
    ack = None
    for frame in _chunks(upload_id, data, **kw):
        ack = inbox.put(frame)
    return ack


def test_state_dir_inside_the_workspace_is_refused(tmp_path):
    with pytest.raises(AttachmentError):
        AttachmentInbox(tmp_path, state_dir=tmp_path / ".agents" / "state")


def test_partials_live_outside_the_workspace(tmp_path):
    ws, inbox = _inbox(tmp_path)
    data = b"x" * (CHUNK_BYTES + 10)
    inbox.put(next(_chunks("upload-0100", data)))
    assert not (ws / ".agents").exists()
    assert (tmp_path / "host-state" / "partial" / "upload-0100.part").is_file()


@pytest.mark.parametrize("planted", [".agents", ".agents/inbox", ".agents/inbox/upload-0101"])
def test_symlinked_inbox_directory_is_not_written_through(tmp_path, planted):
    ws, inbox = _inbox(tmp_path)
    outside = tmp_path / "outside"
    outside.mkdir()
    link = ws / planted
    link.parent.mkdir(parents=True, exist_ok=True)
    link.symlink_to(outside, target_is_directory=True)
    with pytest.raises(AttachmentError, match="symlink"):
        _upload(inbox, "upload-0101", b"payload", name="evil.txt", mime="text/plain")
    assert list(outside.rglob("*")) == []
    assert inbox.resolve("upload-0101") is None


def test_symlinked_final_file_is_replaced_not_written_through(tmp_path):
    ws, inbox = _inbox(tmp_path)
    victim = tmp_path / "victim.txt"
    victim.write_text("keep me")
    blob = ws / ".agents" / "inbox" / "upload-0102"
    blob.mkdir(parents=True)
    (blob / "note.txt").symlink_to(victim)
    _upload(inbox, "upload-0102", b"new bytes", name="note.txt", mime="text/plain")
    assert victim.read_text() == "keep me"
    assert not (blob / "note.txt").is_symlink()
    assert (blob / "note.txt").read_bytes() == b"new bytes"


def test_forged_workspace_meta_is_ignored(tmp_path):
    ws, inbox = _inbox(tmp_path)
    blob = ws / ".agents" / "inbox" / "forged-0001"
    blob.mkdir(parents=True)
    (blob / "meta.json").write_text(
        '{"blob_id": "forged-0001", "name": "x", "mime": "image/png", "size": 1,'
        ' "sha256": "' + "0" * 64 + '", "kind": "image", "path": "../../../etc/passwd"}'
    )
    (blob / "x").write_bytes(b"x")
    assert inbox.resolve("forged-0001") is None
    with pytest.raises(AttachmentError, match="unknown attachment"):
        inbox.resolve_task([{"blob_id": "forged-0001"}])


def test_resolve_refuses_a_swapped_file(tmp_path):
    ws, inbox = _inbox(tmp_path)
    ack = _upload(inbox, "upload-0103", b"original", name="a.txt", mime="text/plain")
    path = ws / ack["path"]
    assert inbox.resolve("upload-0103")["path"] == ".agents/inbox/upload-0103/a.txt"
    # The agent swaps the file for a symlink to a host file: refused.
    secret = tmp_path / "secret.txt"
    secret.write_bytes(b"original")  # even with the same bytes
    path.unlink()
    path.symlink_to(secret)
    assert inbox.resolve("upload-0103") is None
    # ... or edits it: refused too.
    path.unlink()
    path.write_bytes(b"changed!")
    assert inbox.resolve("upload-0103") is None


def test_image_mime_is_checked_against_the_bytes(tmp_path):
    _, inbox = _inbox(tmp_path)
    _upload(inbox, "upload-0104", b"#!/bin/sh\necho hi\n", name="a.png", mime="image/png")
    assert inbox.resolve("upload-0104")["kind"] == "file"
    png = b"\x89PNG\r\n\x1a\n" + b"0" * 32
    _upload(inbox, "upload-0105", png, name="b.png", mime="image/png")
    assert inbox.resolve("upload-0105")["kind"] == "image"


def test_sweep_only_touches_host_state(tmp_path):
    ws, inbox = _inbox(tmp_path)
    keep = ws / ".agents" / "inbox" / ".partial"
    keep.mkdir(parents=True)
    victim = tmp_path / "victim.part"
    victim.write_text("keep")
    (keep / "old-00001.json").write_text('{"touched_at": 0}')
    (keep / "old-00001.part").symlink_to(victim)
    stale = tmp_path / "host-state" / "partial"
    stale.mkdir(parents=True)
    (stale / "stale-0001.json").write_text('{"touched_at": 0}')
    (stale / "stale-0001.part").write_bytes(b"x")
    (stale / "noise.txt").write_text("not a record")
    assert inbox.sweep() == 1
    assert not (stale / "stale-0001.part").exists()
    assert (stale / "noise.txt").exists()
    assert victim.read_text() == "keep" and (keep / "old-00001.json").exists()


def test_remove_does_not_follow_links(tmp_path):
    ws, inbox = _inbox(tmp_path)
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "precious").write_text("keep")
    # No host record: nothing is removed, even a real directory.
    planted = ws / ".agents" / "inbox" / "planted-0001"
    planted.mkdir(parents=True)
    assert inbox.remove("planted-0001") is False and planted.is_dir()
    # A recorded upload whose directory the agent replaced with a symlink.
    _upload(inbox, "upload-0106", b"data", name="a.txt", mime="text/plain")
    blob = ws / ".agents" / "inbox" / "upload-0106"
    (blob / "a.txt").unlink()
    blob.rmdir()
    blob.symlink_to(outside, target_is_directory=True)
    (outside / "a.txt").write_text("keep too")
    assert inbox.remove("upload-0106") is True
    assert (outside / "precious").read_text() == "keep"
    assert (outside / "a.txt").read_text() == "keep too"
    assert inbox.resolve("upload-0106") is None
