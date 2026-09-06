"""Completion notifications from the host (docs/WIRE_CONTRACT.md, P7).

When a run ends and no app is attached, the user must be told another way.
This module is the host's outbound side of that:

1. the desktop channel (:class:`DesktopNotifier`) — same machine, no cloud;
2. the cloud channel — one row in ``cowork_run_notifications`` (owner-only RLS,
   written with the user's own token), then a call to the Edge Function
   ``notify-run`` which pushes to the user's registered devices (FCM).

Rules:

- The notification carries NO answer content. Title and body are generic;
  the answer stays in the store and reaches the app over the sealed channel.
  The names it does carry are the ones the user knows — the coworker they
  named, the automation they set up — never the roster's generated codename.
  :mod:`cowork_host.notification_text` owns that wording and its lookup.
- One notification per run. ``runs.notified_at`` is set first, once; a second
  caller sees ``False`` and stops. The table's unique key and the function's
  ``pushed_at`` check make a retry harmless.
- Never on the task worker. Delivery runs on one background thread, so a slow
  network can never delay the next task.
- Best-effort with an outbox. A failed delivery is kept (bounded) and retried
  when the app re-provisions (it just handed the host a fresh token).
- Optional keyless sinks (``COWORK_NTFY_TOPIC``, ``COWORK_WEBHOOK_URL``) for
  self-hosters without Firebase. Same generic text, same rules.
"""

from __future__ import annotations

import json
import os
import threading
from collections import deque
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from typing import Any

import httpx

from cowork_agent import StateStore, SupabaseSession

from .desktop_notify import DesktopNotifier, set_labels_provider
from .notification_text import RunLabels, approval_text, completion_text, resolve_labels

KIND_COMPLETED = "completed"
KIND_FAILED = "failed"
KIND_APPROVAL = "approval_needed"

#: A pending cloud delivery: the row to insert, as the REST API wants it.
Record = dict[str, Any]


class SupabaseNotifier:
    """Host → Supabase → push. See the module docstring."""

    TABLE = "cowork_run_notifications"
    FUNCTION = "notify-run"

    def __init__(
        self,
        *,
        session_provider: Callable[[], SupabaseSession | None],
        user_id_provider: Callable[[], str],
        agent_provider: Callable[[], tuple[str, str]],
        db_path: str,
        roster_path: str | None = None,
        desktop: DesktopNotifier | None = None,
        http_client: httpx.Client | None = None,
        logger: Callable[[str], None] | None = None,
        ntfy_topic: str | None = None,
        webhook_url: str | None = None,
        max_outbox: int = 50,
        background: bool = True,
        timeout: float = 8.0,
    ) -> None:
        self._session_provider = session_provider
        self._user_id_provider = user_id_provider
        self._agent_provider = agent_provider
        self._db_path = db_path
        # The coworker's name lives in ``roster.db``, next to the state file.
        self._roster_path = roster_path
        self._desktop = desktop
        self._http = http_client
        self._log = logger or (lambda _m: None)
        self._ntfy_topic = ntfy_topic if ntfy_topic is not None else os.environ.get("COWORK_NTFY_TOPIC")
        self._webhook_url = webhook_url if webhook_url is not None else os.environ.get("COWORK_WEBHOOK_URL")
        self._timeout = timeout
        self._outbox: deque[Record] = deque(maxlen=max_outbox)
        self._outbox_lock = threading.Lock()
        self._pool = ThreadPoolExecutor(max_workers=1, thread_name_prefix="cowork-notify") if background else None
        # Diagnostics, read by tests and logs.
        self.delivered = 0
        self.dropped_duplicates = 0
        # The host's own desktop-only path composes its text through
        # ``desktop_notify.completion_text``, which has no store to read; hand
        # it this notifier's lookup so it names the coworker, not the codename.
        set_labels_provider(self.labels)

    # -- entry points (called from the executor's hooks, via the host) -------

    def labels(self, summary: dict | None = None, *, session_key: str | None = None) -> RunLabels:
        """The names this notification should carry: the coworker whose thread
        the run belongs to and, for a fired automation, the automation's own
        name. Never the roster codename."""
        fields = summary if isinstance(summary, dict) else {}
        automation_id = fields.get("automation_id")
        return resolve_labels(
            db_path=self._db_path,
            roster_path=self._roster_path,
            automation_id=str(automation_id) if automation_id else None,
            session_key=str(fields.get("session_key") or session_key or "") or None,
        )

    def _agent_id(self) -> str:
        """The row's identity column. Its sibling ``agent_name`` carries the
        name the user chose, not the roster name that comes with the id: the
        row is what the push renders, and a codename in a push is noise."""
        agent_id, _codename = self._agent_provider()
        return agent_id

    def notify_run_finished(self, summary: dict) -> bool:
        """Tell the user a run ended. Returns True when this call owns the
        notification (first for the run), False when it was already sent."""
        run_id = str(summary.get("run_id") or "")
        if run_id and not self._mark_notified_once(run_id):
            self.dropped_duplicates += 1
            return False
        failed = bool(summary.get("error")) or str(summary.get("reason") or "") == "failed"
        labels = self.labels(summary)
        title, body = completion_text(labels, failed=failed)
        record = self._record(
            run_id=run_id,
            agent_id=self._agent_id(),
            agent_name=labels.coworker or "",
            session_key=str(summary.get("session_key") or "default"),
            kind=KIND_FAILED if failed else KIND_COMPLETED,
            title=title,
            body=body,
        )
        self._fire(title, body, record)
        return True

    def notify_approval_pending(self, info: dict, *, session_key: str = "default") -> None:
        """A run is blocked on a here.now publish approval nobody can see."""
        labels = self.labels(session_key=session_key)
        title, body = approval_text(labels)
        record = self._record(
            run_id=str(info.get("request_id") or info.get("approval_id") or ""),
            agent_id=self._agent_id(),
            agent_name=labels.coworker or "",
            session_key=session_key,
            kind=KIND_APPROVAL,
            title=title,
            body=body,
        )
        self._fire(title, body, record)

    def flush_outbox(self) -> None:
        """Retry what could not be delivered. Called when the app re-provisions
        (a fresh token) and on demand."""
        with self._outbox_lock:
            pending = list(self._outbox)
            self._outbox.clear()
        if not pending:
            return
        self._submit(lambda: [self._deliver_cloud(r, retry_on_fail=True) for r in pending])

    @property
    def outbox_size(self) -> int:
        with self._outbox_lock:
            return len(self._outbox)

    def close(self) -> None:
        set_labels_provider(None)
        if self._pool is not None:
            self._pool.shutdown(wait=False)

    # -- internals -------------------------------------------------------------

    def _mark_notified_once(self, run_id: str) -> bool:
        try:
            store = StateStore(self._db_path)
            try:
                return store.mark_run_notified(run_id)
            finally:
                store.close()
        except Exception:  # noqa: BLE001 — no store, no dedup; still notify once here
            return True

    @staticmethod
    def _record(**fields: Any) -> Record:
        # Only these columns. No prompt, no answer, no tool output — ever.
        return {
            "run_id": fields["run_id"],
            "agent_id": fields["agent_id"],
            "agent_name": fields["agent_name"],
            "session_key": fields["session_key"],
            "kind": fields["kind"],
            "title": fields["title"],
            "body": fields["body"],
        }

    def _fire(self, title: str, body: str, record: Record) -> None:
        def work() -> None:
            if self._desktop is not None:
                self._desktop.notify(title, body)
            self._deliver_cloud(record, retry_on_fail=True)
            self._deliver_sinks(title, body)

        self._submit(work)

    def _submit(self, fn: Callable[[], Any]) -> None:
        if self._pool is None:
            fn()
            return
        try:
            self._pool.submit(fn)
        except RuntimeError:  # pool shut down
            pass

    def _client(self) -> httpx.Client:
        return self._http or httpx.Client(timeout=self._timeout)

    def _headers(self, session: SupabaseSession) -> dict[str, str]:
        return {
            "apikey": session.anon_key,
            "Authorization": f"Bearer {session.access_token}",
            "Content-Type": "application/json",
        }

    def _deliver_cloud(self, record: Record, *, retry_on_fail: bool) -> bool:
        session = self._session_provider()
        user_id = self._user_id_provider()
        if session is None or not session.supabase_url or not user_id:
            self._park(record)
            return False
        row = {**record, "user_id": user_id}
        client = self._client()
        own_client = self._http is None
        try:
            try:
                inserted = self._insert_row(client, session, row)
            except _Unauthorized:
                try:
                    session.refresh()
                except Exception as exc:  # noqa: BLE001 — a refresh failure parks the record
                    self._log(f"notify: token refresh failed: {type(exc).__name__}")
                    self._park(record)
                    return False
                inserted = self._insert_row(client, session, row)
            if inserted is None:
                # Duplicate (unique key): already in the table, already pushed.
                self.dropped_duplicates += 1
                return True
            self._call_function(client, session, inserted)
            self.delivered += 1
            return True
        except Exception as exc:  # noqa: BLE001 — never let delivery raise
            self._log(f"notify: cloud delivery failed: {type(exc).__name__}: {exc}")
            if retry_on_fail:
                self._park(record)
            return False
        finally:
            if own_client:
                client.close()

    def _insert_row(self, client: httpx.Client, session: SupabaseSession, row: dict) -> str | None:
        """Insert the row. Returns its id, or None when the unique key says it
        was already there (the function has already been called for it)."""
        url = f"{session.supabase_url.rstrip('/')}/rest/v1/{self.TABLE}"
        headers = {
            **self._headers(session),
            "Prefer": "return=representation,resolution=ignore-duplicates",
        }
        resp = client.post(url, headers=headers, content=json.dumps([row]))
        if resp.status_code == 401:
            raise _Unauthorized()
        resp.raise_for_status()
        data = resp.json()
        if isinstance(data, list) and data and isinstance(data[0], dict):
            return str(data[0].get("id") or "") or None
        return None

    def _call_function(self, client: httpx.Client, session: SupabaseSession, notification_id: str) -> None:
        url = f"{session.supabase_url.rstrip('/')}/functions/v1/{self.FUNCTION}"
        resp = client.post(
            url,
            headers=self._headers(session),
            content=json.dumps({"notification_id": notification_id}),
        )
        if resp.status_code == 401:
            raise _Unauthorized()
        resp.raise_for_status()

    def _deliver_sinks(self, title: str, body: str) -> None:
        """Optional keyless channels. Same generic text, best-effort."""
        client = self._client()
        own_client = self._http is None
        try:
            if self._ntfy_topic:
                try:
                    client.post(
                        f"https://ntfy.sh/{self._ntfy_topic}",
                        headers={"Title": title},
                        content=body.encode(),
                    )
                except Exception:  # noqa: BLE001
                    pass
            if self._webhook_url:
                try:
                    client.post(
                        self._webhook_url,
                        headers={"Content-Type": "application/json"},
                        content=json.dumps({"title": title, "body": body}),
                    )
                except Exception:  # noqa: BLE001
                    pass
        finally:
            if own_client:
                client.close()

    def _park(self, record: Record) -> None:
        with self._outbox_lock:
            self._outbox.append(record)


class _Unauthorized(Exception):
    """The user token was rejected (401): refresh once and retry."""
