"""A small client for the Telegram Bot API over httpx (CHAT-184).

Only the methods the gateway uses. Every call is a POST to
``<base>/bot<token>/<method>``. The token is part of every URL, so nothing in
this module puts a URL, a request or an httpx exception text into an error:
:class:`TelegramApiError` carries the method, the Bot API ``error_code`` and
``description``, and ``retry_after`` for a 429.
"""

from __future__ import annotations

import json
from typing import Any

import httpx

API_BASE = "https://api.telegram.org"
#: Telegram's limit for one text message.
MAX_MESSAGE_CHARS = 4096
#: Telegram's limit for a file a bot downloads with getFile.
MAX_DOWNLOAD_BYTES = 20 * 1024 * 1024
#: Telegram's limit for a file a bot uploads.
MAX_UPLOAD_BYTES = 50 * 1024 * 1024


class TelegramApiError(Exception):
    """A failed Bot API call. ``code`` is the Bot API ``error_code`` (0 for a
    network failure); ``retry_after`` is set for a 429."""

    def __init__(self, method: str, code: int, description: str, retry_after: float | None = None):
        self.method = method
        self.code = int(code)
        self.description = str(description)[:300]
        self.retry_after = retry_after
        super().__init__(f"{method}: {self.code} {self.description}")


class TelegramBotApi:
    def __init__(
        self,
        token: str,
        *,
        client: httpx.Client | None = None,
        base_url: str = API_BASE,
        poll_timeout: int = 25,
    ) -> None:
        if not token or "/" in token or any(ch.isspace() for ch in token):
            raise ValueError("not a bot token")
        self._token = token
        self._base = base_url.rstrip("/")
        self.poll_timeout = int(poll_timeout)
        # The read timeout must be longer than the long-poll wait.
        self._client = client or httpx.Client(
            timeout=httpx.Timeout(connect=10.0, read=poll_timeout + 15.0, write=30.0, pool=10.0)
        )

    def __repr__(self) -> str:  # never the token
        return "TelegramBotApi(<token hidden>)"

    def close(self) -> None:
        try:
            self._client.close()
        except Exception:  # noqa: BLE001
            pass

    # -- transport -----------------------------------------------------------

    def call(self, method: str, params: dict | None = None, files: dict | None = None) -> Any:
        url = f"{self._base}/bot{self._token}/{method}"
        try:
            if files:
                data = {
                    k: (json.dumps(v) if isinstance(v, (dict, list)) else str(v))
                    for k, v in (params or {}).items()
                    if v is not None
                }
                response = self._client.post(url, data=data, files=files)
            else:
                body = {k: v for k, v in (params or {}).items() if v is not None}
                response = self._client.post(url, json=body)
        except httpx.HTTPError as exc:
            # ``str(exc)`` can hold the URL, and the URL holds the token.
            raise TelegramApiError(method, 0, f"network error ({type(exc).__name__})") from None
        try:
            payload = response.json()
        except ValueError:
            raise TelegramApiError(method, response.status_code, "not a JSON answer") from None
        if not isinstance(payload, dict) or not payload.get("ok"):
            info = payload if isinstance(payload, dict) else {}
            params_ = info.get("parameters") if isinstance(info.get("parameters"), dict) else {}
            retry = params_.get("retry_after")
            raise TelegramApiError(
                method,
                int(info.get("error_code") or response.status_code),
                str(info.get("description") or "failed"),
                float(retry) if isinstance(retry, (int, float)) else None,
            )
        return payload.get("result")

    # -- methods ---------------------------------------------------------------

    def get_me(self) -> dict:
        return self.call("getMe")

    def get_updates(self, offset: int | None, timeout: int | None = None) -> list[dict]:
        result = self.call(
            "getUpdates",
            {
                "offset": offset or None,
                "timeout": self.poll_timeout if timeout is None else int(timeout),
                "allowed_updates": ["message", "callback_query"],
            },
        )
        return result if isinstance(result, list) else []

    def send_message(self, chat_id: int, text: str, reply_markup: dict | None = None) -> dict:
        return self.call(
            "sendMessage",
            {
                "chat_id": chat_id,
                "text": text[:MAX_MESSAGE_CHARS],
                "reply_markup": reply_markup,
                "link_preview_options": {"is_disabled": True},
            },
        )

    def edit_message_text(
        self, chat_id: int, message_id: int, text: str, reply_markup: dict | None = None
    ) -> Any:
        return self.call(
            "editMessageText",
            {
                "chat_id": chat_id,
                "message_id": message_id,
                "text": text[:MAX_MESSAGE_CHARS],
                "reply_markup": reply_markup,
                "link_preview_options": {"is_disabled": True},
            },
        )

    def answer_callback_query(self, callback_query_id: str, text: str | None = None) -> Any:
        return self.call(
            "answerCallbackQuery", {"callback_query_id": callback_query_id, "text": text}
        )

    def send_chat_action(self, chat_id: int, action: str = "typing") -> Any:
        return self.call("sendChatAction", {"chat_id": chat_id, "action": action})

    def send_document(
        self, chat_id: int, name: str, data: bytes, mime_type: str = "application/octet-stream",
        caption: str | None = None,
    ) -> dict:
        if len(data) > MAX_UPLOAD_BYTES:
            raise TelegramApiError("sendDocument", 413, "file too large for Telegram")
        return self.call(
            "sendDocument",
            {"chat_id": chat_id, "caption": caption},
            files={"document": (name, data, mime_type or "application/octet-stream")},
        )

    def download(self, file_id: str, max_bytes: int = MAX_DOWNLOAD_BYTES) -> bytes:
        """The bytes of one file the user sent (getFile, then the file URL)."""
        info = self.call("getFile", {"file_id": file_id})
        path = info.get("file_path") if isinstance(info, dict) else None
        size = info.get("file_size") if isinstance(info, dict) else None
        if not isinstance(path, str) or not path:
            raise TelegramApiError("getFile", 400, "no file path")
        if isinstance(size, int) and size > max_bytes:
            raise TelegramApiError("getFile", 413, "file too large")
        url = f"{self._base}/file/bot{self._token}/{path}"
        try:
            with self._client.stream("GET", url) as response:
                if response.status_code != 200:
                    raise TelegramApiError("download", response.status_code, "download failed")
                chunks: list[bytes] = []
                total = 0
                for chunk in response.iter_bytes():
                    total += len(chunk)
                    if total > max_bytes:
                        raise TelegramApiError("download", 413, "file too large")
                    chunks.append(chunk)
        except httpx.HTTPError as exc:
            raise TelegramApiError("download", 0, f"network error ({type(exc).__name__})") from None
        return b"".join(chunks)
