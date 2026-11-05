"""Inbound webhooks on the host (research H44; docs/WIRE_CONTRACT.md,
"Inbound webhooks"): the app makes the server webhook and then a ``webhook``
row with the server's row id; the server pushes ``webhook_event`` frames;
the scope, the signature and the filter decide; a burst is merged into one
fire."""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import uuid
from datetime import UTC, datetime

import pytest

from chuk_agents_host.automations import (
    EVENT_CREATED,
    EVENT_FIRED,
    AutomationManager,
)
from chuk_agents_host.cloud_relay import (
    DECISION_WEBHOOK,
    TYPE_WEBHOOK_EVENT,
    CloudRelayLink,
)
from chuk_agents_host.webhooks import (
    MAX_BODY_BYTES,
    REPLAY_TTL_SECONDS,
    decode_event,
    event_payload,
    verify_signature,
)
from chuk_agents_runtime.automations import PAYLOAD_MARKER

NOW = 1_762_300_000.0
RECEIVED = datetime.fromtimestamp(NOW, UTC).isoformat().replace("+00:00", "Z")


class _Clock:
    def __init__(self, now: float = NOW) -> None:
        self.now = now

    def __call__(self) -> float:
        return self.now


class _Host:
    def __init__(self) -> None:
        self.fired: list[tuple[str, str, dict]] = []
        self.sent: list[dict] = []
        self.busy = False

    def fire(self, session_key: str, prompt: str, meta: dict) -> str | None:
        self.fired.append((session_key, prompt, meta))
        return f"run-{len(self.fired)}"

    def send(self, payload: dict) -> None:
        self.sent.append(payload)


def _scope(agent_id, device_id):
    if device_id and device_id != "dev-1":
        return "other_device"
    if agent_id and agent_id not in ("host:me", "agent-2"):
        return "other_agent"
    return None


def _manager(tmp_path, host: _Host, clock: _Clock, **kw) -> AutomationManager:
    workspace = tmp_path / "ws"
    workspace.mkdir(exist_ok=True)
    return AutomationManager(
        db_path=str(tmp_path / "state.db"),
        workspace=str(workspace),
        fire=host.fire,
        send=host.send,
        busy=lambda _key: host.busy,
        clock=clock,
        estop_path=str(tmp_path / "ESTOP"),
        tick=1000.0,
        poll=1000.0,
        webhook_scope=_scope,
        **kw,
    )


@pytest.fixture
def env(tmp_path):
    host, clock = _Host(), _Clock()
    return _manager(tmp_path, host, clock), host, clock


def _create(manager: AutomationManager, webhook_id: str | None = None, **spec) -> dict:
    result = manager.create(
        {
            "type": "automation_create",
            "session_key": "s1",
            "kind": "webhook",
            "name": "GitHub",
            "prompt": "Review the new pull request.",
            "spec": {"webhook_id": webhook_id or str(uuid.uuid4()), **spec},
        }
    )
    assert result["ok"], result
    return result


def _frame(webhook_id: str, body: object = None, *, headers: dict | None = None, event_id: str | None = None,
           raw: bytes | None = None, received_at: str = RECEIVED, **extra) -> dict:
    if raw is None:
        raw = json.dumps(body if body is not None else {"action": "opened"}).encode()
    try:
        text, encoding = raw.decode("utf-8"), "utf8"
    except UnicodeDecodeError:
        text, encoding = base64.b64encode(raw).decode(), "base64"
    return {
        "type": TYPE_WEBHOOK_EVENT,
        "v": 1,
        "event_id": event_id or uuid.uuid4().hex,
        "webhook_id": webhook_id,
        "webhook_id_hash": "0" * 64,
        "agent_id": None,
        "device_id": None,
        "received_at": received_at,
        "method": "POST",
        "headers": {"content-type": "application/json", **(headers or {})},
        "body": text,
        "body_encoding": encoding,
        "body_size": len(raw),
        **extra,
    }


def _wid(row: dict) -> str:
    return row["spec"]["webhook_id"]


# -- create ------------------------------------------------------------------------


def test_create_takes_the_server_row_id(env):
    manager, host, _clock = env
    wid = str(uuid.uuid4())
    row = _create(manager, wid.upper(), filter={"path": "$.action", "equals": "opened"})
    assert _wid(row) == wid
    assert row["kind"] == "webhook" and row["name"] == "GitHub"
    assert "webhook_url" not in row  # the app keeps the secret URL
    assert row["spec"]["debounce_s"] == 10 and row["spec"]["max_wait_s"] == 300
    assert host.sent[-1]["event"] == EVENT_CREATED


def test_create_refuses_a_bad_id_and_a_second_row(env):
    manager, _host, _clock = env
    for bad in (None, "wh_" + "a" * 43, "not-a-uuid"):
        result = manager.create({"type": "automation_create", "session_key": "s1", "kind": "webhook",
                                 "prompt": "p", "spec": {"webhook_id": bad} if bad else {}})
        assert result["ok"] is False and "webhook_id" in result["error"]
    row = _create(manager)
    again = manager.create({"type": "automation_create", "session_key": "s1", "kind": "webhook",
                            "prompt": "p", "spec": {"webhook_id": _wid(row)}})
    assert again["ok"] is False
    manager.control(None, row["id"], "cancel")
    assert _create(manager, _wid(row))["ok"]  # a cancelled row frees the id


def test_the_signing_secret_never_goes_back_to_the_app(env):
    manager, host, _clock = env
    row = _create(manager, signing_secret="topsecret-123")
    assert "signing_secret" not in row["spec"] and row["spec"]["signed"] is True
    assert all("topsecret-123" not in json.dumps(p) for p in host.sent)
    assert all("topsecret-123" not in json.dumps(r) for r in manager.list())
    assert manager.store.get(row["id"])["spec"]["signing_secret"] == "topsecret-123"


def test_an_invalid_filter_is_refused_at_create(env):
    manager, _host, _clock = env
    result = manager.create(
        {"type": "automation_create", "session_key": "s1", "kind": "webhook", "prompt": "p",
         "spec": {"webhook_id": str(uuid.uuid4()), "filter": {"path": "$.a", "regex": "(a+)+"}}}
    )
    assert result["ok"] is False and "regex" in result["error"]
    assert manager.list() == []


def test_update_keeps_the_id_and_the_secret(env):
    manager, _host, _clock = env
    row = _create(manager, signing_secret="topsecret-123")
    result = manager.update(None, row["id"], {"spec": {"webhook_id": str(uuid.uuid4()), "debounce_s": 0,
                                                       "filter": {"path": "$.action", "equals": "closed"}}})
    assert result["ok"], result
    stored = manager.store.get(row["id"])["spec"]
    assert stored["webhook_id"] == _wid(row) and stored["signing_secret"] == "topsecret-123"
    assert stored["debounce_s"] == 0 and stored["filter"]["equals"] == "closed"
    manager.update(None, row["id"], {"spec": {"signing_secret": "", "filter": None}})
    stored = manager.store.get(row["id"])["spec"]
    assert "signing_secret" not in stored and "filter" not in stored
    assert manager.update(None, row["id"], {"spec": {"filter": {"path": "nope", "equals": 1}}})["ok"] is False


# -- offer_webhook --------------------------------------------------------------


def test_a_matching_event_fires_once_after_the_quiet_window(env):
    manager, host, clock = env
    row = _create(manager, filter={"path": "$.action", "equals": "opened"}, debounce_s=10)
    assert manager.offer_webhook(_frame(_wid(row), {"action": "opened", "number": 7})) == "queued"
    assert manager.run_watchdog_once() == 0  # still quiet-waiting
    clock.now += 10
    assert manager.run_watchdog_once() == 1
    session_key, prompt, meta = host.fired[0]
    assert session_key == "s1" and meta["kind"] == "webhook" and meta["reason"] == "webhook"
    head, _, tail = prompt.partition(PAYLOAD_MARKER)
    assert "Review the new pull request." in head
    assert "events arrived close together" not in head
    event = json.loads(tail.strip())["events"][0]
    assert event["body"] == {"action": "opened", "number": 7}
    assert event["headers"] == {"content-type": "application/json"}
    assert event["method"] == "POST" and event["received_at"] == NOW
    assert any(p["event"] == EVENT_FIRED for p in host.sent)


def test_a_filtered_event_does_not_fire(env):
    manager, host, clock = env
    row = _create(manager, filter={"path": "$.action", "equals": "opened"}, debounce_s=0)
    assert manager.offer_webhook(_frame(_wid(row), {"action": "closed"})) == "filtered"
    clock.now += 60
    assert manager.run_watchdog_once() == 0 and host.fired == []


def test_a_header_filter(env):
    manager, _host, _clock = env
    row = _create(manager, filter={"header": "x-github-event", "equals": "push"})
    assert manager.offer_webhook(_frame(_wid(row), headers={"X-GitHub-Event": "push"})) == "queued"
    assert manager.offer_webhook(_frame(_wid(row), headers={"x-github-event": "issues"})) == "filtered"


def test_unknown_id_duplicate_paused_version_and_bad_frames(env):
    manager, host, clock = env
    row = _create(manager, debounce_s=0)
    assert manager.offer_webhook(_frame(str(uuid.uuid4()))) == "unknown_webhook"
    frame = _frame(_wid(row))
    assert manager.offer_webhook(frame) == "queued"
    assert manager.offer_webhook(dict(frame)) == "duplicate"
    assert manager.offer_webhook(_frame(_wid(row), v=2)) == "unknown_version"
    assert manager.offer_webhook({k: v for k, v in _frame(_wid(row)).items() if k != "v"}) == "unknown_version"
    manager.control(None, row["id"], "pause")
    assert manager.offer_webhook(_frame(_wid(row))) == "paused"
    assert manager.offer_webhook({"type": TYPE_WEBHOOK_EVENT, "v": 1}) == "malformed"
    assert manager.offer_webhook(_frame("wh_" + "a" * 43)) == "malformed"
    assert manager.offer_webhook(_frame(_wid(row), raw=b"x" * (MAX_BODY_BYTES + 1))) == "too_large"
    clock.now += 60
    assert manager.run_watchdog_once() == 0 and host.fired == []


def test_agent_and_device_scope(env):
    manager, _host, _clock = env
    row = _create(manager)
    wid = _wid(row)
    assert manager.offer_webhook(_frame(wid, agent_id="someone-else")) == "other_agent"
    assert manager.offer_webhook(_frame(wid, device_id="dev-2")) == "other_device"
    assert manager.offer_webhook(_frame(wid, agent_id="agent-2", device_id="dev-1")) == "queued"
    assert manager.offer_webhook(_frame(wid, agent_id="host:me")) == "queued"


def test_a_body_that_is_not_json_matches_only_a_row_without_filter(env):
    manager, host, clock = env
    open_row = _create(manager, debounce_s=0)
    filtered = _create(manager, debounce_s=0, filter={"path": "$.action", "exists": True})
    assert manager.offer_webhook(_frame(_wid(open_row), raw=b"plain text")) == "queued"
    assert manager.offer_webhook(_frame(_wid(filtered), raw=b"plain text")) == "filtered"
    assert manager.offer_webhook(_frame(_wid(open_row), raw=b"\xff\xfe\x00bin")) == "queued"
    clock.now += 1
    manager.run_watchdog_once()
    payload = json.loads(host.fired[0][1].partition(PAYLOAD_MARKER)[2])
    assert payload["events"][0]["body_text"] == "plain text"
    assert payload["events"][1]["body_base64"] == base64.b64encode(b"\xff\xfe\x00bin").decode()


# -- burst merging --------------------------------------------------------------


def test_a_burst_is_merged_into_one_fire(env):
    manager, host, clock = env
    row = _create(manager, debounce_s=10)
    wid = _wid(row)
    for n in range(3):
        assert manager.offer_webhook(_frame(wid, {"n": n})) == "queued"
        clock.now += 8
        assert manager.run_watchdog_once() == 0
    clock.now += 2  # 10 s after the last event
    assert manager.run_watchdog_once() == 1
    head, _, tail = host.fired[0][1].partition(PAYLOAD_MARKER)
    assert "3 events arrived close together" in head and "2 earlier event(s) merged" in head
    assert [e["body"]["n"] for e in json.loads(tail)["events"]] == [0, 1, 2]
    assert manager.store.get(row["id"])["suppressed_count"] == 2


def test_max_wait_caps_a_steady_stream(env):
    manager, host, clock = env
    row = _create(manager, debounce_s=10, max_wait_s=30)
    start = clock.now
    fired_at = None
    while clock.now - start < 60:
        manager.offer_webhook(_frame(_wid(row), {"t": clock.now - start}))
        clock.now += 5
        if manager.run_watchdog_once():
            fired_at = clock.now - start
            break
    assert fired_at == 30
    assert len(host.fired) == 1


def test_merged_events_are_capped_and_the_newest_stay(env):
    manager, host, clock = env
    row = _create(manager, debounce_s=5)
    wid = _wid(row)
    for n in range(25):
        manager.offer_webhook(_frame(wid, {"n": n, "pad": "x" * 100}))
    clock.now += 5
    assert manager.run_watchdog_once() == 1
    head, _, tail = host.fired[0][1].partition(PAYLOAD_MARKER)
    assert "25 events arrived close together" in head
    events = json.loads(tail)["events"]
    assert len(events) == 20 and events[-1]["body"]["n"] == 24
    for n in range(10):
        manager.offer_webhook(_frame(wid, {"n": n, "pad": "y" * 6000}))
    clock.now += 60
    assert manager.run_watchdog_once() == 1
    tail = host.fired[1][1].partition(PAYLOAD_MARKER)[2]
    assert len(tail.encode()) <= 16 * 1024 + 2
    events = json.loads(tail)["events"]
    assert events[-1]["body"]["n"] == 9 and len(events) < 10


def test_the_busy_gate_holds_a_due_burst(env):
    manager, host, clock = env
    row = _create(manager, debounce_s=0)
    manager.offer_webhook(_frame(_wid(row)))
    host.busy = True
    clock.now += 5
    assert manager.run_watchdog_once() == 0
    host.busy = False
    assert manager.run_watchdog_once() == 1


def test_a_pending_burst_survives_a_restart(tmp_path):
    host, clock = _Host(), _Clock()
    manager = _manager(tmp_path, host, clock)
    row = _create(manager, debounce_s=30)
    manager.offer_webhook(_frame(_wid(row), {"a": 1}))
    again = _manager(tmp_path, host, clock)
    assert again._restore_triggers()
    clock.now += 29
    assert again.run_watchdog_once() == 0
    clock.now += 1
    assert again.run_watchdog_once() == 1


# -- signatures -------------------------------------------------------------------


def _hex(key: bytes, message: bytes) -> str:
    return hmac.new(key, message, hashlib.sha256).hexdigest()


def _event(raw: bytes, headers: dict):
    return decode_event(_frame(str(uuid.uuid4()), raw=raw, headers=headers))


RAW = b'{"action":"opened"}'
SECRET = "topsecret-123"


def test_github_style(env):
    manager, _host, _clock = env
    row = _create(manager, signing_secret=SECRET)
    good = _frame(_wid(row), raw=RAW, headers={"x-hub-signature-256": "sha256=" + _hex(SECRET.encode(), RAW)})
    assert manager.offer_webhook(good) == "queued"
    other = b'{"action":"closed"}'
    bare = _frame(_wid(row), raw=other, headers={"x-signature-256": _hex(SECRET.encode(), other)})
    assert manager.offer_webhook(bare) == "queued"
    wrong = _frame(_wid(row), raw=RAW, headers={"x-hub-signature-256": "sha256=" + _hex(b"other", RAW)})
    assert manager.offer_webhook(wrong) == "bad_signature"
    assert manager.offer_webhook(_frame(_wid(row), raw=RAW)) == "bad_signature"
    assert "signature" in manager.store.get(row["id"])["last_error"]


def test_stripe_style():
    stamp = int(NOW)
    sig = _hex(SECRET.encode(), f"{stamp}.".encode() + RAW)
    assert verify_signature(SECRET, _event(RAW, {"stripe-signature": f"t={stamp},v1=deadbeef,v1={sig}"}))
    stale = int(NOW) - 301
    old = _hex(SECRET.encode(), f"{stale}.".encode() + RAW)
    assert not verify_signature(SECRET, _event(RAW, {"stripe-signature": f"t={stale},v1={old}"}))
    assert not verify_signature("other-secret", _event(RAW, {"stripe-signature": f"t={stamp},v1={sig}"}))


@pytest.mark.parametrize("prefix", ["svix-", "webhook-"])
def test_svix_and_standard_webhooks(prefix):
    key = b"0123456789abcdef0123456789abcdef"
    secret = "whsec_" + base64.b64encode(key).decode()
    stamp = str(int(NOW))
    sig = base64.b64encode(hmac.new(key, f"msg_1.{stamp}.".encode() + RAW, hashlib.sha256).digest()).decode()
    headers = {prefix + "id": "msg_1", prefix + "timestamp": stamp, prefix + "signature": f"v1,bad v1,{sig}"}
    assert verify_signature(secret, _event(RAW, headers))
    assert not verify_signature("whsec_" + base64.b64encode(b"x" * 32).decode(), _event(RAW, headers))
    assert not verify_signature(secret, _event(RAW, {**headers, prefix + "timestamp": str(int(NOW) - 400)}))
    assert not verify_signature(secret, _event(RAW, {**headers, prefix + "id": ""}))


def test_slack_style():
    stamp = str(int(NOW))
    sig = "v0=" + _hex(SECRET.encode(), f"v0:{stamp}:".encode() + RAW)
    headers = {"x-slack-signature": sig, "x-slack-request-timestamp": stamp}
    assert verify_signature(SECRET, _event(RAW, headers))
    assert not verify_signature(SECRET, _event(RAW, {**headers, "x-slack-signature": "v0=00"}))


def test_gitlab_token():
    assert verify_signature(SECRET, _event(RAW, {"x-gitlab-token": SECRET}))
    assert not verify_signature(SECRET, _event(RAW, {"x-gitlab-token": "nope"}))
    assert not verify_signature(SECRET, _event(RAW, {}))


def test_signature_and_token_headers_do_not_reach_the_model(env):
    manager, host, clock = env
    row = _create(manager, signing_secret=SECRET, debounce_s=0)
    manager.offer_webhook(_frame(_wid(row), raw=RAW, headers={"x-gitlab-token": SECRET, "x-gitlab-event": "Push Hook"}))
    clock.now += 1
    manager.run_watchdog_once()
    prompt = host.fired[0][1]
    assert "x-gitlab-token" not in prompt and SECRET not in prompt
    assert "Push Hook" in prompt


def test_decode_event_reads_base64_and_caps_headers():
    raw = bytes(range(256))
    frame = _frame(str(uuid.uuid4()), raw=raw, headers={f"x-github-h{i}": "v" * 2000 for i in range(40)})
    event = decode_event(frame)
    assert event.raw == raw
    assert len(event.headers) == 32 and all(len(v) <= 1024 for v in event.headers.values())


# -- the relay frame ---------------------------------------------------------------


class _Ws:
    def __init__(self) -> None:
        self.sent: list[dict] = []

    def send(self, raw: str) -> None:
        self.sent.append(json.loads(raw))

    def close(self) -> None:
        pass


class _Recorder:
    enabled = True

    def __init__(self) -> None:
        self.lines: list[tuple[str, dict]] = []

    def emit(self, phase: str, **fields) -> None:
        self.lines.append((phase, fields))


def test_the_relay_frame_reaches_the_automations_and_is_ledgered(env):
    from chuk_agents_runtime.telemetry import set_tracer

    manager, _host, _clock = env
    row = _create(manager)
    logged: list[str] = []
    link = CloudRelayLink(_Ws(), logger=logged.append, on_webhook=manager.offer_webhook)
    recorder = _Recorder()
    previous = set_tracer(recorder)
    try:
        frame = _frame(_wid(row), event_id="a" * 32)
        assert link.handle_frame({**frame, "req_id": "r1"}) == []
        assert link.handle_frame({**frame, "req_id": "r2"}) == []  # duplicate
        assert link.handle_frame({**_frame(str(uuid.uuid4())), "req_id": "r3"}) == []
        assert link.handle_frame({**_frame(_wid(row), v=9), "req_id": "r4"}) == []
    finally:
        set_tracer(previous)
    acted = [f for phase, f in recorder.lines if phase == "relay_frame_in"]
    assert acted == [
        {
            "frame_type": TYPE_WEBHOOK_EVENT,
            "decision": DECISION_WEBHOOK,
            "outcome": "queued",
            "req_id": "r1",
            "webhook_id": _wid(row),
            "event_id": "a" * 32,
        }
    ]
    assert any("reason=duplicate" in line and "req_id=r2" in line for line in logged)
    assert any("reason=unknown_webhook" in line and "req_id=r3" in line for line in logged)
    assert any("reason=unknown_version" in line and "req_id=r4" in line for line in logged)
    # The body is the caller's data: never in a log line.
    assert not any("opened" in line for line in logged)


def test_a_host_without_webhooks_drops_the_frame_as_not_enabled():
    logged: list[str] = []
    link = CloudRelayLink(_Ws(), logger=logged.append)
    assert link.handle_frame(_frame(str(uuid.uuid4()))) == []
    assert any("webhook_event" in line and "reason=not_enabled" in line for line in logged)


def test_a_webhook_event_inside_a_sealed_envelope_is_not_a_webhook():
    """Only the top-level control frame counts; a party message of that type
    goes up to the party like any other payload, not to the automations."""
    seen: list[dict] = []
    link = CloudRelayLink(_Ws(), on_webhook=lambda f: seen.append(f) or "queued")
    inner = _frame(str(uuid.uuid4()))
    out = link.handle_frame({"type": "cowork_relay", "payload": json.dumps(inner)})
    assert seen == [] and out and out[0]["type"] == TYPE_WEBHOOK_EVENT


def test_a_huge_frame_is_dropped_before_parsing():
    logged: list[str] = []
    seen: list[dict] = []
    link = CloudRelayLink(_Ws(), logger=logged.append, on_webhook=lambda f: seen.append(f) or "queued")
    frame = _frame(str(uuid.uuid4()))
    frame["body"] = "x" * (400 * 1024 + 1)
    link.handle_frame(frame)
    assert seen == []
    assert any("reason=too_large" in line for line in logged)


def test_too_large_from_the_manager_is_ledgered(env):
    manager, _host, _clock = env
    row = _create(manager)
    logged: list[str] = []
    link = CloudRelayLink(_Ws(), logger=logged.append, on_webhook=manager.offer_webhook)
    link.handle_frame(_frame(_wid(row), raw=b"x" * (MAX_BODY_BYTES + 1)))
    assert any("reason=too_large" in line for line in logged)


def test_the_host_scope_uses_its_relay_id_and_its_agents():
    from types import SimpleNamespace

    from chuk_agents_host.host import LocalHost

    fake = SimpleNamespace(
        _relay_device_id="dev-1",
        _primary_agent_ids=lambda: ("", "default", "row-1", "host:dev-x"),
        _is_own_coworker=lambda agent_id: agent_id == "agent-2",
    )
    scope = LocalHost._webhook_scope
    assert scope(fake, None, None) is None
    assert scope(fake, "host:dev-x", "dev-1") is None
    assert scope(fake, "agent-2", None) is None
    assert scope(fake, "agent-9", None) == "other_agent"
    assert scope(fake, None, "dev-2") == "other_device"


# -- security review 3cb9aa01: L1-L5 ------------------------------------------------


def _svix_headers(prefix: str, key: bytes, msg_id: str, stamp: str, raw: bytes = RAW) -> dict:
    sig = base64.b64encode(hmac.new(key, f"{msg_id}.{stamp}.".encode() + raw, hashlib.sha256).digest()).decode()
    return {prefix + "id": msg_id, prefix + "timestamp": stamp, prefix + "signature": f"v1,{sig}"}


@pytest.mark.parametrize("prefix", ["svix-", "webhook-"])
def test_a_replayed_svix_call_is_refused(env, prefix):
    """L1: an attacker who captured one signed call POSTs it again. The
    server gives it a new event_id; the signed sender id gives it away."""
    manager, _host, clock = env
    key = b"0123456789abcdef0123456789abcdef"
    row = _create(manager, signing_secret="whsec_" + base64.b64encode(key).decode())
    headers = _svix_headers(prefix, key, "msg_1", str(int(NOW)))
    assert manager.offer_webhook(_frame(_wid(row), raw=RAW, headers=headers)) == "queued"
    assert manager.offer_webhook(_frame(_wid(row), raw=RAW, headers=headers)) == "replay"
    other = _svix_headers(prefix, key, "msg_2", str(int(NOW)))
    assert manager.offer_webhook(_frame(_wid(row), raw=RAW, headers=other)) == "queued"


def test_a_replayed_github_call_is_refused_even_with_a_new_delivery_id(env):
    """L1: x-github-delivery is not signed; the body MAC is. A replay with a
    fresh delivery header is still caught; a real redelivery too."""
    manager, _host, clock = env
    row = _create(manager, signing_secret=SECRET)
    sig = "sha256=" + _hex(SECRET.encode(), RAW)
    first = {"x-hub-signature-256": sig, "x-github-delivery": "d-1"}
    assert manager.offer_webhook(_frame(_wid(row), raw=RAW, headers=first)) == "queued"
    assert manager.offer_webhook(_frame(_wid(row), raw=RAW, headers=first)) == "replay"
    assert manager.offer_webhook(_frame(_wid(row), raw=RAW, headers={**first, "x-github-delivery": "d-2"})) == "replay"
    # After the TTL the window is over.
    clock.now += REPLAY_TTL_SECONDS + 1
    later = _frame(_wid(row), raw=RAW, headers=first, received_at=datetime.fromtimestamp(clock.now, UTC).isoformat())
    assert manager.offer_webhook(later) == "queued"


def test_a_replayed_stripe_event_is_refused(env):
    """L1: Stripe retries keep the event id; a replay with a new t= and a
    re-made signature cannot happen without the secret, but the same event
    id twice is refused."""
    manager, _host, _clock = env
    row = _create(manager, signing_secret=SECRET)
    raw = b'{"id":"evt_1","type":"invoice.paid"}'

    def headers(stamp: int) -> dict:
        return {"stripe-signature": f"t={stamp},v1=" + _hex(SECRET.encode(), f"{stamp}.".encode() + raw)}

    assert manager.offer_webhook(_frame(_wid(row), raw=raw, headers=headers(int(NOW)))) == "queued"
    assert manager.offer_webhook(_frame(_wid(row), raw=raw, headers=headers(int(NOW) - 10))) == "replay"


def test_replay_ids_are_per_webhook(env):
    manager, _host, _clock = env
    a = _create(manager, signing_secret=SECRET)
    b = _create(manager, signing_secret=SECRET)
    headers = {"x-hub-signature-256": "sha256=" + _hex(SECRET.encode(), RAW)}
    assert manager.offer_webhook(_frame(_wid(a), raw=RAW, headers=headers)) == "queued"
    assert manager.offer_webhook(_frame(_wid(b), raw=RAW, headers=headers)) == "queued"


@pytest.mark.parametrize(
    "headers",
    [
        {"x-hub-signature-256": "sha256=\u00e9" + "0" * 63},
        {"x-signature-256": "\u00fc\u00fc"},
        {"stripe-signature": f"t={int(NOW)},v1=\u00e9\u00e9"},
        {"stripe-signature": "t=\u00b2\u00b2,v1=00"},
        {"stripe-signature": "t=\u0661\u0662,v1=00"},
        {"svix-id": "m", "svix-timestamp": str(int(NOW)), "svix-signature": "v1,\u00e9"},
        {"x-slack-signature": "v0=\u00e9", "x-slack-request-timestamp": str(int(NOW))},
        {"x-gitlab-token": "\u00e9\ud800"},
    ],
)
def test_a_non_ascii_signature_header_is_a_bad_signature(env, headers):
    """L2: compare_digest on a non-ASCII str raised TypeError; now bytes."""
    assert not verify_signature(SECRET, _event(RAW, headers))
    manager, _host, _clock = env
    row = _create(manager, signing_secret=SECRET)
    assert manager.offer_webhook(_frame(_wid(row), raw=RAW, headers=headers)) == "bad_signature"


def test_only_allowlisted_headers_reach_the_payload():
    """L3: an allowlist, not a denylist: auth headers with other names stay out."""
    event = _event(
        RAW,
        {
            "authorization": "Bearer abc",
            "cookie": "session=abc",
            "x-api-key": "k-123",
            "proxy-authorization": "Basic x",
            "x-amz-security-credential": "c",
            "x-github-event": "pull_request",
            "user-agent": "GitHub-Hookshot/1",
            "x-hub-signature-256": "sha256=00",
            "stripe-signature": "t=1,v1=00",
        },
    )
    headers = event_payload(event)["headers"]
    assert set(headers) == {"content-type", "x-github-event", "user-agent"}


def test_a_bad_signature_does_not_burn_the_event_id(env):
    """L5: a forged frame that reuses a real event id (or an id the server
    will hand out) must not make the real delivery a duplicate."""
    manager, _host, _clock = env
    row = _create(manager, signing_secret=SECRET)
    forged = _frame(_wid(row), raw=RAW, event_id="evt-shared", headers={"x-hub-signature-256": "sha256=" + "0" * 64})
    assert manager.offer_webhook(forged) == "bad_signature"
    good = _frame(
        _wid(row), raw=RAW, event_id="evt-shared", headers={"x-hub-signature-256": "sha256=" + _hex(SECRET.encode(), RAW)}
    )
    assert manager.offer_webhook(good) == "queued"
    assert manager.offer_webhook(dict(good)) == "duplicate"


def test_a_paused_row_does_not_burn_the_event_id(env):
    manager, _host, _clock = env
    row = _create(manager)
    frame = _frame(_wid(row), event_id="evt-p")
    manager.control(None, row["id"], "pause")
    assert manager.offer_webhook(frame) == "paused"
    manager.control(None, row["id"], "resume")
    assert manager.offer_webhook(dict(frame)) == "queued"
