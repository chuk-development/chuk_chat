"""Automations on the host: the clock, the watchers and the self-wake file.

docs/WIRE_CONTRACT.md, section "Automations". The agent side (spec grammar,
cron arithmetic, the tools) is ``cowork_agent.automations``; this module is
what needs a process that stays up:

- :class:`AutomationStore` — the ``automations`` table, in the executor's
  state SQLite file next to ``runs``. Persisted, so a host restart loses
  nothing.
- :class:`AutomationManager` — three jobs on two daemon threads:

  1. **Scheduler** (every ``tick`` seconds): fire every active schedule whose
     ``next_fire_at`` is due, then compute the next time.
  2. **Watcher supervisor**: one child process per active watcher, started
     with the sandbox's boundaries (a local process in the workspace, or
     ``docker exec`` in the agent's container), stdout/stderr appended to
     ``.cowork/automations/<id>.log``, restarted on crash with backoff.
  3. **Trigger watchdog** (every ``poll`` seconds): tail
     ``.cowork/automations/triggers.jsonl``, the file ``cowork_hooks.trigger``
     appends to, and turn each line into a task of the watcher's session —
     at most one per watcher per ``rate_window`` seconds; the rest is folded.

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

from cowork_agent import StateStore
from cowork_agent.automations import (
    AUTOMATIONS_DIRNAME,
    KIND_SCHEDULE,
    KIND_WATCHER,
    STATE_ACTIVE,
    STATE_DONE,
    STATE_FAILED,
    STATE_PAUSED,
    TRIGGERS_FILENAME,
    AutomationSpecError,
    cap_payload,
    fired_prompt,
    next_fire,
    parse_schedule_spec,
    spec_label,
)
from cowork_agent import cowork_hooks as _hooks_module

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

EVENT_CREATED = "created"
EVENT_FIRED = "fired"
EVENT_PAUSED = "paused"
EVENT_RESUMED = "resumed"
EVENT_CANCELLED = "cancelled"
EVENT_FAILED = "failed"
EVENT_DONE = "done"

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
CREATE TABLE IF NOT EXISTS automation_trigger_checkpoint (
    workspace TEXT PRIMARY KEY, offset INTEGER NOT NULL, pending TEXT NOT NULL
);
"""


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
    ) -> dict:
        row_id = automation_id or _new_id()
        with self._connect() as conn:
            conn.execute(
                "INSERT INTO automations(id, session_key, kind, name, spec, prompt, state, "
                "created_at, next_fire_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
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

    def due(self, now: float) -> list[dict]:
        with self._connect() as conn:
            rows = conn.execute(
                "SELECT * FROM automations WHERE kind=? AND state=? AND next_fire_at IS NOT NULL "
                "AND next_fire_at<=? ORDER BY next_fire_at, rowid",
                (KIND_SCHEDULE, STATE_ACTIVE, now),
            ).fetchall()
        return [self._row(r) for r in rows]  # type: ignore[misc]

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
    }
    for key in ("next_fire_at", "last_fired_at", "last_error"):
        if row.get(key) is not None:
            out[key] = row[key]
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
        for name, target in (("scheduler", self._scheduler_loop), ("watchdog", self._watchdog_loop)):
            thread = threading.Thread(target=target, name=f"cowork-automations-{name}", daemon=True)
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

    def schedule(self, session_key: str, spec: dict | str, prompt: str, name: str | None) -> dict:
        try:
            parsed = parse_schedule_spec(spec)
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
        )
        self._emit(row, EVENT_CREATED)
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
        prompt = fired_prompt(automation_id, row["name"], row.get("prompt"), payload)
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
        updated = self.store.record_fire(
            automation_id, fired_at=now, next_fire_at=when, suppressed=suppressed, state=state
        ) or row
        self.fired += 1
        self._emit(updated, EVENT_FIRED, run_id=run_id, reason=reason)
        if state == STATE_DONE:
            self._emit(updated, EVENT_DONE)
        return True

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

    def _emit(self, row: dict, event: str, *, run_id: str | None = None, reason: str | None = None) -> None:
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
        hook = self._dir / "cowork_hooks.py"
        source = Path(_hooks_module.__file__)
        try:
            if not hook.exists() or hook.read_bytes() != source.read_bytes():
                shutil.copyfile(source, hook)
        except OSError as exc:
            self._log(f"[automations] cannot install cowork_hooks.py: {exc}")

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


def _env_name_ok(name: str) -> bool:
    return bool(name) and name.replace("_", "a").isalnum() and not name[0].isdigit() and " " not in name


class SessionAutomations:
    """The :class:`cowork_agent.automations.AutomationBackend` for ONE session.
    Every call carries the bound key; there is no way to name another."""

    def __init__(self, manager: AutomationManager, session_key: str) -> None:
        self._manager = manager
        self._session_key = session_key

    @property
    def session_key(self) -> str:
        return self._session_key

    def schedule(self, spec: dict, prompt: str, name: str | None) -> dict:
        return self._manager.schedule(self._session_key, spec, prompt, name)

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
]
