"""The Telegram gateway (CHAT-184, docs/agents/GATEWAYS.md).

Long polling (``getUpdates``) on one thread, an outbox on a second thread.

- Only paired Telegram user ids may talk, and only in a private chat with the
  bot. A user pairs with ``/pair <code>``; the code comes from
  ``agents-host telegram pair`` (or :meth:`TelegramGateway.new_pairing_code`).
  An unknown sender gets one short refusal per hour, and all refusals together
  are capped per minute.
- A chat talks to one agent at a time. Each (chat, agent) pair has one stable
  thread on the host, ``<agent>#auto-telegram-<token>``, so the history
  continues and the app shows it as a chat of that agent. ``/agent <name>``
  switches the agent, ``/new`` starts a new thread, ``/stop`` stops the run.
- A message becomes a normal run through the same executor as an app task
  (``submit_task``, ``origin: telegram``). The answer streams into one message
  that is edited at most every :data:`EDIT_INTERVAL` seconds; the final answer
  is split at 4096 characters.
- An approval appears as inline buttons (Allow once / Always / Skip). A
  button answers through the same path as the app's ``approval_decision``.
- A photo or a document is saved in the agent workspace under
  ``telegram/`` and named in the task. A ``file`` event of the run goes back
  as a document.
"""

from __future__ import annotations

import base64
import binascii
import collections
import os
import queue
import secrets
import threading
import time
from dataclasses import dataclass
from typing import Any, Callable

from .base import Gateway, GatewayHost, gateway_session_key, split_message
from .store import GatewayStore
from .telegram_api import (
    MAX_DOWNLOAD_BYTES,
    MAX_MESSAGE_CHARS,
    TelegramApiError,
    TelegramBotApi,
)

NAME = "telegram"
ORIGIN = "telegram"
#: The host secret (vault) that may hold the bot token. The sealed token file
#: from ``agents-host telegram token`` wins over it.
TOKEN_SECRET_NAME = "TELEGRAM_BOT_TOKEN"

#: Seconds between two edits of one streamed message. Telegram allows about
#: one message per second per chat; edits count.
EDIT_INTERVAL = 1.5
#: Seconds between two "typing" actions while a run works.
TYPING_INTERVAL = 4.5
#: One refusal per unknown user per this many seconds.
REFUSAL_INTERVAL = 3600.0
#: All refusals together, per minute.
MAX_REFUSALS_PER_MINUTE = 20
#: Wrong pairing codes per user per window before the bot stops listening.
MAX_PAIR_FAILURES = 5
PAIR_FAILURE_WINDOW = 600.0
#: How many finished run ids :meth:`owns_run` remembers.
FINISHED_MEMORY = 256
#: The sub-directory of the agent workspace that takes incoming files.
INBOX_DIR = "telegram"

REFUSAL_TEXT = "This bot is private."
NOT_READY_TEXT = (
    "The Agents host is not ready yet. Open the Agents app once, then try again."
)
HELP_TEXT = (
    "Send a message to talk to your agent.\n"
    "/agent - list the agents, /agent <name> - talk to another agent\n"
    "/new - start a new conversation\n"
    "/stop - stop the current run"
)

_SCOPE_ONCE = "once"
_SCOPE_AGENT = "always_this_agent"
_SCOPE_SITE = "always_this_site"
_SCOPE_DENY = "deny"


@dataclass
class _Stream:
    """One run this gateway started and still shows."""

    run_id: str
    chat_id: int
    session_key: str
    message_id: int | None = None
    text: str = ""
    shown: str = ""
    dirty: bool = False
    next_edit: float = 0.0
    next_typing: float = 0.0


def _safe_file_name(raw: Any, fallback: str) -> str:
    text = str(raw or "").replace("\\", "/").rsplit("/", 1)[-1]
    text = "".join(ch for ch in text if ch.isprintable() and ch not in '<>:"|?*')
    text = text.strip().lstrip(".").strip()[:120]
    return text or fallback


class TelegramGateway(Gateway):
    name = NAME

    def __init__(
        self,
        api: TelegramBotApi,
        host: GatewayHost,
        store: GatewayStore,
        *,
        clock: Callable[[], float] = time.monotonic,
        log: Callable[[str], None] | None = None,
    ) -> None:
        self._api = api
        self._host = host
        self._store = store
        self._clock = clock
        self._log = log or (lambda _m: None)
        # Guards _streams, _approvals and _finished. Re-entrant: an executor
        # may emit an event on the submitting thread.
        self._lock = threading.RLock()
        self._streams: dict[str, _Stream] = {}
        self._approvals: dict[str, dict] = {}
        self._finished: collections.deque[str] = collections.deque(maxlen=FINISHED_MEMORY)
        self._outbox: queue.Queue = queue.Queue()
        self._submitting = 0
        self._refused: dict[str, float] = {}
        self._refusal_times: collections.deque[float] = collections.deque()
        self._pair_failures: dict[str, list[float]] = {}
        self._stop = threading.Event()
        self._threads: list[threading.Thread] = []
        self._bot_name: str | None = None
        self._last_error: str | None = None

    # -- lifecycle -------------------------------------------------------------

    def start(self) -> None:
        self._stop.clear()
        for target, label in ((self._poll_loop, "poll"), (self._outbox_loop, "outbox")):
            thread = threading.Thread(target=target, name=f"telegram-{label}", daemon=True)
            thread.start()
            self._threads.append(thread)
        self._log("[telegram] gateway started")

    def stop(self) -> None:
        self._stop.set()
        self._outbox.put(None)
        for thread in self._threads:
            thread.join(timeout=2.0)
        self._threads.clear()
        self._api.close()

    def status(self) -> dict[str, Any]:
        return {
            "gateway": NAME,
            "running": any(t.is_alive() for t in self._threads),
            "bot": self._bot_name,
            "paired_users": len(self._store.paired()),
            "last_error": self._last_error,
        }

    def owns_run(self, run_id: str) -> bool:
        with self._lock:
            return run_id in self._streams or run_id in self._finished

    def new_pairing_code(self) -> str:
        """A one-time code for ``/pair`` (the host API of the pairing)."""
        return self._store.new_pairing_code()

    # -- polling ---------------------------------------------------------------

    def _poll_loop(self) -> None:
        backoff = 1.0
        try:
            me = self._api.get_me()
            self._bot_name = str(me.get("username") or "") or None
        except TelegramApiError as exc:
            self._note_error(exc)
            if exc.code in (401, 404):
                self._log("[telegram] the bot token is not valid; the gateway stops")
                return
        while not self._stop.is_set():
            try:
                self.poll_once()
                backoff = 1.0
            except TelegramApiError as exc:
                self._note_error(exc)
                if exc.code in (401, 404):
                    self._log("[telegram] the bot token is not valid; the gateway stops")
                    return
                wait = exc.retry_after or backoff
                backoff = min(backoff * 2, 60.0)
                self._stop.wait(wait)
            except Exception as exc:  # noqa: BLE001 — the loop must live
                self._log(f"[telegram] poll failed: {type(exc).__name__}")
                self._stop.wait(backoff)
                backoff = min(backoff * 2, 60.0)

    def poll_once(self, timeout: int | None = None) -> int:
        """One ``getUpdates``; handles every update. Returns how many came."""
        updates = self._api.get_updates(self._store.offset(), timeout)
        for update in updates:
            update_id = update.get("update_id")
            try:
                self.handle_update(update)
            except Exception as exc:  # noqa: BLE001 — one bad update never blocks the next
                self._log(f"[telegram] update failed: {type(exc).__name__}")
            if isinstance(update_id, int):
                self._store.set_offset(update_id + 1)
        return len(updates)

    def _note_error(self, exc: TelegramApiError) -> None:
        self._last_error = f"{exc.method}: {exc.code} {exc.description}"
        self._log(f"[telegram] {self._last_error}")

    # -- updates -----------------------------------------------------------------

    def handle_update(self, update: dict) -> None:
        if isinstance(update.get("callback_query"), dict):
            self._handle_callback(update["callback_query"])
            return
        message = update.get("message")
        if not isinstance(message, dict):
            return
        sender = message.get("from") if isinstance(message.get("from"), dict) else {}
        chat = message.get("chat") if isinstance(message.get("chat"), dict) else {}
        user_id = sender.get("id")
        chat_id = chat.get("id")
        if not isinstance(user_id, int) or not isinstance(chat_id, int) or sender.get("is_bot"):
            return
        if chat.get("type") != "private":
            # Groups are not supported: other members would read the answers.
            return
        text = message.get("text") if isinstance(message.get("text"), str) else ""
        command, _, arg = text.strip().partition(" ")
        command = command.split("@", 1)[0].lower() if command.startswith("/") else ""
        if command == "/pair":
            self._handle_pair(chat_id, user_id, sender, arg.strip())
            return
        if not self._store.is_paired(user_id):
            self._refuse(chat_id, user_id)
            return
        if command in ("/start", "/help"):
            self._send(chat_id, HELP_TEXT)
        elif command == "/agent":
            self._handle_agent(chat_id, arg.strip())
        elif command == "/new":
            self._handle_new(chat_id)
        elif command == "/stop":
            self._handle_stop(chat_id)
        elif command:
            self._send(chat_id, "Unknown command.\n" + HELP_TEXT)
        else:
            self._handle_message(chat_id, message)

    def _handle_pair(self, chat_id: int, user_id: int, sender: dict, code: str) -> None:
        key = str(user_id)
        now = self._clock()
        failures = [t for t in self._pair_failures.get(key, []) if now - t < PAIR_FAILURE_WINDOW]
        if len(failures) >= MAX_PAIR_FAILURES:
            self._pair_failures[key] = failures
            return  # silent: no oracle for guessing
        name = " ".join(
            str(sender.get(k) or "") for k in ("first_name", "last_name")
        ).strip() or str(sender.get("username") or "")
        if code and self._store.redeem_code(code, user_id, name):
            self._pair_failures.pop(key, None)
            self._refused.pop(key, None)
            self._log(f"[telegram] paired user {user_id}")
            self._send(chat_id, "Paired. You can talk to your agent now.\n\n" + HELP_TEXT)
            return
        failures.append(now)
        self._pair_failures[key] = failures
        self._send(chat_id, "That code is not valid. Make a new one with: agents-host telegram pair")

    def _refuse(self, chat_id: int, user_id: int) -> None:
        now = self._clock()
        key = str(user_id)
        last = self._refused.get(key)
        if last is not None and now - last < REFUSAL_INTERVAL:
            return
        while self._refusal_times and now - self._refusal_times[0] > 60.0:
            self._refusal_times.popleft()
        if len(self._refusal_times) >= MAX_REFUSALS_PER_MINUTE:
            return
        self._refusal_times.append(now)
        if len(self._refused) > 10_000:
            self._refused.clear()
        self._refused[key] = now
        self._send(chat_id, REFUSAL_TEXT)

    # -- routes ----------------------------------------------------------------

    def _route(self, chat_id: int) -> dict:
        route = self._store.route(chat_id) or {}
        agent = route.get("agent") if isinstance(route.get("agent"), str) else None
        sessions = route.get("sessions") if isinstance(route.get("sessions"), dict) else {}
        if not agent:
            agent = self._host.default_agent()
        changed = route.get("agent") != agent
        if not isinstance(sessions.get(agent), str):
            sessions[agent] = gateway_session_key(agent, NAME, secrets.token_hex(4))
            changed = True
        route = {"agent": agent, "sessions": sessions}
        if changed:
            self._store.set_route(chat_id, route)
        return route

    def _agent_name(self, agent_id: str) -> str:
        for row in self._host.agents():
            if row.get("agent_id") == agent_id:
                return str(row.get("name") or agent_id)
        return agent_id

    def _handle_agent(self, chat_id: int, wanted: str) -> None:
        agents = self._host.agents()
        route = self._route(chat_id)
        if not wanted:
            lines = [
                ("* " if row.get("agent_id") == route["agent"] else "- ")
                + str(row.get("name") or row.get("agent_id"))
                for row in agents
            ]
            self._send(chat_id, "Agents:\n" + "\n".join(lines) + "\n\nSwitch with /agent <name>.")
            return
        folded = wanted.casefold()
        match = next(
            (r for r in agents if str(r.get("name") or "").casefold() == folded), None
        ) or next((r for r in agents if r.get("agent_id") == wanted), None)
        if match is None:
            self._send(chat_id, f"No agent with the name {wanted!r}. Send /agent for the list.")
            return
        agent_id = str(match["agent_id"])
        sessions = dict(route["sessions"])
        if not isinstance(sessions.get(agent_id), str):
            sessions[agent_id] = gateway_session_key(agent_id, NAME, secrets.token_hex(4))
        self._store.set_route(chat_id, {"agent": agent_id, "sessions": sessions})
        self._send(chat_id, f"You talk to {match.get('name') or agent_id} now.")

    def _handle_new(self, chat_id: int) -> None:
        route = self._route(chat_id)
        sessions = dict(route["sessions"])
        sessions[route["agent"]] = gateway_session_key(route["agent"], NAME, secrets.token_hex(4))
        self._store.set_route(chat_id, {"agent": route["agent"], "sessions": sessions})
        self._send(chat_id, f"New conversation with {self._agent_name(route['agent'])}.")

    def _handle_stop(self, chat_id: int) -> None:
        route = self._route(chat_id)
        try:
            stopped = self._host.stop(route["sessions"][route["agent"]])
        except Exception as exc:  # noqa: BLE001
            self._log(f"[telegram] stop failed: {type(exc).__name__}")
            stopped = 0
        self._send(chat_id, "Stopping." if stopped else "Nothing is running.")

    # -- a message becomes a run -----------------------------------------------

    def _handle_message(self, chat_id: int, message: dict) -> None:
        text = message.get("text") or message.get("caption") or ""
        text = text.strip() if isinstance(text, str) else ""
        has_file = isinstance(message.get("document"), dict) or isinstance(message.get("photo"), list)
        if not text and not has_file:
            self._send(chat_id, "I can read text, photos and documents.")
            return
        if not self._host.ready():
            self._send(chat_id, NOT_READY_TEXT)
            return
        route = self._route(chat_id)
        session_key = route["sessions"][route["agent"]]
        saved: list[str] = []
        if has_file:
            try:
                saved.append(self._save_incoming(session_key, message))
            except (TelegramApiError, OSError, ValueError) as exc:
                reason = exc.description if isinstance(exc, TelegramApiError) else type(exc).__name__
                self._send(chat_id, f"I could not save the file ({reason}).")
                if not text:
                    return
        prompt = text or "The user sent a file."
        if saved:
            prompt += "\n\n" + "\n".join(
                f"[Attached file, in your workspace: {path}]" for path in saved
            )
        placeholder = self._send(chat_id, "...")
        with self._lock:
            self._host.subscribe(self._on_event)
            self._submitting += 1
            try:
                run_id = self._host.submit(
                    session_key,
                    prompt,
                    {"origin": ORIGIN, "mode_session_key": route["agent"]},
                )
            except Exception as exc:  # noqa: BLE001
                self._log(f"[telegram] submit failed: {type(exc).__name__}")
                run_id = None
            if run_id:
                self._streams[str(run_id)] = _Stream(
                    run_id=str(run_id),
                    chat_id=chat_id,
                    session_key=session_key,
                    message_id=placeholder,
                    next_edit=self._clock() + EDIT_INTERVAL,
                )
            self._submitting -= 1
        if not run_id:
            self._edit_or_send(chat_id, placeholder, NOT_READY_TEXT)

    def _save_incoming(self, session_key: str, message: dict) -> str:
        """Save the photo or document into the agent workspace. Returns the
        path relative to the workspace."""
        workspace = self._host.workspace_for(session_key)
        if not workspace:
            raise ValueError("no workspace")
        document = message.get("document")
        if isinstance(document, dict):
            file_id = document.get("file_id")
            name = _safe_file_name(document.get("file_name"), "document")
            size = document.get("file_size")
        else:
            photos = [p for p in message.get("photo") or [] if isinstance(p, dict)]
            if not photos:
                raise ValueError("no photo")
            best = max(photos, key=lambda p: int(p.get("file_size") or 0) or
                       int(p.get("width") or 0) * int(p.get("height") or 0))
            file_id = best.get("file_id")
            name = "photo.jpg"
            size = best.get("file_size")
        if not isinstance(file_id, str) or not file_id:
            raise ValueError("no file id")
        if isinstance(size, int) and size > MAX_DOWNLOAD_BYTES:
            raise TelegramApiError("getFile", 413, "file too large, the limit is 20 MB")
        data = self._api.download(file_id)
        file_name = f"{time.strftime('%Y%m%d-%H%M%S')}-{secrets.token_hex(2)}-{name}"
        # The agent owns its workspace and could plant a symlink at
        # ``telegram``: open the inbox relative to the workspace with
        # O_NOFOLLOW, and the file with O_NOFOLLOW | O_EXCL inside it.
        root = os.open(workspace, os.O_RDONLY | os.O_DIRECTORY)
        try:
            try:
                os.mkdir(INBOX_DIR, 0o755, dir_fd=root)
            except FileExistsError:
                pass
            inbox = os.open(INBOX_DIR, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=root)
            try:
                fd = os.open(
                    file_name,
                    os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                    # The sandbox user must read it (as in the app inbox).
                    0o644,
                    dir_fd=inbox,
                )
                with open(fd, "wb") as handle:
                    handle.write(data)
            finally:
                os.close(inbox)
        finally:
            os.close(root)
        return f"{INBOX_DIR}/{file_name}"

    # -- events from the executor (any thread) ------------------------------

    def _on_event(self, payload: dict) -> None:
        run_id = payload.get("run_id") if isinstance(payload, dict) else None
        if not isinstance(run_id, str):
            return
        # No lock here: this runs on an executor thread, and waiting for the
        # gateway lock there could tie the two together. A run being
        # submitted right now is not registered yet, so its events are queued
        # while ``_submitting`` is set; the outbox filters under the lock.
        if run_id in self._streams or self._submitting:
            self._outbox.put(payload)

    # -- the outbox (one thread) ----------------------------------------------

    def _outbox_loop(self) -> None:
        while not self._stop.is_set():
            try:
                self.pump(0.25)
            except Exception as exc:  # noqa: BLE001 — the loop must live
                self._log(f"[telegram] outbox failed: {type(exc).__name__}")

    def pump(self, timeout: float = 0.0) -> None:
        """Handle the queued events, then flush the streams that are due."""
        try:
            item = self._outbox.get(timeout=timeout) if timeout > 0 else self._outbox.get_nowait()
        except queue.Empty:
            item = None
        while item is not None:
            self._handle_event(item)
            try:
                item = self._outbox.get_nowait()
            except queue.Empty:
                item = None
        self._flush_streams()

    def _handle_event(self, payload: dict) -> None:
        with self._lock:
            stream = self._streams.get(str(payload.get("run_id")))
        if stream is None:
            return
        kind = payload.get("type")
        if kind == "delta" and isinstance(payload.get("text"), str):
            stream.text += payload["text"]
            stream.dirty = True
        elif kind == "approval_request":
            self._show_approval(stream, payload)
        elif kind == "file":
            self._send_file(stream, payload)
        elif kind == "done":
            self._finish(stream, payload)
        elif kind == "error":
            message = str(payload.get("message") or "unknown error")[:500]
            self._finish(stream, {"final_answer": f"The run failed: {message}"})

    def _flush_streams(self) -> None:
        now = self._clock()
        with self._lock:
            streams = list(self._streams.values())
        for stream in streams:
            if now >= stream.next_typing and not stream.dirty:
                stream.next_typing = now + TYPING_INTERVAL
                try:
                    self._api.send_chat_action(stream.chat_id)
                except TelegramApiError:
                    pass
            if not stream.dirty or now < stream.next_edit:
                continue
            preview = stream.text.strip()
            if len(preview) > MAX_MESSAGE_CHARS - 2:
                preview = "..." + preview[-(MAX_MESSAGE_CHARS - 5):]
            stream.dirty = False
            if not preview or preview == stream.shown:
                continue
            try:
                if stream.message_id is None:
                    stream.message_id = self._message_id(
                        self._api.send_message(stream.chat_id, preview)
                    )
                else:
                    self._api.edit_message_text(stream.chat_id, stream.message_id, preview)
                stream.shown = preview
                stream.next_edit = now + EDIT_INTERVAL
            except TelegramApiError as exc:
                stream.dirty = True
                stream.next_edit = now + (exc.retry_after or EDIT_INTERVAL)
                if exc.code == 400:  # "message is not modified" and friends
                    stream.dirty = False

    def _finish(self, stream: _Stream, payload: dict) -> None:
        answer = payload.get("final_answer")
        text = answer.strip() if isinstance(answer, str) else ""
        if not text:
            text = stream.text.strip()
        if not text:
            reason = payload.get("reason")
            text = f"(The run ended without an answer: {reason}.)" if reason else "(No answer.)"
        parts = split_message(text, MAX_MESSAGE_CHARS)
        self._edit_or_send(stream.chat_id, stream.message_id, parts[0])
        for part in parts[1:]:
            self._send(stream.chat_id, part)
        with self._lock:
            self._streams.pop(stream.run_id, None)
            self._finished.append(stream.run_id)
            for approval_id in [a for a, v in self._approvals.items() if v["run_id"] == stream.run_id]:
                self._approvals.pop(approval_id, None)

    # -- approvals ---------------------------------------------------------------

    def _show_approval(self, stream: _Stream, payload: dict) -> None:
        approval_id = payload.get("approval_id")
        if not isinstance(approval_id, str) or not approval_id or len(approval_id) > 48:
            return
        with self._lock:
            known = self._approvals.get(approval_id)
        if payload.get("decision"):
            # Closed (by the app, a button, a timeout or a stop): show the
            # outcome and remove the buttons.
            if known is not None:
                word = "Allowed" if payload.get("decision") == "approved" else "Not allowed"
                reason = payload.get("decision_reason")
                if reason in ("timeout", "stopped"):
                    word += f" ({reason})"
                self._edit_or_send(stream.chat_id, known["message_id"], f"{known['text']}\n\n{word}.")
                with self._lock:
                    self._approvals.pop(approval_id, None)
            return
        if known is not None:
            return
        text, buttons = self._approval_card(approval_id, payload)
        markup = {"inline_keyboard": [buttons]} if buttons else None
        try:
            message_id = self._message_id(self._api.send_message(stream.chat_id, text, markup))
        except TelegramApiError as exc:
            self._note_error(exc)
            return
        with self._lock:
            self._approvals[approval_id] = {
                "chat_id": stream.chat_id,
                "message_id": message_id,
                "run_id": stream.run_id,
                "options": [o for o in payload.get("options") or [] if isinstance(o, str)],
                "text": text,
            }

    @staticmethod
    def _approval_card(approval_id: str, payload: dict) -> tuple[str, list[dict]]:
        action = payload.get("action")
        options = [o for o in payload.get("options") or [] if isinstance(o, str)]

        def button(label: str, code: str) -> dict:
            return {"text": label, "callback_data": f"ap:{approval_id}:{code}"}

        if action == "browser_takeover":
            site = payload.get("site") or "a website"
            return (
                f"The agent needs you in its browser ({payload.get('kind') or 'a step'} on {site}). "
                "Open the Agents app to do it.",
                [button("Skip", "s")],
            )
        if action == "plan_review":
            plan = str(payload.get("plan") or payload.get("summary") or "")[:3000]
            return (
                "The agent has a plan for review." + (f"\n\n{plan}" if plan else ""),
                [button("Approve", "o"), button("Keep planning", "s")],
            )
        if action == "herenow_publish" and not payload.get("summary"):
            what = (
                f"Publish {payload.get('name') or payload.get('path') or 'files'} "
                f"({payload.get('file_count') or 0} files) to {payload.get('base_url') or 'the web'}"
            )
        else:
            what = str(payload.get("summary") or payload.get("tool") or "an action")
        lines = [f"Approval needed: {what[:1500]}"]
        if payload.get("site"):
            lines.append(f"Site: {payload['site']}")
        buttons = [button("Allow once", "o")]
        if _SCOPE_AGENT in options or _SCOPE_SITE in options:
            buttons.append(button("Always", "a"))
        buttons.append(button("Skip", "s"))
        return "\n".join(lines), buttons

    def _handle_callback(self, query: dict) -> None:
        query_id = query.get("id")
        sender = query.get("from") if isinstance(query.get("from"), dict) else {}
        user_id = sender.get("id")
        data = query.get("data") if isinstance(query.get("data"), str) else ""
        if not isinstance(query_id, str):
            return
        if not isinstance(user_id, int) or not self._store.is_paired(user_id):
            self._answer_callback(query_id, None)
            return
        prefix, _, rest = data.partition(":")
        approval_id, _, code = rest.rpartition(":")
        with self._lock:
            known = self._approvals.get(approval_id) if prefix == "ap" else None
        message = query.get("message") if isinstance(query.get("message"), dict) else {}
        chat = message.get("chat") if isinstance(message.get("chat"), dict) else {}
        if known is None or chat.get("id") != known["chat_id"] or code not in ("o", "a", "s"):
            self._answer_callback(query_id, "This request is closed.")
            return
        if code == "o":
            approved, scope = True, _SCOPE_ONCE
        elif code == "a":
            options = known["options"]
            approved = True
            scope = _SCOPE_AGENT if _SCOPE_AGENT in options else (
                _SCOPE_SITE if _SCOPE_SITE in options else _SCOPE_ONCE
            )
        else:
            approved, scope = False, _SCOPE_DENY
        try:
            self._host.resolve_approval(approval_id, approved, scope)
        except Exception as exc:  # noqa: BLE001
            self._log(f"[telegram] approval answer failed: {type(exc).__name__}")
            self._answer_callback(query_id, "That did not work.")
            return
        self._answer_callback(query_id, "Allowed." if approved else "Skipped.")

    def _answer_callback(self, query_id: str, text: str | None) -> None:
        try:
            self._api.answer_callback_query(query_id, text)
        except TelegramApiError:
            pass

    # -- files out ---------------------------------------------------------------

    def _send_file(self, stream: _Stream, payload: dict) -> None:
        data_b64 = payload.get("data")
        if not isinstance(data_b64, str):
            return
        try:
            data = base64.b64decode(data_b64, validate=True)
        except (binascii.Error, ValueError):
            return
        name = _safe_file_name(payload.get("name"), "file")
        try:
            self._api.send_document(
                stream.chat_id, name, data, str(payload.get("mime_type") or "application/octet-stream")
            )
        except TelegramApiError as exc:
            self._note_error(exc)
            self._send(stream.chat_id, f"I could not send the file {name} ({exc.description}).")

    # -- small helpers -----------------------------------------------------------

    @staticmethod
    def _message_id(result: Any) -> int | None:
        if isinstance(result, dict) and isinstance(result.get("message_id"), int):
            return result["message_id"]
        return None

    def _send(self, chat_id: int, text: str) -> int | None:
        try:
            return self._message_id(self._api.send_message(chat_id, text))
        except TelegramApiError as exc:
            self._note_error(exc)
            return None

    def _edit_or_send(self, chat_id: int, message_id: int | None, text: str) -> None:
        if message_id is not None:
            try:
                self._api.edit_message_text(chat_id, message_id, text)
                return
            except TelegramApiError as exc:
                if exc.code == 400 and "not modified" in exc.description:
                    return
        self._send(chat_id, text)
