"""Agent mail on the host: fetch, claim, and start the mail runs.

The host half of docs/AGENT_MAIL.md, sections 5.1 and 5.2. The runtime half
(the REST client, the tools, the prompts) is ``chuk_agents_runtime.agent_mail``.

When the host fetches: when it starts, when the relay connects again, when an
``agent_mail`` relay frame arrives (it carries no content, only "fetch now"),
and every 5 minutes.

What it does with each mail that is not delivered yet:

| mail | action |
|---|---|
| ``is_bulk`` | claim, no run |
| ``owner`` / ``trusted`` | claim, then ONE full run on the main agent session for all of them (``origin="mail"``) |
| ``unknown`` | wait until the mail is 30 s old, claim, then one restricted run on ``mail:<id>`` (``origin="mail_untrusted"``), at most 20 per day |

The server's claim is what makes a mail run once: two hosts of one user, or a
host after a restart, can list the same mail, but only the host whose claim
names it starts a run. A mail whose claim this host lost starts nothing. A
mail this host claimed but could not start (the executor went away between the
check and the start) is kept as pending, in memory and in the state file, and
is started before the next claim round.

Nothing here logs content, subjects or addresses. Log lines carry counts and
ids only.
"""

from __future__ import annotations

import json
import os
import threading
import time
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

import httpx

from chuk_agents_runtime.agent_mail import (
    KNOWN_TRUST,
    ORIGIN_MAIL,
    ORIGIN_MAIL_UNTRUSTED,
    PROFILE_MAIL_UNTRUSTED,
    TRUST_SELF,
    AgentMailClient,
    AgentMailError,
    mail_prompt,
    parse_time,
    restricted_prompt,
    restricted_session_key,
    valid_id,
)
from chuk_agents_runtime.web_search import DEFAULT_BASE_URL

#: The host state file (next to ``agent_permissions.json``).
STATE_FILE = "agent_mail.json"

POLL_SECONDS = 300.0
#: An unknown mail waits this long before a restricted run takes it, so a
#: ``mail_wait`` of a running task can take it first (§5.2).
UNKNOWN_DELAY_SECONDS = 30.0
#: Restricted runs per mailbox per day (§3).
RESTRICTED_DAILY_CAP = 20
#: How soon to look again when the host cannot start a run yet (no task
#: server: restarted, no app since). A local check, no network.
NOT_READY_RETRY_SECONDS = 10.0
#: How soon to look again when the main session is busy: trusted mail then
#: waits unclaimed and goes into the next free run, all of it at once.
BUSY_RETRY_SECONDS = 30.0
PAGE_LIMIT = 100
MAX_PAGES = 5
#: Trusted mails per full run. More mails make more runs.
MAX_BATCH = 10

#: Server answers that mean "no mailbox here": no mail tools, no fetch.
_UNAVAILABLE = ("no_subscription", "agent_mail_unavailable")

Submit = Callable[[str, str, dict], "str | None"]


@dataclass
class DispatchReport:
    """What one fetch did. Counts and ids only."""

    skipped: str | None = None
    listed: int = 0
    bulk: int = 0
    full_mails: int = 0
    full_runs: list[str] = field(default_factory=list)
    restricted_runs: list[str] = field(default_factory=list)
    capped: int = 0
    waiting: int = 0
    deferred: int = 0
    lost: int = 0
    pending: int = 0
    retry_in: float | None = None

    def soon(self, seconds: float) -> None:
        self.retry_in = seconds if self.retry_in is None else min(self.retry_in, seconds)


class MailState:
    """The host state file of agent mail, so a restart loses nothing:

    - the day's count of restricted runs (the day is the UTC date), and
    - the mails this host claimed but could not start yet.
    """

    def __init__(
        self,
        path: Path,
        *,
        cap: int = RESTRICTED_DAILY_CAP,
        clock: Callable[[], float] = time.time,
        log: Callable[[str], None] | None = None,
    ) -> None:
        self._path = Path(path)
        self._cap = int(cap)
        self._clock = clock
        self._log = log or (lambda _m: None)
        self._lock = threading.Lock()

    def _day(self) -> str:
        return datetime.fromtimestamp(self._clock(), tz=timezone.utc).strftime("%Y-%m-%d")

    def _load(self) -> dict:
        try:
            data = json.loads(self._path.read_text())
        except FileNotFoundError:
            return {}
        except (OSError, ValueError):
            self._log("[mail] unreadable mail state; counting from zero")
            return {}
        return data if isinstance(data, dict) else {}

    def _save(self, data: dict) -> None:
        data["version"] = 1
        try:
            self._path.parent.mkdir(parents=True, exist_ok=True)
            tmp = self._path.with_suffix(".tmp")
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
            with os.fdopen(fd, "w") as handle:
                json.dump(data, handle)
            os.replace(tmp, self._path)
        except OSError as exc:
            self._log(f"[mail] could not save the mail state: {type(exc).__name__}")

    def used(self) -> int:
        with self._lock:
            entry = self._load().get("restricted_runs")
        if not isinstance(entry, dict) or entry.get("day") != self._day():
            return 0
        count = entry.get("count")
        return count if isinstance(count, int) and count > 0 else 0

    def remaining(self) -> int:
        return max(0, self._cap - self.used())

    def take(self) -> None:
        """Count one restricted run for today."""
        with self._lock:
            data = self._load()
            day = self._day()
            entry = data.get("restricted_runs")
            count = entry.get("count", 0) if isinstance(entry, dict) and entry.get("day") == day else 0
            data["restricted_runs"] = {"day": day, "count": int(count) + 1}
            self._save(data)

    def pending(self) -> tuple[list[dict], list[str]]:
        """The claimed mails no run took yet: ``([{id, sender_trust}], [id])``
        for the full and the restricted runs."""
        with self._lock:
            entry = self._load().get("pending")
        entry = entry if isinstance(entry, dict) else {}
        full = [
            {"id": ident, "sender_trust": str(row.get("sender_trust") or "")}
            for row in entry.get("full") or []
            if isinstance(row, dict) and (ident := valid_id(row.get("id")))
        ]
        restricted = [i for i in (valid_id(x) for x in entry.get("restricted") or []) if i]
        return full, restricted

    def set_pending(self, full: list[dict], restricted: list[str]) -> None:
        with self._lock:
            data = self._load()
            data["pending"] = {
                "full": [{"id": r["id"], "sender_trust": r.get("sender_trust")} for r in full],
                "restricted": list(restricted),
            }
            self._save(data)


class AgentMailService:
    """The host's mail service: the client for the tools, and the dispatcher.

    ``submit(session_key, prompt, meta)`` starts a run and returns its id, or
    ``None`` when no executor can take it. ``ready()`` says whether a run can
    start at all; nothing is claimed while it is False. ``busy(session_key)``
    says whether that session has a run queued or in flight.
    """

    def __init__(
        self,
        *,
        session_provider: Callable[[], Any],
        submit: Submit,
        ready: Callable[[], bool],
        busy: Callable[[str], bool],
        main_session: str,
        state_path: Path,
        base_url: str = DEFAULT_BASE_URL,
        http_client: httpx.Client | None = None,
        clock: Callable[[], float] = time.time,
        logger: Callable[[str], None] | None = None,
        poll_seconds: float = POLL_SECONDS,
        unknown_delay: float = UNKNOWN_DELAY_SECONDS,
        daily_cap: int = RESTRICTED_DAILY_CAP,
    ) -> None:
        self._client = AgentMailClient(session_provider, base_url=base_url, http_client=http_client)
        self._submit = submit
        self._ready = ready
        self._busy = busy
        self._main_session = main_session
        self._clock = clock
        self._log = logger or (lambda _m: None)
        self._poll = float(poll_seconds)
        self._unknown_delay = float(unknown_delay)
        self.state = MailState(state_path, cap=daily_cap, clock=clock, log=self._log)
        # Claimed, but no run took them yet (see the module docstring).
        self._pending_full, self._pending_restricted = self.state.pending()
        #: ``None`` unknown, True a mailbox answered, False the server said
        #: there is none (no subscription, mail off on the server).
        self._available: bool | None = None
        self._checked_at: float | None = None
        self._capped_day: str | None = None
        self._dispatch_lock = threading.Lock()
        self._wake = threading.Event()
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    # -- for the executor -------------------------------------------------

    def client(self) -> AgentMailClient | None:
        """The REST client for the mail tools, or ``None``: no account
        session, or the server said this account has no mailbox."""
        if not self._client.has_session() or self._available is False:
            return None
        return self._client

    # -- lifecycle --------------------------------------------------------

    def start(self) -> None:
        if self._thread is not None:
            return
        self._stop.clear()
        self._thread = threading.Thread(target=self._loop, name="agent-mail", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        self._wake.set()
        thread, self._thread = self._thread, None
        if thread is not None:
            thread.join(timeout=5.0)

    def wake(self, reason: str = "frame") -> None:
        """Fetch now: an ``agent_mail`` frame came in, or the relay connected
        again, or the host was provisioned."""
        self._wake.set()

    def _loop(self) -> None:
        delay = 0.0  # the fetch at start
        while not self._stop.is_set():
            if delay > 0:
                self._wake.wait(delay)
            if self._stop.is_set():
                return
            self._wake.clear()
            try:
                report = self.dispatch_once()
            except Exception as exc:  # noqa: BLE001 — the loop must keep running
                self._log(f"[mail] fetch failed: {type(exc).__name__}")
                report = DispatchReport(skipped="error")
            delay = self._poll if report.retry_in is None else max(1.0, min(self._poll, report.retry_in))

    # -- one fetch --------------------------------------------------------

    def dispatch_once(self) -> DispatchReport:
        """List the undelivered mail and handle each one once (§5.2)."""
        with self._dispatch_lock:
            return self._dispatch()

    def _dispatch(self) -> DispatchReport:
        report = DispatchReport()
        if not self._client.has_session():
            report.skipped = "no_account"
            return report
        if not self._ready():
            report.skipped = "not_ready"
            report.soon(NOT_READY_RETRY_SECONDS)
            return report
        # What this host claimed earlier and could not start goes first. No
        # new claim while any of it is still waiting.
        if not self._start_pending(report):
            report.skipped = "pending"
            report.soon(NOT_READY_RETRY_SECONDS)
            return report
        if not self._mailbox_ok(report):
            return report
        try:
            rows = self._undelivered()
        except AgentMailError as exc:
            self._note_error(exc, report)
            return report
        report.listed = len(rows)
        if not rows:
            return report

        now = self._clock()
        bulk: list[str] = []
        known: list[dict] = []
        unknown: list[str] = []
        for row in rows:
            ident = valid_id(row.get("id"))
            # The agent's own sent mail and drafts start nothing.
            if (
                ident is None
                or str(row.get("direction") or "").startswith("out")
                or row.get("sender_trust") == TRUST_SELF
            ):
                continue
            if row.get("is_bulk"):
                bulk.append(ident)
            elif row.get("sender_trust") in KNOWN_TRUST:
                known.append(row)
            else:
                created = parse_time(row.get("created_at"))
                age = now - created if created is not None else self._unknown_delay
                if age < self._unknown_delay:
                    report.waiting += 1
                    report.soon(self._unknown_delay - age + 1.0)
                else:
                    unknown.append(ident)

        # Trusted mail waits unclaimed while the main session is busy, so the
        # next free run takes all of it at once.
        if known and self._is_busy(self._main_session):
            report.deferred = len(known)
            report.soon(BUSY_RETRY_SECONDS)
            known = []

        room = self.state.remaining()
        runnable, capped = unknown[:room], unknown[room:]
        wanted = bulk + [str(r["id"]).strip() for r in known] + unknown
        if not wanted:
            return report
        # The last check before the claim: a claimed mail that no executor
        # can take would be lost.
        if not self._ready():
            report.skipped = "not_ready"
            report.soon(NOT_READY_RETRY_SECONDS)
            return report
        try:
            claimed = set(self._client.claim(wanted))
        except AgentMailError as exc:
            self._note_error(exc, report)
            return report
        report.lost = sum(1 for ident in wanted if ident not in claimed)
        report.bulk = sum(1 for ident in bulk if ident in claimed)

        mine = [r for r in known if str(r["id"]).strip() in claimed]
        for start in range(0, len(mine), MAX_BATCH):
            batch = mine[start : start + MAX_BATCH]
            if not self._start_full_run(batch, report):
                self._pending_full.extend(_pending_row(r) for r in batch)

        for ident in runnable:
            if ident in claimed and not self._start_restricted_run(ident, report):
                self._pending_restricted.append(ident)
        report.pending = len(self._pending_full) + len(self._pending_restricted)
        if report.pending:
            self.state.set_pending(self._pending_full, self._pending_restricted)
            report.soon(NOT_READY_RETRY_SECONDS)
        report.capped = sum(1 for ident in capped if ident in claimed)
        if report.capped:
            day = datetime.fromtimestamp(now, tz=timezone.utc).strftime("%Y-%m-%d")
            if self._capped_day != day:
                self._capped_day = day
                self._log(
                    f"[mail] the daily limit of restricted runs is reached; "
                    f"{report.capped} unknown mail(s) stored without a run"
                )
        self._log(
            f"[mail] listed {report.listed}: bulk {report.bulk}, "
            f"trusted {report.full_mails} in {len(report.full_runs)} run(s), "
            f"unknown {len(report.restricted_runs)} run(s), capped {report.capped}, "
            f"waiting {report.waiting}, deferred {report.deferred}, lost {report.lost}, "
            f"pending {report.pending}"
        )
        return report

    def _mailbox_ok(self, report: DispatchReport) -> bool:
        now = self._clock()
        if self._checked_at is None or now - self._checked_at >= self._poll:
            try:
                self._client.mailbox()
            except AgentMailError as exc:
                self._note_error(exc, report, probe=True)
                if self._available is not False:
                    return False
            else:
                self._available = True
                self._checked_at = now
        if self._available is False:
            report.skipped = report.skipped or "unavailable"
            return False
        return True

    def _note_error(self, exc: AgentMailError, report: DispatchReport, *, probe: bool = False) -> None:
        # The server also answers ``503 agent_mail_unavailable`` for a passing
        # fault (a Supabase timeout, api_server ``routers/agent_mail``
        # ``_run``). Only the mailbox probe may conclude "no mailbox here";
        # a 503 of the list or the claim is retried soon, and the mail tools
        # stay.
        if exc.status == 503 and not probe:
            report.skipped = "error"
            report.soon(BUSY_RETRY_SECONDS)
            self._log(f"[mail] request failed: {exc.status} {exc.detail}")
            return
        if exc.status in (402, 503) or exc.detail in _UNAVAILABLE:
            if self._available is not False:
                self._log(f"[mail] no mailbox for this account ({exc.detail})")
            self._available = False
            self._checked_at = self._clock()
            report.skipped = "unavailable"
            return
        report.skipped = "error"
        self._log(f"[mail] request failed: {exc.status} {exc.detail}")

    def _undelivered(self) -> list[dict]:
        rows: list[dict] = []
        before: str | None = None
        for _ in range(MAX_PAGES):
            data = self._client.list_messages(
                folder="inbox", undelivered=True, limit=PAGE_LIMIT, before=before
            )
            batch = [r for r in (data.get("messages") or []) if isinstance(r, dict)]
            rows.extend(batch)
            nxt = data.get("next_before")
            if not isinstance(nxt, str) or not nxt or len(batch) < PAGE_LIMIT:
                break
            before = nxt
        return rows

    def _is_busy(self, session_key: str) -> bool:
        try:
            return bool(self._busy(session_key))
        except Exception:  # noqa: BLE001 — a broken probe means "not busy"
            return False

    def _start_pending(self, report: DispatchReport) -> bool:
        """Start the claimed mails that no run took yet. True when none is
        left waiting."""
        if not self._pending_full and not self._pending_restricted:
            return True
        full, self._pending_full = self._pending_full, []
        restricted, self._pending_restricted = self._pending_restricted, []
        for start in range(0, len(full), MAX_BATCH):
            batch = full[start : start + MAX_BATCH]
            if not self._start_full_run(batch, report):
                self._pending_full.extend(batch)
        for ident in restricted:
            if not self._start_restricted_run(ident, report):
                self._pending_restricted.append(ident)
        self.state.set_pending(self._pending_full, self._pending_restricted)
        report.pending = len(self._pending_full) + len(self._pending_restricted)
        return report.pending == 0

    def _start_full_run(self, rows: list[dict], report: DispatchReport) -> bool:
        views: list[dict] = []
        for row in rows:
            try:
                views.append(self._client.host_view(str(row["id"]).strip()))
            except AgentMailError:
                # The summary still names sender and subject; the model reads
                # the text with mail_read.
                views.append({k: v for k, v in row.items() if k != "text_body"})
        prompt = mail_prompt(views)
        ids = [str(r["id"]).strip() for r in rows]
        meta = {"origin": ORIGIN_MAIL, "name": "mail", "message_ids": ids}
        run_id = self._run(self._main_session, prompt, meta)
        if run_id:
            report.full_runs.append(run_id)
            report.full_mails += len(rows)
            return True
        self._log(f"[mail] could not start a run for {len(ids)} claimed mail(s); kept as pending")
        return False

    def _start_restricted_run(self, ident: str, report: DispatchReport) -> bool:
        meta = {
            "origin": ORIGIN_MAIL_UNTRUSTED,
            "profile": PROFILE_MAIL_UNTRUSTED,
            "message_id": ident,
        }
        run_id = self._run(restricted_session_key(ident), restricted_prompt(ident), meta)
        if run_id:
            self.state.take()
            report.restricted_runs.append(run_id)
            return True
        self._log(f"[mail] could not start the restricted run for mail {ident}; kept as pending")
        return False

    def _run(self, session_key: str, prompt: str, meta: dict) -> str | None:
        try:
            return self._submit(session_key, prompt, meta)
        except Exception as exc:  # noqa: BLE001 — one bad submit must not stop the rest
            self._log(f"[mail] submit failed: {type(exc).__name__}")
            return None


def _pending_row(row: dict) -> dict:
    """What a pending full-run mail keeps: its id and its sender trust. The
    run fetches the HostView again when it starts."""
    return {"id": str(row["id"]).strip(), "sender_trust": row.get("sender_trust")}


__all__ = [
    "AgentMailService",
    "DispatchReport",
    "MailState",
    "STATE_FILE",
]
