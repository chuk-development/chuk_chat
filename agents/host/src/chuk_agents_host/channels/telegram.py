"""The Telegram channel of one coworker.

Two threads per enabled coworker:

* the **poller** long-polls ``getUpdates`` (no webhook, no open port), handles
  each message and keeps the update offset in the channel store. A network
  drop, a 5xx or a 429 sends it into an exponential backoff (1 s doubling to
  60 s, with jitter); a revoked token stops it with state ``unauthorized``.
* the **sender** delivers replies and files in order, at most one message per
  second per chat, honours ``retry_after`` and shows "typing" while a run of
  this channel is in flight.

Who may talk: exactly one Telegram chat, the linked one. Until a chat is
linked, a private chat that writes to the bot gets a one-time six-digit code;
the user types that code into the app, which proves the chat is the user's
own. Every other chat gets one short, neutral refusal per hour and never
starts a run.

An inbound text becomes a normal task in the coworker's one session (the
same ``session_key`` the app uses), so the turn also shows in the app's
thread, marked with :data:`PROMPT_MARKER`. The run's final answer comes back
here through the host's ``on_run_finished`` hook.
"""

from __future__ import annotations

import hmac
import logging
import queue
import random
import secrets
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

from .format import TELEGRAM_MAX_CHARS, markdown_to_html, split_text
from .store import ChannelStore
from .telegram_api import (
    KIND_ABORTED,
    KIND_BAD_REQUEST,
    KIND_CONFLICT,
    KIND_RATE_LIMITED,
    KIND_UNAUTHORIZED,
    TelegramClient,
    TelegramError,
)

logger = logging.getLogger(__name__)

KIND = "telegram"

#: The first line of every prompt that came in over Telegram. The app's
#: thread shows it, so the user sees where a turn came from.
PROMPT_MARKER = "[via Telegram]"
#: ``origin`` of a run this channel started (run summary, ``done``).
ORIGIN = "telegram"

# Poller states, as the app sees them in ``agent_channel.state``.
STATE_STARTING = "starting"
STATE_POLLING = "polling"
STATE_BACKOFF = "backoff"
STATE_CONFLICT = "conflict"
STATE_UNAUTHORIZED = "unauthorized"
STATE_STOPPED = "stopped"

#: How many chats may hold an open link code at once.
MAX_PENDING_LINKS = 3
#: Wrong codes typed in the app before every open code is dropped.
MAX_LINK_ATTEMPTS = 5
#: One refusal per stranger chat per this many seconds.
REFUSAL_INTERVAL = 3600.0
#: The same open code is sent again to its chat at most this often.
CODE_RESEND_INTERVAL = 30.0
#: "typing" lasts five seconds on Telegram's side; refresh a little earlier.
TYPING_INTERVAL = 4.5
#: Retries of one outbound message on a network error, 5xx or 429.
SEND_RETRIES = 4

TEXT_LINK_OFFER = (
    "To link this chat to {label}, enter this code in the Chuk app, in the "
    "coworker's Telegram settings:\n\n{code}\n\nThe code expires in {minutes} "
    "minutes. Note: Telegram is not end-to-end encrypted."
)
TEXT_LINKED = (
    "Linked. Messages in this chat now go to {label}. Telegram is not "
    "end-to-end encrypted, so do not send anything here that must stay private."
)
TEXT_REFUSAL = "This bot is private."
TEXT_LINKED_START = "This chat is linked to {label}. Send a message to give it a task."
TEXT_TEXT_ONLY = "I can read text messages only for now."
TEXT_NOT_READY = (
    "The computer is not ready yet. Open the Chuk app once so it can connect, "
    "then send the message again."
)
TEXT_STOPPED = "Stopped."
TEXT_FAILED = "The task failed: {error}"
TEXT_NO_ANSWER = "Done. There is no text answer."

_PHOTO_TYPES = ("image/png", "image/jpeg", "image/webp")
_PHOTO_MAX_BYTES = 10 * 1024 * 1024


@dataclass
class _Pending:
    code: str
    expires_at: float
    name: str
    sent_at: float


@dataclass
class _Outbound:
    chat_id: int
    text: str | None = None
    markdown: bool = False
    file: dict | None = None


@dataclass
class TelegramTiming:
    """The clocks of one channel. Tests shrink them."""

    poll_timeout: int = 25
    link_ttl: float = 600.0
    backoff_base: float = 1.0
    backoff_max: float = 60.0
    send_interval: float = 1.0
    typing_interval: float = TYPING_INTERVAL


class TelegramChannel:
    """One coworker's bot: poller + sender + link state."""

    def __init__(
        self,
        *,
        agent_id: str,
        token: str,
        store: ChannelStore,
        submit: Callable[[str, str, dict], str | None],
        label: Callable[[], str],
        scrub: Callable[[str], str] = lambda text: text,
        read_files: Callable[[dict], list[dict]] = lambda _summary: [],
        on_change: Callable[[str], None] = lambda _agent_id: None,
        api_base: str = "https://api.telegram.org",
        timing: TelegramTiming | None = None,
        client_factory: Callable[..., TelegramClient] = TelegramClient,
        clock: Callable[[], float] = time.time,
    ) -> None:
        self.agent_id = agent_id
        self._store = store
        self._submit = submit
        self._label = label
        self._scrub = scrub
        self._read_files = read_files
        self._on_change = on_change
        self._timing = timing or TelegramTiming()
        self._clock = clock
        self._client = client_factory(token, base_url=api_base)
        self._stop = threading.Event()
        self._lock = threading.Lock()
        self._state = STATE_STARTING
        self._error = ""
        record = store.get(agent_id, KIND)
        self._bot_username = str(record.get("bot_username") or "")
        self._offset = int(record.get("offset") or 0)
        self._linked_chat: int | None = record.get("chat_id") if isinstance(record.get("chat_id"), int) else None
        self._pending: dict[int, _Pending] = {}
        self._failed_links = 0
        self._refused: dict[int, float] = {}
        self._runs: dict[str, int] = {}  # run_id -> chat id
        self._outbox: queue.Queue[_Outbound | None] = queue.Queue()
        self._last_sent: dict[int, float] = {}
        self._poller: threading.Thread | None = None
        self._sender: threading.Thread | None = None

    # -- lifecycle ------------------------------------------------------------

    def start(self) -> None:
        self._poller = threading.Thread(
            target=self._poll_loop, name=f"telegram-poll-{self.agent_id[:16]}", daemon=True
        )
        self._sender = threading.Thread(
            target=self._send_loop, name=f"telegram-send-{self.agent_id[:16]}", daemon=True
        )
        self._poller.start()
        self._sender.start()

    def stop(self, timeout: float = 5.0) -> None:
        """Stop both threads. The long poll is cut at once, not waited out."""
        self._stop.set()
        self._client.abort()
        self._outbox.put(None)
        for thread in (self._poller, self._sender):
            if thread is not None and thread is not threading.current_thread():
                thread.join(timeout)
        with self._lock:
            self._state = STATE_STOPPED

    @property
    def alive(self) -> bool:
        return bool(self._poller and self._poller.is_alive())

    # -- what the app sees ------------------------------------------------------

    def status(self) -> dict:
        now = self._clock()
        with self._lock:
            self._prune(now)
            pending = sorted(self._pending.values(), key=lambda p: p.expires_at)
            out: dict[str, Any] = {
                "state": self._state,
                "bot_username": self._bot_username,
                "linked": self._linked_chat is not None,
                "pending_link": bool(pending),
            }
            if pending:
                out["pending_link_expires_at"] = pending[-1].expires_at
            if self._error:
                out["error"] = self._error
        return out

    # -- linking (called from the app's frame) -------------------------------

    def link(self, code: object) -> tuple[bool, str]:
        """Link the chat that holds ``code``. ``(ok, error)``."""
        digits = "".join(ch for ch in str(code or "") if ch.isdigit())
        now = self._clock()
        with self._lock:
            self._prune(now)
            if not self._pending:
                return False, "no_pending_link"
            match = None
            for chat_id, pending in self._pending.items():
                # Compare every entry, constant time, so timing says nothing.
                if hmac.compare_digest(pending.code, digits) and match is None:
                    match = (chat_id, pending)
            if match is None:
                self._failed_links += 1
                if self._failed_links >= MAX_LINK_ATTEMPTS:
                    self._pending.clear()
                    self._failed_links = 0
                    return False, "too_many_attempts"
                return False, "wrong_code"
            chat_id, pending = match
            self._pending.clear()
            self._failed_links = 0
            self._linked_chat = chat_id
        self._store.update(self.agent_id, KIND, chat_id=chat_id, linked_name=pending.name)
        self._queue_text(chat_id, TEXT_LINKED.format(label=self._label()))
        self._on_change(self.agent_id)
        return True, ""

    def unlink(self) -> None:
        with self._lock:
            self._linked_chat = None
            self._pending.clear()
        self._store.update(self.agent_id, KIND, chat_id=None, linked_name=None)

    # -- the run's end (host hook) ------------------------------------------

    def on_run_finished(self, summary: dict) -> bool:
        """Send the answer of a run this channel started. True if it was ours."""
        run_id = str(summary.get("run_id") or "")
        with self._lock:
            chat_id = self._runs.pop(run_id, None)
        if chat_id is None:
            return False
        answer = summary.get("final_answer")
        if isinstance(answer, str) and answer.strip():
            text, markdown = answer, True
        elif str(summary.get("reason") or "") == "interrupted":
            text, markdown = TEXT_STOPPED, False
        elif summary.get("error"):
            text, markdown = TEXT_FAILED.format(error=str(summary.get("error"))[:500]), False
        else:
            text, markdown = TEXT_NO_ANSWER, False
        text = self._scrub(text)
        for chunk in split_text(text):
            self._outbox.put(_Outbound(chat_id=chat_id, text=chunk, markdown=markdown))
        try:
            files = self._read_files(summary)
        except Exception as exc:  # noqa: BLE001 — a reply must not die on a file read
            logger.warning("telegram: could not read the run's files: %s", type(exc).__name__)
            files = []
        for item in files:
            self._outbox.put(_Outbound(chat_id=chat_id, file=item))
        return True

    # -- the poller -------------------------------------------------------------

    def _set_state(self, state: str, error: str = "") -> None:
        with self._lock:
            changed = (state, error) != (self._state, self._error)
            self._state = state
            self._error = error
        if changed:
            self._on_change(self.agent_id)

    def _delay(self, failures: int) -> float:
        base = min(self._timing.backoff_max, self._timing.backoff_base * (2 ** max(0, failures - 1)))
        return base * random.uniform(0.8, 1.2)

    def _poll_loop(self) -> None:
        failures = 0
        while not self._stop.is_set():
            try:
                if not self._bot_username:
                    me = self._client.get_me()
                    self._bot_username = str((me or {}).get("username") or "")
                    self._store.update(self.agent_id, KIND, bot_username=self._bot_username or None)
                updates = self._client.get_updates(self._offset, self._timing.poll_timeout)
            except TelegramError as exc:
                if exc.kind == KIND_ABORTED or self._stop.is_set():
                    break
                if exc.kind == KIND_UNAUTHORIZED:
                    # A wrong or revoked token does not heal by waiting.
                    self._set_state(STATE_UNAUTHORIZED, "the bot token was refused")
                    return
                failures += 1
                delay = self._delay(failures)
                if exc.kind == KIND_RATE_LIMITED and exc.retry_after:
                    delay = max(delay, float(exc.retry_after))
                if exc.kind == KIND_CONFLICT:
                    self._set_state(STATE_CONFLICT, "another poller or a webhook uses this bot")
                else:
                    self._set_state(STATE_BACKOFF, exc.kind)
                self._stop.wait(delay)
                continue
            except Exception as exc:  # noqa: BLE001 — the poller must survive anything
                failures += 1
                logger.warning("telegram: poll failed: %s", type(exc).__name__)
                self._set_state(STATE_BACKOFF, "internal")
                self._stop.wait(self._delay(failures))
                continue
            failures = 0
            self._set_state(STATE_POLLING)
            start_offset = self._offset
            for update in updates:
                if self._stop.is_set():
                    break
                update_id = update.get("update_id") if isinstance(update, dict) else None
                if isinstance(update_id, int):
                    self._offset = max(self._offset, update_id + 1)
                try:
                    self._handle(update)
                except Exception as exc:  # noqa: BLE001 — one bad update costs only itself
                    logger.warning("telegram: update failed: %s", type(exc).__name__)
            if self._offset != start_offset:
                self._store.update(self.agent_id, KIND, offset=self._offset)

    def _prune(self, now: float) -> None:
        for chat_id in [c for c, p in self._pending.items() if p.expires_at <= now]:
            self._pending.pop(chat_id, None)

    def _handle(self, update: dict) -> None:
        message = update.get("message") if isinstance(update, dict) else None
        if not isinstance(message, dict):
            return
        chat = message.get("chat") if isinstance(message.get("chat"), dict) else {}
        chat_id = chat.get("id")
        sender = message.get("from") if isinstance(message.get("from"), dict) else {}
        if not isinstance(chat_id, int) or sender.get("is_bot"):
            return
        if self._linked_chat is not None and chat_id == self._linked_chat:
            self._inbound(chat_id, message)
            return
        if self._linked_chat is None and chat.get("type") == "private":
            self._offer_link(chat_id, sender)
            return
        self._refuse(chat_id)

    def _offer_link(self, chat_id: int, sender: dict) -> None:
        now = self._clock()
        with self._lock:
            self._prune(now)
            pending = self._pending.get(chat_id)
            if pending is not None:
                if now - pending.sent_at < CODE_RESEND_INTERVAL:
                    return
                pending.sent_at = now
            elif len(self._pending) >= MAX_PENDING_LINKS:
                pending = None
            else:
                taken = {p.code for p in self._pending.values()}
                code = f"{secrets.randbelow(1_000_000):06d}"
                while code in taken:
                    code = f"{secrets.randbelow(1_000_000):06d}"
                username = sender.get("username")
                name = f"@{username}" if isinstance(username, str) and username else str(
                    sender.get("first_name") or ""
                )[:64]
                pending = _Pending(
                    code=code, expires_at=now + self._timing.link_ttl, name=name, sent_at=now
                )
                self._pending[chat_id] = pending
        if pending is None:
            self._refuse(chat_id)
            return
        minutes = max(1, int(round(self._timing.link_ttl / 60)))
        self._queue_text(
            chat_id,
            TEXT_LINK_OFFER.format(label=self._label(), code=pending.code, minutes=minutes),
        )
        self._on_change(self.agent_id)

    def _refuse(self, chat_id: int) -> None:
        now = self._clock()
        with self._lock:
            last = self._refused.get(chat_id)
            if last is not None and now - last < REFUSAL_INTERVAL:
                return
            if len(self._refused) > 1000:
                self._refused.clear()
            self._refused[chat_id] = now
        self._queue_text(chat_id, TEXT_REFUSAL)

    def _inbound(self, chat_id: int, message: dict) -> None:
        text = message.get("text") if isinstance(message.get("text"), str) else message.get("caption")
        if not isinstance(text, str) or not text.strip():
            self._queue_text(chat_id, TEXT_TEXT_ONLY)
            return
        command = text.strip().split()[0].split("@")[0].lower()
        if command == "/start":
            self._queue_text(chat_id, TEXT_LINKED_START.format(label=self._label()))
            return
        # Submitted under the lock: a run that ends at once blocks in
        # ``on_run_finished`` until its run id is known here.
        with self._lock:
            try:
                run_id = self._submit(
                    self.agent_id, f"{PROMPT_MARKER}\n{text.strip()}", {"origin": ORIGIN}
                )
            except Exception as exc:  # noqa: BLE001 — tell the user instead of going silent
                logger.warning("telegram: submit failed: %s", type(exc).__name__)
                run_id = None
            if run_id:
                self._runs[str(run_id)] = chat_id
        if not run_id:
            self._queue_text(chat_id, TEXT_NOT_READY)
            return
        # Show "typing" right away; the sender refreshes it while the run lives.
        self._outbox.put(_Outbound(chat_id=chat_id))

    # -- the sender -------------------------------------------------------------

    def _queue_text(self, chat_id: int, text: str) -> None:
        for chunk in split_text(text) or [text]:
            self._outbox.put(_Outbound(chat_id=chat_id, text=chunk))

    def _send_loop(self) -> None:
        while not self._stop.is_set():
            try:
                job = self._outbox.get(timeout=self._timing.typing_interval)
            except queue.Empty:
                self._refresh_typing()
                continue
            if job is None or self._stop.is_set():
                break
            try:
                self._deliver(job)
            except TelegramError as exc:
                if exc.kind == KIND_ABORTED:
                    break
                if exc.kind == KIND_UNAUTHORIZED:
                    self._set_state(STATE_UNAUTHORIZED, "the bot token was refused")
                logger.warning("telegram: send failed: %s", exc.kind)
            except Exception as exc:  # noqa: BLE001 — the sender must survive anything
                logger.warning("telegram: send failed: %s", type(exc).__name__)

    def _refresh_typing(self) -> None:
        with self._lock:
            chats = set(self._runs.values())
        for chat_id in chats:
            try:
                self._client.send_chat_action(chat_id, "typing")
            except TelegramError:
                pass

    def _pace(self, chat_id: int) -> None:
        last = self._last_sent.get(chat_id)
        if last is not None:
            wait = self._timing.send_interval - (time.monotonic() - last)
            if wait > 0:
                self._stop.wait(wait)
        self._last_sent[chat_id] = time.monotonic()

    def _with_retry(self, call: Callable[[], Any]) -> Any:
        failures = 0
        while True:
            try:
                return call()
            except TelegramError as exc:
                if exc.kind in (KIND_ABORTED, KIND_UNAUTHORIZED, KIND_BAD_REQUEST):
                    raise
                failures += 1
                if failures >= SEND_RETRIES or self._stop.is_set():
                    raise
                delay = self._delay(failures)
                if exc.kind == KIND_RATE_LIMITED and exc.retry_after:
                    delay = max(delay, float(exc.retry_after))
                self._stop.wait(delay)

    def _deliver(self, job: _Outbound) -> None:
        chat_id = job.chat_id
        if job.text is None and job.file is None:
            self._client.send_chat_action(chat_id, "typing")
            return
        self._pace(chat_id)
        if job.file is not None:
            self._deliver_file(chat_id, job.file)
            return
        text = job.text or ""
        if job.markdown:
            rendered = markdown_to_html(text)
            if len(rendered) <= TELEGRAM_MAX_CHARS:
                try:
                    self._with_retry(
                        lambda: self._client.send_message(chat_id, rendered, parse_mode="HTML")
                    )
                    return
                except TelegramError as exc:
                    if exc.kind != KIND_BAD_REQUEST:
                        raise
                    # Telegram refused the markup: the same text, plain.
        for piece in split_text(text, TELEGRAM_MAX_CHARS) or [text]:
            self._with_retry(lambda piece=piece: self._client.send_message(chat_id, piece))

    def _deliver_file(self, chat_id: int, item: dict) -> None:
        name = str(item.get("name") or "file")
        mime = str(item.get("mime_type") or "application/octet-stream")
        data = item.get("data")
        if not isinstance(data, (bytes, bytearray)) or not data:
            return
        if mime in _PHOTO_TYPES and len(data) <= _PHOTO_MAX_BYTES:
            try:
                self._with_retry(lambda: self._client.send_photo(chat_id, name, bytes(data), mime))
                return
            except TelegramError as exc:
                if exc.kind != KIND_BAD_REQUEST:
                    raise
                # Not a photo Telegram accepts (size, ratio): send it as a file.
        self._with_retry(lambda: self._client.send_document(chat_id, name, bytes(data), mime))


__all__ = [
    "KIND",
    "ORIGIN",
    "PROMPT_MARKER",
    "STATE_BACKOFF",
    "STATE_CONFLICT",
    "STATE_POLLING",
    "STATE_STARTING",
    "STATE_STOPPED",
    "STATE_UNAUTHORIZED",
    "TelegramChannel",
    "TelegramTiming",
]
