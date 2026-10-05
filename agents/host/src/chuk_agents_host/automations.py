"""Automations on the host: the clock, the watchers and the self-wake file.

docs/WIRE_CONTRACT.md, section "Automations". The agent side (spec grammar,
cron arithmetic, the tools) is ``chuk_agents_runtime.automations``; this module is
what needs a process that stays up:

- :class:`AutomationStore` — the ``automations`` table, in the executor's
  state SQLite file next to ``runs``. Persisted, so a host restart loses
  nothing.
- :class:`AutomationManager` — four jobs on three daemon threads:

  1. **Scheduler** (every ``tick`` seconds): fire every active schedule whose
     ``next_fire_at`` is due, then compute the next time.
  2. **Watcher supervisor**: one child process per active watcher, started
     with the sandbox's boundaries (a local process in the workspace, or
     ``docker exec`` in the agent's container), stdout/stderr appended to
     ``.agents/automations/<id>.log``, restarted on crash with backoff.
  3. **Trigger watchdog** (every ``poll`` seconds): tail
     ``.agents/automations/triggers.jsonl``, the file ``agents_hooks.trigger``
     appends to, and turn each line into a task of the watcher's session —
     at most one per watcher per ``rate_window`` seconds; the rest is folded.
  4. **URL checker** (every ``tick`` seconds): fetch each due ``watch_url``
     page (``url_watch.fetch_url``) and queue a fire when its text changed.

Event triggers (docs/WIRE_CONTRACT.md, "Event triggers"): a ``watch_url``
row fires on a changed page; a ``mail`` row fires when the mail dispatcher
offers a claimed mail that matches its filter (:meth:`AutomationManager.offer_mail`).
Both go through the same pending table as a watcher's report, so the rate
limit and the busy gate apply to them too.

"Notify only on change": a row with ``notify = on_change`` asks the fired run
to call ``automation_result(changed, summary)``. When the run ends the
executor calls :meth:`AutomationManager.finish_run`, which compares the digest
of the summary with the last one, stores the new one and says whether the run
counts as a change. No change = no toast, no push, and the app collapses the
run (``done.automation_result.changed == false``).

A fire is a normal task: the manager calls the ``fire`` callable the host
wired (``Executor.submit_task``) and gets a ``run_id`` back — or ``None``
when the host has restarted and no app has provisioned it yet. Nothing is
lost then: the schedule stays due and the trigger stays pending, and the
next tick tries again.

Every state change is one ``automation`` frame: persisted as an ``event``
row of the session (so a replay carries it, 266 pattern) and sent live to an
attached app through ``send``.

Secrets reach a watcher exactly as they reach ``run_python``: as environment
variables of the child, from the ``env_provider`` the secrets work owns. This
module never reads a value; for ``docker exec`` the names go on the command
line (``-e NAME``) and the values only into the client's environment.
"""

from __future__ import annotations

import contextlib
import json
import os
import secrets as _secrets
import shutil
import signal
import sqlite3
import subprocess
import threading
import time
from collections import deque
from collections.abc import Callable, Mapping
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from chuk_agents_runtime import StateStore
from chuk_agents_runtime.automations import (
    AUTOMATIONS_DIRNAME,
    KIND_MAIL,
    KIND_SCHEDULE,
    KIND_WATCH_URL,
    KIND_WATCHER,
    MAX_RESULT_SUMMARY_CHARS,
    NOTIFY_ALWAYS,
    NOTIFY_ON_CHANGE,
    STATE_ACTIVE,
    STATE_DONE,
    STATE_FAILED,
    STATE_PAUSED,
    TRIGGERS_FILENAME,
    AutomationSpecError,
    cap_payload,
    decide_changed,
    fired_prompt,
    mail_matches,
    next_fire,
    parse_mail_spec,
    parse_notify,
    parse_schedule_spec,
    parse_watch_url_spec,
    spec_label,
    summary_digest,
)
from chuk_agents_runtime import agents_hooks as _hooks_module

from . import url_watch

#: ``fire(session_key, prompt, meta) -> run_id | None``. ``meta`` carries
#: ``automation_id`` and ``name``. ``None`` = the host cannot run a task now.
FireFn = Callable[[str, str, dict], str | None]
#: ``send(payload)``: the live half of an ``automation`` frame. May drop.
SendFn = Callable[[dict], None]
#: The secrets env for a child process. ``None`` = no secrets on this host.
EnvProvider = Callable[[], Mapping[str, str]]
#: The sandbox environment the watchers must share boundaries with. Duck-typed:
#: a docker environment has ``container_id`` (and a ``_cli`` with a binary).
EnvironmentProvider = Callable[[], Any]
#: ``fetch(url, etag, last_modified) -> url_watch.FetchResult``; raises
#: ``url_watch.UrlWatchError``. Injected by tests.
UrlFetcher = Callable[[str, str | None, str | None], "url_watch.FetchResult"]

EVENT_CREATED = "created"
EVENT_FIRED = "fired"
EVENT_PAUSED = "paused"
EVENT_RESUMED = "resumed"
EVENT_CANCELLED = "cancelled"
EVENT_FAILED = "failed"
EVENT_DONE = "done"
#: The app changed name / prompt / spec / notify (``automation_update``).
EVENT_UPDATED = "updated"
#: An ``on_change`` run reported its result (``changed`` + ``summary``).
EVENT_RESULT = "result"

#: Mails one pending mail trigger collects before it fires.
MAX_PENDING_MAILS = 10
#: An ``automation_result`` that no run end picked up is dropped after this.
RESULT_TTL_SECONDS = 6 * 3600

#: Restart policy for a crashing watcher.
BACKOFF_MAX_SECONDS = 60.0
CRASH_WINDOW_SECONDS = 600.0
CRASH_LIMIT = 10

#: How long the host waits for a killed watcher before it gives up joining.
KILL_GRACE_SECONDS = 3.0

_SCHEMA = """
CREATE TABLE IF NOT EXISTS automations (
    id               TEXT PRIMARY KEY,
    session_key      TEXT NOT NULL,
    kind             TEXT NOT NULL,
    name             TEXT NOT NULL,
    spec             TEXT NOT NULL,
    prompt           TEXT NOT NULL DEFAULT '',
    state            TEXT NOT NULL,
    created_at       REAL NOT NULL,
    last_fired_at    REAL,
    next_fire_at     REAL,
    fire_count       INTEGER NOT NULL DEFAULT 0,
    suppressed_count INTEGER NOT NULL DEFAULT 0,
    last_error       TEXT
);
CREATE INDEX IF NOT EXISTS idx_automations_session ON automations(session_key, created_at);
CREATE TABLE IF NOT EXISTS automation_url_state (
    id TEXT PRIMARY KEY, state TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS automation_trigger_checkpoint (
    workspace TEXT PRIMARY KEY, offset INTEGER NOT NULL, pending TEXT NOT NULL
);
"""


#: Columns added after the first release, with their DDL. Added in place on
#: open; an old row reads as ``notify = always`` with no last result.
_ADDED_COLUMNS = (
    ("notify", "TEXT NOT NULL DEFAULT 'always'"),
    ("last_digest", "TEXT"),
    ("last_summary", "TEXT"),
    ("last_result_at", "REAL"),
    ("unchanged_count", "INTEGER NOT NULL DEFAULT 0"),
)


def _new_id() -> str:
    return _secrets.token_hex(4)


class AutomationStore:
    """The ``automations`` table. One short-lived connection per call, so any
    thread may use one instance; the file is shared with :class:`StateStore`
    (WAL), which is why this opens the same path and adds its own table."""

    def __init__(self, path: str) -> None:
        self._path = path
        with self._connect() as conn:
            conn.executescript(_SCHEMA)
            have = {row[1] for row in conn.execute("PRAGMA table_info(automations)")}
            for name, ddl in _ADDED_COLUMNS:
                if name not in have:
                    conn.execute(f"ALTER TABLE automations ADD COLUMN {name} {ddl}")

    def _connect(self):
        """A connection that is CLOSED on exit (a bare sqlite3 connection as a
        context manager only ends the transaction and keeps the file open)."""
        conn = sqlite3.connect(self._path, timeout=30.0, isolation_level=None)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA journal_mode=WAL")
        conn.execute("PRAGMA busy_timeout=30000")
        return contextlib.closing(conn)

    @staticmethod
    def _row(row: sqlite3.Row | None) -> dict | None:
        if row is None:
            return None
        out = dict(row)
        try:
            out["spec"] = json.loads(out["spec"])
        except (TypeError, ValueError):
            out["spec"] = {}
        return out

    def create(
        self,
        *,
        session_key: str,
        kind: str,
        name: str,
        spec: dict,
        prompt: str,
        next_fire_at: float | None,
        automation_id: str | None = None,
        notify: str = NOTIFY_ALWAYS,
    ) -> dict:
        row_id = automation_id or _new_id()
        with self._connect() as conn:
            conn.execute(
                "INSERT INTO automations(id, session_key, kind, name, spec, prompt, state, "
                "created_at, next_fire_at, notify) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (
                    row_id,
                    session_key,
                    kind,
                    name,
                    json.dumps(spec),
                    prompt or "",
                    STATE_ACTIVE,
                    time.time(),
                    next_fire_at,
                    notify,
                ),
            )
        return self.get(row_id)  # type: ignore[return-value]

    def get(self, automation_id: str) -> dict | None:
        with self._connect() as conn:
            row = conn.execute(
                "SELECT * FROM automations WHERE id=?", (automation_id,)
            ).fetchone()
        return self._row(row)

    def list(self, session_key: str | None = None, *, states: tuple[str, ...] | None = None) -> list[dict]:
        sql = "SELECT * FROM automations"
        where: list[str] = []
        args: list[Any] = []
        if session_key is not None:
            where.append("session_key=?")
            args.append(session_key)
        if states:
            where.append(f"state IN ({','.join('?' * len(states))})")
            args.extend(states)
        if where:
            sql += " WHERE " + " AND ".join(where)
        sql += " ORDER BY created_at, rowid"
        with self._connect() as conn:
            rows = conn.execute(sql, args).fetchall()
        return [self._row(r) for r in rows]  # type: ignore[misc]

    def due(self, now: float, kind: str = KIND_SCHEDULE) -> list[dict]:
        """Active rows of ``kind`` whose ``next_fire_at`` is due. For a
        ``watch_url`` row ``next_fire_at`` is the next check, not a fire."""
        with self._connect() as conn:
            rows = conn.execute(
                "SELECT * FROM automations WHERE kind=? AND state=? AND next_fire_at IS NOT NULL "
                "AND next_fire_at<=? ORDER BY next_fire_at, rowid",
                (kind, STATE_ACTIVE, now),
            ).fetchall()
        return [self._row(r) for r in rows]  # type: ignore[misc]

    def url_state(self, automation_id: str) -> dict:
        """What the last check of a ``watch_url`` row saw: ``hash``, ``etag``,
        ``last_modified``, ``checked_at``, ``changed_at`` and the ``snapshot``
        text the next diff starts from. Kept apart from the row, so a list
        never carries the page."""
        with self._connect() as conn:
            row = conn.execute(
                "SELECT state FROM automation_url_state WHERE id=?", (automation_id,)
            ).fetchone()
        if row is None:
            return {}
        try:
            data = json.loads(row["state"])
        except (TypeError, ValueError):
            return {}
        return data if isinstance(data, dict) else {}

    def set_url_state(self, automation_id: str, state: dict | None) -> None:
        with self._connect() as conn:
            if state is None:
                conn.execute("DELETE FROM automation_url_state WHERE id=?", (automation_id,))
            else:
                conn.execute(
                    "INSERT INTO automation_url_state(id, state) VALUES(?, ?) "
                    "ON CONFLICT(id) DO UPDATE SET state=excluded.state",
                    (automation_id, json.dumps(state)),
                )

    def update(self, automation_id: str, **fields: Any) -> dict | None:
        if not fields:
            return self.get(automation_id)
        if "spec" in fields:
            fields["spec"] = json.dumps(fields["spec"])
        assignments = ", ".join(f"{k}=?" for k in fields)
        with self._connect() as conn:
            conn.execute(
                f"UPDATE automations SET {assignments} WHERE id=?",
                (*fields.values(), automation_id),
            )
        return self.get(automation_id)

    def record_fire(
        self,
        automation_id: str,
        *,
        fired_at: float,
        next_fire_at: float | None,
        suppressed: int = 0,
        state: str | None = None,
    ) -> dict | None:
        with self._connect() as conn:
            conn.execute(
                "UPDATE automations SET last_fired_at=?, next_fire_at=?, "
                "fire_count=fire_count+1, suppressed_count=suppressed_count+?, "
                "last_error=NULL" + (", state=?" if state else "") + " WHERE id=?",
                (fired_at, next_fire_at, suppressed, *((state,) if state else ()), automation_id),
            )
        return self.get(automation_id)


def automation_fields(row: dict, *, log_path: str | None = None) -> dict:
    """The wire projection of a row (docs/WIRE_CONTRACT.md, ``automation``)."""
    out = {
        "id": row["id"],
        "session_key": row["session_key"],
        "kind": row["kind"],
        "name": row["name"],
        "spec": row.get("spec") or {},
        "prompt": row.get("prompt") or "",
        "state": row["state"],
        "fire_count": int(row.get("fire_count") or 0),
        "suppressed_count": int(row.get("suppressed_count") or 0),
        "created_at": row.get("created_at"),
        # Additive (docs/WIRE_CONTRACT.md, "Event triggers"): an older row
        # reads as ``always``.
        "notify": row.get("notify") or NOTIFY_ALWAYS,
    }
    for key in ("next_fire_at", "last_fired_at", "last_error", "last_summary", "last_result_at"):
        if row.get(key) is not None:
            out[key] = row[key]
    if row.get("unchanged_count"):
        out["unchanged_count"] = int(row["unchanged_count"])
    if log_path:
        out["log_path"] = log_path
    return out


@dataclass
class _Watcher:
    """One supervised child."""

    automation_id: str
    proc: subprocess.Popen | None = None
    log: Any = None
    script_path: str = ""
    # The process GROUP of the last child. The tracked process is not always
    # the monitor: a PEP 723 script runs under ``uv run --script``, so ``proc``
    # is uv and the script is its child. Reaping uv would leave the monitor
    # running, orphaned, still appending triggers for a row the host has
    # closed - and every one of those reports is then dropped.
    pgid: int | None = None
    crashes: deque = field(default_factory=lambda: deque(maxlen=CRASH_LIMIT + 1))
    restarts: int = 0
    restart_at: float | None = None
    docker_cid: str | None = None
    docker_prefix: list[str] | None = None


@dataclass
class _Pending:
    """A trigger held back by the rate limit: the last payload wins."""

    reason: str
    payload: Any
    folded: int = 0


class AutomationManager:
    """See the module docstring."""

    def __init__(
        self,
        *,
        db_path: str,
        workspace: str,
        fire: FireFn,
        busy: Callable[[str], bool] | None = None,
        send: SendFn | None = None,
        env_provider: EnvProvider | None = None,
        environment_provider: EnvironmentProvider | None = None,
        estop_path: str | None = None,
        logger: Callable[[str], None] | None = None,
        tick: float = 15.0,
        poll: float = 1.0,
        rate_window: float = 30.0,
        python: str = "python3",
        clock: Callable[[], float] = time.time,
        url_fetcher: UrlFetcher | None = None,
        network_allowed: Callable[[], bool] | None = None,
        allow_private_urls: bool = False,
    ) -> None:
        self._db_path = db_path
        self._workspace = Path(workspace).expanduser().resolve()
        self._fire = fire
        # True while that thread already has a run queued or in flight. A
        # watcher that reports every 60 s must not stack a run per report:
        # a 20-minute round would queue twenty of them and the newest numbers
        # would land behind a wall of stale ones.
        self._busy = busy or (lambda _key: False)
        self._send = send or (lambda _p: None)
        self._env_provider = env_provider
        self._environment_provider = environment_provider
        self._estop_path = estop_path
        self._log = logger or (lambda _m: None)
        self._tick = tick
        self._poll = poll
        self._rate_window = rate_window
        self._python = python
        self._now = clock
        self._allow_private_urls = allow_private_urls
        self._url_fetcher: UrlFetcher = url_fetcher or self._default_fetch
        # The coworker's ``network`` permission: off = no URL is fetched for it.
        self._network_allowed = network_allowed or (lambda: True)
        # ``run_id -> {automation_id, changed, summary, at}``: what an
        # ``on_change`` run reported through ``automation_result``, until the
        # executor ends the run (:meth:`finish_run`).
        self._results: dict[str, dict] = {}

        self.store = AutomationStore(db_path)
        self._dir = self._workspace / AUTOMATIONS_DIRNAME
        self._triggers_path = self._dir / TRIGGERS_FILENAME
        self._trigger_offset = 0
        self._checkpoint_cache = None
        self._pending: dict[str, _Pending] = {}
        self._watchers: dict[str, _Watcher] = {}
        # Trigger lines carry ``kind`` (default ``automation``). A second
        # consumer (the terminal work's background jobs, ``kind: job``) docks
        # here: one callable per kind, called with the whole record on the
        # watchdog thread. Unknown kinds are dropped.
        self._consumers: dict[str, Callable[[dict], None]] = {"automation": self._accept_trigger}
        self._unprovisioned_logged: set[str] = set()
        # Whether uv exists here (key: container id, "" for a local sandbox).
        self._uv_available: dict[str, bool] = {}
        self._lock = threading.RLock()
        self._stop = threading.Event()
        self._threads: list[threading.Thread] = []
        # Diagnostics for tests and the log.
        self.fired = 0

    # -- lifecycle ---------------------------------------------------------------

    def start(self) -> None:
        """Install the hook module, restart the persisted watchers, start the
        two threads. Idempotent."""
        if self._threads:
            return
        self._ensure_dir()
        self._stop.clear()
        # A durable cursor and pending outbox preserve callbacks across restart.
        # Only the first upgrade skips legacy lines with no delivery checkpoint.
        if not self._restore_triggers():
            try:
                self._trigger_offset = self._triggers_path.stat().st_size
            except OSError:
                self._trigger_offset = 0
            self._save_triggers()
        restarted = 0
        for row in self.store.list(states=(STATE_ACTIVE,)):
            if row["kind"] == KIND_WATCHER:
                self._spawn(row)
                restarted += 1
        if restarted:
            self._log(f"[automations] restarted {restarted} watcher(s)")
        for name, target in (
            ("scheduler", self._scheduler_loop),
            ("watchdog", self._watchdog_loop),
            ("urlwatch", self._url_loop),
        ):
            thread = threading.Thread(target=target, name=f"agents-automations-{name}", daemon=True)
            thread.start()
            self._threads.append(thread)

    def stop(self) -> None:
        """Stop the threads and every watcher child. The rows stay ``active``:
        the next host start brings the watchers back."""
        self._stop.set()
        for thread in self._threads:
            thread.join(timeout=max(self._poll, self._tick) + 1.0)
        self._threads = []
        with self._lock:
            watchers = list(self._watchers.values())
            self._watchers.clear()
        for watcher in watchers:
            self._kill(watcher)

    # -- the tool-facing API ---------------------------------------------------------

    def bound(self, session_key: str) -> "SessionAutomations":
        return SessionAutomations(self, session_key)

    def schedule(
        self,
        session_key: str,
        spec: dict | str,
        prompt: str,
        name: str | None,
        notify: str = NOTIFY_ALWAYS,
    ) -> dict:
        try:
            parsed = parse_schedule_spec(spec)
            notify = parse_notify(notify)
        except AutomationSpecError as exc:
            return {"ok": False, "error": str(exc)}
        now = self._now()
        when = next_fire(parsed, after=now)
        if when is None:
            return {"ok": False, "error": "that time is already in the past"}
        row = self.store.create(
            session_key=session_key,
            kind=KIND_SCHEDULE,
            name=name or spec_label(parsed),
            spec=parsed,
            prompt=prompt,
            next_fire_at=when,
            notify=notify,
        )
        self._emit(row, EVENT_CREATED)
        return {"ok": True, **automation_fields(row)}

    def watch_url(
        self,
        session_key: str,
        spec: dict,
        prompt: str,
        name: str | None,
        notify: str = NOTIFY_ALWAYS,
    ) -> dict:
        """A ``watch_url`` row. The first check runs at the next URL tick and
        only records the page; a later check with other text fires."""
        try:
            parsed = parse_watch_url_spec(spec.get("url"), spec.get("every"))
            notify = parse_notify(notify)
        except (AutomationSpecError, AttributeError) as exc:
            return {"ok": False, "error": str(exc)}
        if not isinstance(prompt, str) or not prompt.strip():
            return {"ok": False, "error": "prompt must not be empty"}
        row = self.store.create(
            session_key=session_key,
            kind=KIND_WATCH_URL,
            name=name or spec_label(parsed),
            spec=parsed,
            prompt=prompt.strip(),
            next_fire_at=self._now(),
            notify=notify,
        )
        self._emit(row, EVENT_CREATED)
        return {"ok": True, **automation_fields(row)}

    def watch_mail(
        self,
        session_key: str,
        spec: dict,
        prompt: str,
        name: str | None,
        notify: str = NOTIFY_ALWAYS,
    ) -> dict:
        """A ``mail`` row: fires for each claimed mail that matches."""
        try:
            parsed = parse_mail_spec(spec.get("from"), spec.get("subject"))
            notify = parse_notify(notify)
        except (AutomationSpecError, AttributeError) as exc:
            return {"ok": False, "error": str(exc)}
        if not isinstance(prompt, str) or not prompt.strip():
            return {"ok": False, "error": "prompt must not be empty"}
        row = self.store.create(
            session_key=session_key,
            kind=KIND_MAIL,
            name=name or spec_label(parsed),
            spec=parsed,
            prompt=prompt.strip(),
            next_fire_at=None,
            notify=notify,
        )
        self._emit(row, EVENT_CREATED)
        return {"ok": True, **automation_fields(row)}

    def create(self, payload: dict) -> dict:
        """The app's ``automation_create`` (docs/WIRE_CONTRACT.md, "Event
        triggers"). ``kind`` is ``schedule`` / ``watch_url`` / ``mail``; a
        watcher needs a script in the workspace and is the model's job."""
        session_key = payload.get("session_key")
        if not isinstance(session_key, str) or not session_key.strip():
            return {"ok": False, "error": "session_key is required"}
        kind = payload.get("kind")
        spec = payload.get("spec")
        prompt = payload.get("prompt")
        name = _clean_name(payload.get("name"))
        notify = payload.get("notify")
        if not isinstance(prompt, str) or not prompt.strip():
            return {"ok": False, "error": "prompt must not be empty"}
        if kind == KIND_SCHEDULE:
            if not isinstance(spec, (dict, str)):
                return {"ok": False, "error": "spec is required"}
            try:
                mode = parse_notify(notify)
            except AutomationSpecError as exc:
                return {"ok": False, "error": str(exc)}
            return self.schedule(session_key, spec, prompt.strip(), name, mode)
        if not isinstance(spec, dict):
            return {"ok": False, "error": "spec must be an object"}
        if kind == KIND_WATCH_URL:
            return self.watch_url(session_key, spec, prompt, name, notify)
        if kind == KIND_MAIL:
            return self.watch_mail(session_key, spec, prompt, name, notify)
        return {"ok": False, "error": f"cannot create an automation of kind {kind!r}"}

    def update(self, session_key: str | None, automation_id: str, changes: dict) -> dict:
        """Change ``name`` / ``prompt`` / ``notify`` / ``spec`` of one row
        (the app's ``automation_update``). ``session_key`` set = scoped like
        the tools. A new spec is validated for the row's kind; a schedule
        gets a new ``next_fire_at``, a URL watch a fresh baseline. Switching
        ``notify`` back to ``always`` forgets the last result."""
        row = self.store.get(automation_id)
        if row is None or (session_key is not None and row["session_key"] != session_key):
            return {"ok": False, "error": "not found"}
        if row["state"] in (STATE_DONE,):
            return {"ok": False, "error": "a cancelled automation cannot be changed"}
        fields: dict[str, Any] = {}
        reset_url = False
        try:
            if "name" in changes:
                name = _clean_name(changes.get("name"))
                fields["name"] = name or spec_label(row["spec"])
            if "prompt" in changes:
                prompt = changes.get("prompt")
                if not isinstance(prompt, str):
                    return {"ok": False, "error": "prompt must be text"}
                if not prompt.strip() and row["kind"] != KIND_WATCHER:
                    return {"ok": False, "error": "prompt must not be empty"}
                fields["prompt"] = prompt.strip()
            if "notify" in changes:
                fields["notify"] = parse_notify(changes.get("notify"))
                if fields["notify"] == NOTIFY_ALWAYS:
                    fields.update(last_digest=None, last_summary=None, last_result_at=None, unchanged_count=0)
            if "spec" in changes:
                spec = changes.get("spec")
                if row["kind"] == KIND_SCHEDULE:
                    parsed = parse_schedule_spec(spec)  # type: ignore[arg-type]
                    when = next_fire(parsed, after=self._now())
                    if when is None:
                        return {"ok": False, "error": "that time is already in the past"}
                    fields.update(spec=parsed, next_fire_at=when)
                elif row["kind"] == KIND_WATCH_URL and isinstance(spec, dict):
                    parsed = parse_watch_url_spec(spec.get("url"), spec.get("every"))
                    reset_url = parsed["url"] != row["spec"].get("url")
                    fields.update(spec=parsed, next_fire_at=self._now())
                elif row["kind"] == KIND_MAIL and isinstance(spec, dict):
                    fields["spec"] = parse_mail_spec(spec.get("from"), spec.get("subject"))
                else:
                    return {"ok": False, "error": f"the spec of a {row['kind']} cannot be changed here"}
        except AutomationSpecError as exc:
            return {"ok": False, "error": str(exc)}
        if not fields:
            return {"ok": False, "error": "nothing to change"}
        if row["state"] != STATE_ACTIVE and "next_fire_at" in fields:
            # A paused row gets its next time at resume.
            fields.pop("next_fire_at")
        if reset_url:
            self.store.set_url_state(row["id"], None)
        row = self.store.update(row["id"], **fields) or row
        self._emit(row, EVENT_UPDATED)
        return {"ok": True, **automation_fields(row)}

    def start_watcher(self, session_key: str, script_path: str, name: str | None, restart: bool) -> dict:
        rel = script_path.strip().lstrip("./")
        target = (self._workspace / rel).resolve()
        try:
            target.relative_to(self._workspace)
        except ValueError:
            return {"ok": False, "error": "script_path must stay inside the workspace"}
        if not target.is_file():
            return {"ok": False, "error": f"no such file in the workspace: {rel}"}
        spec = {"script_path": rel, "restart": bool(restart)}
        row = self.store.create(
            session_key=session_key,
            kind=KIND_WATCHER,
            name=name or spec_label(spec),
            spec=spec,
            prompt="",
            next_fire_at=None,
        )
        self._ensure_dir()
        started = self._spawn(row)
        if not started:
            row = self.store.get(row["id"]) or row
        self._emit(row, EVENT_CREATED if row["state"] == STATE_ACTIVE else EVENT_FAILED)
        return {"ok": row["state"] == STATE_ACTIVE, **automation_fields(row, log_path=self.log_path(row["id"]))}

    def list(self, session_key: str | None = None) -> list[dict]:
        rows = self.store.list(session_key)
        return [
            automation_fields(r, log_path=self.log_path(r["id"]) if r["kind"] == KIND_WATCHER else None)
            for r in rows
        ]

    def control(self, session_key: str | None, automation_id: str, action: str) -> dict:
        """Pause / resume / cancel. ``session_key`` set = the tools: an id of
        another session is "not found". ``None`` = the app (the user), which
        may manage every automation of this host."""
        row = self.store.get(automation_id)
        if row is None or (session_key is not None and row["session_key"] != session_key):
            return {"ok": False, "error": "not found"}
        if action == "pause":
            if row["state"] != STATE_ACTIVE:
                return {"ok": False, "error": f"cannot pause an automation that is {row['state']}"}
            self._stop_watcher(row["id"])
            row = self.store.update(row["id"], state=STATE_PAUSED) or row
            self._pending.pop(row["id"], None)
            self._emit(row, EVENT_PAUSED)
        elif action == "resume":
            if row["state"] != STATE_PAUSED:
                return {"ok": False, "error": f"cannot resume an automation that is {row['state']}"}
            fields: dict[str, Any] = {"state": STATE_ACTIVE, "last_error": None}
            if row["kind"] == KIND_SCHEDULE:
                now = self._now()
                if row.get("next_fire_at") is None or float(row["next_fire_at"]) <= now:
                    when = next_fire(row["spec"], after=now)
                    if when is None:
                        fields["state"] = STATE_DONE
                    fields["next_fire_at"] = when
            elif row["kind"] == KIND_WATCH_URL:
                now = self._now()
                if row.get("next_fire_at") is None or float(row["next_fire_at"]) <= now:
                    fields["next_fire_at"] = now
            row = self.store.update(row["id"], **fields) or row
            if row["kind"] == KIND_WATCHER and row["state"] == STATE_ACTIVE:
                self._spawn(row)
                row = self.store.get(row["id"]) or row
            self._emit(row, EVENT_RESUMED if row["state"] == STATE_ACTIVE else EVENT_DONE)
        elif action == "cancel":
            if row["state"] in (STATE_DONE,):
                return {"ok": False, "error": "already cancelled"}
            self._stop_watcher(row["id"])
            self._pending.pop(row["id"], None)
            row = self.store.update(row["id"], state=STATE_DONE, next_fire_at=None) or row
            if row["kind"] == KIND_WATCH_URL:
                # The page snapshot is the user's data; a cancelled watch keeps none.
                self.store.set_url_state(row["id"], None)
            self._emit(row, EVENT_CANCELLED)
        else:
            return {"ok": False, "error": f"unknown action {action!r}"}
        self._save_triggers()
        return {"ok": True, **automation_fields(row)}

    def register_trigger_consumer(self, kind: str, consumer: Callable[[dict], None]) -> None:
        """Route trigger lines of ``kind`` to ``consumer(record)``. The record
        is the parsed JSON line (``automation_id``, ``reason``, ``payload``,
        ``ts``, ``kind``). ``automation`` is this manager's own."""
        with self._lock:
            self._consumers[str(kind)] = consumer

    def log_path(self, automation_id: str) -> str:
        return f"{AUTOMATIONS_DIRNAME}/{automation_id}.log"

    def triggers_path(self) -> Path:
        return self._triggers_path

    # -- scheduler ------------------------------------------------------------------

    def _scheduler_loop(self) -> None:
        while not self._stop.wait(self._tick):
            try:
                self.run_scheduler_once()
            except Exception as exc:  # noqa: BLE001 — the clock must keep ticking
                self._log(f"[automations] scheduler: {type(exc).__name__}: {exc}")

    def run_scheduler_once(self) -> int:
        """Fire every due schedule. Returns how many fired. Exposed for tests."""
        if self._estop_engaged():
            return 0
        now = self._now()
        fired = 0
        for row in self.store.due(now):
            if self._fire_row(row, payload=None, reason=None):
                fired += 1
        return fired

    # -- watchdog: triggers + supervisor ----------------------------------------------

    def _watchdog_loop(self) -> None:
        while not self._stop.wait(self._poll):
            try:
                self.run_watchdog_once()
            except Exception as exc:  # noqa: BLE001 — never lose the tail
                self._log(f"[automations] watchdog: {type(exc).__name__}: {exc}")

    def run_watchdog_once(self) -> int:
        """One poll: read new trigger lines, fire what the rate limit allows,
        supervise the children. Returns how many tasks fired. Exposed for tests."""
        fired = 0
        self._consume_triggers()
        estop = self._estop_engaged()
        if not estop:
            fired += self._flush_pending()
        self._supervise(estop)
        return fired

    def _restore_triggers(self) -> bool:
        with self.store._connect() as conn:
            row = conn.execute('SELECT offset, pending FROM automation_trigger_checkpoint WHERE workspace=?',
                               (str(self._workspace),)).fetchone()
        if row is None:
            return False
        with self._lock:
            self._trigger_offset = row['offset']
            self._pending = {key: _Pending(**value) for key, value in json.loads(row['pending']).items()}
        return True

    def _save_triggers(self) -> None:
        with self._lock:
            pending = {key: {'reason': value.reason, 'payload': value.payload, 'folded': value.folded}
                       for key, value in self._pending.items()}
            snapshot = (self._trigger_offset, json.dumps(pending))
            if snapshot == self._checkpoint_cache:
                return
            with self.store._connect() as conn:
                conn.execute('INSERT INTO automation_trigger_checkpoint VALUES(?,?,?) '
                             'ON CONFLICT(workspace) DO UPDATE SET offset=excluded.offset, pending=excluded.pending',
                             (str(self._workspace), *snapshot))
            self._checkpoint_cache = snapshot

    def _consume_triggers(self) -> None:
        for record in self._read_new_triggers():
            kind = str(record.get("kind") or "automation")
            with self._lock:
                consumer = self._consumers.get(kind)
            if consumer is None:
                continue
            try:
                consumer(record)
            except Exception as exc:  # noqa: BLE001 — one consumer must not stall the tail
                self._log(f"[automations] trigger consumer {kind}: {type(exc).__name__}: {exc}")
        self._save_triggers()

    def _read_new_triggers(self) -> list[dict]:
        path = self._triggers_path
        try:
            size = path.stat().st_size
        except OSError:
            return []
        if size < self._trigger_offset:
            self._trigger_offset = 0  # truncated / replaced
        if size == self._trigger_offset:
            return []
        with path.open("rb") as handle:
            handle.seek(self._trigger_offset)
            chunk = handle.read(size - self._trigger_offset)
        # Only whole lines; a partial last line waits for its newline.
        cut = chunk.rfind(b"\n")
        if cut < 0:
            return []
        self._trigger_offset += cut + 1
        records: list[dict] = []
        for raw in chunk[: cut + 1].splitlines():
            raw = raw.strip()
            if not raw:
                continue
            try:
                record = json.loads(raw.decode("utf-8"))
            except (ValueError, UnicodeDecodeError):
                continue
            # An automation line names its watcher; another consumer's line
            # (``kind: job``) may name nothing of ours. Both pass; the
            # consumer for the kind decides.
            if isinstance(record, dict) and (
                isinstance(record.get("automation_id"), str) or record.get("kind")
            ):
                records.append(record)
        return records

    def _accept_trigger(self, record: dict) -> None:
        automation_id = record.get("automation_id")
        if not isinstance(automation_id, str):
            return
        row = self.store.get(automation_id)
        if row is None:
            self._log(f"[automations] report for unknown automation {automation_id}; dropped")
            return
        if row["kind"] != KIND_WATCHER or row["state"] != STATE_ACTIVE:
            # Never drop a report in silence. A watcher that keeps reporting
            # under a closed or paused row is exactly what "the automation does
            # not fire any more" looks like from outside: the script works, the
            # line is written, and nothing happens. Say so on the row.
            self._log(
                f"[automations] report from {automation_id} ignored: the row is "
                f"{row['state']}"
            )
            self.store.update(
                automation_id, last_error=f"a report arrived while this automation was {row['state']}"
            )
            return
        reason = str(record.get("reason") or "")[:500]
        payload = cap_payload(record.get("payload"))
        with self._lock:
            pending = self._pending.get(automation_id)
            if pending is None:
                self._pending[automation_id] = _Pending(reason=reason, payload=payload)
            else:
                pending.reason = reason
                pending.payload = payload
                pending.folded += 1

    def _flush_pending(self) -> int:
        now = self._now()
        fired = 0
        with self._lock:
            ready = list(self._pending.items())
        for automation_id, pending in ready:
            row = self.store.get(automation_id)
            if row is None or row["state"] != STATE_ACTIVE:
                with self._lock:
                    self._pending.pop(automation_id, None)
                continue
            last = float(row.get("last_fired_at") or 0.0)
            if now - last < self._rate_window:
                continue
            # The pending entry keeps absorbing newer triggers while the
            # thread is busy, so what finally fires is the latest state, once.
            try:
                if self._busy(row["session_key"]):
                    continue
            except Exception as exc:  # noqa: BLE001 — a broken probe must not stop the schedule
                self._log(f"[automations] busy probe failed: {type(exc).__name__}: {exc}")
            if self._fire_row(row, payload=pending.payload, reason=pending.reason, suppressed=pending.folded):
                fired += 1
                with self._lock:
                    if self._pending.get(automation_id) is pending:
                        self._pending.pop(automation_id, None)
        self._save_triggers()
        return fired

    def _fire_row(self, row: dict, *, payload: Any, reason: str | None, suppressed: int = 0) -> bool:
        automation_id = row["id"]
        notify = row.get("notify") or NOTIFY_ALWAYS
        prompt = fired_prompt(
            automation_id,
            row["name"],
            row.get("prompt"),
            payload,
            notify=notify,
            last_summary=row.get("last_summary") if notify == NOTIFY_ON_CHANGE else None,
        )
        meta = {"automation_id": automation_id, "name": row["name"], "kind": row["kind"], "reason": reason}
        try:
            run_id = self._fire(row["session_key"], prompt, meta)
        except Exception as exc:  # noqa: BLE001 — a broken host must not kill the schedule
            run_id = None
            self._log(f"[automations] fire {automation_id}: {type(exc).__name__}: {exc}")
        if not run_id:
            if automation_id not in self._unprovisioned_logged:
                self._log(f"[automations] {automation_id} is due but the host is not provisioned; will retry")
                self._unprovisioned_logged.add(automation_id)
            self.store.update(automation_id, last_error="host not provisioned")
            return False
        self._unprovisioned_logged.discard(automation_id)
        now = self._now()
        state: str | None = None
        when: float | None = None
        if row["kind"] == KIND_SCHEDULE:
            when = next_fire(row["spec"], after=now)
            if when is None:
                state = STATE_DONE
        elif row["kind"] == KIND_WATCH_URL:
            # ``next_fire_at`` of a URL watch is its next check; a fire
            # does not move it.
            current = self.store.get(automation_id) or row
            when = current.get("next_fire_at")
        updated = self.store.record_fire(
            automation_id, fired_at=now, next_fire_at=when, suppressed=suppressed, state=state
        ) or row
        self.fired += 1
        self._emit(updated, EVENT_FIRED, run_id=run_id, reason=reason)
        if state == STATE_DONE:
            self._emit(updated, EVENT_DONE)
        return True

    # -- event triggers: URL watch -----------------------------------------------------

    def _url_loop(self) -> None:
        while not self._stop.wait(self._tick):
            try:
                self.run_url_checks_once()
            except Exception as exc:  # noqa: BLE001 — the checker must keep running
                self._log(f"[automations] url checks: {type(exc).__name__}: {exc}")

    def _default_fetch(self, url: str, etag: str | None, last_modified: str | None) -> url_watch.FetchResult:
        return url_watch.fetch_url(
            url, etag=etag, last_modified=last_modified, allow_private=self._allow_private_urls
        )

    def run_url_checks_once(self) -> int:
        """Check every due ``watch_url`` row once. Returns how many changes
        were queued. Exposed for tests."""
        if self._estop_engaged():
            return 0
        now = self._now()
        changed = 0
        for row in self.store.due(now, KIND_WATCH_URL):
            if self._check_url(row):
                changed += 1
        if changed:
            self._save_triggers()
        return changed

    def _check_url(self, row: dict) -> bool:
        spec = row["spec"] or {}
        every = float(spec.get("every") or 3600)
        now = self._now()
        # The next check is set before the fetch: a page that hangs or a
        # crash in here cannot turn into a tight retry loop.
        self.store.update(row["id"], next_fire_at=now + every)
        try:
            allowed = bool(self._network_allowed())
        except Exception:  # noqa: BLE001 — a broken probe means "not allowed"
            allowed = False
        if not allowed:
            self.store.update(row["id"], last_error="network is off for this coworker; the page is not checked")
            return False
        state = self.store.url_state(row["id"])
        url = str(spec.get("url") or "")
        try:
            result = self._url_fetcher(url, state.get("etag"), state.get("last_modified"))
        except url_watch.UrlWatchError as exc:
            self.store.update(row["id"], last_error=f"check failed: {exc}")
            return False
        except Exception as exc:  # noqa: BLE001 — one bad page must not stop the rest
            self.store.update(row["id"], last_error=f"check failed: {type(exc).__name__}")
            return False
        state["checked_at"] = now
        if result.etag:
            state["etag"] = result.etag
        if result.last_modified:
            state["last_modified"] = result.last_modified
        if result.not_modified:
            self.store.set_url_state(row["id"], state)
            self._clear_check_error(row)
            return False
        digest = url_watch.content_hash(result.text)
        previous = state.get("hash")
        old_text = str(state.get("snapshot") or "")
        state["hash"] = digest
        state["snapshot"] = result.text[: url_watch.SNAPSHOT_CHARS]
        if previous == digest:
            self.store.set_url_state(row["id"], state)
            self._clear_check_error(row)
            return False
        state["changed_at"] = now
        self.store.set_url_state(row["id"], state)
        self._clear_check_error(row)
        if previous is None:
            # The first look is the baseline, not a change.
            self._log(f"[automations] url watch {row['id']}: baseline recorded")
            return False
        payload: dict[str, Any] = {
            "url": url,
            "status": result.status,
            "content_type": result.content_type,
            "diff": url_watch.text_diff(old_text, result.text),
            "excerpt": result.text[: url_watch.EXCERPT_CHARS],
        }
        if result.final_url and result.final_url != url:
            payload["final_url"] = result.final_url
        if result.truncated:
            payload["truncated"] = True
        self._log(f"[automations] url watch {row['id']}: the page changed")
        self._queue(row["id"], "page changed", payload)
        return True

    def _clear_check_error(self, row: dict) -> None:
        if str(row.get("last_error") or "").startswith(("check failed", "network is off")):
            self.store.update(row["id"], last_error=None)

    # -- event triggers: mail ----------------------------------------------------------

    def offer_mail(self, mail: dict) -> bool:
        """The mail dispatcher claimed ``mail`` (an opened summary in the
        HostView shape: ``id``, ``from_address``, ``subject``,
        ``sender_trust`` ...). Every active ``mail`` row whose filter matches
        queues a fire with it. Returns True when at least one row took it.
        Called on the mail thread."""
        if not isinstance(mail, dict):
            return False
        taken = False
        for row in self.store.list(states=(STATE_ACTIVE,)):
            if row["kind"] != KIND_MAIL or not mail_matches(row["spec"] or {}, mail):
                continue
            self._queue(row["id"], "mail", mail, collect=True)
            taken = True
        if taken:
            self._save_triggers()
        return taken

    def _queue(self, automation_id: str, reason: str, payload: Any, *, collect: bool = False) -> None:
        """Hold one fire for the pending table (rate limit + busy gate).
        ``collect`` keeps a list (``{"mails": [...]}``, newest last, capped)
        instead of letting the last payload win."""
        with self._lock:
            pending = self._pending.get(automation_id)
            if collect:
                mails = []
                if pending is not None and isinstance(pending.payload, dict):
                    mails = list(pending.payload.get("mails") or [])
                mails = (mails + [payload])[-MAX_PENDING_MAILS:]
                value: Any = {"mails": mails}
            else:
                value = cap_payload(payload)
            if pending is None:
                self._pending[automation_id] = _Pending(reason=reason, payload=value)
            else:
                pending.reason = reason
                pending.payload = value
                pending.folded += 1

    # -- "notify only on change" -------------------------------------------------------

    def wants_result(self, session_key: str, automation_id: str | None) -> bool:
        if not automation_id:
            return False
        row = self.store.get(automation_id)
        return bool(
            row is not None
            and row["session_key"] == session_key
            and (row.get("notify") or NOTIFY_ALWAYS) == NOTIFY_ON_CHANGE
        )

    def record_result(
        self, session_key: str, automation_id: str | None, run_id: str | None, changed: bool, summary: str
    ) -> dict:
        """What ``automation_result`` reports. Held until the run ends; the
        last call of a run wins."""
        if not run_id or not self.wants_result(session_key, automation_id):
            return {"ok": False, "error": "this run is not an on_change automation run"}
        now = self._now()
        with self._lock:
            for key in [k for k, v in self._results.items() if now - float(v.get("at") or 0) > RESULT_TTL_SECONDS]:
                self._results.pop(key, None)
            self._results[run_id] = {
                "automation_id": automation_id,
                "changed": bool(changed),
                "summary": " ".join(str(summary or "").split())[:MAX_RESULT_SUMMARY_CHARS],
                "at": now,
            }
        return {"ok": True, "recorded": True, "note": "the host decides at the end of the run whether the user is told"}

    def finish_run(self, run_id: str | None, automation_id: str | None, *, ok: bool = True) -> dict | None:
        """The run of an automation ended. For an ``on_change`` row: compare
        the reported summary's digest with the last one and store the new
        one. Returns ``{"changed": bool, "summary": str}`` (the run counts as
        a change or not) or ``None`` when the row is not ``on_change``.

        Fail-open: a failed run, or a run that never called
        ``automation_result``, is a change (the user is told as before), and
        the stored result stays as it was."""
        with self._lock:
            reported = self._results.pop(run_id, None) if run_id else None
        if not automation_id:
            return None
        row = self.store.get(automation_id)
        if row is None or (row.get("notify") or NOTIFY_ALWAYS) != NOTIFY_ON_CHANGE:
            return None
        if not ok or reported is None or reported.get("automation_id") != automation_id:
            outcome = {"changed": True, "reported": False}
            self._emit(row, EVENT_RESULT, run_id=run_id, extra=outcome)
            return outcome
        summary = str(reported.get("summary") or "")
        digest = summary_digest(summary)
        changed = decide_changed(bool(reported.get("changed")), digest, row.get("last_digest"))
        fields: dict[str, Any] = {
            "last_digest": digest,
            "last_summary": summary,
            "last_result_at": self._now(),
            "unchanged_count": 0 if changed else int(row.get("unchanged_count") or 0) + 1,
        }
        row = self.store.update(automation_id, **fields) or row
        outcome = {"changed": changed, "summary": summary, "reported": True}
        self._emit(row, EVENT_RESULT, run_id=run_id, extra=outcome)
        return outcome

    # -- watcher supervisor -----------------------------------------------------------

    def _supervise(self, estop: bool) -> None:
        with self._lock:
            watchers = list(self._watchers.values())
        for watcher in watchers:
            proc = watcher.proc
            if estop:
                if proc is not None and proc.poll() is None:
                    self._log(f"[automations] ESTOP: stopping watcher {watcher.automation_id}")
                    self._kill(watcher)
                continue
            if proc is not None and proc.poll() is None:
                continue
            row = self.store.get(watcher.automation_id)
            if row is None or row["state"] != STATE_ACTIVE:
                self._forget_watcher(watcher.automation_id)
                continue
            if proc is not None:
                code = proc.returncode
                # The handle is dead; nothing it started may outlive it.
                self._reap(watcher)
                if code == 0:
                    # The child may have appended its final trigger after this
                    # tick's initial read. Once exit is observed, drain those
                    # lines before deciding it is done. Keep the exited process
                    # registered until delivery succeeds; it must not restart
                    # or discard a final report held by throttling/provisioning.
                    self._consume_triggers()
                    with self._lock:
                        if watcher.automation_id in self._pending:
                            self._close_log(watcher)
                            continue
                watcher.proc = None
                self._close_log(watcher)
                if code == 0:
                    self.store.update(row["id"], state=STATE_DONE)
                    self._forget_watcher(row["id"])
                    self._emit(self.store.get(row["id"]) or row, EVENT_DONE)
                    continue
                if not row["spec"].get("restart", True):
                    self.store.update(row["id"], state=STATE_FAILED, last_error=f"exit code {code}")
                    self._forget_watcher(row["id"])
                    self._emit(self.store.get(row["id"]) or row, EVENT_FAILED)
                    continue
                now = self._now()
                watcher.crashes.append(now)
                recent = [t for t in watcher.crashes if now - t <= CRASH_WINDOW_SECONDS]
                if len(recent) > CRASH_LIMIT:
                    self.store.update(
                        row["id"],
                        state=STATE_FAILED,
                        last_error=f"crashed {len(recent)} times in {int(CRASH_WINDOW_SECONDS)} s (last exit {code})",
                    )
                    self._forget_watcher(row["id"])
                    self._emit(self.store.get(row["id"]) or row, EVENT_FAILED)
                    continue
                delay = min(BACKOFF_MAX_SECONDS, 2.0 ** watcher.restarts)
                watcher.restarts += 1
                watcher.restart_at = now + delay
                self.store.update(row["id"], last_error=f"exit code {code}; restart in {delay:g} s")
                self._log(f"[automations] watcher {row['id']} exited {code}; restart in {delay:g} s")
                continue
            # No process: either waiting for its restart time, or ESTOP just lifted.
            if watcher.restart_at is None or self._now() >= watcher.restart_at:
                watcher.restart_at = None
                self._launch(watcher, row)

    def _spawn(self, row: dict) -> bool:
        """Start (or restart) the child of an active watcher row."""
        with self._lock:
            watcher = self._watchers.get(row["id"])
            if watcher is not None and watcher.proc is not None and watcher.proc.poll() is None:
                return True
            if watcher is None:
                watcher = _Watcher(automation_id=row["id"])
                self._watchers[row["id"]] = watcher
        # A dead handle can still own a live tree (uv exits, the script does
        # not). Two children of one watcher fight over the same state, and the
        # one the host does not know about reports under a row nobody reads.
        self._reap(watcher)
        if self._estop_engaged():
            self._log(f"[automations] ESTOP engaged: watcher {row['id']} waits")
            return True
        return self._launch(watcher, row)

    def _launch(self, watcher: _Watcher, row: dict) -> bool:
        script = str(row["spec"].get("script_path") or "")
        watcher.script_path = script
        env_secrets: dict[str, str] = {}
        if self._env_provider is not None:
            try:
                env_secrets = {
                    str(k): str(v) for k, v in dict(self._env_provider()).items() if _env_name_ok(str(k))
                }
            except Exception as exc:  # noqa: BLE001 — no secrets is not "no watcher"
                self._log(f"[automations] secrets env unavailable: {type(exc).__name__}")
        child_env = {
            _hooks_module.ENV_AUTOMATION_ID: row["id"],
            _hooks_module.ENV_TRIGGERS_PATH: f"{AUTOMATIONS_DIRNAME}/{TRIGGERS_FILENAME}",
            "PYTHONUNBUFFERED": "1",
        }
        try:
            self._ensure_dir()
            log_file = self._workspace / self.log_path(row["id"])
            watcher.log = open(log_file, "ab", buffering=0)  # noqa: SIM115 — closed in _close_log
            stamp = time.strftime("%Y-%m-%d %H:%M:%S")
            watcher.log.write(f"--- [{stamp}] start {script}\n".encode())
            # PEP 723 monitors declare curl_cffi and other dependencies. uv
            # resolves its cached environment; bare scripts keep the old runner.
            with (self._workspace / script).open('rb') as source:
                has_metadata = b'# /// script' in source.read(8192)
            docker = self._docker_target()
            runner = self._runner(has_metadata, docker)
            if docker is not None:
                prefix, cid = docker
                watcher.docker_prefix, watcher.docker_cid = prefix, cid
                container_dir = f"/workspace/{AUTOMATIONS_DIRNAME}"
                child_env["PYTHONPATH"] = container_dir
                argv = [*prefix, "-w", "/workspace"]
                for name in (*child_env, *env_secrets):
                    argv += ["-e", name]  # the NAME only; the value rides the client env
                argv += [cid, *runner, script]
                popen_env = {**os.environ, **child_env, **env_secrets}
                cwd = None
            else:
                host_dir = str(self._dir)
                existing = os.environ.get("PYTHONPATH", "")
                child_env["PYTHONPATH"] = host_dir + (os.pathsep + existing if existing else "")
                argv = [*runner, script]
                popen_env = {**os.environ, **child_env, **env_secrets}
                cwd = str(self._workspace)
            watcher.proc = subprocess.Popen(
                argv,
                cwd=cwd,
                env=popen_env,
                stdin=subprocess.DEVNULL,
                stdout=watcher.log,
                stderr=subprocess.STDOUT,
                start_new_session=True,
            )
            # ``start_new_session=True`` makes the child its own group leader,
            # so its pid IS the group. Read it from the handle, not from
            # ``os.getpgid``: a script that exits at once is already gone by
            # the time the call is made, and the group would be forgotten with
            # its children still running.
            watcher.pgid = watcher.proc.pid
        except Exception as exc:  # noqa: BLE001 — a bad script must not take the host down
            self._close_log(watcher)
            self.store.update(row["id"], state=STATE_FAILED, last_error=f"cannot start: {type(exc).__name__}: {exc}")
            self._forget_watcher(row["id"])
            self._log(f"[automations] watcher {row['id']} cannot start: {type(exc).__name__}: {exc}")
            return False
        return True

    def _docker_target(self) -> tuple[list[str], str] | None:
        """``docker exec`` prefix + container id when the agent's sandbox is a
        container, else None (a local process)."""
        if self._environment_provider is None:
            return None
        try:
            env = self._environment_provider()
        except Exception:  # noqa: BLE001
            return None
        cli = getattr(env, "_cli", None)
        binary = getattr(cli, "binary", None)
        if binary is None or not hasattr(env, "container_id"):
            return None
        try:
            env.run_bash("true", internal=True)  # realize the container
        except Exception:  # noqa: BLE001
            return None
        cid = getattr(env, "container_id", None)
        if not cid:
            return None
        prefix = [binary, "exec"]
        user = getattr(env, "_user", None)
        if user:
            prefix += ["-u", str(user)]
        return prefix, str(cid)

    def _runner(self, has_metadata: bool, docker: tuple[list[str], str] | None) -> list[str]:
        """The argv prefix that starts a watcher script. ``uv run --script``
        resolves a PEP 723 header's dependencies, but only where uv exists: on
        a host (or in an image) without it every launch would exit non-zero and
        the watcher would crash-loop into ``failed`` instead of reporting. No
        uv, plain interpreter."""
        if not has_metadata:
            return [self._python]
        if self._have_uv(docker):
            return ["uv", "run", "--script"]
        self._log(f"[automations] uv is not available; running the script on {self._python}")
        return [self._python]

    def _have_uv(self, docker: tuple[list[str], str] | None) -> bool:
        """Whether uv can be run here. Probed once per sandbox."""
        key = docker[1] if docker is not None else ""
        with self._lock:
            known = self._uv_available.get(key)
        if known is not None:
            return known
        if docker is None:
            found = shutil.which("uv") is not None
        else:
            prefix, cid = docker
            try:
                found = (
                    subprocess.run(
                        [*prefix, cid, "sh", "-c", "command -v uv"],
                        check=False,
                        timeout=10,
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                    ).returncode
                    == 0
                )
            except Exception:  # noqa: BLE001 — no probe, no uv
                found = False
        with self._lock:
            self._uv_available[key] = found
        return found

    def _reap(self, watcher: _Watcher) -> None:
        """The tracked child has exited. Make sure nothing of that watcher is
        still running before the handle is dropped.

        ``proc`` is not always the monitor: a PEP 723 script runs under ``uv
        run --script``, so the tracked process is uv and the script is its
        child. When uv goes away first the monitor keeps running with no
        supervisor — it goes on appending trigger lines under an id whose row
        the host may already have closed, and every one of those reports is
        then dropped without a trace. One orphan is one silently dead
        automation."""
        pgid = watcher.pgid
        watcher.pgid = None
        if pgid is not None and pgid != os.getpgid(0):
            try:
                os.killpg(pgid, signal.SIGTERM)
            except (ProcessLookupError, PermissionError, OSError):
                pgid = None
            if pgid is not None:
                deadline = time.monotonic() + KILL_GRACE_SECONDS
                while time.monotonic() < deadline:
                    try:
                        os.killpg(pgid, 0)
                    except OSError:
                        break
                    time.sleep(0.05)
                else:
                    try:
                        os.killpg(pgid, signal.SIGKILL)
                    except OSError:
                        pass
        if watcher.docker_prefix and watcher.docker_cid and watcher.script_path:
            # The same story inside a container: the exec client is gone, the
            # tree it started is not.
            try:
                subprocess.run(
                    [*watcher.docker_prefix, watcher.docker_cid, "pkill", "-f", watcher.script_path],
                    check=False,
                    timeout=10,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
            except Exception:  # noqa: BLE001
                pass

    def _stop_watcher(self, automation_id: str) -> None:
        with self._lock:
            watcher = self._watchers.pop(automation_id, None)
        if watcher is not None:
            self._kill(watcher)

    def _forget_watcher(self, automation_id: str) -> None:
        with self._lock:
            watcher = self._watchers.pop(automation_id, None)
        if watcher is not None:
            self._close_log(watcher)

    def _kill(self, watcher: _Watcher) -> None:
        proc = watcher.proc
        watcher.proc = None
        if proc is not None and proc.poll() is None:
            try:
                os.killpg(os.getpgid(proc.pid), signal.SIGTERM)
            except (ProcessLookupError, PermissionError, OSError):
                proc.terminate()
            try:
                proc.wait(timeout=KILL_GRACE_SECONDS)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
                except (ProcessLookupError, PermissionError, OSError):
                    proc.kill()
                proc.wait(timeout=KILL_GRACE_SECONDS)
            if watcher.docker_prefix and watcher.docker_cid and watcher.script_path:
                # The exec client is dead; the tree inside the container is not.
                try:
                    subprocess.run(
                        [*watcher.docker_prefix, watcher.docker_cid, "pkill", "-f", watcher.script_path],
                        check=False,
                        timeout=10,
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                    )
                except Exception:  # noqa: BLE001
                    pass
        watcher.pgid = None
        self._close_log(watcher)

    @staticmethod
    def _close_log(watcher: _Watcher) -> None:
        log = watcher.log
        watcher.log = None
        if log is not None:
            try:
                log.close()
            except Exception:  # noqa: BLE001
                pass

    def running_watchers(self) -> list[str]:
        """Ids of watchers with a live child (diagnostics, tests)."""
        with self._lock:
            return [
                w.automation_id
                for w in self._watchers.values()
                if w.proc is not None and w.proc.poll() is None
            ]

    # -- events ----------------------------------------------------------------------

    def _emit(
        self,
        row: dict,
        event: str,
        *,
        run_id: str | None = None,
        reason: str | None = None,
        extra: dict | None = None,
    ) -> None:
        payload: dict[str, Any] = {
            "type": "automation",
            "event": event,
            **automation_fields(row, log_path=self.log_path(row["id"]) if row["kind"] == KIND_WATCHER else None),
            "at": self._now(),
        }
        if run_id:
            payload["run_id"] = run_id
        if reason:
            payload["reason"] = reason
        if extra:
            payload.update(extra)
        # Persist first (the row exists even if nobody listens), then stream.
        try:
            store = StateStore(self._db_path)
            try:
                store.append_event(store.route(row["session_key"]), payload)
            finally:
                store.close()
        except Exception as exc:  # noqa: BLE001 — best effort, like _record_run
            self._log(f"[automations] could not persist {event} for {row['id']}: {type(exc).__name__}")
        try:
            self._send(payload)
        except Exception as exc:  # noqa: BLE001 — a relay hiccup must not raise here
            self._log(f"[automations] could not send {event}: {type(exc).__name__}")

    # -- helpers ---------------------------------------------------------------------

    def _ensure_dir(self) -> None:
        self._dir.mkdir(parents=True, exist_ok=True)
        hook = self._dir / "agents_hooks.py"
        source = Path(_hooks_module.__file__)
        try:
            if not hook.exists() or hook.read_bytes() != source.read_bytes():
                shutil.copyfile(source, hook)
        except OSError as exc:
            self._log(f"[automations] cannot install agents_hooks.py: {exc}")

    def _estop_engaged(self) -> bool:
        if not self._estop_path:
            return False
        try:
            os.stat(self._estop_path)
        except FileNotFoundError:
            return False
        except OSError:
            return True
        return True


def _clean_name(name: Any) -> str | None:
    if not isinstance(name, str):
        return None
    cleaned = " ".join(name.split())[:80]
    return cleaned or None


def _env_name_ok(name: str) -> bool:
    return bool(name) and name.replace("_", "a").isalnum() and not name[0].isdigit() and " " not in name


class SessionAutomations:
    """The :class:`chuk_agents_runtime.automations.AutomationBackend` for ONE session.
    Every call carries the bound key; there is no way to name another."""

    def __init__(
        self,
        manager: AutomationManager,
        session_key: str,
        *,
        run_id: str | None = None,
        automation_id: str | None = None,
    ) -> None:
        self._manager = manager
        self._session_key = session_key
        self._run_id = run_id
        self._automation_id = automation_id

    @property
    def session_key(self) -> str:
        return self._session_key

    def for_run(self, run_id: str | None, automation_id: str | None) -> "SessionAutomations":
        """The same session, bound to one fired run: ``automation_result``
        reports for that run and that automation only."""
        return SessionAutomations(
            self._manager, self._session_key, run_id=run_id, automation_id=automation_id
        )

    def schedule(self, spec: dict, prompt: str, name: str | None, notify: str = NOTIFY_ALWAYS) -> dict:
        return self._manager.schedule(self._session_key, spec, prompt, name, notify)

    def watch_url(self, spec: dict, prompt: str, name: str | None, notify: str = NOTIFY_ALWAYS) -> dict:
        return self._manager.watch_url(self._session_key, spec, prompt, name, notify)

    def watch_mail(self, spec: dict, prompt: str, name: str | None, notify: str = NOTIFY_ALWAYS) -> dict:
        return self._manager.watch_mail(self._session_key, spec, prompt, name, notify)

    def wants_result(self) -> bool:
        return self._manager.wants_result(self._session_key, self._automation_id)

    def record_result(self, changed: bool, summary: str) -> dict:
        return self._manager.record_result(
            self._session_key, self._automation_id, self._run_id, changed, summary
        )

    def start_watcher(self, script_path: str, name: str | None, restart: bool) -> dict:
        return self._manager.start_watcher(self._session_key, script_path, name, restart)

    def list(self) -> list[dict]:
        return self._manager.list(self._session_key)

    def control(self, automation_id: str, action: str) -> dict:
        return self._manager.control(self._session_key, automation_id, action)


__all__ = [
    "AutomationManager",
    "AutomationStore",
    "SessionAutomations",
    "automation_fields",
    "EVENT_CREATED",
    "EVENT_FIRED",
    "EVENT_PAUSED",
    "EVENT_RESUMED",
    "EVENT_CANCELLED",
    "EVENT_FAILED",
    "EVENT_DONE",
    "EVENT_RESULT",
    "EVENT_UPDATED",
]
