"""The production model path: a real :class:`BackendModelClient` (built by
``make_backend_model_factory`` from a :class:`SupabaseSession`) drives the real
encrypted Executor against a local mock ``/v2/ws`` server. No real credits.

Proves the prod wiring end to end: the executor opens an encrypted task, the
backend client authenticates over ``/v2/ws``, streams a ``<tool_call>`` in its
content, the sandbox runs the command, and the controller receives encrypted
result frames — all without the mock model used elsewhere.
"""

from __future__ import annotations

import json
import threading

from cowork_agent import SupabaseSession
from cowork_manager import RosterStore, RuntimeStatus
from cowork_sandbox import LocalEnvironment
from websockets.sync.server import serve

from cowork_executor import (
    ControllerSession,
    Executor,
    ExecutorSupervisor,
    loopback_pair,
    make_backend_model_factory,
)

from wiring import paired_channel


class _MockWsServer:
    """Speaks the ChukChat /v2/ws protocol. First chat -> a run_command tool call,
    second chat -> the final answer. Routes frames by req_id."""

    def __init__(self):
        self._server = serve(self._handler, "127.0.0.1", 0)
        host, port = self._server.socket.getsockname()[:2]
        self.base_url = f"ws://{host}:{port}"
        self._thread = threading.Thread(target=self._server.serve_forever, daemon=True)
        self._thread.start()

    def _handler(self, ws):
        raw = ws.recv()
        assert json.loads(raw)["type"] == "auth"
        ws.send(json.dumps({"type": "auth_ok"}))
        chat_count = 0
        try:
            while True:
                frame = json.loads(ws.recv())
                if frame.get("type") == "ping":
                    ws.send(json.dumps({"type": "pong"}))
                    continue
                if frame.get("type") != "chat":
                    continue
                req_id = frame["req_id"]
                if chat_count == 0:
                    block = (
                        '<tool_call>{"name":"run_command","arguments":'
                        '{"command":"echo hi > out.txt"}}</tool_call>'
                    )
                    outs = [
                        {"kind": "content", "data": block},
                        {"kind": "done"},
                    ]
                else:
                    outs = [
                        {"kind": "content", "data": "all set"},
                        {"kind": "done"},
                    ]
                chat_count += 1
                for out in outs:
                    out = {**out, "req_id": req_id}
                    ws.send(json.dumps(out))
        except Exception:
            return

    def stop(self):
        self._server.shutdown()


def test_backend_factory_drives_encrypted_executor(tmp_path):
    workspace = tmp_path / "workspace"
    workspace.mkdir()

    server = _MockWsServer()
    session = SupabaseSession(
        access_token="valid-token",
        refresh_token="r",
        supabase_url="https://proj.supabase.co",
        anon_key="anon",
    )
    factory = make_backend_model_factory(
        session,
        model_id="openai/gpt-oss-20b",
        provider_slug="groq",
        base_url=server.base_url,
    )

    roster = RosterStore(":memory:")
    agent = roster.create(workspace_dir=str(workspace), persona="do the thing")

    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()

    def exec_factory(a):
        return Executor(
            name=a.name,
            endpoint=executor_ep,
            opener=channel.executor.opener,
            sealer=channel.executor.sealer,
            environment=LocalEnvironment(workdir=a.workspace_dir),
            db_path=str(tmp_path / "executor-state.db"),
            model_factory=factory,
            system_prompt="You are a CoWork coworker.",
        )

    supervisor = ExecutorSupervisor(roster, exec_factory)
    controller = ControllerSession(
        endpoint=controller_ep,
        sealer=channel.controller.sealer,
        opener=channel.controller.opener,
    )

    try:
        state = supervisor.start(agent.id)
        assert state.status is RuntimeStatus.RUNNING
        request_id = controller.send_task(
            "make a file then tell me done", session_key="thread-1"
        )
        events = controller.collect(request_id, timeout=15.0)
    finally:
        supervisor.stop(agent.id)
        server.stop()

    # The sandbox really ran the command the backend model asked for.
    produced = workspace / "out.txt"
    assert produced.exists()
    assert produced.read_text().strip() == "hi"

    # Encrypted result frames decrypted to the tool activity and the final answer.
    types = [e["type"] for e in events]
    assert types[-1] == "done"
    tool_events = [e for e in events if e["type"] == "tool"]
    assert len(tool_events) == 1
    assert tool_events[0]["name"] == "run_command"
    assert tool_events[0]["exit_code"] == 0
    assert events[-1]["final_answer"] == "all set"
    assert events[-1]["reason"] == "finished"
