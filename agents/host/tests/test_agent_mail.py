"""Agent mail on the host (docs/AGENT_MAIL.md §3.1, §6.1, §7): the mail key
and its frame, the ``agent_mail`` relay frame, and the dispatcher that claims
mail and starts the runs.

The mail API is an ``httpx.MockTransport`` that stores every mail sealed to a
test mail key, as the real server does; runs are recorded, not executed.
"""

from __future__ import annotations

import base64
import json
import os
import stat
from datetime import datetime, timezone

import httpx
from chuk_agents_crypto.device_keys import DeviceIdentity
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey

from chuk_agents_host.agent_mail import (
    KEY_INVALID,
    KEY_STORED,
    KEY_UNCHANGED,
    AgentMailService,
    MailKeyStore,
    MailState,
)
from chuk_agents_host.cloud_relay import TYPE_AGENT_MAIL, CloudRelayLink, CloudRelayTransport
from chuk_agents_host.host import LocalHost
from chuk_agents_host.relay_ledger import (
    DECISION_MAIL_FETCH,
    DECISION_MAIL_KEY,
    REASON_INVALID,
    REASON_NOT_ENABLED,
)
from chuk_agents_host.secrets_key import mail_key_at_rest_key, secrets_at_rest_key
from chuk_agents_runtime.agent_mail import KEY_FRAME_TYPE, MAIL_MARKER, PROFILE_MAIL_UNTRUSTED
from chuk_agents_runtime.mail_seal import MailKey, seal_json

NOW = datetime(2026, 9, 30, 12, 0, 0, tzinfo=timezone.utc).timestamp()
MAIN = "host:cowork-host"


def _new_key() -> MailKey:
    private = X25519PrivateKey.generate()
    return MailKey(private.public_key().public_bytes_raw(), private.private_bytes_raw())


KEY = _new_key()


def _frame(key: MailKey) -> dict:
    return {"type": KEY_FRAME_TYPE, "public_key": key.public_b64(), "private_key": key.private_b64()}


def _store(key: MailKey | None = KEY) -> MailKeyStore:
    store = MailKeyStore()
    if key is not None:
        store.put(key.public_b64(), key.private_b64())
    return store


def _iso(ts: float) -> str:
    return datetime.fromtimestamp(ts, tz=timezone.utc).isoformat().replace("+00:00", "Z")


# -- the relay frame -------------------------------------------------------------


class FakeWebSocket:
    def __init__(self, inbound: list[dict] | None = None) -> None:
        self.sent: list[dict] = []
        self._inbound = list(inbound or [])

    def send(self, raw: str) -> None:
        self.sent.append(json.loads(raw))

    def recv(self, timeout: float | None = None) -> str:
        if not self._inbound:
            raise TimeoutError("no frame queued")
        return json.dumps(self._inbound.pop(0))

    def close(self) -> None:
        pass


class _Recorder:
    enabled = True

    def __init__(self) -> None:
        self.lines: list[tuple[str, dict]] = []

    def emit(self, phase: str, **fields) -> None:
        self.lines.append((phase, fields))


def test_the_agent_mail_frame_is_recorded_and_wakes_the_fetch():
    from chuk_agents_runtime.telemetry import set_tracer

    signals: list[str] = []
    link = CloudRelayLink(FakeWebSocket(), on_agent_mail=signals.append)
    recorder = _Recorder()
    previous = set_tracer(recorder)
    try:
        out = link.handle_frame(
            {"type": TYPE_AGENT_MAIL, "event": "new", "message_id": "m-1", "req_id": "r9"}
        )
    finally:
        set_tracer(previous)
    assert out == []  # not a party message
    assert signals == ["frame"]
    lines = [f for phase, f in recorder.lines if phase == "relay_frame_in"]
    assert lines == [
        {
            "frame_type": "agent_mail",
            "decision": DECISION_MAIL_FETCH,
            "req_id": "r9",
            "event": "new",
            "message_id": "m-1",
        }
    ]


def test_a_host_without_mail_logs_the_frame_as_dropped():
    logged: list[str] = []
    link = CloudRelayLink(FakeWebSocket(), logger=logged.append)
    assert link.handle_frame({"type": TYPE_AGENT_MAIL, "event": "new", "message_id": "m-2"}) == []
    assert any("agent_mail" in line and REASON_NOT_ENABLED in line for line in logged)


def test_a_listener_that_raises_does_not_kill_the_pipe():
    def boom(_reason: str) -> None:
        raise RuntimeError("x")

    link = CloudRelayLink(FakeWebSocket(), on_agent_mail=boom, logger=lambda _m: None)
    assert link.handle_frame({"type": TYPE_AGENT_MAIL, "event": "new"}) == []


def _connector(ws: FakeWebSocket):
    def connect(url: str, **_kwargs):
        return ws

    return connect


def test_an_authenticated_connect_fetches_and_a_parked_one_does_not():
    signals: list[str] = []
    transport = CloudRelayTransport(
        device_id="d1",
        channel_id="chan",
        token_provider=lambda: "jwt",
        on_agent_mail=signals.append,
        connect=_connector(FakeWebSocket([{"type": "auth_ok"}])),
    )
    transport.open()
    assert signals == ["connected"]

    parked = CloudRelayTransport(
        device_id="d1",
        channel_id="chan",
        pairing_channel_provider=lambda: "pairing-chan",
        on_agent_mail=signals.append,
        connect=_connector(FakeWebSocket([{"type": "auth_ok", "mode": "pairing"}])),
    )
    parked.open()
    assert signals == ["connected"]


# -- the dispatcher --------------------------------------------------------------


class _Session:
    access_token = "jwt-1"

    def refresh(self) -> None:
        self.access_token = "jwt-2"


_PLAIN = ("id", "direction", "sender_trust", "is_bulk", "created_at")


def _sealed(row: dict, *, body: bool) -> dict:
    """A plain test row as the server returns it: plain columns, the rest
    sealed to :data:`KEY`."""
    out = {k: row[k] for k in _PLAIN if k in row}
    # The server sends each sealed field as a JSON string of the envelope.
    out["sealed_summary"] = json.dumps(
        seal_json(
            {"subject": row.get("subject"), "from_address": row.get("from_address"), "to": []},
            KEY.public_key,
        )
    )
    if body:
        out["sealed_body"] = json.dumps(seal_json({"text": f"text of {row['id']}"}, KEY.public_key))
    return out


class _Api:
    """``/v1/agent-mail`` with a mutable inbox. ``claim_only`` limits what a
    claim may take (another host took the rest)."""

    def __init__(self, rows: list[dict]) -> None:
        self.rows = rows
        self.calls: list[httpx.Request] = []
        self.claim_only: set[str] | None = None
        self.mailbox_status = 200
        #: Answers of the list, used up first: ``(status, detail)``.
        self.list_failures: list[tuple[int, str]] = []
        #: Mail ids whose ``GET /messages/{id}`` fails.
        self.message_failures: set[str] = set()

    def handle(self, request: httpx.Request) -> httpx.Response:
        self.calls.append(request)
        path = request.url.path.removeprefix("/v1/agent-mail")
        if path == "/mailbox":
            if self.mailbox_status != 200:
                return httpx.Response(self.mailbox_status, json={"detail": "no_subscription"})
            return httpx.Response(200, json={"address": "x@chukagents.com", "status": "active"})
        if path == "/messages" and request.method == "GET":
            assert request.url.params["undelivered"] == "true"
            if self.list_failures:
                status, detail = self.list_failures.pop(0)
                return httpx.Response(status, json={"detail": detail})
            rows = [_sealed(r, body=False) for r in self.rows if not r.get("_claimed")]
            return httpx.Response(200, json={"messages": rows, "next_before": None})
        if path == "/messages/claim":
            ids = json.loads(request.content)["ids"]
            taken = []
            for row in self.rows:
                if row["id"] in ids and not row.get("_claimed"):
                    if self.claim_only is None or row["id"] in self.claim_only:
                        row["_claimed"] = True
                        taken.append(row["id"])
            return httpx.Response(200, json={"claimed": taken})
        if path.startswith("/messages/") and request.method == "GET":
            ident = path.rsplit("/", 1)[1]
            # The HostView is host code now: the server is never asked for one.
            assert "view" not in request.url.params
            if ident in self.message_failures:
                return httpx.Response(500, json={"detail": "boom"})
            row = next(r for r in self.rows if r["id"] == ident)
            return httpx.Response(200, json=_sealed(row, body=True))
        return httpx.Response(404, json={"detail": "not_found"})

    def claims(self) -> list[list[str]]:
        return [json.loads(r.content)["ids"] for r in self.calls if r.url.path.endswith("/claim")]


class _Clock:
    def __init__(self, now: float = NOW) -> None:
        self.now = now

    def __call__(self) -> float:
        return self.now


class _Runs:
    def __init__(self) -> None:
        self.ready = True
        self.busy_keys: set[str] = set()
        self.submitted: list[tuple[str, str, dict]] = []
        self.gone = False

    def submit(self, session_key: str, prompt: str, meta: dict) -> str | None:
        if self.gone:
            return None  # the executor went away after the claim
        self.submitted.append((session_key, prompt, meta))
        return f"run-{len(self.submitted)}"


def _row(ident: str, trust: str, *, age: float = 120.0, bulk: bool = False) -> dict:
    return {
        "id": ident,
        "direction": "inbound",
        "from_address": f"{ident}@example.org",
        "subject": f"subject {ident}",
        "sender_trust": trust,
        "is_bulk": bulk,
        "created_at": _iso(NOW - age),
    }


def _service(
    tmp_path, api: _Api, runs: _Runs, clock: _Clock, *, session=True, key: MailKey | None = KEY, **kw
) -> AgentMailService:
    session_obj = _Session() if session else None
    kw.setdefault("key_store", _store(key))
    return AgentMailService(
        session_provider=lambda: session_obj,
        submit=runs.submit,
        ready=lambda: runs.ready,
        busy=lambda key: key in runs.busy_keys,
        main_session=MAIN,
        state_path=tmp_path / "agent_mail.json",
        base_url="https://api.example.test",
        http_client=httpx.Client(transport=httpx.MockTransport(api.handle)),
        clock=clock,
        **kw,
    )


def test_bulk_mail_is_claimed_and_starts_no_run(tmp_path):
    api = _Api([_row("b1", "trusted", bulk=True), _row("b2", "unknown", bulk=True)])
    runs = _Runs()
    report = _service(tmp_path, api, runs, _Clock()).dispatch_once()
    assert api.claims() == [["b1", "b2"]]
    assert report.bulk == 2 and runs.submitted == []


def test_trusted_mail_is_batched_into_one_full_run_on_the_main_session(tmp_path):
    api = _Api([_row("t1", "owner"), _row("t2", "trusted")])
    runs = _Runs()
    report = _service(tmp_path, api, runs, _Clock()).dispatch_once()
    assert api.claims() == [["t1", "t2"]]
    assert len(runs.submitted) == 1 and report.full_mails == 2
    session_key, prompt, meta = runs.submitted[0]
    assert session_key == MAIN
    assert meta["origin"] == "mail" and "profile" not in meta
    header, _, body = prompt.partition(MAIL_MARKER + "\n")
    assert "[mail: 2 new messages" in header
    mails = json.loads(body)
    assert [m["id"] for m in mails] == ["t1", "t2"]
    # Fetched and opened on the host; the subject came out of sealed_summary.
    assert mails[0]["text"] == "text of t1" and mails[0]["subject"] == "subject t1"


def test_unknown_mail_waits_30_seconds_then_gets_a_restricted_run(tmp_path):
    api = _Api([_row("u1", "unknown", age=10.0)])
    runs = _Runs()
    clock = _Clock()
    service = _service(tmp_path, api, runs, clock)
    report = service.dispatch_once()
    # Too young: not claimed, so a mail_wait can still take it.
    assert api.claims() == [] and runs.submitted == []
    assert report.waiting == 1 and 20.0 <= report.retry_in <= 22.0

    clock.now += 25.0
    report = service.dispatch_once()
    assert api.claims() == [["u1"]]
    session_key, prompt, meta = runs.submitted[0]
    assert session_key == "mail:u1"
    assert meta == {"origin": "mail_untrusted", "profile": PROFILE_MAIL_UNTRUSTED, "message_id": "u1"}
    # The task text carries no mail content.
    assert "subject u1" not in prompt and "u1@example.org" not in prompt
    assert report.restricted_runs == ["run-1"]


def test_the_daily_cap_is_kept_across_a_restart_and_resets_the_next_day(tmp_path):
    api = _Api([_row(f"u{i}", "unknown") for i in range(3)])
    runs = _Runs()
    clock = _Clock()
    report = _service(tmp_path, api, runs, clock, daily_cap=2).dispatch_once()
    assert len(report.restricted_runs) == 2 and report.capped == 1
    # The capped mail is stored (claimed) but starts no run.
    assert api.claims() == [["u0", "u1", "u2"]]
    assert [s[0] for s in runs.submitted] == ["mail:u0", "mail:u1"]

    # A restart: a new service on the same state file keeps the day's count.
    api.rows.append(_row("u3", "unknown"))
    report = _service(tmp_path, api, runs, clock, daily_cap=2).dispatch_once()
    assert report.restricted_runs == [] and report.capped == 1

    clock.now += 24 * 3600
    api.rows.append({**_row("u4", "unknown"), "created_at": _iso(clock.now - 60)})
    report = _service(tmp_path, api, runs, clock, daily_cap=2).dispatch_once()
    assert len(report.restricted_runs) == 1
    assert json.loads((tmp_path / "agent_mail.json").read_text())["restricted_runs"]["count"] == 1


def test_a_lost_claim_starts_no_run(tmp_path):
    api = _Api([_row("t1", "trusted"), _row("u1", "unknown")])
    api.claim_only = set()  # another host of the user was first
    runs = _Runs()
    report = _service(tmp_path, api, runs, _Clock()).dispatch_once()
    assert report.lost == 2 and runs.submitted == []
    assert MailState(tmp_path / "agent_mail.json", clock=_Clock()).used() == 0


def test_claimed_mail_that_could_not_start_is_started_later(tmp_path):
    api = _Api([_row("t1", "trusted"), _row("u1", "unknown")])
    runs = _Runs()
    runs.gone = True
    clock = _Clock()
    report = _service(tmp_path, api, runs, clock).dispatch_once()
    assert api.claims() == [["t1", "u1"]]
    assert runs.submitted == [] and report.pending == 2 and report.retry_in == 10.0
    # Kept on disk too: a restart does not lose them.
    state = json.loads((tmp_path / "agent_mail.json").read_text())["pending"]
    assert state == {"full": [{"id": "t1", "sender_trust": "trusted"}], "restricted": ["u1"]}

    # Still gone: nothing new is claimed while mails wait.
    api.rows.append(_row("t2", "owner"))
    service = _service(tmp_path, api, runs, clock)
    assert service.dispatch_once().skipped == "pending"
    assert api.claims() == [["t1", "u1"]]

    # Back: the pending mails start first, with no second claim for them.
    runs.gone = False
    report = service.dispatch_once()
    keys = [key for key, _prompt, _meta in runs.submitted]
    assert keys[:2] == [MAIN, "mail:u1"]
    assert json.loads(runs.submitted[0][1].partition(MAIL_MARKER + "\n")[2])[0]["id"] == "t1"
    assert api.claims() == [["t1", "u1"], ["t2"]]
    assert keys[2:] == [MAIN]
    assert json.loads((tmp_path / "agent_mail.json").read_text())["pending"] == {"full": [], "restricted": []}
    # The test's clock, not the real date: the day count is per UTC day.
    assert MailState(tmp_path / "agent_mail.json", clock=clock).used() == 1


def test_each_mail_is_handled_once(tmp_path):
    api = _Api([_row("t1", "trusted")])
    runs = _Runs()
    service = _service(tmp_path, api, runs, _Clock())
    service.dispatch_once()
    service.dispatch_once()
    assert len(runs.submitted) == 1


def test_trusted_mail_waits_unclaimed_while_the_main_session_is_busy(tmp_path):
    api = _Api([_row("t1", "trusted")])
    runs = _Runs()
    runs.busy_keys.add(MAIN)
    service = _service(tmp_path, api, runs, _Clock())
    report = service.dispatch_once()
    assert report.deferred == 1 and api.claims() == [] and report.retry_in == 30.0
    runs.busy_keys.clear()
    api.rows.append(_row("t2", "owner"))
    service.dispatch_once()
    assert len(runs.submitted) == 1
    assert [m["id"] for m in json.loads(runs.submitted[0][1].partition(MAIL_MARKER + "\n")[2])] == ["t1", "t2"]


def test_the_agents_own_mail_starts_nothing(tmp_path):
    api = _Api([{**_row("s1", "self"), "direction": None}, {**_row("s2", "owner"), "direction": "outbound"}])
    runs = _Runs()
    report = _service(tmp_path, api, runs, _Clock()).dispatch_once()
    assert report.listed == 2 and api.claims() == [] and runs.submitted == []


def test_nothing_is_fetched_before_a_run_can_start(tmp_path):
    api = _Api([_row("t1", "trusted")])
    runs = _Runs()
    runs.ready = False
    report = _service(tmp_path, api, runs, _Clock()).dispatch_once()
    assert report.skipped == "not_ready" and report.retry_in == 10.0
    assert api.calls == []


def test_no_account_session_means_no_client_and_no_request(tmp_path):
    api = _Api([_row("t1", "trusted")])
    service = _service(tmp_path, api, _Runs(), _Clock(), session=False)
    assert service.client() is None
    assert service.dispatch_once().skipped == "no_account"
    assert api.calls == []


def test_no_subscription_means_no_mail_tools(tmp_path):
    api = _Api([_row("t1", "trusted")])
    api.mailbox_status = 402
    runs = _Runs()
    service = _service(tmp_path, api, runs, _Clock())
    assert service.client() is not None  # unknown until the server answers
    report = service.dispatch_once()
    assert report.skipped == "unavailable" and runs.submitted == []
    assert service.client() is None


def test_a_passing_503_of_the_list_keeps_the_mail_tools_and_retries_soon(tmp_path):
    # The server answers 503 agent_mail_unavailable for a Supabase timeout
    # too. After a good mailbox probe that is a fault, not "no mailbox".
    api = _Api([_row("t1", "trusted")])
    api.list_failures = [(503, "agent_mail_unavailable")]
    runs = _Runs()
    service = _service(tmp_path, api, runs, _Clock())
    report = service.dispatch_once()
    assert report.skipped == "error" and report.retry_in == 30.0
    assert service.client() is not None
    report = service.dispatch_once()
    assert report.skipped is None and len(runs.submitted) == 1


def test_a_503_of_the_mailbox_probe_means_no_mail_tools(tmp_path):
    api = _Api([_row("t1", "trusted")])
    api.mailbox_status = 503
    service = _service(tmp_path, api, _Runs(), _Clock())
    assert service.dispatch_once().skipped == "unavailable"
    assert service.client() is None


def test_the_thread_fetches_at_start_and_on_wake(tmp_path):
    api = _Api([_row("t1", "trusted")])
    runs = _Runs()
    service = _service(tmp_path, api, runs, _Clock(), poll_seconds=3600)
    service.start()
    try:
        import time

        deadline = time.monotonic() + 5
        while not runs.submitted and time.monotonic() < deadline:
            time.sleep(0.02)
        assert len(runs.submitted) == 1
        api.rows.append(_row("t2", "trusted"))
        service.wake("frame")
        deadline = time.monotonic() + 5
        while len(runs.submitted) < 2 and time.monotonic() < deadline:
            time.sleep(0.02)
        assert len(runs.submitted) == 2
    finally:
        service.stop()


# -- the host --------------------------------------------------------------------


class _Notifier:
    def __init__(self) -> None:
        self.summaries: list[dict] = []

    def notify_run_finished(self, summary: dict) -> bool:
        self.summaries.append(summary)
        return True


def _host(tmp_path) -> LocalHost:
    return LocalHost(
        port=0,
        workspace_dir=str(tmp_path),
        agent_name="t",
        channel_id="testchannel00",
        digits="428913",
        model_factory_override=lambda: None,
    )


def test_a_restricted_run_is_never_announced_and_a_mail_run_is(tmp_path):
    host = _host(tmp_path)
    try:
        notifier = _Notifier()
        host._notifier = notifier  # type: ignore[assignment]
        host._controller_attached = lambda: False  # type: ignore[method-assign]
        host._on_run_finished({"run_id": "r1", "session_key": "mail:u1", "origin": "mail_untrusted"})
        host._on_run_finished({"run_id": "r2", "session_key": MAIN, "origin": "mail"})
        assert [s["run_id"] for s in notifier.summaries] == ["r2"]
        # Attached: a mail run is unattended like an automation, so no
        # run_ack timer waits for it.
        host._controller_attached = lambda: True  # type: ignore[method-assign]
        host._desktop_notifier = None
        host._notifier._mark_notified_once = lambda _rid: True  # type: ignore[attr-defined]
        host._on_run_finished({"run_id": "r3", "session_key": MAIN, "origin": "mail"})
        assert "r3" not in host._ack_pending
    finally:
        host._roster.close()
        host._coworker_names.close()


def test_mail_runs_go_to_the_hosts_executor(tmp_path):
    host = _host(tmp_path)

    class _Executor:
        def __init__(self) -> None:
            self.tasks: list[tuple[str, str, dict]] = []

        def submit_task(self, key, prompt, meta):
            self.tasks.append((key, prompt, meta))
            return "run-x"

        def has_live_run(self, key):
            return key == "busy"

    executor = _Executor()

    class _Supervisor:
        def executor(self, agent_id):
            return executor if agent_id == host._agent.id else None

    class _Server:
        supervisor = _Supervisor()

    class _Party:
        task_server = _Server()

    try:
        assert host._submit_mail_run("mail:u1", "p", {}) is None  # no party yet
        host._party = _Party()  # type: ignore[assignment]
        assert host._submit_mail_run("mail:u1", "p", {"profile": "mail_untrusted"}) == "run-x"
        assert executor.tasks == [("mail:u1", "p", {"profile": "mail_untrusted"})]
        assert host._mail_session_busy("busy") and not host._mail_session_busy("idle")
        # Before start() there is no mail service; a frame is a no-op.
        host._on_agent_mail_signal("frame")
    finally:
        host._party = None
        host._roster.close()
        host._coworker_names.close()


# -- the full run's prompt when a fetch fails --------------------------------------


def test_a_failed_fetch_falls_back_to_the_opened_summary(tmp_path):
    api = _Api([_row("t1", "trusted")])
    api.message_failures.add("t1")
    runs = _Runs()
    _service(tmp_path, api, runs, _Clock()).dispatch_once()
    mail = json.loads(runs.submitted[0][1].partition(MAIL_MARKER + "\n")[2])[0]
    assert mail["subject"] == "subject t1" and mail["text_omitted"] is True
    assert "text" not in mail


# -- the mail key (docs/AGENT_MAIL.md §3.1, §6.1) ----------------------------------


def test_the_key_frame_is_stored_once_and_wakes_the_fetch(tmp_path):
    logged: list[str] = []
    service = _service(tmp_path, _Api([]), _Runs(), _Clock(), key=None, logger=logged.append)
    assert service.keys.get() is None
    assert service.accept_key_frame(_frame(KEY)) == KEY_STORED
    assert service.keys.get().same_as(KEY)
    assert service._wake.is_set()
    service._wake.clear()
    # The app sends it on every connect: the same key changes nothing.
    assert service.accept_key_frame(_frame(KEY)) == KEY_UNCHANGED
    assert not service._wake.is_set()
    # A new key (made again in the app) replaces the old one.
    other = _new_key()
    assert service.accept_key_frame(_frame(other)) == KEY_STORED
    assert service.keys.get().same_as(other)
    assert not any(KEY.private_b64() in line or other.private_b64() in line for line in logged)


def test_a_key_frame_with_a_mismatched_pair_is_refused(tmp_path):
    logged: list[str] = []
    service = _service(tmp_path, _Api([]), _Runs(), _Clock(), key=None, logger=logged.append)
    other = _new_key()
    bad = {"type": KEY_FRAME_TYPE, "public_key": other.public_b64(), "private_key": KEY.private_b64()}
    for frame in (
        bad,
        {"type": KEY_FRAME_TYPE, "public_key": KEY.public_b64()},
        {"type": KEY_FRAME_TYPE, "public_key": "AAAA", "private_key": "AAAA"},
        {"type": KEY_FRAME_TYPE, "public_key": 7, "private_key": ["x"]},
    ):
        assert service.accept_key_frame(frame) == KEY_INVALID
    assert service.keys.get() is None
    # A bad frame never replaces a good key either.
    service.accept_key_frame(_frame(KEY))
    assert service.accept_key_frame(bad) == KEY_INVALID
    assert service.keys.get().same_as(KEY)
    assert not any(KEY.private_b64() in line for line in logged)


def test_the_key_is_kept_at_rest_encrypted_with_mode_600(tmp_path):
    identity = DeviceIdentity.generate()
    at_rest = mail_key_at_rest_key(identity)
    # A label of its own: not the secret vault's key.
    assert at_rest != secrets_at_rest_key(identity)
    path = tmp_path / "agent_mail_key.enc"
    store = MailKeyStore(path, at_rest_key=at_rest)
    assert store.get() is None
    assert store.put(KEY.public_b64(), KEY.private_b64()) is True
    assert stat.S_IMODE(os.stat(path).st_mode) == 0o600
    text = path.read_text()
    assert KEY.private_b64() not in text and KEY.public_b64() not in text
    assert not list(tmp_path.glob("*.tmp"))
    # A restart reads it back.
    assert MailKeyStore(path, at_rest_key=at_rest).get().same_as(KEY)
    # Another host identity cannot open it: no key, no crash.
    logged: list[str] = []
    other = MailKeyStore(path, at_rest_key=mail_key_at_rest_key(DeviceIdentity.generate()), log=logged.append)
    assert other.get() is None and logged
    # The same key again writes nothing.
    before = path.stat().st_mtime_ns
    assert store.put(KEY.public_b64(), KEY.private_b64()) is False
    assert path.stat().st_mtime_ns == before


def test_without_a_key_nothing_is_listed_or_claimed_until_the_key_frame(tmp_path):
    api = _Api([_row("t1", "trusted"), _row("u1", "unknown")])
    runs = _Runs()
    logged: list[str] = []
    service = _service(tmp_path, api, runs, _Clock(), key=None, logger=logged.append)
    report = service.dispatch_once()
    assert report.skipped == "needs_key" and report.retry_in is None
    assert api.calls == [] and runs.submitted == []
    service.dispatch_once()
    assert sum("no mail key" in line for line in logged) == 1  # said once, not per poll
    # The tools are still offered, and say what to do.
    client = service.client()
    assert client is not None and client.mail_key() is None
    # The app connects and hands the key over: dispatch resumes.
    assert service.accept_key_frame(_frame(KEY)) == KEY_STORED
    report = service.dispatch_once()
    assert report.skipped is None
    assert [key for key, _p, _m in runs.submitted] == [MAIN, "mail:u1"]


def test_claimed_mail_waits_for_the_key_too(tmp_path):
    api = _Api([_row("t1", "trusted")])
    runs = _Runs()
    runs.gone = True
    clock = _Clock()
    store = _store()
    _service(tmp_path, api, runs, clock, key_store=store).dispatch_once()
    assert api.claims() == [["t1"]]
    # A restart with no key yet (the file did not open): the pending mail
    # starts nothing, and nothing new is claimed.
    runs.gone = False
    service = _service(tmp_path, api, runs, clock, key=None)
    assert service.dispatch_once().skipped == "needs_key"
    assert runs.submitted == []
    service.accept_key_frame(_frame(KEY))
    service.dispatch_once()
    assert [key for key, _p, _m in runs.submitted] == [MAIN]


# -- the key frame at the cloud party ----------------------------------------------


def _party_with(handler):
    import test_lost_task_frame as harness

    from chuk_agents_crypto.device_keys import DeviceIdentity as Identity
    from chuk_agents_host.cloud_party import CloudHostParty
    from chuk_agents_host.pairing_store import HostTrust

    identity = Identity.generate()
    servers: list = []

    def build(opener, sealer, token, host):
        servers.append(harness.FakeTaskServer())
        return servers[-1]

    trust = HostTrust(harness.CHANNEL, harness.CHANNEL_KEY, harness.PHONE, Identity.generate().public_key)
    lines: list[str] = []
    party = CloudHostParty(
        trust_provider=lambda: trust,
        mail_key_handler=handler,
        transport=object(),
        channel_id=harness.CHANNEL,
        pairing_factory=lambda: None,
        device_id="host",
        device_identity=identity,
        key_version=1,
        build_task_server=build,
        logger=lines.append,
    )
    app = harness.Wire(party, identity)
    app.resume()
    return party, app, servers, lines


def test_the_cloud_party_takes_the_key_frame_before_the_provision_gate():
    from chuk_agents_runtime.telemetry import set_tracer

    store = MailKeyStore()
    service_calls: list[dict] = []

    def handler(payload: dict) -> str:
        service_calls.append(payload)
        try:
            return KEY_STORED if store.put(payload.get("public_key"), payload.get("private_key")) else KEY_UNCHANGED
        except ValueError:
            return KEY_INVALID

    party, app, servers, lines = _party_with(handler)
    recorder = _Recorder()
    previous = set_tracer(recorder)
    try:
        # Not provisioned yet: the key still lands, and no task server sees it.
        app.send(_frame(KEY))
        app.send(_frame(KEY))
        app.send({"type": KEY_FRAME_TYPE, "public_key": _new_key().public_b64(), "private_key": KEY.private_b64()})
    finally:
        set_tracer(previous)
    assert store.get().same_as(KEY) and len(service_calls) == 3
    assert servers == []
    acted = [f for phase, f in recorder.lines if phase == "relay_frame_in"]
    assert [(f["decision"], f.get("outcome")) for f in acted if f["frame_type"] == KEY_FRAME_TYPE] == [
        (DECISION_MAIL_KEY, KEY_STORED),
        (DECISION_MAIL_KEY, KEY_UNCHANGED),
    ]
    assert any(KEY_FRAME_TYPE in line and REASON_INVALID in line for line in lines)
    # It is answered with nothing.
    assert app.sent == []
    assert not any(KEY.private_b64() in line for line in lines)
    for _phase, fields in recorder.lines:
        assert KEY.private_b64() not in json.dumps(fields)


def test_a_cloud_party_without_agent_mail_logs_the_key_frame_as_dropped():
    party, app, servers, lines = _party_with(None)
    app.provision()
    app.send(_frame(KEY))
    assert any(KEY_FRAME_TYPE in line and REASON_NOT_ENABLED in line for line in lines)
    # Not handed to the executor either.
    assert len(servers) == 1 and servers[0].submitted == []


def test_the_host_answers_not_enabled_without_a_mail_service(tmp_path):
    host = _host(tmp_path)
    try:
        assert host._on_mail_key_frame(_frame(KEY)) == "not_enabled"
    finally:
        host._roster.close()
        host._coworker_names.close()


# -- mail automations (docs/WIRE_CONTRACT.md, "Event triggers") ----------------


def test_claimed_mail_is_offered_to_the_mail_automations(tmp_path):
    api = _Api(
        [
            _row("t1", "owner"),
            _row("t2", "trusted"),
            _row("b1", "unknown", bulk=True),
            _row("u1", "unknown"),
        ]
    )
    runs = _Runs()
    offered: list[dict] = []

    def on_mail(view: dict) -> bool:
        offered.append(view)
        return view["id"] in ("t2", "b1", "u1")

    report = _service(tmp_path, api, runs, _Clock(), on_mail=on_mail).dispatch_once()
    assert sorted(v["id"] for v in offered) == ["b1", "t1", "t2", "u1"]
    by_id = {v["id"]: v for v in offered}
    # The HostView of a summary: an unknown sender shows sender and subject only.
    assert by_id["u1"]["subject"] == "subject u1" and by_id["u1"]["sender_trust"] == "unknown"
    assert "snippet" not in by_id["u1"] and "text" not in by_id["u1"]
    assert report.automations == 3
    # The taken trusted mail left the general run; the unknown one keeps its
    # restricted run; bulk still starts nothing of its own.
    full = [s for s in runs.submitted if s[2]["origin"] == "mail"]
    assert len(full) == 1 and full[0][2]["message_ids"] == ["t1"]
    restricted = [s for s in runs.submitted if s[2]["origin"] == "mail_untrusted"]
    assert [s[2]["message_id"] for s in restricted] == ["u1"]


def test_a_broken_mail_hook_loses_no_mail(tmp_path):
    api = _Api([_row("t1", "owner")])
    runs = _Runs()

    def on_mail(view: dict) -> bool:
        raise RuntimeError("boom")

    _service(tmp_path, api, runs, _Clock(), on_mail=on_mail).dispatch_once()
    assert len(runs.submitted) == 1 and runs.submitted[0][2]["message_ids"] == ["t1"]
