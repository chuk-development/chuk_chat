"""Per-action approvals through the executor (docs/WIRE_CONTRACT.md,
"Per-action approvals", bead chuk_chat-mxxm): the ``approval_request`` frame
of a class action, the decision scopes, an older app's plain yes, and a lasting
decision that reaches the host's store and stops the next ask."""

from __future__ import annotations

import threading
import time
from types import SimpleNamespace

from chuk_agents_runtime import MockModelClient, StateStore, tool_call_response
from chuk_agents_runtime.action_policy import ActionDecision, ActionPolicy, ActionRequest
from chuk_agents_sandbox import LocalEnvironment

from chuk_agents_executor import (
    ControllerSession,
    Executor,
    approval_decision_payload,
    loopback_pair,
    task_payload,
)

from test_herenow_approval import _drive, _make_site, _Stub, stub  # noqa: F401 — the fixture
from wiring import paired_channel


class _Hook:
    """Stands in for the host's ``ActionApprovalsBridge``."""

    def __init__(self, policies: dict | None = None) -> None:
        self.policies: dict[str, ActionPolicy] = dict(policies or {})
        self.remembered: list[tuple[str, str, str, str]] = []

    def policy_for(self, session_key: str) -> ActionPolicy:
        return self.policies.get(session_key, ActionPolicy())

    def remember(self, session_key: str, action_class: str, scope: str, site: str = "") -> None:
        self.remembered.append((session_key, action_class, scope, site))
        self.policies[session_key] = self.policy_for(session_key).remembered(action_class, scope, site)


def _executor(tmp_path, *, hook=None, pending=None) -> Executor:
    workspace = tmp_path / "ws"
    workspace.mkdir(exist_ok=True)
    channel = paired_channel()
    _, executor_ep = loopback_pair()
    return Executor(
        name="approvals",
        endpoint=executor_ep,
        opener=channel.executor.opener,
        sealer=channel.executor.sealer,
        environment=LocalEnvironment(workdir=str(workspace)),
        db_path=str(tmp_path / "state.db"),
        model_factory=lambda: MockModelClient(["unused"]),
        action_approvals=hook,
        on_approval_pending=pending,
    )


def _no_kill() -> SimpleNamespace:
    return SimpleNamespace(interrupted=lambda: False, estop_engaged=lambda: False)


def _ask(executor, request, decision: dict):
    """Run the gate on a worker thread, answer with ``decision`` once the frame
    is out, and return ``(frame, answer)``."""
    sent: list[dict] = []
    executor._event = lambda rid, payload: sent.append(payload)  # type: ignore[method-assign]
    gate = executor._make_approval_gate("req-1", _no_kill(), "thread-1")
    outcome: list = []
    worker = threading.Thread(target=lambda: outcome.append(gate(request)))
    worker.start()
    deadline = time.monotonic() + 5
    while not sent and time.monotonic() < deadline:
        time.sleep(0.01)
    assert sent, "no approval_request was sent"
    executor._resolve_approval({"approval_id": sent[0]["approval_id"], **decision})
    worker.join(5)
    return sent[0], outcome[0]


def _mail_request() -> ActionRequest:
    return ActionRequest(
        "send_external",
        "mail_send",
        "Send a mail to bob@example.com",
        {"to": ["bob@example.com"], "subject": "Hi", "preview": "Hello"},
    )


def test_a_class_action_sends_the_card_and_returns_the_scope(tmp_path):
    pending: list[dict] = []
    executor = _executor(tmp_path, pending=pending.append)
    frame, answer = _ask(executor, _mail_request(), {"approved": True, "scope": "always_this_agent"})
    assert frame == {
        "type": "approval_request",
        "approval_id": frame["approval_id"],
        "action": "action_approval",
        "action_class": "send_external",
        "options": ["once", "always_this_agent", "deny"],
        "summary": "Send a mail to bob@example.com",
        "tool": "mail_send",
        "details": {"to": ["bob@example.com"], "subject": "Hi", "preview": "Hello"},
        "path": "",
        "name": "",
        "file_count": 0,
        "total_bytes": 0,
        "base_url": "",
        "public": False,
        "session_key": "thread-1",
    }
    assert answer == ActionDecision(approved=True, scope="always_this_agent")
    # The push hook names the class, so the host can word the notification.
    assert pending[0]["action"] == "action_approval"
    assert pending[0]["action_class"] == "send_external"
    # The persisted row carries what the answer covered.
    store = StateStore(str(tmp_path / "state.db"))
    (row,) = store.replay_events(store.route("thread-1"))
    assert row["decision"] == "approved" and row["decision_scope"] == "always_this_agent"
    store.close()


def test_an_older_app_answering_approved_true_is_once(tmp_path):
    executor = _executor(tmp_path)
    _frame, answer = _ask(executor, _mail_request(), {"approved": True})
    assert answer == ActionDecision(approved=True, scope="once")


def test_a_scope_the_card_did_not_offer_is_once(tmp_path):
    executor = _executor(tmp_path)
    _frame, answer = _ask(executor, _mail_request(), {"approved": True, "scope": "always_this_site"})
    assert answer == ActionDecision(approved=True, scope="once")


def test_deny_is_a_no(tmp_path):
    executor = _executor(tmp_path)
    _frame, answer = _ask(executor, _mail_request(), {"approved": False, "scope": "deny"})
    assert answer == ActionDecision(approved=False, scope="deny")
    assert not answer
    store = StateStore(str(tmp_path / "state.db"))
    (row,) = store.replay_events(store.route("thread-1"))
    assert row["decision"] == "denied" and row["decision_scope"] == "deny"
    store.close()


def test_approved_true_with_scope_deny_is_a_no(tmp_path):
    """A yes whose scope says deny is contradictory: it must never approve."""
    executor = _executor(tmp_path)
    _frame, answer = _ask(executor, _mail_request(), {"approved": True, "scope": "deny"})
    assert answer == ActionDecision(approved=False, scope="deny")
    assert not answer
    store = StateStore(str(tmp_path / "state.db"))
    (row,) = store.replay_events(store.route("thread-1"))
    assert row["decision"] == "denied" and row["decision_scope"] == "deny"
    store.close()


def test_approved_true_with_scope_deny_does_not_run_the_tool(tmp_path, stub):  # noqa: F811
    ws = tmp_path / "ws"
    ws.mkdir()
    _make_site(ws)
    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    executor = Executor(
        name="pub",
        endpoint=executor_ep,
        opener=channel.executor.opener,
        sealer=channel.executor.sealer,
        environment=LocalEnvironment(workdir=str(ws)),
        db_path=str(tmp_path / "state.db"),
        model_factory=lambda: MockModelClient(
            [tool_call_response(("herenow_publish", {"path": "site"})), "done"]
        ),
        workspace=str(ws),
        action_approvals=_Hook(),
    )
    controller = ControllerSession(
        endpoint=controller_ep, sealer=channel.controller.sealer, opener=channel.controller.opener
    )
    executor.start()
    try:
        rid = controller.send_payload(
            task_payload("publish it", "t1", herenow={"enabled": True, "approval": "ask", "base_url": stub})
        )
        events = _drive_scoped(controller, controller_ep, rid, scope="deny")
    finally:
        executor.stop()
    asks = [e for e in events if e.get("type") == "approval_request" and "decision" not in e]
    assert len(asks) == 1
    assert _Stub.uploaded == {}
    store = StateStore(str(tmp_path / "state.db"))
    rows = [r for r in store.replay_events(store.route("t1")) if r.get("type") == "approval_request"]
    store.close()
    assert rows and rows[-1]["decision"] == "denied"


def test_a_browser_card_offers_the_site(tmp_path):
    executor = _executor(tmp_path)
    request = ActionRequest(
        "browser_act", "mcp__pw__browser_click", "Click Buy on shop.example", {"element": "Buy"}, site="shop.example"
    )
    frame, answer = _ask(executor, request, {"approved": True, "scope": "always_this_site"})
    assert frame["site"] == "shop.example"
    assert frame["options"] == ["once", "always_this_agent", "always_this_site", "deny"]
    assert answer == ActionDecision(approved=True, scope="always_this_site")


def test_a_publish_card_keeps_its_fields_and_adds_the_class(tmp_path):
    executor = _executor(tmp_path)
    publish = SimpleNamespace(
        path="site", name="My site", file_count=2, total_bytes=1234, base_url="here.now", public=True
    )
    request = ActionRequest("publish", "herenow_publish", "Publish My site on the open internet", publish=publish)
    frame, answer = _ask(executor, request, {"approved": True})
    assert frame["action"] == "herenow_publish"
    assert frame["file_count"] == 2 and frame["name"] == "My site"
    assert frame["action_class"] == "publish"
    assert frame["options"] == ["once", "always_this_agent", "deny"]
    assert answer == ActionDecision(approved=True, scope="once")


def test_a_plain_publish_gate_still_answers_a_bool(tmp_path):
    executor = _executor(tmp_path)
    publish = SimpleNamespace(
        path="site", name="My site", file_count=2, total_bytes=1234, base_url="here.now", public=True
    )
    frame, answer = _ask(executor, publish, {"approved": True, "scope": "always_this_agent"})
    assert "action_class" not in frame and "options" not in frame
    assert answer is True


def test_always_this_agent_reaches_the_store_and_the_next_task_does_not_ask(tmp_path, stub):  # noqa: F811
    ws = tmp_path / "ws"
    ws.mkdir()
    _make_site(ws)
    hook = _Hook()
    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    executor = Executor(
        name="pub",
        endpoint=executor_ep,
        opener=channel.executor.opener,
        sealer=channel.executor.sealer,
        environment=LocalEnvironment(workdir=str(ws)),
        db_path=str(tmp_path / "state.db"),
        model_factory=lambda: MockModelClient(
            [tool_call_response(("herenow_publish", {"path": "site", "name": "My Page"})), "done"]
        ),
        workspace=str(ws),
        action_approvals=hook,
    )
    controller = ControllerSession(
        endpoint=controller_ep, sealer=channel.controller.sealer, opener=channel.controller.opener
    )
    herenow = {"enabled": True, "approval": "ask", "base_url": stub}
    executor.start()
    try:
        rid = controller.send_payload(task_payload("publish it", "t1", herenow=herenow))
        first = _drive_scoped(controller, controller_ep, rid, scope="always_this_agent")
        rid = controller.send_payload(task_payload("publish again", "t1", herenow=herenow))
        second = _drive_scoped(controller, controller_ep, rid, scope=None)
    finally:
        executor.stop()

    asks = [e for e in first if e.get("type") == "approval_request"]
    assert len(asks) == 1 and asks[0]["action_class"] == "publish"
    assert hook.remembered == [("t1", "publish", "always_this_agent", "")]
    assert any(e.get("type") == "done" and e.get("reason") == "finished" for e in first)
    # The second task follows the remembered "allow": no card, the site went out.
    assert not [e for e in second if e.get("type") == "approval_request"]
    assert any(e.get("type") == "done" and e.get("reason") == "finished" for e in second)
    assert _Stub.uploaded.get("index.html") == b"<h1>hi</h1>"


def test_a_denied_class_never_asks(tmp_path, stub):  # noqa: F811
    ws = tmp_path / "ws"
    ws.mkdir()
    _make_site(ws)
    hook = _Hook({"t1": ActionPolicy(modes={"publish": "deny"})})
    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    executor = Executor(
        name="pub",
        endpoint=executor_ep,
        opener=channel.executor.opener,
        sealer=channel.executor.sealer,
        environment=LocalEnvironment(workdir=str(ws)),
        db_path=str(tmp_path / "state.db"),
        model_factory=lambda: MockModelClient(
            [tool_call_response(("herenow_publish", {"path": "site"})), "done"]
        ),
        workspace=str(ws),
        action_approvals=hook,
    )
    controller = ControllerSession(
        endpoint=controller_ep, sealer=channel.controller.sealer, opener=channel.controller.opener
    )
    executor.start()
    try:
        rid = controller.send_payload(
            task_payload("publish it", "t1", herenow={"enabled": True, "approval": "auto", "base_url": stub})
        )
        events = _drive(controller, controller_ep, rid, decision=None)
    finally:
        executor.stop()
    assert not [e for e in events if e.get("type") == "approval_request"]
    tools = [e for e in events if e.get("type") == "tool" and e.get("name") == "herenow_publish"]
    assert tools and "not allowed to publish" in tools[-1]["result"]
    assert _Stub.uploaded == {}


def _drive_scoped(controller, endpoint, request_id, *, scope, timeout=25.0):
    """Like ``_drive``, but the answer carries a ``scope``."""
    from chuk_agents_manager import decode_frames

    from chuk_agents_executor.protocol import METHOD_EVENT

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
                if payload.get("type") == "approval_request" and "decision" not in payload:
                    controller.send_payload(
                        approval_decision_payload(
                            approval_id=payload["approval_id"], approved=True, scope=scope
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
