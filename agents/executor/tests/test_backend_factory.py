"""The production model path: a real :class:`BackendModelClient` (built by
``make_backend_model_factory`` from a :class:`SupabaseSession`) drives the real
encrypted Executor against a local OpenAI-compatible ``/v1/chat/completions``
server. No real credits.

Proves the prod wiring end to end: the executor opens an encrypted task, the
agent loop streams from the route with the session's bearer (Pydantic AI's
``OpenAIChatModel``), a native tool call runs in the sandbox, and the
controller receives encrypted result frames — without the mock model used
elsewhere.
"""

from __future__ import annotations

import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from chuk_agents_runtime import SupabaseSession
from chuk_agents_manager import RosterStore, RuntimeStatus
from chuk_agents_sandbox import LocalEnvironment

from chuk_agents_executor import (
    ControllerSession,
    Executor,
    ExecutorSupervisor,
    loopback_pair,
    make_backend_model_factory,
)

from wiring import paired_channel


def _chunk(delta: dict, finish: str | None = None, usage: dict | None = None) -> str:
    body = {
        "id": "c",
        "object": "chat.completion.chunk",
        "created": 0,
        "model": "m",
        "choices": [{"index": 0, "delta": delta, "finish_reason": finish}],
    }
    if usage is not None:
        body["usage"] = usage
    return "data: " + json.dumps(body) + "\n\n"


class _MockRoute:
    """``POST /v1/chat/completions`` as the account proxy speaks it. First
    request -> one complete ``run_command`` tool call, second -> the answer.
    Anything but the session's bearer gets the route's 401."""

    def __init__(self):
        route = self
        self.requests: list[dict] = []

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):  # keep the test output clean
                return

            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                route.requests.append({"path": self.path, "auth": self.headers.get("Authorization"), "body": body})
                if self.headers.get("Authorization") != "Bearer valid-token":
                    self.send_response(401)
                    self.end_headers()
                    return
                usage = {"prompt_tokens": 5, "completion_tokens": 2, "total_tokens": 7}
                if len(route.requests) == 1:
                    call = {
                        "index": 0,
                        "id": "call_0",
                        "type": "function",
                        "function": {"name": "run_command", "arguments": json.dumps({"command": "echo hi > out.txt"})},
                    }
                    events = [
                        _chunk({"role": "assistant", "content": None}),
                        _chunk({"tool_calls": [call]}),
                        _chunk({}, "tool_calls", usage),
                    ]
                else:
                    events = [
                        _chunk({"role": "assistant", "content": ""}),
                        _chunk({"content": "all set"}),
                        _chunk({}, "stop", usage),
                    ]
                payload = ("".join(events) + "data: [DONE]\n\n").encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

        self._server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        host, port = self._server.server_address[:2]
        self.base_url = f"http://{host}:{port}"
        self._thread = threading.Thread(target=self._server.serve_forever, daemon=True)
        self._thread.start()

    def stop(self):
        self._server.shutdown()


def test_backend_factory_drives_encrypted_executor(tmp_path):
    workspace = tmp_path / "workspace"
    workspace.mkdir()

    server = _MockRoute()
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
            system_prompt="You are a Agents coworker.",
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
    # The loop streamed from the OpenAI-compatible route with the bearer.
    assert [r["path"] for r in server.requests] == ["/v1/chat/completions"] * 2
    assert all(r["auth"] == "Bearer valid-token" for r in server.requests)
    first = server.requests[0]["body"]
    assert first["model"] == "openai/gpt-oss-20b" and first["provider"] == "groq"
    assert first["stream"] is True
    assert "run_command" in [t["function"]["name"] for t in first["tools"]]
