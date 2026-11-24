"""The proactive agent on the host (CHAT-182, docs/agents/PROACTIVE.md).

The pure rules (settings, quiet hours, the nudge ledger, prompts, tools) are
in :mod:`chuk_agents_runtime.proactive`. This module is the part that needs a
process that stays up:

- :class:`ProactiveManager` — one daemon thread. Each tick it

  1. sends the pushes that waited for the end of the quiet hours,
  2. fires each due **heartbeat** row of an idle chat, after a zero-token
     pre-check (nothing changed = no model call),
  3. fires each due **morning brief** row (and first writes yesterday's
     journal with ``daily_summary``, zero tokens).

  :meth:`ProactiveManager.filter_run` is the gate the host calls before it
  announces the end of an unattended run: a silent heartbeat, a repeated
  topic or a nudge over the daily cap is not pushed, and a push inside the
  quiet hours is queued.

- :class:`SessionProactive` — the tools' backend for one chat.

The heartbeat and the brief are rows of the ``automations`` table (kinds
``heartbeat`` and ``morning_brief``) with ``notify = on_change``. So the app
lists them, the user can pause or cancel them there, the run gets the
``automation_result`` tool, and a "no change" run is collapsed in the app
and not pushed, all through the existing automation path. The automation
scheduler fires only ``schedule`` rows; these two kinds are fired here.
"""

from __future__ import annotations

import hashlib
import json
import threading
import time
from collections.abc import Callable
from datetime import date, datetime, timedelta
from pathlib import Path
from typing import Any

from chuk_agents_runtime import StateStore
from chuk_agents_runtime.automations import (
    CREATED_BY_USER,
    KIND_MAIL,
    KIND_WATCH_URL,
    KIND_WATCHER,
    KIND_WEBHOOK,
    NOTIFY_ON_CHANGE,
    STATE_ACTIVE,
    STATE_PAUSED,
    owner_session_key,
)
from chuk_agents_runtime.proactive import (
    HEARTBEAT_NAME,
    KIND_HEARTBEAT,
    KIND_MORNING_BRIEF,
    MORNING_BRIEF_NAME,
    NudgeLedger,
    ProactiveSettings,
    ProactiveSettingsError,
    checklist_path,
    heartbeat_prompt,
    in_quiet_hours,
    is_silent_answer,
    morning_brief_prompt,
    next_brief_at,
    quiet_ends_at,
    read_checklist,
    settings_zone,
    write_checklist,
)

#: ``fire(session_key, prompt, meta) -> run_id | None`` (the automation fire).
FireFn = Callable[[str, str, dict], str | None]
#: ``deliver(summary)``: announce a run that waited for the quiet hours.
DeliverFn = Callable[[dict], Any]
#: An extra pre-check source: ``provider(session_key) -> {name: fingerprint}``.
SignalProvider = Callable[[str], dict[str, str]]
#: ``writer(day, tz_name)``: writes that day's journal; returns the file or
#: ``None``. ``tz_name`` is the user's IANA zone (``"UTC"`` when none is set).
JournalWriter = Callable[[date, str], Path | None]

STATE_FILENAME = ".agents/proactive.json"
#: At most this many queued pushes go out when the quiet hours end; older
#: ones are dropped (the runs stay in the chat).
MAX_QUEUE_DELIVER = 3
MAX_QUEUE = 50
#: A brief that is this late (host away) waits for the next day.
BRIEF_CATCH_UP_SECONDS = 2 * 3600
#: How long a fired run id is remembered for :meth:`filter_run`.
RUN_MEMORY_SECONDS = 6 * 3600
#: Queued summary fields (the notifier needs no more).
_QUEUE_KEYS = (
    "run_id",
    "session_key",
    "final_answer",
    "reason",
    "error",
    "origin",
    "automation_id",
    "started_at",
    "finished_at",
)

_EVENT_TRIGGER_KINDS = (KIND_WATCHER, KIND_WATCH_URL, KIND_MAIL, KIND_WEBHOOK)


def _digest(value: Any) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, default=str).encode()).hexdigest()[:16]


class ProactiveManager:
    """See the module docstring."""

    def __init__(
        self,
        *,
        automations: Any,
        workspace: str,
        db_path: str,
        fire: FireFn,
        busy: Callable[[str], bool] | None = None,
        deliver: DeliverFn | None = None,
        logger: Callable[[str], None] | None = None,
        clock: Callable[[], float] = time.time,
        tick: float = 60.0,
        signal_providers: list[SignalProvider] | None = None,
        journal_writer: JournalWriter | None = None,
    ) -> None:
        self._automations = automations
        self._workspace = Path(workspace).expanduser()
        self._db_path = db_path
        self._fire = fire
        self._busy = busy or (lambda _key: False)
        self._deliver = deliver
        self._log = logger or (lambda _m: None)
        self._now = clock
        self._tick = tick
        self._providers = list(signal_providers or [])
        self._journal_writer = journal_writer
        self._state_path = self._workspace / STATE_FILENAME
        self._lock = threading.RLock()
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._state = self._load()
        # Diagnostics for tests and the log.
        self.fired = 0
        self.skipped = 0

    # -- state file -------------------------------------------------------------------

    def _load(self) -> dict:
        try:
            data = json.loads(self._state_path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            data = {}
        if not isinstance(data, dict):
            data = {}
        for key, empty in (("user", {}), ("agents", {}), ("beats", {}), ("runs", {}), ("queue", []), ("ledger", {})):
            if not isinstance(data.get(key), type(empty)):
                data[key] = empty
        return data

    def _save(self) -> None:
        try:
            self._state_path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self._state_path.with_suffix(".json.tmp")
            tmp.write_text(json.dumps(self._state, ensure_ascii=False, indent=1), encoding="utf-8")
            tmp.replace(self._state_path)
        except OSError as exc:
            self._log(f"[proactive] cannot save state: {exc}")

    # -- lifecycle --------------------------------------------------------------------

    def start(self) -> None:
        if self._thread is not None:
            return
        self._stop.clear()
        self._thread = threading.Thread(target=self._loop, name="agents-proactive", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        thread, self._thread = self._thread, None
        if thread is not None:
            thread.join(timeout=self._tick + 1.0)

    def _loop(self) -> None:
        while not self._stop.wait(self._tick):
            try:
                self.run_once()
            except Exception as exc:  # noqa: BLE001 — the clock must keep ticking
                self._log(f"[proactive] tick: {type(exc).__name__}: {exc}")

    # -- settings ---------------------------------------------------------------------

    def settings_for(self, session_key: str) -> ProactiveSettings:
        owner = owner_session_key(session_key)
        with self._lock:
            merged = {**self._state["agents"].get(owner, {}), **self._state["user"]}
        return ProactiveSettings.from_dict(merged)

    def update_settings(self, session_key: str, changes: dict[str, Any]) -> dict:
        owner = owner_session_key(session_key)
        try:
            settings = self.settings_for(owner).apply(changes)
        except ProactiveSettingsError as exc:
            return {"ok": False, "error": str(exc)}
        values = settings.to_dict()
        with self._lock:
            self._state["user"] = {k: values[k] for k in ProactiveSettings.USER_KEYS}
            self._state["agents"][owner] = {k: values[k] for k in ProactiveSettings.AGENT_KEYS}
            self._save()
        self._sync_rows(owner, settings, enable_changed={k for k in changes if k.endswith("_enabled")})
        return {"ok": True, **self.describe(owner)}

    def describe(self, session_key: str) -> dict:
        """The settings as the tool shows them, plus the state of the rows."""
        owner = owner_session_key(session_key)
        settings = self.settings_for(owner)
        out = settings.to_dict()
        now = self._now()
        for kind, prefix in ((KIND_HEARTBEAT, "heartbeat"), (KIND_MORNING_BRIEF, "brief")):
            row = self._row(owner, kind)
            out[f"{prefix}_state"] = row["state"] if row else "off"
            if row and row.get("next_fire_at"):
                out[f"{prefix}_next_local"] = self._local_text(float(row["next_fire_at"]), settings)
        out["in_quiet_hours"] = in_quiet_hours(now, settings)
        out["now_local"] = self._local_text(now, settings)
        out["queued_pushes"] = len(self._state["queue"])
        return out

    @staticmethod
    def _local_text(stamp: float, settings: ProactiveSettings) -> str:
        return datetime.fromtimestamp(stamp, settings_zone(settings)).strftime("%A, %Y-%m-%d %H:%M (%Z)")

    def _row(self, owner: str, kind: str) -> dict | None:
        """The live (active or paused) row of ``kind`` for ``owner``."""
        rows = [
            r
            for r in self._automations.store.list(owner)
            if r["kind"] == kind and r["state"] in (STATE_ACTIVE, STATE_PAUSED)
        ]
        return rows[-1] if rows else None

    def _sync_rows(self, owner: str, settings: ProactiveSettings, *, enable_changed: set[str]) -> None:
        """Make the rows match the settings: create, retime, resume or cancel."""
        now = self._now()
        plan = (
            (
                KIND_HEARTBEAT,
                settings.heartbeat_enabled,
                {"every": int(settings.heartbeat_every_minutes) * 60},
                HEARTBEAT_NAME,
                now + int(settings.heartbeat_every_minutes) * 60,
                "heartbeat_enabled",
            ),
            (
                KIND_MORNING_BRIEF,
                settings.brief_enabled,
                {"daily_at": settings.brief_time, "timezone": settings.timezone or "local"},
                MORNING_BRIEF_NAME,
                next_brief_at(now, settings),
                "brief_enabled",
            ),
        )
        for kind, enabled, spec, name, first_fire, switch in plan:
            row = self._row(owner, kind)
            if not enabled:
                if row is not None:
                    self._automations.control(None, row["id"], "cancel")
                continue
            if row is None:
                row = self._automations.store.create(
                    session_key=owner,
                    kind=kind,
                    name=name,
                    spec=spec,
                    prompt=f"{name} (proactive_settings)",
                    next_fire_at=first_fire,
                    notify=NOTIFY_ON_CHANGE,
                    extra={"created_by": CREATED_BY_USER},
                )
                self._emit(row, "created")
                continue
            fields: dict[str, Any] = {}
            if row.get("spec") != spec:
                fields.update(spec=spec, next_fire_at=first_fire)
            if fields:
                row = self._automations.store.update(row["id"], **fields) or row
                self._emit(row, "updated")
            if row["state"] == STATE_PAUSED and switch in enable_changed:
                # The user switched it on again by word: that resumes it.
                self._automations.control(None, row["id"], "resume")

    def _emit(self, row: dict, event: str, **kwargs: Any) -> None:
        emit = getattr(self._automations, "_emit", None)
        if callable(emit):
            try:
                emit(row, event, **kwargs)
            except Exception as exc:  # noqa: BLE001 — a frame must not stop the clock
                self._log(f"[proactive] emit {event}: {type(exc).__name__}")

    # -- checklist ----------------------------------------------------------------------

    def checklist_path(self, session_key: str) -> Path:
        return checklist_path(self._workspace, owner_session_key(session_key))

    def read_checklist(self, session_key: str) -> str:
        return read_checklist(self.checklist_path(session_key))

    def write_checklist(self, session_key: str, text: str) -> dict:
        try:
            written = write_checklist(self.checklist_path(session_key), text)
        except OSError as exc:
            return {"ok": False, "error": f"cannot write the checklist: {exc}"}
        return {"ok": True, "checklist": written}

    def bound(self, session_key: str) -> "SessionProactive":
        return SessionProactive(self, session_key)

    # -- the tick -------------------------------------------------------------------------

    def run_once(self) -> int:
        """One tick. Returns how many runs were started. Exposed for tests."""
        estop = getattr(self._automations, "_estop_engaged", None)
        if callable(estop) and estop():
            return 0
        now = self._now()
        self._deliver_queue(now)
        started = 0
        store = self._automations.store
        for row in store.list(states=(STATE_ACTIVE,)):
            due = row.get("next_fire_at")
            if due is not None and float(due) > now:
                continue
            try:
                if row["kind"] == KIND_HEARTBEAT and self._beat(row, now):
                    started += 1
                elif row["kind"] == KIND_MORNING_BRIEF and self._brief(row, now):
                    started += 1
            except Exception as exc:  # noqa: BLE001 — one bad row must not stop the others
                self._log(f"[proactive] {row['id']}: {type(exc).__name__}: {exc}")
        self._forget_old_runs(now)
        return started

    def _is_busy(self, session_key: str) -> bool:
        try:
            return bool(self._busy(session_key))
        except Exception:  # noqa: BLE001 — unknown = busy; the next tick tries again
            return True

    # -- heartbeat ----------------------------------------------------------------------

    def signals(self, session_key: str) -> dict[str, str]:
        """The zero-token pre-check: one fingerprint per source. Nothing here
        calls a model or the network."""
        owner = owner_session_key(session_key)
        out: dict[str, str] = {"checklist": _digest(self.read_checklist(owner))}
        for row in self._automations.store.list(owner):
            if row["kind"] in (KIND_HEARTBEAT, KIND_MORNING_BRIEF) or row["state"] != STATE_ACTIVE:
                continue
            if row["kind"] in _EVENT_TRIGGER_KINDS:
                out[f"automation:{row['id']}:{row['name']}"] = _digest(
                    [row.get("fire_count"), row.get("last_digest")]
                )
            elif row.get("last_digest"):
                out[f"automation:{row['id']}:{row['name']}"] = str(row["last_digest"])
        todo = self._todo_fingerprint(owner)
        if todo is not None:
            out["todo"] = todo
        for provider in self._providers:
            try:
                extra = provider(owner) or {}
            except Exception as exc:  # noqa: BLE001 — a broken source is left out
                self._log(f"[proactive] signal provider failed: {type(exc).__name__}")
                continue
            out.update({str(k): str(v) for k, v in extra.items()})
        return out

    def _todo_fingerprint(self, session_key: str) -> str | None:
        try:
            store = StateStore(self._db_path)
            try:
                doc = store.load_feature(session_key, "todo")
            finally:
                store.close()
        except Exception:  # noqa: BLE001 — no store, no signal
            return None
        todos = (doc or {}).get("todos") if isinstance(doc, dict) else None
        if not todos:
            return None
        open_items = [t.get("content") for t in todos if isinstance(t, dict) and t.get("status") != "completed"]
        return _digest(open_items)

    @staticmethod
    def describe_changes(before: dict[str, str], after: dict[str, str]) -> list[str]:
        lines: list[str] = []
        for key in sorted(set(before) | set(after)):
            if before.get(key) == after.get(key):
                continue
            if key == "checklist":
                lines.append("the checklist was edited")
            elif key == "todo":
                lines.append("the todo list changed")
            elif key.startswith("automation:"):
                name = key.split(":", 2)[-1]
                lines.append(f"automation '{name}' has a new result" if key in after else f"automation '{name}' ended")
            else:
                lines.append(f"{key} changed")
        return lines

    def _beat(self, row: dict, now: float) -> bool:
        owner = row["session_key"]
        settings = self.settings_for(owner)
        every = float((row.get("spec") or {}).get("every") or settings.heartbeat_every_minutes * 60)
        end = quiet_ends_at(now, settings)
        if end is not None:
            # No beat in the quiet hours: the first beat after them sees
            # everything that changed in the night.
            self._automations.store.update(row["id"], next_fire_at=end)
            return False
        if self._is_busy(owner):
            # Idle only. The row stays due; missed ticks merge into one beat.
            return False
        fingerprint = self.signals(owner)
        with self._lock:
            beat = dict(self._state["beats"].get(row["id"]) or {})
        previous = beat.get("fingerprint")
        last_model = float(beat.get("last_model_at") or 0.0)
        full_due = now - last_model >= float(settings.full_check_hours) * 3600.0
        changes = self.describe_changes(previous or {}, fingerprint) if isinstance(previous, dict) else []
        if isinstance(previous, dict) and not changes and not full_due:
            self.skipped += 1
            self._automations.store.update(
                row["id"],
                next_fire_at=now + every,
                suppressed_count=int(row.get("suppressed_count") or 0) + 1,
            )
            return False
        prompt = heartbeat_prompt(
            row["id"], self.read_checklist(owner), changes, last_summary=row.get("last_summary")
        )
        run_id = self._start(row, prompt)
        if not run_id:
            return False
        self._automations.store.record_fire(row["id"], fired_at=now, next_fire_at=now + every)
        with self._lock:
            self._state["beats"][row["id"]] = {"fingerprint": fingerprint, "last_model_at": now}
            self._save()
        self._emit(self._automations.store.get(row["id"]) or row, "fired", run_id=run_id, reason="heartbeat")
        return True

    def _start(self, row: dict, prompt: str) -> str | None:
        meta = {"automation_id": row["id"], "name": row["name"], "kind": row["kind"], "reason": row["kind"]}
        try:
            run_id = self._fire(row["session_key"], prompt, meta)
        except Exception as exc:  # noqa: BLE001 — a broken host must not stop the clock
            self._log(f"[proactive] fire {row['id']}: {type(exc).__name__}: {exc}")
            return None
        if not run_id:
            return None
        self.fired += 1
        with self._lock:
            self._state["runs"][run_id] = {"kind": row["kind"], "automation_id": row["id"], "at": self._now()}
            self._save()
        return run_id

    # -- morning brief --------------------------------------------------------------------

    def _brief(self, row: dict, now: float) -> bool:
        owner = row["session_key"]
        settings = self.settings_for(owner)
        due = float(row.get("next_fire_at") or now)
        if now - due > BRIEF_CATCH_UP_SECONDS:
            # The host was away: a brief at noon is no morning brief.
            self._automations.store.update(row["id"], next_fire_at=next_brief_at(now, settings))
            self._log(f"[proactive] {row['id']}: missed morning brief skipped")
            return False
        if self._is_busy(owner):
            return False
        today = datetime.fromtimestamp(now, settings_zone(settings)).date()
        journal = self._write_journal(today - timedelta(days=1), settings.timezone or "UTC")
        prompt = morning_brief_prompt(row["id"], settings, today=today, journal_file=journal)
        run_id = self._start(row, prompt)
        if not run_id:
            return False
        self._automations.store.record_fire(row["id"], fired_at=now, next_fire_at=next_brief_at(now, settings))
        self._emit(self._automations.store.get(row["id"]) or row, "fired", run_id=run_id, reason="morning_brief")
        return True

    def _write_journal(self, day: date, tz_name: str) -> str | None:
        if self._journal_writer is None:
            return None
        try:
            path = self._journal_writer(day, tz_name)
        except Exception as exc:  # noqa: BLE001 — the brief works without it
            self._log(f"[proactive] journal: {type(exc).__name__}: {exc}")
            return None
        if path is None:
            return None
        try:
            return str(Path(path).relative_to(self._workspace))
        except ValueError:
            return str(path)

    # -- the push gate ----------------------------------------------------------------------

    def filter_run(self, summary: dict) -> bool:
        """``True`` = do not announce this run now. Called by the host for
        every unattended automation run before the toast and the push.

        - a heartbeat that answered only ``HEARTBEAT_OK``: silent;
        - a heartbeat nudge on a topic inside its cooldown, or over the
          daily cap: dropped;
        - any automation run inside the quiet hours: queued, sent when they
          end."""
        if not isinstance(summary, dict) or summary.get("origin") != "automation":
            return False
        now = self._now()
        session_key = str(summary.get("session_key") or "default")
        settings = self.settings_for(session_key)
        run_id = str(summary.get("run_id") or "")
        with self._lock:
            run = dict(self._state["runs"].get(run_id) or {})
        kind = run.get("kind")
        topic: str | None = None
        if kind == KIND_HEARTBEAT:
            answer = summary.get("final_answer")
            if not summary.get("error") and is_silent_answer(answer):
                self._log(f"[proactive] heartbeat {run_id}: silent")
                return True
            result = summary.get("automation_result")
            if isinstance(result, dict) and isinstance(result.get("summary"), str) and result["summary"].strip():
                topic = result["summary"]
            else:
                topic = str(answer or "")[:300]
            with self._lock:
                ledger = NudgeLedger.from_dict(self._state["ledger"])
            reason = ledger.check(topic, now, settings)
            if reason is not None:
                self._log(f"[proactive] heartbeat {run_id}: not pushed ({reason})")
                return True
        if in_quiet_hours(now, settings):
            entry = {k: summary.get(k) for k in _QUEUE_KEYS if summary.get(k) is not None}
            entry["queued_at"] = now
            with self._lock:
                queue = self._state["queue"]
                queue.append(entry)
                del queue[:-MAX_QUEUE]
                if topic is not None:
                    self._record(topic, now, settings)
                self._save()
            self._log(f"[proactive] run {run_id}: queued until the quiet hours end")
            return True
        if topic is not None:
            with self._lock:
                self._record(topic, now, settings)
                self._save()
        return False

    def _record(self, topic: str, now: float, settings: ProactiveSettings) -> None:
        ledger = NudgeLedger.from_dict(self._state["ledger"])
        ledger.record(topic, now, settings)
        self._state["ledger"] = ledger.to_dict()

    def _deliver_queue(self, now: float) -> int:
        with self._lock:
            queue = list(self._state["queue"])
        if not queue:
            return 0
        # Quiet hours are the user's, not per chat: one check for the queue.
        settings = self.settings_for(str(queue[-1].get("session_key") or "default"))
        if in_quiet_hours(now, settings):
            return 0
        send = queue[-MAX_QUEUE_DELIVER:]
        dropped = len(queue) - len(send)
        with self._lock:
            self._state["queue"] = []
            self._save()
        if dropped:
            self._log(f"[proactive] {dropped} older queued push(es) dropped; the runs stay in the chat")
        sent = 0
        for entry in send:
            if self._deliver is None:
                break
            try:
                self._deliver(dict(entry))
                sent += 1
            except Exception as exc:  # noqa: BLE001 — a failed push must not stop the clock
                self._log(f"[proactive] queued push failed: {type(exc).__name__}")
        return sent

    def _forget_old_runs(self, now: float) -> None:
        with self._lock:
            runs = self._state["runs"]
            old = [k for k, v in runs.items() if now - float((v or {}).get("at") or 0) > RUN_MEMORY_SECONDS]
            if not old:
                return
            for key in old:
                runs.pop(key, None)
            self._save()

    @property
    def queue(self) -> list[dict]:
        with self._lock:
            return list(self._state["queue"])


class SessionProactive:
    """The :class:`chuk_agents_runtime.proactive.ProactiveBackend` for ONE chat."""

    def __init__(self, manager: ProactiveManager, session_key: str) -> None:
        self._manager = manager
        self._session_key = owner_session_key(session_key)

    def get_settings(self) -> dict:
        return self._manager.describe(self._session_key)

    def update_settings(self, changes: dict[str, Any]) -> dict:
        return self._manager.update_settings(self._session_key, changes)

    def read_checklist(self) -> str:
        return self._manager.read_checklist(self._session_key)

    def write_checklist(self, text: str) -> dict:
        return self._manager.write_checklist(self._session_key, text)


def daily_journal_writer(workspace: str | Path) -> JournalWriter:
    """A :data:`JournalWriter` on ``chuk_agents_manager.daily_summary``:
    writes ``journal/<day>.md`` from the action journal, zero tokens."""

    def write(day: date, tz_name: str) -> Path | None:
        from chuk_agents_manager.daily_summary import write_daily_summary

        return write_daily_summary(workspace, day=day, tz=tz_name)

    return write


__all__ = [
    "ProactiveManager",
    "SessionProactive",
    "daily_journal_writer",
]
