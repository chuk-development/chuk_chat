"""The host's side of the user's own browser (docs/WIRE_CONTRACT.md, "The
user's own browser"; bead chuk_chat-8xsn): status pushes to the app, the
coworker's name for the strip, the panel's messages, and
``in_use_by_this_agent`` for the host's own agent. No relay, no add-on: the
party, the sealer and the broker are fakes.
"""

from __future__ import annotations

from test_reprovision import _host

from chuk_agents_executor.user_browser import PANEL_MARK, PANEL_ORIGIN
from chuk_agents_host import host as host_module

HOST_AGENT = "host:cowork-host"


def _status(holder=None, **over):
    status = {
        "host_listening": True,
        "connected": True,
        "browser": "chrome",
        "version": "0.2.0",
        "trusted_input": True,
        "holder": holder,
        "stopped": False,
        "installed": True,
        "browsers": ["chrome"],
    }
    status.update(over)
    return status


class _FakeBroker:
    def __init__(self, *, connected: bool = True) -> None:
        self.connected = connected
        self.sent: list[dict] = []
        self.listeners: list = []
        self.name_resolver = None
        self.page_handler = None

    def add_change_listener(self, callback) -> None:
        self.listeners.append(callback)

    def set_name_resolver(self, resolver) -> None:
        self.name_resolver = resolver

    def set_page_message_handler(self, handler) -> None:
        self.page_handler = handler

    def send_to_extension(self, frame) -> bool:
        if not self.connected:
            return False
        self.sent.append(dict(frame))
        return True


# -- in_use_by_this_agent ------------------------------------------------------------


def test_the_hosts_own_agent_holding_the_browser_is_this_agent(tmp_path, monkeypatch):
    host, _party = _host(tmp_path, attached=True)
    host._coworker_names.upsert("local:desk:1:7", "Crypto Desk", created_by_app=True)

    # The run of the host's own agent names the broker its thread key, not
    # the roster id its permissions are stored under.
    for holder in (HOST_AGENT, "default", "thread-1"):
        monkeypatch.setattr(host_module, "shared_status", lambda h=holder: _status(h))
        reply = host._on_permissions_frame({"type": "agent_permissions_get", "agent_id": HOST_AGENT})
        block = reply["user_browser"]
        assert block["in_use"] is True, holder
        assert block["in_use_by_this_agent"] is True, holder
        assert block["in_use_by"] == {"agent_id": HOST_AGENT, "name": "Your coworker"}
        assert "holder" not in block
        other = host._on_permissions_frame({"type": "agent_permissions_get", "agent_id": "local:desk:1:7"})
        assert other["user_browser"]["in_use_by_this_agent"] is False

    monkeypatch.setattr(host_module, "shared_status", lambda: _status("local:desk:1:7"))
    desk = host._on_permissions_frame({"type": "agent_permissions_get", "agent_id": "local:desk:1:7"})
    assert desk["user_browser"]["in_use_by_this_agent"] is True
    assert desk["user_browser"]["in_use_by"] == {"agent_id": "local:desk:1:7", "name": "Crypto Desk"}
    mine = host._on_permissions_frame({"type": "agent_permissions_get", "agent_id": HOST_AGENT})
    assert mine["user_browser"]["in_use_by_this_agent"] is False

    monkeypatch.setattr(host_module, "shared_status", lambda: _status(None))
    free = host._on_permissions_frame({"type": "agent_permissions_get", "agent_id": HOST_AGENT})
    assert free["user_browser"]["in_use"] is False
    assert free["user_browser"]["in_use_by"] is None
    assert free["user_browser"]["in_use_by_this_agent"] is False


# -- the push -------------------------------------------------------------------------


def test_a_change_is_pushed_once_and_never_names_a_thread_key(tmp_path, monkeypatch):
    host, party = _host(tmp_path, attached=True)
    current = {"status": _status(None)}
    monkeypatch.setattr(host_module, "shared_status", lambda: dict(current["status"]))

    host._on_user_browser_change({})
    host._on_user_browser_change({})  # nothing changed: nothing sent
    current["status"] = _status("thread-1")
    host._on_user_browser_change({})
    current["status"] = _status(None, stopped=True)
    host._on_user_browser_change({})

    pushes = [f for f in party.frames if f.get("type") == "user_browser_status"]
    assert len(pushes) == 3
    first, taken, stopped = (p["user_browser"] for p in pushes)
    assert first["in_use"] is False and first["connected"] is True
    assert taken["in_use_by"] == {"agent_id": HOST_AGENT, "name": "Your coworker"}
    assert "in_use_by_this_agent" not in taken  # host-wide: the app compares in_use_by
    assert "thread-1" not in str(taken)
    assert stopped["stopped"] is True and stopped["in_use"] is False


def test_a_push_nobody_heard_is_sent_again(tmp_path, monkeypatch):
    host, party = _host(tmp_path, attached=False)
    monkeypatch.setattr(host_module, "shared_status", lambda: _status(None))
    host._on_user_browser_change({})
    assert party.frames == []
    party.controller_attached = True
    host._on_user_browser_change({})
    assert [f["type"] for f in party.frames] == ["user_browser_status"]


def test_the_host_wires_itself_into_the_broker(tmp_path):
    host, _party = _host(tmp_path, attached=True)
    host._coworker_names.upsert("local:desk:1:7", "Crypto Desk", created_by_app=True)
    broker = _FakeBroker()
    host._wire_user_browser(broker)
    assert broker.listeners == [host._on_user_browser_change]
    # The strip on the page says the name the user gave the coworker.
    assert broker.name_resolver("local:desk:1:7") == "Crypto Desk"
    assert broker.name_resolver("thread-1") == "Your coworker"
    assert broker.page_handler == host._on_browser_page_message


# -- the panel ---------------------------------------------------------------------------


def test_a_panel_message_is_a_task_of_the_coworker_in_the_browser(tmp_path, monkeypatch):
    host, _party = _host(tmp_path, attached=True)
    host._coworker_names.upsert("local:desk:1:7", "Crypto Desk", created_by_app=True)
    submitted: list[tuple] = []

    def submit(session_key, prompt, meta):
        submitted.append((session_key, prompt, meta))
        return f"run-{len(submitted)}"

    monkeypatch.setattr(host, "_submit_channel_task", submit)
    frame = {
        "type": "page_message",
        "text": "Is this a good price?",
        "context": {"url": "https://shop.example/item/7", "title": "Item 7", "text": "Price 12 EUR"},
    }

    ack = host._on_browser_page_message("local:desk:1:7", frame)
    assert ack == {"ok": True, "coworker": "Crypto Desk"}
    session_key, prompt, meta = submitted[-1]
    assert session_key == "local:desk:1:7"
    assert meta == {"origin": PANEL_ORIGIN}
    assert prompt.startswith(PANEL_MARK + "\nIs this a good price?")
    assert "https://shop.example/item/7" in prompt and "Price 12 EUR" in prompt

    # Nobody held the browser: the host's own coworker, in the app's thread.
    ack = host._on_browser_page_message(None, frame)
    assert ack["ok"] is True and ack["coworker"] == "Your coworker"
    assert submitted[-1][0] == HOST_AGENT

    # An empty message starts nothing.
    assert host._on_browser_page_message(None, {"type": "page_message", "text": "  "})["ok"] is False
    assert len(submitted) == 2


def test_a_panel_message_before_the_host_is_provisioned_says_so(tmp_path, monkeypatch):
    host, _party = _host(tmp_path, attached=True)
    monkeypatch.setattr(host, "_submit_channel_task", lambda *_a: None)
    ack = host._on_browser_page_message(None, {"type": "page_message", "text": "hi"})
    assert ack["ok"] is False and "not ready" in ack["error"]


def test_the_answer_goes_back_to_the_panel_and_replaces_the_toast(tmp_path, monkeypatch):
    host, _party = _host(tmp_path, attached=False)
    broker = _FakeBroker()
    monkeypatch.setattr(host_module, "shared_broker", lambda start=True: broker)
    monkeypatch.setattr(host, "_submit_channel_task", lambda *_a: "run-1")
    notified: list[dict] = []

    class _Notifier:
        def notify_run_finished(self, summary):
            notified.append(summary)

    host._notifier = _Notifier()
    host._on_browser_page_message(None, {"type": "page_message", "text": "hi"})

    host._on_run_finished({"run_id": "run-1", "origin": PANEL_ORIGIN, "final_answer": "Hello."})
    assert broker.sent == [{"type": "page_reply", "coworker": "Your coworker", "text": "Hello."}]
    assert notified == []

    # The add-on went away: the usual toast / push instead.
    broker.connected = False
    host._on_browser_page_message(None, {"type": "page_message", "text": "again"})
    host._on_run_finished({"run_id": "run-1", "origin": PANEL_ORIGIN, "final_answer": "Hi."})
    assert len(notified) == 1

    # A run the panel did not start is not the panel's.
    broker.connected = True
    host._on_run_finished({"run_id": "other", "origin": PANEL_ORIGIN, "final_answer": "x"})
    assert len(broker.sent) == 1


def test_the_panel_runs_the_host_waits_on_are_capped(tmp_path, monkeypatch):
    host, _party = _host(tmp_path, attached=False)
    broker = _FakeBroker()
    monkeypatch.setattr(host_module, "shared_broker", lambda start=True: broker)
    count = iter(range(1, 10_000))
    monkeypatch.setattr(host, "_submit_channel_task", lambda *_a: f"run-{next(count)}")
    total = host_module.MAX_PANEL_RUNS + 10
    for _ in range(total):
        host._on_browser_page_message(None, {"type": "page_message", "text": "hi"})
    assert len(host._panel_runs) == host_module.MAX_PANEL_RUNS
    # The oldest went first: its answer is no longer the panel's.
    assert "run-1" not in host._panel_runs
    host._on_run_finished({"run_id": f"run-{total}", "origin": PANEL_ORIGIN, "final_answer": "ok"})
    assert broker.sent == [{"type": "page_reply", "coworker": "Your coworker", "text": "ok"}]


# -- "Allow again" in the app (user_browser_resume) ----------------------------------


class _StoppedBroker:
    running = True

    def __init__(self) -> None:
        self.stopped = True
        self.lifts = 0

    def resume_by_user(self) -> bool:
        self.lifts += 1
        was, self.stopped = self.stopped, False
        return was


def test_the_apps_resume_lifts_the_stop_and_answers_with_the_status(tmp_path, monkeypatch):
    host, _party = _host(tmp_path, attached=True)
    broker = _StoppedBroker()
    monkeypatch.setattr(host_module, "shared_broker", lambda start=True: broker)
    monkeypatch.setattr(host_module, "shared_status", lambda: _status(None, stopped=broker.stopped))
    reply = host._on_agent_frame({"type": "user_browser_resume"})
    assert broker.lifts == 1
    assert reply["type"] == "user_browser_status"
    assert reply["user_browser"]["stopped"] is False
    assert "in_use_by_this_agent" not in reply["user_browser"]  # host-wide, like the push
    # A second tap finds no Stop: still a status, nothing else changes.
    again = host._on_agent_frame({"type": "user_browser_resume"})
    assert again["user_browser"]["stopped"] is False


def test_the_resume_without_a_broker_still_answers(tmp_path, monkeypatch):
    host, _party = _host(tmp_path, attached=True)
    monkeypatch.setattr(host_module, "shared_broker", lambda start=True: None)
    monkeypatch.setattr(host_module, "shared_status", lambda: _status(None, host_listening=False))
    reply = host._on_agent_frame({"type": "user_browser_resume"})
    assert reply["type"] == "user_browser_status"
    assert reply["user_browser"]["host_listening"] is False


def test_host_route_names_the_resume_capability(tmp_path, monkeypatch):
    host, party = _host(tmp_path, attached=True)
    host._on_agent_frame({"type": "agent_list"})
    routes = [f for f in party.frames if f.get("type") == "host_route"]
    assert routes and "user_browser_resume" in routes[-1]["capabilities"]
