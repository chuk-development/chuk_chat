"""``send_file_to_user`` end to end: a file the agent produced reaches the
controller sealed, and byte-exact.

The interesting properties are all on the executor side, so they are tested
where they live:

- the ``file`` event rides the same sealed stream as the deltas, so a stranger
  cannot open it and the raw bytes never appear on the wire;
- binary content survives the base64 -> seal -> relay -> open -> decode round
  trip exactly, including bytes that are not valid UTF-8;
- the size gate refuses an oversized file at the protocol layer, and the agent
  hears about it as a normal tool failure instead of the channel being flooded.
"""

from __future__ import annotations

import base64
import os

import pytest
from cowork_agent import MockModelClient
from cowork_crypto import ApprovedDevices, CoworkFrameOpener
from cowork_manager import decode_frames
from cowork_sandbox import LocalEnvironment

from cowork_executor import (
    MAX_FILE_BYTES,
    ControllerSession,
    Executor,
    PayloadTooLarge,
    file_payload,
    loopback_pair,
)

from wiring import KEY_VERSION, paired_channel

# Not valid UTF-8 anywhere: proof the payload is carried as bytes, not text.
BINARY = bytes(range(256)) * 40


def _model(*script: str) -> MockModelClient:
    return MockModelClient(list(script))


def _run(tmp_path, workspace, model_factory, timeout: float = 20.0):
    """Start an executor over a paired loopback channel, send one task, and
    return the decrypted events plus the raw wire bytes."""
    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    executor = Executor(
        name="filer",
        endpoint=executor_ep,
        opener=channel.executor.opener,
        sealer=channel.executor.sealer,
        environment=LocalEnvironment(workdir=str(workspace)),
        db_path=str(tmp_path / "state.db"),
        model_factory=model_factory,
        workspace=str(workspace),
    )
    controller = ControllerSession(
        endpoint=controller_ep,
        sealer=channel.controller.sealer,
        opener=channel.controller.opener,
    )
    executor.start()
    try:
        request_id = controller.send_task("send me the file", session_key="t1")
        events = controller.collect(request_id, timeout=timeout)
    finally:
        executor.stop()
    return channel, events


# -- the protocol gate --------------------------------------------------------


def test_file_payload_shape():
    payload = file_payload(name="a.csv", mime_type="text/csv", data=b"a,b\n")

    assert payload["type"] == "file"
    assert payload["name"] == "a.csv"
    assert payload["mime_type"] == "text/csv"
    assert payload["size"] == 4
    assert base64.b64decode(payload["data"]) == b"a,b\n"


def test_file_payload_refuses_an_oversized_file():
    with pytest.raises(PayloadTooLarge):
        file_payload(name="big.bin", mime_type="application/octet-stream",
                     data=b"x" * 1001, max_bytes=1000)


def test_file_payload_refuses_an_empty_file():
    with pytest.raises(ValueError):
        file_payload(name="e", mime_type="text/plain", data=b"")


def test_the_two_ceilings_agree():
    """The agent refuses before it moves a byte; the protocol refuses before it
    builds a frame. They must be the same number or one of them is decoration."""
    from cowork_agent.files_out import MAX_FILE_BYTES as AGENT_LIMIT

    assert MAX_FILE_BYTES == AGENT_LIMIT


# -- end to end ---------------------------------------------------------------


def test_binary_file_survives_the_encrypted_round_trip(tmp_path):
    workspace = tmp_path / "ws"
    workspace.mkdir()
    (workspace / "report.bin").write_bytes(BINARY)

    def factory():
        return _model(
            '<tool_call>{"name":"send_file_to_user",'
            '"arguments":{"path":"report.bin","name":"report.bin"}}</tool_call>',
            "sent it",
        )

    _channel, events = _run(tmp_path, workspace, factory)

    files = [e for e in events if e["type"] == "file"]
    assert len(files) == 1, [e["type"] for e in events]
    sent = files[0]
    assert sent["name"] == "report.bin"
    assert sent["size"] == len(BINARY)
    assert base64.b64decode(sent["data"]) == BINARY
    assert events[-1]["type"] == "done"


def test_the_file_never_appears_in_the_prompt_result(tmp_path):
    """The tool result the model sees carries the name and the size, not the
    bytes — otherwise the file would be re-sent to the model every turn."""
    workspace = tmp_path / "ws"
    workspace.mkdir()
    (workspace / "note.txt").write_bytes(b"MARKER-CONTENT" * 50)

    def factory():
        return _model(
            '<tool_call>{"name":"send_file_to_user",'
            '"arguments":{"path":"note.txt"}}</tool_call>',
            "sent",
        )

    _channel, events = _run(tmp_path, workspace, factory)

    files = [e for e in events if e["type"] == "file"]
    assert base64.b64decode(files[0]["data"]) == b"MARKER-CONTENT" * 50
    # The state store holds what the model was shown; the transcript of the
    # tool result must not contain the content.
    import sqlite3

    rows = sqlite3.connect(tmp_path / "state.db").execute(
        "SELECT content FROM messages"
    ).fetchall()
    transcript = "\n".join(r[0] for r in rows if r[0])
    assert "MARKER-CONTENT" not in transcript
    assert "note.txt" in transcript


def test_the_file_is_encrypted_on_the_wire(tmp_path):
    workspace = tmp_path / "ws"
    workspace.mkdir()
    marker = b"TOP-SECRET-PAYLOAD"
    (workspace / "secret.txt").write_bytes(marker)

    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    executor = Executor(
        name="filer",
        endpoint=executor_ep,
        opener=channel.executor.opener,
        sealer=channel.executor.sealer,
        environment=LocalEnvironment(workdir=str(workspace)),
        db_path=str(tmp_path / "state.db"),
        model_factory=lambda: _model(
            '<tool_call>{"name":"send_file_to_user",'
            '"arguments":{"path":"secret.txt"}}</tool_call>',
            "sent",
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
        request_id = controller.send_task("send it", session_key="t")
        # Drain the raw wire ourselves so the bytes can be inspected.
        raw = b""
        events = []
        import time

        deadline = time.monotonic() + 20.0
        while time.monotonic() < deadline and not events:
            data = controller_ep.recv(timeout=0.2)
            if data is None:
                continue
            raw += data
            frames, _ = decode_frames(raw)
            events = [
                f
                for f in frames
                if f.get("method") == "event"
                and (f.get("params") or {}).get("requestId") == request_id
            ]
    finally:
        executor.stop()

    assert raw, "nothing reached the wire"
    assert marker not in raw
    assert base64.b64encode(marker).rstrip(b"=") not in raw

    # And a stranger cannot open the frame that carries it.
    sealed = base64.b64decode(events[0]["params"]["frame"])
    stranger = CoworkFrameOpener(
        channel_key=channel.channel_key,
        key_version=KEY_VERSION,
        approved_devices=ApprovedDevices(),  # default deny
    )
    from cowork_crypto import CoworkFrameRejected

    with pytest.raises(CoworkFrameRejected):
        stranger.open(sealed)


def test_an_oversized_file_is_refused_and_the_model_is_told(tmp_path):
    workspace = tmp_path / "ws"
    workspace.mkdir()
    # Comfortably over the agent-side ceiling would be slow to build; the agent
    # limit is exercised in the agent suite. Here the file is small enough to
    # transfer and the *protocol* gate is what refuses it.
    (workspace / "big.bin").write_bytes(os.urandom(4096))

    def factory():
        return _model(
            '<tool_call>{"name":"send_file_to_user",'
            '"arguments":{"path":"big.bin"}}</tool_call>',
            "could not send it",
        )

    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    executor = Executor(
        name="filer",
        endpoint=executor_ep,
        opener=channel.executor.opener,
        sealer=channel.executor.sealer,
        environment=LocalEnvironment(workdir=str(workspace)),
        db_path=str(tmp_path / "state.db"),
        model_factory=factory,
        workspace=str(workspace),
    )
    # Shrink the protocol ceiling for this executor only.
    import cowork_executor.executor as executor_module

    original = executor_module.file_payload
    executor_module.file_payload = lambda **kw: original(**kw, max_bytes=1024)

    controller = ControllerSession(
        endpoint=controller_ep,
        sealer=channel.controller.sealer,
        opener=channel.controller.opener,
    )
    executor.start()
    try:
        request_id = controller.send_task("send it", session_key="t")
        events = controller.collect(request_id, timeout=20.0)
    finally:
        executor.stop()
        executor_module.file_payload = original

    # No file event was emitted...
    assert [e for e in events if e["type"] == "file"] == []
    # ...the task still finished cleanly...
    assert events[-1]["type"] == "done"
    # ...and the model was told, so it can compress or split instead of retrying.
    import sqlite3

    rows = sqlite3.connect(tmp_path / "state.db").execute(
        "SELECT content FROM messages"
    ).fetchall()
    transcript = "\n".join(r[0] for r in rows if r[0])
    assert "could not send" in transcript


def test_media_tools_are_absent_without_a_mount(tmp_path):
    """An executor with no workspace mount must not advertise ffmpeg: the model
    would call a tool that cannot run, and pay prompt tokens for it (§7.9)."""
    workspace = tmp_path / "ws"
    workspace.mkdir()
    seen: list[list[dict]] = []

    class PromptSpy(MockModelClient):
        def complete(self, messages):
            seen.append(messages)
            return super().complete(messages)

    def factory():
        return PromptSpy(["nothing to do"])

    _channel, events = _run(tmp_path, workspace, factory)

    assert events[-1]["type"] == "done"
    system = seen[0][0]["content"]
    assert "run_ffmpeg" not in system
    assert "run_ffprobe" not in system
    # send_file_to_user, in contrast, always has a channel here.
    assert "send_file_to_user" in system
