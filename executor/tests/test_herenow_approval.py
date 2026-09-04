"""here.now publish approval, end to end through the executor.

The novel piece is a genuine reverse round-trip: the run reaches a
``herenow_publish`` call, the executor emits an ``approval_request`` and
**blocks** the worker until the app answers with an ``approval_decision``. These
tests drive that both ways over the real sealed loopback:

- **approve** -> the publisher runs against a stub here.now and the site goes
  live, and the ``approval_request`` the app saw carried the honest scan
  (file count, byte total);
- **deny** -> nothing is published and the tool reports the decline;
- **disabled connector** -> there is no ``herenow_publish`` tool at all, so the
  model's call comes back "unknown tool" — the gate is not the only lock, the
  absence of the tool is.
"""

from __future__ import annotations

import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest
from cowork_agent import MockModelClient, tool_call_response
from cowork_manager import decode_frames
from cowork_sandbox import LocalEnvironment

from cowork_executor import (
    ControllerSession,
    Executor,
    approval_decision_payload,
    loopback_pair,
    task_payload,
)
from cowork_executor.protocol import METHOD_EVENT

from wiring import paired_channel


# -- stub here.now -----------------------------------------------------------


class _Stub(BaseHTTPRequestHandler):
    uploaded: dict[str, bytes] = {}

    def log_message(self, *a):
        pass

    def _json(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        n = int(self.headers.get("content-length", "0"))
        body = self.rfile.read(n) if n else b""
        base = f"http://{self.headers.get('host')}"
        if self.path == "/api/v1/publish":
            req = json.loads(body)
            self._json(200, {
                "slug": "stub", "siteUrl": f"{base}/site/stub/",
                "anonymous": True, "claimUrl": f"{base}/c/tok",
                "expiresAt": "2026-09-04T12:00:00.000Z",
                "upload": {
                    "versionId": "v1",
                    "uploads": [
                        {"path": f["path"], "method": "PUT",
                         "url": f"{base}/u/{f['path']}", "headers": {}}
                        for f in req["files"]
                    ],
                    "finalizeUrl": f"{base}/api/v1/publish/stub/finalize",
                    "expiresInSeconds": 3600,
                },
            })
        elif self.path.endswith("/finalize"):
            self._json(200, {"success": True, "slug": "stub", "siteUrl": f"{base}/site/stub/", "currentVersionId": "v1"})
        else:
            self._json(404, {})

    def do_PUT(self):
        n = int(self.headers.get("content-length", "0"))
        _Stub.uploaded[self.path[len("/u/"):]] = self.rfile.read(n) if n else b""
        self.send_response(200)
        self.end_headers()


@pytest.fixture()
def stub():
    _Stub.uploaded = {}
    server = ThreadingHTTPServer(("127.0.0.1", 0), _Stub)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        yield f"http://127.0.0.1:{server.server_address[1]}"
    finally:
        server.shutdown()


# -- a driver that answers the approval mid-stream ---------------------------


def _drive(controller, endpoint, request_id, *, decision, timeout=25.0):
    """Read the executor's stream and, when an ``approval_request`` arrives,
    reply with the given decision. Returns every payload for ``request_id`` up to
    and including the terminal ``done``/``error``."""
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
                if payload.get("type") == "approval_request" and decision is not None:
                    controller.send_payload(
                        approval_decision_payload(
                            approval_id=payload["approval_id"], approved=decision
                        )
                    )
            elif frame.get("type") == "response":
                result = frame.get("result") or {}
                if "frame" in result:
                    payload = controller._open(result["frame"])
                    if payload.get("type") in ("done", "error"):
                        events.append(payload)
                        return events
    return events


def _start(tmp_path, workspace, model_factory):
    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    executor = Executor(
        name="pub",
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
    return executor, controller, controller_ep


def _publish_model():
    return MockModelClient([
        tool_call_response(("herenow_publish", {"path": "site", "name": "My Page"})),
        "done",
    ])


def _make_site(workspace):
    site = workspace / "site"
    site.mkdir()
    (site / "index.html").write_text("<h1>hi</h1>")


def test_approve_publishes_and_carries_the_scan(tmp_path, stub):
    ws = tmp_path / "ws"
    ws.mkdir()
    _make_site(ws)
    executor, controller, ep = _start(tmp_path, ws, _publish_model)
    try:
        rid = controller.send_payload(
            task_payload("publish it", "t1", herenow={"enabled": True, "approval": "ask", "base_url": stub})
        )
        events = _drive(controller, ep, rid, decision=True)
    finally:
        executor.stop()

    asks = [e for e in events if e.get("type") == "approval_request"]
    assert asks, events
    assert asks[0]["action"] == "herenow_publish"
    assert asks[0]["file_count"] == 1 and asks[0]["total_bytes"] == len("<h1>hi</h1>")
    assert asks[0]["public"] is True
    # The publish actually ran: the stub got the file, the run finished cleanly.
    assert _Stub.uploaded.get("index.html") == b"<h1>hi</h1>"
    assert any(e.get("type") == "done" and e.get("reason") == "finished" for e in events)


def test_deny_does_not_publish(tmp_path, stub):
    ws = tmp_path / "ws"
    ws.mkdir()
    _make_site(ws)
    executor, controller, ep = _start(tmp_path, ws, _publish_model)
    try:
        rid = controller.send_payload(
            task_payload("publish it", "t1", herenow={"enabled": True, "approval": "ask", "base_url": stub})
        )
        events = _drive(controller, ep, rid, decision=False)
    finally:
        executor.stop()

    assert any(e.get("type") == "approval_request" for e in events)
    assert _Stub.uploaded == {}  # nothing left the sandbox
    assert any(e.get("type") == "done" for e in events)


def test_disabled_connector_has_no_publish_tool(tmp_path, stub):
    ws = tmp_path / "ws"
    ws.mkdir()
    _make_site(ws)
    executor, controller, ep = _start(tmp_path, ws, _publish_model)
    try:
        # No herenow config at all -> the tool is never registered.
        rid = controller.send_payload(task_payload("publish it", "t1"))
        events = _drive(controller, ep, rid, decision=None)
    finally:
        executor.stop()

    assert not any(e.get("type") == "approval_request" for e in events)
    assert _Stub.uploaded == {}
    # The model asked for a tool that does not exist; the run still terminates.
    assert any(e.get("type") == "done" for e in events)
