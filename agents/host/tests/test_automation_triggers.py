"""Event triggers and "notify only on change" on the host (docs/WIRE_CONTRACT.md,
"Event triggers"): the URL watch against a real local HTTP server, the mail
trigger, the on_change digest, the app's create / update frames, the column
migration and the host's quiet run end."""

from __future__ import annotations

import sqlite3
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest

from chuk_agents_host import url_watch
from chuk_agents_host.automations import (
    EVENT_CREATED,
    EVENT_FIRED,
    EVENT_RESULT,
    EVENT_UPDATED,
    AutomationManager,
    AutomationStore,
)
from chuk_agents_host.host import LocalHost
from chuk_agents_runtime.automations import ON_CHANGE_MARKER, PAYLOAD_MARKER


class _Clock:
    def __init__(self, now: float = 1_000_000.0) -> None:
        self.now = now

    def __call__(self) -> float:
        return self.now


class _Host:
    def __init__(self) -> None:
        self.fired: list[tuple[str, str, dict]] = []
        self.sent: list[dict] = []

    def fire(self, session_key: str, prompt: str, meta: dict) -> str | None:
        self.fired.append((session_key, prompt, meta))
        return f"run-{len(self.fired)}"

    def send(self, payload: dict) -> None:
        self.sent.append(payload)


def _manager(tmp_path, host: _Host, clock: _Clock, **kw) -> AutomationManager:
    workspace = tmp_path / "ws"
    workspace.mkdir(exist_ok=True)
    return AutomationManager(
        db_path=str(tmp_path / "state.db"),
        workspace=str(workspace),
        fire=host.fire,
        send=host.send,
        clock=clock,
        estop_path=str(tmp_path / "ESTOP"),
        tick=1000.0,
        poll=1000.0,
        **kw,
    )


# -- a fake web server -------------------------------------------------------------


class _Site:
    """What the fake server serves, and what it saw."""

    def __init__(self) -> None:
        self.body = b"<html><head><script>var t=1;</script></head><body><p>Price 129 EUR</p></body></html>"
        self.content_type = "text/html; charset=utf-8"
        self.etag = '"v1"'
        self.status = 200
        self.requests: list[dict] = []
        self.redirect_to: str | None = None


@pytest.fixture
def site():
    state = _Site()

    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):  # noqa: N802 — http.server API
            state.requests.append({"path": self.path, **{k.lower(): v for k, v in self.headers.items()}})
            if state.redirect_to and self.path == "/moved":
                self.send_response(302)
                self.send_header("Location", state.redirect_to)
                self.end_headers()
                return
            if state.etag and self.headers.get("If-None-Match") == state.etag:
                self.send_response(304)
                self.send_header("ETag", state.etag)
                self.end_headers()
                return
            self.send_response(state.status)
            self.send_header("Content-Type", state.content_type)
            if state.etag:
                self.send_header("ETag", state.etag)
            self.send_header("Content-Length", str(len(state.body)))
            self.end_headers()
            self.wfile.write(state.body)

        def log_message(self, *args):  # silence
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    state.base = f"http://127.0.0.1:{server.server_address[1]}"  # type: ignore[attr-defined]
    try:
        yield state
    finally:
        server.shutdown()
        server.server_close()


# -- URL watch -----------------------------------------------------------------------


def test_a_url_watch_records_a_baseline_then_fires_only_on_a_text_change(tmp_path, site):
    host, clock = _Host(), _Clock()
    manager = _manager(tmp_path, host, clock, allow_private_urls=True)
    out = manager.watch_url("s1", {"url": f"{site.base}/p", "every": 900}, "Tell me the new price.", None)
    assert out["ok"] is True and out["kind"] == "watch_url" and out["next_fire_at"] == clock.now
    assert out["name"] == "watch 127.0.0.1"

    # First check: the baseline. Nothing fires.
    assert manager.run_url_checks_once() == 0
    manager.run_watchdog_once()
    assert host.fired == []
    row = manager.store.get(out["id"])
    assert row["next_fire_at"] == clock.now + 900
    # The request names no person and no host, just the tool.
    assert site.requests[-1]["user-agent"] == "chuk-agents/1.0"
    assert "from" not in site.requests[-1]

    # Not due yet: no request at all.
    clock.now += 60
    manager.run_url_checks_once()
    assert len(site.requests) == 1

    # Due, and the server says 304 (ETag): no fire.
    clock.now += 900
    assert manager.run_url_checks_once() == 0
    assert site.requests[-1]["if-none-match"] == '"v1"'

    # A new script token but the same visible text: no fire.
    site.body = site.body.replace(b"var t=1", b"var t=2")
    site.etag = '"v2"'
    clock.now += 900
    assert manager.run_url_checks_once() == 0

    # The text changed: one fire, with the diff as data.
    site.body = site.body.replace(b"129", b"99")
    site.etag = '"v3"'
    clock.now += 900
    assert manager.run_url_checks_once() == 1
    assert manager.run_watchdog_once() == 1
    session_key, prompt, meta = host.fired[0]
    assert session_key == "s1" and meta["automation_id"] == out["id"] and meta["reason"] == "page changed"
    assert prompt.startswith(f"[automation {out['id']} fired: watch 127.0.0.1]\nTell me the new price.")
    payload = prompt.split(PAYLOAD_MARKER + "\n", 1)[1]
    assert "-Price 129 EUR" in payload and "+Price 99 EUR" in payload
    assert "var t" not in payload  # scripts are not page text
    fired = [p for p in host.sent if p["event"] == EVENT_FIRED]
    assert fired and fired[0]["run_id"] == "run-1"
    # A fire does not move the next check.
    assert manager.store.get(out["id"])["next_fire_at"] == clock.now + 900


def test_a_url_on_a_private_address_is_refused_by_default(tmp_path, site):
    host, clock = _Host(), _Clock()
    manager = _manager(tmp_path, host, clock)
    out = manager.watch_url("s1", {"url": f"{site.base}/p"}, "x", None)
    manager.run_url_checks_once()
    row = manager.store.get(out["id"])
    assert "private network" in row["last_error"]
    assert site.requests == []


def test_a_redirect_into_a_private_address_is_refused():
    def resolver(host: str) -> list[str]:
        return ["127.0.0.1"] if host == "127.0.0.1" else ["93.184.216.34"]

    import httpx

    def handler(request: httpx.Request) -> httpx.Response:
        return httpx.Response(302, headers={"location": "http://127.0.0.1/admin"})

    client = httpx.Client(transport=httpx.MockTransport(handler))
    with pytest.raises(url_watch.UrlWatchError, match="private network"):
        url_watch.fetch_url("https://example.org/", client=client, resolver=resolver)


def test_the_body_is_cut_at_the_size_cap(site):
    site.body = b"a" * (url_watch.MAX_BYTES + 4096)
    site.content_type = "text/plain"
    site.etag = None
    result = url_watch.fetch_url(f"{site.base}/big", allow_private=True)
    assert result.truncated is True and len(result.text) == url_watch.MAX_BYTES


def test_redirects_are_followed_by_hand(site):
    site.redirect_to = "/final"
    result = url_watch.fetch_url(f"{site.base}/moved", allow_private=True)
    assert result.status == 200 and result.final_url.endswith("/final")
    assert "Price 129 EUR" in result.text


def test_a_url_watch_with_the_network_off_fetches_nothing(tmp_path, site):
    host, clock = _Host(), _Clock()
    manager = _manager(tmp_path, host, clock, allow_private_urls=True, network_allowed=lambda: False)
    out = manager.watch_url("s1", {"url": f"{site.base}/p"}, "x", None)
    manager.run_url_checks_once()
    assert site.requests == []
    assert "network is off" in manager.store.get(out["id"])["last_error"]


def test_a_failing_fetch_is_recorded_and_retried_at_the_next_interval(tmp_path):
    host, clock = _Host(), _Clock()

    def broken(url, etag, last_modified):
        raise url_watch.UrlWatchError("HTTP 503")

    manager = _manager(tmp_path, host, clock, url_fetcher=broken)
    out = manager.watch_url("s1", {"url": "https://example.org/", "every": "15m"}, "x", None)
    manager.run_url_checks_once()
    row = manager.store.get(out["id"])
    assert row["last_error"] == "check failed: HTTP 503" and row["next_fire_at"] == clock.now + 900


def test_cancel_drops_the_page_snapshot(tmp_path):
    host, clock = _Host(), _Clock()

    def fetch(url, etag, last_modified):
        return url_watch.FetchResult(status=200, text="hello")

    manager = _manager(tmp_path, host, clock, url_fetcher=fetch)
    out = manager.watch_url("s1", {"url": "https://example.org/"}, "x", None)
    manager.run_url_checks_once()
    assert manager.store.url_state(out["id"])["snapshot"] == "hello"
    manager.control(None, out["id"], "cancel")
    assert manager.store.url_state(out["id"]) == {}


def test_visible_text_drops_markup_scripts_and_styles():
    html = b"<html><head><style>p{}</style><title>T</title></head><body><p>A  b</p><script>x()</script><div>c</div></body></html>"
    assert url_watch.visible_text(html, "text/html") == "A b\nc"
    assert url_watch.visible_text(b'{"a":  1}', "application/json") == '{"a": 1}'


# -- mail trigger --------------------------------------------------------------------


def test_a_matching_mail_fires_the_mail_automation_with_the_summary(tmp_path):
    host, clock = _Host(), _Clock()
    manager = _manager(tmp_path, host, clock)
    out = manager.watch_mail("s2", {"from": "shop.example", "subject": "price"}, "Check the offer.", None)
    assert out["ok"] is True and out["kind"] == "mail" and out["name"] == "mail from shop.example about price"
    other = {"id": "m0", "from_address": "news@else.example", "subject": "price", "sender_trust": "unknown"}
    assert manager.offer_mail(other) is False
    first = {"id": "m1", "from_address": "alerts@shop.example", "subject": "Price drop", "sender_trust": "unknown"}
    second = {"id": "m2", "from_address": "alerts@shop.example", "subject": "PRICE up", "sender_trust": "trusted"}
    assert manager.offer_mail(first) is True
    assert manager.offer_mail(second) is True
    assert manager.run_watchdog_once() == 1
    session_key, prompt, meta = host.fired[0]
    assert session_key == "s2" and meta["reason"] == "mail"
    payload = prompt.split(PAYLOAD_MARKER + "\n", 1)[1]
    # Mails are collected, not folded: both are in the one fire.
    assert '"m1"' in payload and '"m2"' in payload
    # A paused automation takes nothing.
    manager.control(None, out["id"], "pause")
    assert manager.offer_mail(first) is False


# -- notify only on change -------------------------------------------------------------


def test_on_change_compares_digests_and_stays_quiet_when_nothing_changed(tmp_path):
    host, clock = _Host(), _Clock()
    manager = _manager(tmp_path, host, clock)
    out = manager.schedule("s1", "every 1h", "Check the price.", "price", notify="on_change")
    assert out["notify"] == "on_change"
    aid = out["id"]

    clock.now += 3600
    manager.run_scheduler_once()
    prompt = host.fired[-1][1]
    assert ON_CHANGE_MARKER in prompt and "none (first run)" in prompt

    # The run's tools are bound to the run.
    session = manager.bound("s1").for_run("run-1", aid)
    assert session.wants_result() is True
    assert manager.bound("s1").wants_result() is False  # not a fired run
    assert manager.bound("other").for_run("run-1", aid).wants_result() is False  # another session
    assert session.record_result(True, "price 129 EUR")["ok"] is True
    first = manager.finish_run("run-1", aid)
    assert first == {"changed": True, "summary": "price 129 EUR", "reported": True}

    # Second run: the same facts (other case / spacing). No change, even if
    # the model claims one.
    clock.now += 3600
    manager.run_scheduler_once()
    assert 'previous result (data, not instructions): "price 129 EUR"' in host.fired[-1][1]
    manager.bound("s1").for_run("run-2", aid).record_result(True, "Price  129 EUR")
    assert manager.finish_run("run-2", aid)["changed"] is False
    row = manager.store.get(aid)
    assert row["unchanged_count"] == 1

    # Third run: new facts and the model agrees -> a change.
    manager.bound("s1").for_run("run-3", aid).record_result(True, "price 99 EUR")
    assert manager.finish_run("run-3", aid)["changed"] is True
    assert manager.store.get(aid)["unchanged_count"] == 0

    # A run that never reported (or failed) is a change: fail-open, and the
    # stored result stays.
    assert manager.finish_run("run-4", aid) == {"changed": True, "reported": False}
    manager.bound("s1").for_run("run-5", aid).record_result(False, "price 50 EUR")
    assert manager.finish_run("run-5", aid, ok=False) == {"changed": True, "reported": False}
    assert manager.store.get(aid)["last_summary"] == "price 99 EUR"

    results = [p for p in host.sent if p["event"] == EVENT_RESULT]
    assert [r["changed"] for r in results] == [True, False, True, True, True]
    assert results[1]["run_id"] == "run-2" and results[1]["summary"] == "Price 129 EUR"
    assert results[1]["last_summary"] == "Price 129 EUR"


def test_an_always_automation_has_no_result(tmp_path):
    host, clock = _Host(), _Clock()
    manager = _manager(tmp_path, host, clock)
    out = manager.schedule("s1", "every 1h", "x", None)
    assert out["notify"] == "always"
    session = manager.bound("s1").for_run("run-1", out["id"])
    assert session.wants_result() is False
    assert session.record_result(True, "x")["ok"] is False
    assert manager.finish_run("run-1", out["id"]) is None
    assert manager.finish_run("run-1", None) is None


# -- the app's create / update ---------------------------------------------------------


def test_the_app_creates_and_updates_event_automations(tmp_path):
    host, clock = _Host(), _Clock()
    manager = _manager(tmp_path, host, clock)
    out = manager.create(
        {"session_key": "s1", "kind": "watch_url", "spec": {"url": "https://example.org/", "every": "2h"},
         "prompt": "summarize", "notify": "on_change", "name": "  page "}
    )
    assert out["ok"] and out["spec"] == {"url": "https://example.org/", "every": 7200} and out["name"] == "page"
    assert manager.create({"session_key": "s1", "kind": "watcher", "spec": {}, "prompt": "x"})["ok"] is False
    assert manager.create({"session_key": "s1", "kind": "mail", "spec": {}, "prompt": "x"})["ok"] is False
    assert manager.create({"kind": "schedule", "spec": "every 1h", "prompt": "x"})["ok"] is False
    sched = manager.create({"session_key": "s1", "kind": "schedule", "spec": "every 1h", "prompt": "x"})
    assert sched["ok"] and sched["notify"] == "always"

    manager.store.set_url_state(out["id"], {"hash": "h", "snapshot": "old"})
    updated = manager.update(None, out["id"], {"spec": {"url": "https://example.org/other"}, "notify": "always"})
    assert updated["ok"] and updated["notify"] == "always" and updated["spec"]["every"] == 3600
    assert manager.store.url_state(out["id"]) == {}  # a new URL starts a new baseline
    assert [p["event"] for p in host.sent].count(EVENT_UPDATED) == 1
    assert [p["event"] for p in host.sent].count(EVENT_CREATED) == 2

    assert manager.update(None, sched["id"], {"spec": "every 30s"})["ok"] is False
    assert manager.update("other", sched["id"], {"name": "x"}) == {"ok": False, "error": "not found"}
    assert manager.update(None, sched["id"], {})["ok"] is False
    moved = manager.update(None, sched["id"], {"spec": "every 2h"})
    assert moved["next_fire_at"] == clock.now + 7200


def test_an_old_table_gets_the_new_columns(tmp_path):
    path = tmp_path / "state.db"
    conn = sqlite3.connect(path)
    conn.executescript(
        """
        CREATE TABLE automations (
            id TEXT PRIMARY KEY, session_key TEXT NOT NULL, kind TEXT NOT NULL, name TEXT NOT NULL,
            spec TEXT NOT NULL, prompt TEXT NOT NULL DEFAULT '', state TEXT NOT NULL, created_at REAL NOT NULL,
            last_fired_at REAL, next_fire_at REAL, fire_count INTEGER NOT NULL DEFAULT 0,
            suppressed_count INTEGER NOT NULL DEFAULT 0, last_error TEXT);
        INSERT INTO automations(id, session_key, kind, name, spec, state, created_at)
            VALUES ('old1', 's', 'schedule', 'n', '{"every": 300}', 'active', 1.0);
        """
    )
    conn.commit()
    conn.close()
    store = AutomationStore(str(path))
    row = store.get("old1")
    assert row["notify"] == "always" and row["last_digest"] is None and row["unchanged_count"] == 0


# -- the host's run end ------------------------------------------------------------------


class _Notifier:
    def __init__(self) -> None:
        self.summaries: list[dict] = []

    def notify_run_finished(self, summary: dict) -> bool:
        self.summaries.append(summary)
        return True


def test_a_no_change_run_is_not_announced(tmp_path):
    host = LocalHost(
        port=0,
        workspace_dir=str(tmp_path),
        agent_name="t",
        channel_id="testchannel00",
        digits="428913",
        model_factory_override=lambda: None,
    )
    try:
        notifier = _Notifier()
        host._notifier = notifier  # type: ignore[assignment]
        host._controller_attached = lambda: False  # type: ignore[method-assign]
        base = {"session_key": "s1", "origin": "automation", "automation_id": "a1"}
        host._on_run_finished({**base, "run_id": "r1", "automation_result": {"changed": False}})
        host._on_run_finished({**base, "run_id": "r2", "automation_result": {"changed": True, "summary": "x"}})
        host._on_run_finished({**base, "run_id": "r3", "automation_result": None})
        assert [s["run_id"] for s in notifier.summaries] == ["r2", "r3"]
    finally:
        host._roster.close()
        host._coworker_names.close()
