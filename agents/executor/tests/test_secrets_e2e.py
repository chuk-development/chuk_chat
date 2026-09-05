"""Secrets end to end through the executor (docs/WIRE_CONTRACT.md, "Secrets").

The proof the coordinator asked for: a script that does
``print(os.environ["X"])`` hands the value to NOBODY — not the tool result
the model gets, not the ``tool`` / ``delta`` / ``done`` frames the app gets,
not the messages database. And the round-trip: ``request_secrets`` emits a
``secret_request``, the app's ``secrets`` frame answers it, the tool returns
``set`` / ``missing``, and a cancel (unchanged set) returns ``missing``.
"""

from __future__ import annotations

import base64
import json
import sqlite3
import threading
import time

from cowork_agent import MockModelClient, tool_call_response
from cowork_manager import decode_frames
from cowork_sandbox import LocalEnvironment

from cowork_executor import (
    ControllerSession,
    Executor,
    SecretsVault,
    loopback_pair,
    secrets_payload,
)
from cowork_executor.protocol import METHOD_EVENT

from wiring import paired_channel

VALUE = "sk-live-0123456789abcdef"
B64 = base64.b64encode(VALUE.encode()).decode()


def _model(*script) -> MockModelClient:
    return MockModelClient(list(script))


def _boot(tmp_path, model_factory, vault: SecretsVault | None, **kw):
    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    workspace = tmp_path / "ws"
    workspace.mkdir()
    executor = Executor(
        name="keeper",
        endpoint=executor_ep,
        opener=channel.executor.opener,
        sealer=channel.executor.sealer,
        environment=LocalEnvironment(workdir=str(workspace)),
        db_path=str(tmp_path / "state.db"),
        model_factory=model_factory,
        workspace=str(workspace),
        secrets=vault,
        **kw,
    )
    controller = ControllerSession(
        endpoint=controller_ep,
        sealer=channel.controller.sealer,
        opener=channel.controller.opener,
    )
    return executor, controller, controller_ep


def _db_dump(tmp_path) -> str:
    conn = sqlite3.connect(str(tmp_path / "state.db"))
    try:
        rows = conn.execute("select content from messages").fetchall()
        runs = conn.execute("select * from runs").fetchall()
    finally:
        conn.close()
    return "\n".join(str(r) for r in rows) + "\n" + "\n".join(str(r) for r in runs)


# -- the proof: nobody gets the value ----------------------------------------------


def test_print_environ_reaches_nobody(tmp_path):
    vault = SecretsVault()
    vault.replace({"X": VALUE}, revision=1)
    code = (
        "import os, base64\n"
        "v = os.environ['X']\n"
        "print('raw', v)\n"
        "print('b64', base64.b64encode(v.encode()).decode())\n"
    )
    factory = lambda: _model(  # noqa: E731
        tool_call_response(("python", {"code": code})),
        tool_call_response(("run_command", {"command": "printenv X; echo $X"})),
        f"the key is {VALUE}",  # a model that echoes what it was (not) told
    )
    executor, controller, _ep = _boot(tmp_path, factory, vault)
    executor.start()
    try:
        request_id = controller.send_task("print the key", session_key="s1")
        events = controller.collect(request_id, timeout=20.0)
    finally:
        executor.stop()

    wire = json.dumps(events)
    assert VALUE not in wire and B64 not in wire
    tools = [e for e in events if e.get("type") == "tool"]
    assert len(tools) == 2
    assert "raw [REDACTED:X]" in tools[0]["result"]
    assert "b64 [REDACTED:X]" in tools[0]["result"]
    assert tools[0]["stdout"].count("[REDACTED:X]") == 2
    assert tools[1]["stdout"] == "[REDACTED:X]\n[REDACTED:X]\n"
    done = events[-1]
    assert done["type"] == "done"
    # Even a model that quotes the value in its answer cannot get it to the app.
    assert done["final_answer"] == "the key is [REDACTED:X]"

    dump = _db_dump(tmp_path)
    assert VALUE not in dump and B64 not in dump
    assert "[REDACTED:X]" in dump


def test_without_a_vault_nothing_changes(tmp_path):
    factory = lambda: _model(  # noqa: E731
        tool_call_response(("run_command", {"command": "echo [$X]"})), "ok"
    )
    executor, controller, _ep = _boot(tmp_path, factory, None)
    executor.start()
    try:
        request_id = controller.send_task("x", session_key="s1")
        events = controller.collect(request_id, timeout=20.0)
    finally:
        executor.stop()
    tools = [e for e in events if e.get("type") == "tool"]
    assert tools[0]["stdout"] == "[]\n"


# -- the round-trip ------------------------------------------------------------------


def _drive(controller, endpoint, request_id, *, answer, timeout=25.0):
    """Read the stream; when a ``secret_request`` arrives, call ``answer(payload)``
    and send what it returns (a ``secrets`` frame). Returns every payload up to
    the terminal."""
    deadline = time.monotonic() + timeout
    rx = b""
    events: list[dict] = []
    while time.monotonic() < deadline:
        data = endpoint.recv(timeout=0.2)
        if data is None:
            continue
        rx += data
        frames, rx = decode_frames(rx)
        for frame in frames:
            if frame.get("method") == METHOD_EVENT:
                params = frame.get("params", {}) or {}
                if params.get("requestId") != request_id:
                    continue
                payload = controller._open(params["frame"])
                events.append(payload)
                if payload.get("type") == "secret_request":
                    reply = answer(payload)
                    if reply is not None:
                        controller.send_payload(reply)
            elif frame.get("type") == "response":
                result = frame.get("result") or {}
                if "frame" in result:
                    payload = controller._open(result["frame"])
                    if payload.get("type") in ("done", "error"):
                        events.append(payload)
                        return events
    return events


def test_request_secrets_round_trip_then_the_key_works(tmp_path):
    vault = SecretsVault()
    pending: list[dict] = []
    factory = lambda: _model(  # noqa: E731
        tool_call_response(
            ("request_secrets", {"names": ["PEXELS_API_KEY", "OTHER"], "purpose": "fetch stock photos"})
        ),
        tool_call_response(("python", {"code": "import os; print(os.environ['PEXELS_API_KEY'])"})),
        "done",
    )
    executor, controller, ep = _boot(
        tmp_path, factory, vault, on_secret_request_pending=pending.append
    )
    executor.start()
    try:
        request_id = controller.send_task("get me photos", session_key="s1")

        def answer(payload):
            assert payload["names"] == ["PEXELS_API_KEY", "OTHER"]
            assert payload["purpose"] == "fetch stock photos"
            assert payload["session_key"] == "s1"
            return secrets_payload(
                {"PEXELS_API_KEY": VALUE}, revision=2, request_id=payload["request_id"]
            )

        events = _drive(controller, ep, request_id, answer=answer)
    finally:
        executor.stop()

    assert vault.env() == {"PEXELS_API_KEY": VALUE}
    tools = [e for e in events if e.get("type") == "tool"]
    assert tools[0]["name"] == "request_secrets"
    assert json.loads(tools[0]["result"]) == {"PEXELS_API_KEY": "set", "OTHER": "missing"}
    assert tools[1]["stdout"] == "[REDACTED:PEXELS_API_KEY]\n"
    assert VALUE not in json.dumps(events)
    assert pending and pending[0]["names"] == ["PEXELS_API_KEY", "OTHER"]
    assert VALUE not in json.dumps(pending)


def test_cancel_answers_missing(tmp_path):
    vault = SecretsVault()
    factory = lambda: _model(  # noqa: E731
        tool_call_response(("request_secrets", {"names": ["NOPE"], "purpose": "x"})),
        "done",
    )
    executor, controller, ep = _boot(tmp_path, factory, vault)
    executor.start()
    try:
        request_id = controller.send_task("x", session_key="s1")
        # Cancel = the unchanged (empty) set with the request id.
        events = _drive(
            controller,
            ep,
            request_id,
            answer=lambda p: secrets_payload({}, revision=0, request_id=p["request_id"]),
        )
    finally:
        executor.stop()
    tools = [e for e in events if e.get("type") == "tool"]
    assert json.loads(tools[0]["result"]) == {"NOPE": "missing"}


def test_a_secrets_frame_with_every_name_wakes_the_wait_without_request_id(tmp_path):
    vault = SecretsVault()
    factory = lambda: _model(  # noqa: E731
        tool_call_response(("request_secrets", {"names": ["A"], "purpose": "x"})),
        "done",
    )
    executor, controller, ep = _boot(tmp_path, factory, vault)
    executor.start()
    try:
        request_id = controller.send_task("x", session_key="s1")
        events = _drive(
            controller, ep, request_id,
            answer=lambda p: secrets_payload({"A": "12345678"}, revision=1),
        )
    finally:
        executor.stop()
    tools = [e for e in events if e.get("type") == "tool"]
    assert json.loads(tools[0]["result"]) == {"A": "set"}


def test_stop_ends_the_wait(tmp_path):
    vault = SecretsVault()
    factory = lambda: _model(  # noqa: E731
        tool_call_response(("request_secrets", {"names": ["A"], "purpose": "x"})),
        "never",
    )
    executor, controller, ep = _boot(tmp_path, factory, vault)
    executor.start()
    try:
        request_id = controller.send_task("x", session_key="s1")

        def answer(_payload):
            threading.Timer(0.2, lambda: controller.send_stop(session_key="s1")).start()
            return None

        events = _drive(controller, ep, request_id, answer=answer)
    finally:
        executor.stop()
    assert events[-1]["type"] == "done" and events[-1]["reason"] == "interrupted"


def test_replay_resends_an_open_request(tmp_path):
    vault = SecretsVault()
    factory = lambda: _model(  # noqa: E731
        tool_call_response(("request_secrets", {"names": ["A"], "purpose": "again"})),
        "done",
    )
    executor, controller, ep = _boot(tmp_path, factory, vault)
    executor.start()
    try:
        request_id = controller.send_task("x", session_key="s1")
        # Read the raw stream ourselves: the first ``secret_request`` on the
        # task stream is NOT answered; instead the "app" asks for a replay, and
        # the request must come back on the replay stream. That one is answered.
        deadline = time.monotonic() + 25.0
        rx = b""
        replay_id: str | None = None
        seen: list[tuple[str, dict]] = []
        done: dict | None = None
        while time.monotonic() < deadline and done is None:
            data = ep.recv(timeout=0.2)
            if data is None:
                continue
            rx += data
            frames, rx = decode_frames(rx)
            for frame in frames:
                if frame.get("method") == METHOD_EVENT:
                    params = frame.get("params", {}) or {}
                    payload = controller._open(params["frame"])
                    if payload.get("type") != "secret_request":
                        continue
                    seen.append((params.get("requestId"), payload))
                    if params.get("requestId") == request_id and replay_id is None:
                        replay_id = controller.send_payload({"type": "replay", "session_key": "s1"})
                    elif params.get("requestId") == replay_id:
                        controller.send_payload(
                            secrets_payload({"A": "12345678"}, revision=1, request_id=payload["request_id"])
                        )
                elif frame.get("type") == "response" and frame.get("requestId") == request_id:
                    result = frame.get("result") or {}
                    if "frame" in result:
                        done = controller._open(result["frame"])
    finally:
        executor.stop()
    assert done is not None and done["type"] == "done"
    ids = [rid for rid, _ in seen]
    assert request_id in ids and replay_id in ids
    live = next(p for rid, p in seen if rid == request_id)
    again = next(p for rid, p in seen if rid == replay_id)
    assert live["request_id"] == again["request_id"]
    assert vault.env() == {"A": "12345678"}
