"""A small Telegram Bot API client on the standard library.

No third-party HTTP stack: the host already has many dependencies, and the
Bot API is plain HTTPS with JSON bodies and one multipart upload. Every call
opens its own connection, so the poller's long poll and the sender's uploads
never share a socket, and :meth:`TelegramClient.abort` can cut a long poll at
once when the host stops.

The bot token is part of every request path (``/bot<token>/<method>``). It
never appears in an exception, a log line or a return value: errors carry the
HTTP status and Telegram's ``description`` only.
"""

from __future__ import annotations

import http.client
import json
import socket
import ssl
import threading
import uuid
from typing import Any
from urllib.parse import urlsplit

#: A neutral agent string. No user, host or contact data in it.
USER_AGENT = "agents-host-channels/1.0"

# The kinds of failure the poller and the sender tell apart.
KIND_NETWORK = "network"  # no answer: DNS, refused, reset, timeout
KIND_UNAUTHORIZED = "unauthorized"  # 401 / 404: the token is wrong or revoked
KIND_CONFLICT = "conflict"  # 409: a webhook is set, or a second poller runs
KIND_RATE_LIMITED = "rate_limited"  # 429: wait ``retry_after`` seconds
KIND_BAD_REQUEST = "bad_request"  # 400: this request is wrong (e.g. bad markup)
KIND_SERVER = "server"  # 5xx: Telegram's side, retry later
KIND_ABORTED = "aborted"  # the host stopped the client


class TelegramError(Exception):
    """A failed Bot API call. Never carries the token or the URL."""

    def __init__(
        self,
        kind: str,
        *,
        status: int = 0,
        description: str = "",
        retry_after: float | None = None,
    ) -> None:
        super().__init__(f"{kind} ({status}): {description}" if status else kind)
        self.kind = kind
        self.status = status
        self.description = description
        self.retry_after = retry_after


def _kind_for(status: int) -> str:
    if status in (401, 404):
        return KIND_UNAUTHORIZED
    if status == 409:
        return KIND_CONFLICT
    if status == 429:
        return KIND_RATE_LIMITED
    if status >= 500:
        return KIND_SERVER
    return KIND_BAD_REQUEST


#: The only hosts a plain-http Bot API base may name (a local test server).
_LOOPBACK_HOSTS = frozenset({"127.0.0.1", "localhost", "::1"})


class TelegramClient:
    """One bot's view of the Bot API."""

    def __init__(self, token: str, *, base_url: str = "https://api.telegram.org") -> None:
        if not isinstance(token, str) or not token.strip():
            raise ValueError("a bot token is required")
        parts = urlsplit(base_url.rstrip("/"))
        if parts.scheme not in ("https", "http") or not parts.hostname:
            raise ValueError("the Bot API base must be an http(s) URL")
        if parts.scheme == "http" and parts.hostname.lower() not in _LOOPBACK_HOSTS:
            # The token is in every request path: plain http would send it
            # in clear text over the network. Only a local test server may
            # use it.
            raise ValueError("the Bot API base must use https unless it is a loopback host")
        self._token = token.strip()
        self._scheme = parts.scheme
        self._host = parts.hostname
        self._port = parts.port
        self._prefix = parts.path or ""
        self._lock = threading.Lock()
        self._live: set[http.client.HTTPConnection] = set()
        self._aborted = False

    # -- the methods the channel uses ---------------------------------------

    def get_me(self) -> dict:
        return self.call("getMe", {}, timeout=15)

    def get_updates(self, offset: int, timeout: int) -> list[dict]:
        result = self.call(
            "getUpdates",
            {"offset": offset, "timeout": max(0, int(timeout)), "allowed_updates": ["message"]},
            timeout=max(0, int(timeout)) + 15,
        )
        return result if isinstance(result, list) else []

    def send_message(self, chat_id: int, text: str, *, parse_mode: str | None = None) -> dict:
        params: dict[str, Any] = {
            "chat_id": chat_id,
            "text": text,
            "link_preview_options": {"is_disabled": True},
        }
        if parse_mode:
            params["parse_mode"] = parse_mode
        return self.call("sendMessage", params, timeout=30)

    def send_chat_action(self, chat_id: int, action: str = "typing") -> None:
        self.call("sendChatAction", {"chat_id": chat_id, "action": action}, timeout=15)

    def send_document(self, chat_id: int, name: str, data: bytes, mime_type: str) -> dict:
        return self._upload("sendDocument", "document", chat_id, name, data, mime_type)

    def send_photo(self, chat_id: int, name: str, data: bytes, mime_type: str) -> dict:
        return self._upload("sendPhoto", "photo", chat_id, name, data, mime_type)

    # -- lifecycle ------------------------------------------------------------

    def abort(self) -> None:
        """Cut every open call now. Later calls fail with ``aborted``."""
        with self._lock:
            self._aborted = True
            live = list(self._live)
        for conn in live:
            sock = getattr(conn, "sock", None)
            try:
                if sock is not None:
                    sock.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            try:
                conn.close()
            except Exception:  # noqa: BLE001 — closing is best effort
                pass

    # -- the wire ---------------------------------------------------------------

    def call(self, method: str, params: dict | None = None, *, timeout: float = 30) -> Any:
        body = json.dumps(params or {}).encode("utf-8")
        return self._request(method, body, "application/json", timeout)

    def _upload(
        self, method: str, field: str, chat_id: int, name: str, data: bytes, mime_type: str
    ) -> dict:
        boundary = uuid.uuid4().hex
        safe_name = (name or "file").replace('"', "'").replace("\r", " ").replace("\n", " ")
        chunks = [
            f"--{boundary}\r\nContent-Disposition: form-data; name=\"chat_id\"\r\n\r\n"
            f"{chat_id}\r\n".encode("utf-8"),
            (
                f"--{boundary}\r\nContent-Disposition: form-data; name=\"{field}\"; "
                f"filename=\"{safe_name}\"\r\nContent-Type: {mime_type or 'application/octet-stream'}"
                "\r\n\r\n"
            ).encode("utf-8"),
            data,
            f"\r\n--{boundary}--\r\n".encode("utf-8"),
        ]
        return self._request(
            method, b"".join(chunks), f"multipart/form-data; boundary={boundary}", 120
        )

    def _connection(self, timeout: float) -> http.client.HTTPConnection:
        if self._scheme == "https":
            return http.client.HTTPSConnection(
                self._host, self._port, timeout=timeout, context=ssl.create_default_context()
            )
        return http.client.HTTPConnection(self._host, self._port, timeout=timeout)

    def _request(self, method: str, body: bytes, content_type: str, timeout: float) -> Any:
        with self._lock:
            if self._aborted:
                raise TelegramError(KIND_ABORTED)
            conn = self._connection(timeout)
            self._live.add(conn)
        try:
            try:
                conn.request(
                    "POST",
                    f"{self._prefix}/bot{self._token}/{method}",
                    body=body,
                    headers={
                        "Content-Type": content_type,
                        "User-Agent": USER_AGENT,
                        "Accept": "application/json",
                    },
                )
                response = conn.getresponse()
                status = response.status
                raw = response.read()
            except (OSError, http.client.HTTPException) as exc:
                if self._aborted:
                    raise TelegramError(KIND_ABORTED) from None
                raise TelegramError(KIND_NETWORK, description=type(exc).__name__) from None
        finally:
            with self._lock:
                self._live.discard(conn)
            try:
                conn.close()
            except Exception:  # noqa: BLE001
                pass
        try:
            payload = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            payload = None
        if not isinstance(payload, dict):
            kind = _kind_for(status) if status >= 400 else KIND_SERVER
            raise TelegramError(kind, status=status, description="no JSON answer")
        if payload.get("ok") is True and status < 400:
            return payload.get("result")
        code = int(payload.get("error_code") or status or 0)
        params = payload.get("parameters") if isinstance(payload.get("parameters"), dict) else {}
        retry_after = params.get("retry_after")
        raise TelegramError(
            _kind_for(code),
            status=code,
            description=str(payload.get("description") or "")[:200],
            retry_after=float(retry_after) if isinstance(retry_after, (int, float)) else None,
        )


__all__ = [
    "KIND_ABORTED",
    "KIND_BAD_REQUEST",
    "KIND_CONFLICT",
    "KIND_NETWORK",
    "KIND_RATE_LIMITED",
    "KIND_SERVER",
    "KIND_UNAUTHORIZED",
    "TelegramClient",
    "TelegramError",
    "USER_AGENT",
]
