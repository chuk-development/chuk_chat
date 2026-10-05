"""The host's channel manager: one Telegram channel per opted-in coworker.

The host builds one :class:`ChannelManager` at start. It starts a
:class:`~chuk_agents_host.channels.telegram.TelegramChannel` for every
coworker whose record says ``enabled`` and stops them all with the host.

The app drives it with two sealed frames, on the same hook as the
``agent_permissions_*`` frames:

App -> host::

    {"type": "agent_channel_get", "agent_id": "<id>", "channel": "telegram"}
    {"type": "agent_channel_set", "agent_id": "<id>", "channel": "telegram",
     "action": "enable", "token": "<bot token>"?}
    {"type": "agent_channel_set", ..., "action": "disable" | "forget" | "unlink"}
    {"type": "agent_channel_set", ..., "action": "link", "code": "123456"}

Host -> app (the answer to both, and pushed unprompted when the state moves,
e.g. a link code was sent or the token was refused)::

    {"type": "agent_channel", "agent_id": "<id>", "channel": "telegram",
     "enabled": bool, "allowed": bool, "has_token": bool, "e2e": false,
     "state": "off" | "disallowed" | "starting" | "polling" | "backoff"
              | "conflict" | "unauthorized" | "stopped",
     "bot_username": "<name>", "linked": bool, "linked_name": "<name>",
     "pending_link": bool, "pending_link_expires_at": <epoch s>?,
     "error": "<code>"?}

The token goes host-ward once and never comes back; the reply says only
``has_token``. ``e2e`` is always ``false``: the app must say so next to the
switch.
"""

from __future__ import annotations

import json
import logging
import re
import sqlite3
import threading
from collections.abc import Callable
from dataclasses import dataclass, field

from .store import ChannelStore
from .telegram import KIND, ORIGIN, TelegramChannel, TelegramTiming
from .telegram_api import TelegramClient

logger = logging.getLogger(__name__)

FRAME_GET = "agent_channel_get"
FRAME_SET = "agent_channel_set"
FRAME_REPLY = "agent_channel"
FRAMES = (FRAME_GET, FRAME_SET)
#: ``host_route.capabilities``: the app sends the channel frames only to a host
#: that names this.
CAPABILITY = "agent_channels"
CHANNELS = (KIND,)

ACTIONS = ("enable", "disable", "forget", "link", "unlink")

#: The shape @BotFather hands out: ``<bot id>:<secret>``.
_TOKEN_RE = re.compile(r"^\d{5,16}:[A-Za-z0-9_-]{30,64}$")


@dataclass(frozen=True)
class ChannelSettings:
    """The host-wide bounds (``[channels]`` in ``config.toml``)."""

    telegram_allowed: bool = True
    telegram_api_base: str = "https://api.telegram.org"
    telegram_poll_timeout: int = 25
    telegram_link_ttl: int = 600
    timing: TelegramTiming | None = field(default=None, compare=False)

    @classmethod
    def from_config(cls) -> "ChannelSettings":
        """Read ``[channels]`` (argument > environment > file > default). A
        broken config file falls back to the defaults: the channel must not
        keep the host from starting."""
        try:
            from chuk_agents_config import load_config

            section = load_config().channels
        except Exception as exc:  # noqa: BLE001
            logger.warning("channels: config not readable, defaults used: %s", type(exc).__name__)
            return cls()
        return cls(
            telegram_allowed=bool(section.telegram_allowed),
            telegram_api_base=str(section.telegram_api_base or cls.telegram_api_base),
            telegram_poll_timeout=max(0, int(section.telegram_poll_timeout)),
            telegram_link_ttl=max(60, int(section.telegram_link_ttl)),
        )

    def telegram_timing(self) -> TelegramTiming:
        if self.timing is not None:
            return self.timing
        return TelegramTiming(
            poll_timeout=self.telegram_poll_timeout, link_ttl=float(self.telegram_link_ttl)
        )


def _row_text(raw: object) -> str:
    """The text of a stored user row (``{"role", "content": str | parts}``)."""
    try:
        data = json.loads(raw) if isinstance(raw, str) else raw
    except ValueError:
        return str(raw or "")
    content = data.get("content") if isinstance(data, dict) else data
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(
            str(part.get("text") or "") for part in content if isinstance(part, dict)
        )
    return ""


def read_run_files(db_path: str, summary: dict) -> list[dict]:
    """The files a run sent with ``send_file_to_user``, from the executor's
    store: ``[{"name", "mime_type", "data": bytes}]``.

    The ``file`` event rows of the run's window (``first_mid < id <= last_mid``),
    starting at the run's own user row, so a run queued behind another one
    does not pick up that run's files. Read only."""
    run_id = str(summary.get("run_id") or "")
    if not run_id or not db_path:
        return []
    conn = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=5)
    try:
        conn.row_factory = sqlite3.Row
        run = conn.execute(
            "SELECT session_id, first_mid, last_mid FROM runs WHERE run_id=?", (run_id,)
        ).fetchone()
        if run is None:
            return []
        low = int(run["first_mid"] or 0)
        high = run["last_mid"]
        sql = "SELECT id, role, content FROM messages WHERE session_id=? AND id>?"
        params: list = [run["session_id"], low]
        if high is not None:
            sql += " AND id<=?"
            params.append(int(high))
        rows = conn.execute(sql + " ORDER BY id", params).fetchall()
        prompt = str(summary.get("prompt") or "")
        start = 0
        for index, row in enumerate(rows):
            if row["role"] == "user" and prompt and prompt in _row_text(row["content"]):
                start = index
                break
        out: list[dict] = []
        for row in rows[start:]:
            if row["role"] != "event":
                continue
            try:
                event = json.loads(row["content"])
            except ValueError:
                continue
            if not isinstance(event, dict) or event.get("type") != "file":
                continue
            blob = conn.execute(
                "SELECT data FROM event_blobs WHERE message_id=?", (row["id"],)
            ).fetchone()
            if blob is None or not blob["data"]:
                continue
            out.append(
                {
                    "name": str(event.get("name") or "file"),
                    "mime_type": str(event.get("mime_type") or "application/octet-stream"),
                    "data": bytes(blob["data"]),
                }
            )
        return out
    finally:
        conn.close()


class ChannelManager:
    """Every coworker's channel on this host."""

    def __init__(
        self,
        *,
        store: ChannelStore,
        submit: Callable[[str, str, dict], str | None],
        key_for: Callable[[str], str | None],
        label_for: Callable[[str], str] = lambda _key: "your coworker",
        scrub: Callable[[str], str] = lambda text: text,
        db_path: str | None = None,
        send_payload: Callable[[dict], object] = lambda _payload: False,
        settings: ChannelSettings | None = None,
        client_factory: Callable[..., TelegramClient] = TelegramClient,
        logger_fn: Callable[[str], None] | None = None,
    ) -> None:
        self._store = store
        self._submit = submit
        self._key_for = key_for
        self._label_for = label_for
        self._scrub = scrub
        self._db_path = db_path
        self._send_payload = send_payload
        self._settings = settings or ChannelSettings()
        self._client_factory = client_factory
        self._log = logger_fn or (lambda _msg: None)
        self._lock = threading.RLock()
        self._channels: dict[str, TelegramChannel] = {}
        self._stopped = False

    # -- lifecycle ------------------------------------------------------------

    def start(self) -> None:
        """Start the channel of every coworker that has one turned on."""
        if not self._settings.telegram_allowed:
            if self._store.all(KIND):
                self._log("[channels] telegram is forbidden on this host; no poller started")
            return
        for key, record in self._store.all(KIND).items():
            if record.get("enabled") and record.get("token"):
                self._start(key, str(record["token"]))

    def stop(self) -> None:
        with self._lock:
            self._stopped = True
            channels = list(self._channels.values())
            self._channels.clear()
        for channel in channels:
            channel.stop()

    def _start(self, key: str, token: str) -> None:
        with self._lock:
            if self._stopped:
                return
            old = self._channels.pop(key, None)
        if old is not None:
            old.stop()
        try:
            channel = TelegramChannel(
                agent_id=key,
                token=token,
                store=self._store,
                submit=self._submit,
                label=lambda key=key: self._label_for(key),
                scrub=self._scrub,
                read_files=self._read_files,
                on_change=self._push,
                api_base=self._settings.telegram_api_base,
                timing=self._settings.telegram_timing(),
                client_factory=self._client_factory,
            )
        except ValueError as exc:
            self._log(f"[channels] telegram not started: {exc}")
            return
        with self._lock:
            if self._stopped:
                return
            self._channels[key] = channel
        channel.start()
        self._log("[channels] telegram poller started for one coworker")

    def _stop_one(self, key: str) -> None:
        with self._lock:
            channel = self._channels.pop(key, None)
        if channel is not None:
            channel.stop()

    def _read_files(self, summary: dict) -> list[dict]:
        if not self._db_path:
            return []
        return read_run_files(self._db_path, summary)

    # -- the host's run hook ------------------------------------------------------

    def on_run_finished(self, summary: dict) -> bool:
        """Route a finished run to the channel that started it. True if one did."""
        if not isinstance(summary, dict) or summary.get("origin") != ORIGIN:
            return False
        with self._lock:
            channels = list(self._channels.values())
        for channel in channels:
            if channel.on_run_finished(summary):
                return True
        return False

    # -- status ---------------------------------------------------------------------

    def status(self, key: str, *, agent_id: str | None = None) -> dict:
        record = self._store.get(key, KIND)
        with self._lock:
            channel = self._channels.get(key)
        enabled = bool(record.get("enabled"))
        reply: dict = {
            "type": FRAME_REPLY,
            "agent_id": agent_id if agent_id is not None else key,
            "channel": KIND,
            "enabled": enabled,
            "allowed": self._settings.telegram_allowed,
            "has_token": bool(record.get("token")),
            "e2e": False,
            "state": "off",
            "bot_username": str(record.get("bot_username") or ""),
            "linked": isinstance(record.get("chat_id"), int),
            "linked_name": str(record.get("linked_name") or ""),
            "pending_link": False,
        }
        if enabled and not self._settings.telegram_allowed:
            reply["state"] = "disallowed"
        elif channel is not None:
            reply.update(channel.status())
        elif enabled:
            reply["state"] = "stopped"
        return reply

    def _push(self, key: str) -> None:
        try:
            self._send_payload(self.status(key))
        except Exception as exc:  # noqa: BLE001 — a push must never break a poller
            self._log(f"[channels] could not push the channel state: {type(exc).__name__}")

    # -- the app's frames ------------------------------------------------------------

    def handle_frame(self, payload: dict) -> dict:
        """Answer ``agent_channel_get`` / ``agent_channel_set``. Never raises."""
        agent_id = payload.get("agent_id") if isinstance(payload, dict) else None
        agent_id = agent_id if isinstance(agent_id, str) else ""
        failure = {"type": FRAME_REPLY, "agent_id": agent_id, "channel": KIND, "e2e": False}
        channel_kind = payload.get("channel", KIND) if isinstance(payload, dict) else KIND
        if channel_kind not in CHANNELS:
            return {**failure, "error": "unknown_channel"}
        key = self._key_for(agent_id) if agent_id else None
        if key is None:
            return {**failure, "error": "unknown_agent"}
        if payload.get("type") == FRAME_GET:
            return self.status(key, agent_id=agent_id)
        action = payload.get("action")
        if action not in ACTIONS:
            return {**self.status(key, agent_id=agent_id), "error": "unknown_action"}
        try:
            error = getattr(self, f"_action_{action}")(key, payload)
        except Exception as exc:  # noqa: BLE001 — the serve loop must survive a bad frame
            self._log(f"[channels] {action} failed: {type(exc).__name__}")
            error = "internal"
        reply = self.status(key, agent_id=agent_id)
        if error:
            reply["error"] = error
        return reply

    def _action_enable(self, key: str, payload: dict) -> str:
        token = payload.get("token")
        record = self._store.get(key, KIND)
        if token is None or token == "":
            token = record.get("token")
            if not token:
                return "token_required"
        if not isinstance(token, str) or not _TOKEN_RE.match(token.strip()):
            return "token_invalid"
        token = token.strip()
        for other, other_record in self._store.all(KIND).items():
            if other != key and other_record.get("token") == token:
                return "token_in_use"
        fields: dict = {"enabled": True, "token": token}
        if record.get("token") != token:
            # A new bot: the old link, offset and name belong to the old one.
            fields.update(chat_id=None, linked_name=None, offset=None, bot_username=None)
        self._store.update(key, KIND, **fields)
        if not self._settings.telegram_allowed:
            return "disallowed"
        self._start(key, token)
        return ""

    def _action_disable(self, key: str, _payload: dict) -> str:
        self._stop_one(key)
        if self._store.get(key, KIND):
            self._store.update(key, KIND, enabled=False)
        return ""

    def _action_forget(self, key: str, _payload: dict) -> str:
        self._stop_one(key)
        self._store.remove(key, KIND)
        return ""

    def _action_unlink(self, key: str, _payload: dict) -> str:
        with self._lock:
            channel = self._channels.get(key)
        if channel is not None:
            channel.unlink()
        elif self._store.get(key, KIND):
            self._store.update(key, KIND, chat_id=None, linked_name=None)
        return ""

    def _action_link(self, key: str, payload: dict) -> str:
        with self._lock:
            channel = self._channels.get(key)
        if channel is None:
            return "not_running"
        ok, error = channel.link(payload.get("code"))
        return "" if ok else error


__all__ = [
    "ACTIONS",
    "CAPABILITY",
    "ChannelManager",
    "ChannelSettings",
    "FRAMES",
    "FRAME_GET",
    "FRAME_REPLY",
    "FRAME_SET",
    "read_run_files",
]
