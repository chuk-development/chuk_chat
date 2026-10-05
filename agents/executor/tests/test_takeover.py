"""Browser takeover through the executor (docs/WIRE_CONTRACT.md, "Browser takeover").

The model calls ``request_takeover``; the executor sends one
``approval_request`` with ``action: browser_takeover`` and BLOCKS the run until
the user taps Done or Skip, the page shows the sign-in is over (the host closes
the wait itself, ``decision_reason: "auto"``), the wait times out, or a stop
fires. These tests drive each ending over the real sealed loopback.

The tool is offered only while the agent's own sandbox browser is the target.
A local test box has no browser, so the tests bind the run's backend to the
executor's real wait (``_request_takeover``) the same way ``_takeover_backend``
does, and feed the page URL through ``takeover_url_source``.
"""

from __future__ import annotations

import threading
import time

import pytest
from chuk_agents_runtime import MockModelClient, StateStore, tool_call_response
from chuk_agents_sandbox import LocalEnvironment

import chuk_agents_executor.executor as executor_module
from chuk_agents_executor import (
    ControllerSession,
    Executor,
    approval_decision_payload,
    loopback_pair,
    takeover_request_payload,
)
from chuk_agents_executor.protocol import approval_outcome_fields

from wiring import paired_channel

LOGIN_URL = "https://github.com/login"
APP_URL = "https://github.com/notifications"


def _model(kind="login", site="github.com", reason="GitHub asks you to sign in"):
    args = {"kind": kind, "reason": reason}
    if site is not None:
        args["site"] = site
    return MockModelClient([tool_call_response(("request_takeover", args)), "continuing"])


def _start(tmp_path, model_factory, *, url_source=None, pending=None, **kwargs):
    ws = tmp_path / "ws"
    ws.mkdir(exist_ok=True)
    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    executor = Executor(
        name="takeover",
        endpoint=executor_ep,
        opener=channel.executor.opener,
        sealer=channel.executor.sealer,
        environment=LocalEnvironment(workdir=str(ws)),
        db_path=str(tmp_path / "state.db"),
        model_factory=model_factory,
        workspace=str(ws),
        takeover_url_source=url_source,
        on_approval_pending=pending,
        heartbeat_seconds=kwargs.pop("heartbeat_seconds", 60),
        **kwargs,
    )

    # The sandbox browser is the target: bind the run's backend to the real
    # wait, exactly as ``_takeover_backend`` does for a box with a browser.
    class _Bridge:
        def __init__(self, request_id, kill, session_key, browser_entry=None):
            self.args = (request_id, kill, session_key)

        def available(self) -> bool:
            return True

        def request(self, kind, site, reason):
            return executor._request_takeover(*self.args, kind, site, reason)

    executor._takeover_backend = _Bridge  # type: ignore[method-assign]
    controller = ControllerSession(
        endpoint=controller_ep,
        sealer=channel.controller.sealer,
        opener=channel.controller.opener,
    )
    executor.start()
    return executor, controller


def _drive(controller, request_id, *, on_request=None, timeout=20.0):
    """Every payload of ``request_id`` up to its terminal. ``on_request`` is
    called once per ``approval_request`` that is still undecided."""
    deadline = time.monotonic() + timeout
    events: list[dict] = []
    while time.monotonic() < deadline:
        for event in controller.collect(request_id, timeout=0.1):
            events.append(event)
            if (
                event.get("type") == "approval_request"
                and "decision" not in event
                and on_request is not None
            ):
                on_request(event)
            if event.get("type") in ("done", "error"):
                return events
    raise AssertionError(f"no terminal within {timeout}s: {events}")


def _tool_result(tmp_path, session_key="t1"):
    store = StateStore(str(tmp_path / "state.db"))
    try:
        rows = [m.content for m in store.get_conversation(store.route(session_key))]
    finally:
        store.close()
    results = [r for r in rows if r.get("role") == "tool" and r.get("name") == "request_takeover"]
    assert results, rows
    return results[0]["content"]


def _stored_request(tmp_path, session_key="t1"):
    store = StateStore(str(tmp_path / "state.db"))
    try:
        rows = [
            e for e in store.replay_events(store.route(session_key))
            if isinstance(e, dict) and e.get("type") == "approval_request"
        ]
    finally:
        store.close()
    assert len(rows) == 1, rows
    return rows[0]


def _answer(controller, approved):
    def reply(event):
        controller.send_payload(
            approval_decision_payload(approval_id=event["approval_id"], approved=approved)
        )

    return reply


# -- the frame ---------------------------------------------------------------


def test_the_frame_keeps_the_publish_fields_for_an_older_app():
    frame = takeover_request_payload(
        approval_id="ap-1",
        kind="two_factor",
        site="github.com",
        reason="GitHub asks for the 2FA code",
        url=LOGIN_URL,
        session_key="t1",
    )
    assert frame == {
        "type": "approval_request",
        "approval_id": "ap-1",
        "action": "browser_takeover",
        "kind": "two_factor",
        "site": "github.com",
        "reason": "GitHub asks for the 2FA code",
        "url": LOGIN_URL,
        "path": "",
        "name": "",
        "file_count": 0,
        "total_bytes": 0,
        "base_url": "",
        "public": False,
        "session_key": "t1",
    }


def test_auto_is_a_valid_decision_reason():
    fields = approval_outcome_fields(approved=True, reason="auto", at=1.0)
    assert fields == {"decision": "approved", "decision_reason": "auto", "decided_at": 1.0}
    with pytest.raises(ValueError):
        approval_outcome_fields(approved=True, reason="guess", at=1.0)


# -- the endings ---------------------------------------------------------------


def test_done_continues_the_run(tmp_path):
    pushes: list[dict] = []
    executor, controller = _start(
        tmp_path, _model, url_source=lambda key: LOGIN_URL, pending=pushes.append
    )
    try:
        rid = controller.send_task("check my GitHub notifications", session_key="t1")
        events = _drive(controller, rid, on_request=_answer(controller, True))
    finally:
        executor.stop()

    asks = [e for e in events if e.get("type") == "approval_request"]
    assert len(asks) == 1
    ask = asks[0]
    assert ask["action"] == "browser_takeover" and ask["kind"] == "login"
    assert ask["site"] == "github.com" and ask["reason"] == "GitHub asks you to sign in"
    assert ask["url"] == LOGIN_URL and ask["session_key"] == "t1"
    assert ask["path"] == "" and ask["file_count"] == 0 and ask["public"] is False
    assert events[-1]["type"] == "done" and events[-1]["reason"] == "finished"
    assert _tool_result(tmp_path)["status"] == "done"
    # The row is persisted and its outcome patched in, like a publish approval.
    stored = _stored_request(tmp_path)
    assert stored["approval_id"] == ask["approval_id"]
    assert stored["decision"] == "approved" and stored["decision_reason"] == "user"
    # The pending push names the action, so it gets its own text.
    assert pushes and pushes[0]["action"] == "browser_takeover"
    assert pushes[0]["kind"] == "login" and pushes[0]["site"] == "github.com"
    assert pushes[0]["session_key"] == "t1"


def test_the_run_says_it_waits_on_the_user(tmp_path):
    executor, controller = _start(tmp_path, _model, url_source=lambda key: LOGIN_URL)
    try:
        rid = controller.send_task("check my GitHub notifications", session_key="t1")
        events = _drive(controller, rid, on_request=_answer(controller, True))
    finally:
        executor.stop()
    phases = [(e.get("phase"), e.get("tool")) for e in events if e["type"] == "heartbeat"]
    ask_at = next(i for i, e in enumerate(events) if e["type"] == "approval_request")
    waiting_at = next(
        i for i, e in enumerate(events)
        if e["type"] == "heartbeat" and e.get("phase") == "waiting_user"
    )
    assert ("tool", "request_takeover") in phases
    assert waiting_at > ask_at
    # After the user is done the run is back in its tool, then the model.
    after = phases[phases.index(("waiting_user", None)) + 1 :]
    assert after[:2] == [("tool", "request_takeover"), ("preparing", None)]


def test_skip_tells_the_model_the_user_skipped(tmp_path):
    executor, controller = _start(tmp_path, _model, url_source=lambda key: LOGIN_URL)
    try:
        rid = controller.send_task("check my GitHub notifications", session_key="t1")
        events = _drive(controller, rid, on_request=_answer(controller, False))
    finally:
        executor.stop()
    assert events[-1]["type"] == "done"
    assert _tool_result(tmp_path)["status"] == "skipped"
    stored = _stored_request(tmp_path)
    assert stored["decision"] == "denied" and stored["decision_reason"] == "user"


def test_nobody_answers_and_the_wait_times_out(tmp_path, monkeypatch):
    monkeypatch.setattr(executor_module, "TAKEOVER_WAIT_SECONDS", 0.4)
    executor, controller = _start(tmp_path, _model, url_source=lambda key: LOGIN_URL)
    try:
        rid = controller.send_task("check my GitHub notifications", session_key="t1")
        events = _drive(controller, rid)
    finally:
        executor.stop()
    assert events[-1]["type"] == "done"
    assert _tool_result(tmp_path)["status"] == "timeout"
    stored = _stored_request(tmp_path)
    assert stored["decision"] == "denied" and stored["decision_reason"] == "timeout"


def test_a_stop_ends_the_wait(tmp_path):
    executor, controller = _start(tmp_path, _model, url_source=lambda key: LOGIN_URL)
    try:
        rid = controller.send_task("check my GitHub notifications", session_key="t1")
        events = _drive(
            controller, rid, on_request=lambda event: controller.send_stop(request_id=rid)
        )
    finally:
        executor.stop()
    assert events[-1]["type"] == "done" and events[-1]["reason"] == "interrupted"
    stored = _stored_request(tmp_path)
    assert stored["decision"] == "denied" and stored["decision_reason"] == "stopped"


def test_the_site_comes_from_the_page_when_the_model_names_none(tmp_path):
    executor, controller = _start(
        tmp_path,
        lambda: _model(site=None),
        url_source=lambda key: "https://accounts.google.com/v3/signin",
    )
    try:
        rid = controller.send_task("read my mail", session_key="t1")
        events = _drive(controller, rid, on_request=_answer(controller, True))
    finally:
        executor.stop()
    ask = next(e for e in events if e["type"] == "approval_request")
    assert ask["site"] == "accounts.google.com"


def test_no_page_url_means_no_url_field(tmp_path):
    executor, controller = _start(tmp_path, _model, url_source=lambda key: None)
    try:
        rid = controller.send_task("check my GitHub notifications", session_key="t1")
        events = _drive(controller, rid, on_request=_answer(controller, True))
    finally:
        executor.stop()
    ask = next(e for e in events if e["type"] == "approval_request")
    assert "url" not in ask and ask["site"] == "github.com"


# -- the host resolves it by itself ------------------------------------------------


def test_the_login_page_goes_away_and_the_host_closes_the_wait(tmp_path, monkeypatch):
    monkeypatch.setattr(executor_module, "TAKEOVER_POLL_SECONDS", 0.05)
    urls = iter([LOGIN_URL, LOGIN_URL, "https://github.com/sessions/two-factor/app"])
    lock = threading.Lock()

    def url_source(session_key):
        with lock:
            return next(urls, APP_URL)

    executor, controller = _start(tmp_path, _model, url_source=url_source)
    seen: list[dict] = []
    try:
        rid = controller.send_task("check my GitHub notifications", session_key="t1")
        events = _drive(controller, rid, on_request=seen.append)
    finally:
        executor.stop()

    asks = [e for e in events if e["type"] == "approval_request"]
    assert len(asks) == 2, asks
    first, decided = asks
    assert "decision" not in first and first["url"] == LOGIN_URL
    # The SAME request again, live, decided by the host.
    assert decided["approval_id"] == first["approval_id"]
    assert decided["action"] == "browser_takeover"
    assert decided["decision"] == "approved" and decided["decision_reason"] == "auto"
    assert decided["session_key"] == "t1"
    assert _tool_result(tmp_path)["status"] == "done"
    stored = _stored_request(tmp_path)
    assert stored["decision"] == "approved" and stored["decision_reason"] == "auto"
    assert events[-1]["type"] == "done" and events[-1]["reason"] == "finished"


def test_a_late_decision_after_auto_changes_nothing(tmp_path, monkeypatch):
    monkeypatch.setattr(executor_module, "TAKEOVER_POLL_SECONDS", 0.05)
    urls = iter([LOGIN_URL])
    executor, controller = _start(
        tmp_path, _model, url_source=lambda key: next(urls, APP_URL)
    )
    try:
        rid = controller.send_task("check my GitHub notifications", session_key="t1")
        events = _drive(controller, rid)
        first = next(e for e in events if e["type"] == "approval_request")
        # The user taps Skip on a card the host already closed: a no-op.
        executor._resolve_approval(
            {"type": "approval_decision", "approval_id": first["approval_id"], "approved": False}
        )
    finally:
        executor.stop()
    assert _tool_result(tmp_path)["status"] == "done"
    assert _stored_request(tmp_path)["decision_reason"] == "auto"


def test_the_user_wins_a_race_with_the_watch(tmp_path):
    executor, controller = _start(tmp_path, _model, url_source=lambda key: LOGIN_URL)
    from chuk_agents_executor.executor import _PendingApproval

    pending = _PendingApproval()
    assert pending.decide(False) is True
    # The watch arrives second and must not overwrite the user's answer.
    assert pending.decide(True) is False
    assert pending.approved is False
    executor.stop()


# -- when it is offered -------------------------------------------------------------


def test_no_sandbox_browser_means_no_takeover(tmp_path):
    ws = tmp_path / "ws"
    ws.mkdir()
    channel = paired_channel()
    _controller_ep, executor_ep = loopback_pair()
    executor = Executor(
        name="nobrowser",
        endpoint=executor_ep,
        opener=channel.executor.opener,
        sealer=channel.executor.sealer,
        environment=LocalEnvironment(workdir=str(ws)),
        db_path=str(tmp_path / "state.db"),
        model_factory=lambda: MockModelClient(["x"]),
        workspace=str(ws),
    )
    from chuk_agents_runtime import KillSwitch

    sandbox_entry = {
        "name": "playwright",
        "command": "docker",
        "args": ["exec", "-i", "box-1", "agents-browser-mcp"],
    }
    # A local box has no browser server: nothing to hand over.
    assert executor._takeover_backend("req-1", KillSwitch(), "t1", None) is None
    # The sandbox's own browser server: offered (while it is connected).
    backend = executor._takeover_backend("req-1", KillSwitch(), "t1", sandbox_entry)
    assert backend is not None
    assert backend.available() is False  # no connected server in this session yet
    # The user's own browser over the extension is never handed over.
    extension = {"name": "playwright", "command": "python3", "args": ["agents_extension_mcp.py"]}
    assert executor._takeover_backend("req-1", KillSwitch(), "t1", extension) is None
    executor._uses_user_browser = lambda key: True  # type: ignore[method-assign]
    assert executor._takeover_backend("req-1", KillSwitch(), "t1", sandbox_entry) is None


def test_the_page_url_is_read_from_the_tabs_list(tmp_path):
    ws = tmp_path / "ws"
    ws.mkdir()
    channel = paired_channel()
    _controller_ep, executor_ep = loopback_pair()
    executor = Executor(
        name="tabs",
        endpoint=executor_ep,
        opener=channel.executor.opener,
        sealer=channel.executor.sealer,
        environment=LocalEnvironment(workdir=str(ws)),
        db_path=str(tmp_path / "state.db"),
        model_factory=lambda: MockModelClient(["x"]),
        workspace=str(ws),
    )

    class _Info:
        def __init__(self, name):
            self.name = name

    class _Connection:
        tools = [_Info("browser_tabs"), _Info("browser_navigate")]

        def alive(self):
            return True

    class _Manager:
        connections = {"playwright": _Connection()}
        calls: list[tuple] = []

        def call(self, server, tool, arguments):
            self.calls.append((server, tool, arguments))
            return {
                "ok": True,
                "content": "### Open tabs\n- 0: (current) [Sign in](https://github.com/login)\n",
            }

    manager = _Manager()
    executor._mcp_managers["t1"] = manager  # type: ignore[assignment]
    assert executor._takeover_page_url("t1") == LOGIN_URL
    # A read, never a navigation.
    assert manager.calls == [("playwright", "browser_tabs", {"action": "list"})]
    assert executor._takeover_page_url("other") is None
