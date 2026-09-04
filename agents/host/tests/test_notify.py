"""The host's cloud notification (docs/WIRE_CONTRACT.md, P7): one row per run
with the user's own token, then the Edge Function; never the answer text;
one per run; refresh on 401; outbox when the cloud is away."""

from __future__ import annotations

import json

import httpx

from cowork_agent import StateStore, SupabaseSession

from cowork_host.desktop_notify import DesktopNotifier
from cowork_host.notify import SupabaseNotifier

SUPABASE = "https://proj.supabase.co"


class _Cloud:
    """A scripted Supabase: records every request, answers by path."""

    def __init__(self) -> None:
        self.requests: list[httpx.Request] = []
        self.reject_first_insert = False
        self.fail_insert = False
        self.duplicate_insert = False
        self._refreshed = False

    def handler(self, request: httpx.Request) -> httpx.Response:
        self.requests.append(request)
        path = request.url.path
        if path.endswith("/auth/v1/token"):
            self._refreshed = True
            return httpx.Response(200, json={"access_token": "fresh", "refresh_token": "r2", "expires_in": 3600})
        if path.endswith("/rest/v1/cowork_run_notifications"):
            if self.fail_insert:
                return httpx.Response(503, text="down")
            if self.reject_first_insert and request.headers.get("Authorization") == "Bearer stale":
                return httpx.Response(401, json={"message": "JWT expired"})
            if self.duplicate_insert:
                return httpx.Response(201, json=[])
            return httpx.Response(201, json=[{"id": "n-1"}])
        if path.endswith("/functions/v1/notify-run"):
            return httpx.Response(200, json={"sent": 1, "failed": 0})
        return httpx.Response(404)

    def bodies(self, suffix: str) -> list[dict]:
        out = []
        for r in self.requests:
            if r.url.path.endswith(suffix):
                data = json.loads(r.content.decode() or "null")
                out.extend(data if isinstance(data, list) else [data])
        return out


def _session(cloud: _Cloud, token: str = "good") -> SupabaseSession:
    client = httpx.Client(transport=httpx.MockTransport(cloud.handler))
    return SupabaseSession(
        access_token=token, refresh_token="r1", supabase_url=SUPABASE, anon_key="anon",
        http_client=client,
    )


def _notifier(tmp_path, cloud: _Cloud, session: SupabaseSession, *, desktop=None) -> SupabaseNotifier:
    return SupabaseNotifier(
        session_provider=lambda: session,
        user_id_provider=lambda: "user-1",
        agent_provider=lambda: ("agent-1", "Ada"),
        db_path=str(tmp_path / "state.db"),
        desktop=desktop,
        http_client=httpx.Client(transport=httpx.MockTransport(cloud.handler)),
        background=False,
        ntfy_topic="",
        webhook_url="",
    )


def _finished_run(tmp_path, run_id: str = "run-1") -> dict:
    store = StateStore(str(tmp_path / "state.db"))
    sid = store.route("thread-1")
    store.begin_run(run_id, sid, "thread-1", "count to 20 slowly")
    store.append_message(sid, "user", {"role": "user", "content": "count to 20 slowly"})
    store.finish_run(run_id, reason="finished", final_answer="the total is 210", iterations=3, tokens_spent=9)
    store.close()
    return {
        "run_id": run_id, "session_key": "thread-1", "prompt": "count to 20 slowly",
        "reason": "finished", "final_answer": "the total is 210", "error": None,
    }


def test_happy_path_inserts_a_row_then_calls_the_function_with_no_answer_text(tmp_path):
    cloud = _Cloud()
    session = _session(cloud)
    calls, runner = [], lambda argv: calls.append(list(argv))
    desktop = DesktopNotifier(runner=runner, enabled=True, system="Linux", which=lambda n: "/x", background=False)
    notifier = _notifier(tmp_path, cloud, session, desktop=desktop)

    assert notifier.notify_run_finished(_finished_run(tmp_path)) is True

    rows = cloud.bodies("/rest/v1/cowork_run_notifications")
    assert len(rows) == 1
    row = rows[0]
    assert row["user_id"] == "user-1" and row["run_id"] == "run-1"
    assert row["kind"] == "completed" and row["session_key"] == "thread-1"
    assert row["agent_name"] == "Ada"
    # Privacy: the answer and the prompt never leave the host.
    serialized = json.dumps(rows)
    assert "210" not in serialized and "count to 20" not in serialized
    # The user's own token, not a service key.
    insert = next(r for r in cloud.requests if r.url.path.endswith("cowork_run_notifications"))
    assert insert.headers["Authorization"] == "Bearer good" and insert.headers["apikey"] == "anon"
    assert "ignore-duplicates" in insert.headers["Prefer"]
    # Then the function, with the row id.
    assert cloud.bodies("/functions/v1/notify-run") == [{"notification_id": "n-1"}]
    # And the desktop toast, once.
    assert len(calls) == 1 and calls[0][0] == "notify-send"
    assert notifier.delivered == 1


def test_one_notification_per_run(tmp_path):
    cloud = _Cloud()
    notifier = _notifier(tmp_path, cloud, _session(cloud))
    summary = _finished_run(tmp_path)
    assert notifier.notify_run_finished(summary) is True
    assert notifier.notify_run_finished(summary) is False
    assert len(cloud.bodies("/rest/v1/cowork_run_notifications")) == 1
    assert notifier.dropped_duplicates == 1


def test_a_stale_token_is_refreshed_once_and_retried(tmp_path):
    cloud = _Cloud()
    cloud.reject_first_insert = True
    session = _session(cloud, token="stale")
    notifier = _notifier(tmp_path, cloud, session)
    assert notifier.notify_run_finished(_finished_run(tmp_path)) is True
    inserts = [r for r in cloud.requests if r.url.path.endswith("cowork_run_notifications")]
    assert [r.headers["Authorization"] for r in inserts] == ["Bearer stale", "Bearer fresh"]
    assert session.access_token == "fresh"
    assert notifier.delivered == 1


def test_a_failed_delivery_goes_to_the_outbox_and_flushes_later(tmp_path):
    cloud = _Cloud()
    cloud.fail_insert = True
    notifier = _notifier(tmp_path, cloud, _session(cloud))
    notifier.notify_run_finished(_finished_run(tmp_path))
    assert notifier.outbox_size == 1 and notifier.delivered == 0
    # The app re-provisions (fresh token) -> the outbox is retried.
    cloud.fail_insert = False
    notifier.flush_outbox()
    assert notifier.outbox_size == 0 and notifier.delivered == 1


def test_a_duplicate_row_skips_the_function(tmp_path):
    cloud = _Cloud()
    cloud.duplicate_insert = True
    notifier = _notifier(tmp_path, cloud, _session(cloud))
    notifier.notify_run_finished(_finished_run(tmp_path))
    assert cloud.bodies("/functions/v1/notify-run") == []
    assert notifier.dropped_duplicates == 1


def test_no_session_parks_the_record(tmp_path):
    cloud = _Cloud()
    notifier = SupabaseNotifier(
        session_provider=lambda: None,
        user_id_provider=lambda: "",
        agent_provider=lambda: ("a", "Ada"),
        db_path=str(tmp_path / "state.db"),
        http_client=httpx.Client(transport=httpx.MockTransport(cloud.handler)),
        background=False, ntfy_topic="", webhook_url="",
    )
    notifier.notify_run_finished(_finished_run(tmp_path))
    assert notifier.outbox_size == 1 and cloud.requests == []


def test_a_failed_run_notifies_as_failed(tmp_path):
    cloud = _Cloud()
    notifier = _notifier(tmp_path, cloud, _session(cloud))
    summary = _finished_run(tmp_path, "run-2")
    summary["reason"], summary["error"] = "failed", "loop failed: Boom"
    notifier.notify_run_finished(summary)
    row = cloud.bodies("/rest/v1/cowork_run_notifications")[0]
    assert row["kind"] == "failed" and "Boom" not in json.dumps(row)
