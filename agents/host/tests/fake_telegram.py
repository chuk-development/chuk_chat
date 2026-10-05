"""A fake Telegram Bot API on loopback, for the channel tests. No network.

It speaks the subset the channel uses: ``getMe``, ``getUpdates`` (a real long
poll on a condition variable), ``sendMessage``, ``sendChatAction``,
``sendDocument`` and ``sendPhoto``. Tests push updates in, read what the bot
sent, and script failures per method: an HTTP status (with ``retry_after``
for 429) or ``"drop"``, which closes the socket with no answer at all.
"""

from __future__ import annotations

import json
import re
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

TOKEN = "123456789:AAFakeTokenForTestsOnly_abcdefghijklmno"
OTHER_TOKEN = "987654321:BBAnotherFakeTokenForTests_abcdefghijk"


class FakeTelegram:
    def __init__(self, token: str = TOKEN, username: str = "test_coworker_bot") -> None:
        self.token = token
        self.username = username
        self.cond = threading.Condition()
        self.updates: list[dict] = []
        self.next_update_id = 1000
        self.sent: list[dict] = []  # every send* call: {"method", ...params}
        self.calls: list[str] = []  # every method name, in order
        self.offsets: list[int] = []
        self.failures: dict[str, list[Any]] = {}
        self.reject_html = False
        self._server = ThreadingHTTPServer(("127.0.0.1", 0), self._handler())
        # A long poll the client cut (host stop) ends in a broken pipe: normal.
        self._server.handle_error = lambda *_args: None
        self._server.daemon_threads = True
        self._thread = threading.Thread(target=self._server.serve_forever, daemon=True)

    # -- lifecycle ------------------------------------------------------------

    def __enter__(self) -> "FakeTelegram":
        self._thread.start()
        return self

    def __exit__(self, *exc: object) -> None:
        with self.cond:
            self.cond.notify_all()
        self._server.shutdown()
        self._server.server_close()

    @property
    def base_url(self) -> str:
        host, port = self._server.server_address[:2]
        return f"http://{host}:{port}"

    # -- test side ------------------------------------------------------------------

    def push_message(
        self,
        text: str | None,
        *,
        chat_id: int,
        chat_type: str = "private",
        username: str | None = "owner",
        is_bot: bool = False,
        extra: dict | None = None,
    ) -> int:
        with self.cond:
            update_id = self.next_update_id
            self.next_update_id += 1
            message: dict = {
                "message_id": update_id,
                "date": int(time.time()),
                "chat": {"id": chat_id, "type": chat_type},
                "from": {"id": chat_id, "is_bot": is_bot, "first_name": "Test"},
            }
            if username:
                message["from"]["username"] = username
            if text is not None:
                message["text"] = text
            if extra:
                message.update(extra)
            self.updates.append({"update_id": update_id, "message": message})
            self.cond.notify_all()
        return update_id

    def fail(self, method: str, *outcomes: Any) -> None:
        """Script the next answers of ``method``: an int status, ``(429, s)``
        for a rate limit, or ``"drop"``."""
        with self.cond:
            self.failures.setdefault(method, []).extend(outcomes)

    def messages(self, chat_id: int | None = None) -> list[dict]:
        with self.cond:
            return [
                s for s in self.sent
                if s["method"] == "sendMessage" and (chat_id is None or s["chat_id"] == chat_id)
            ]

    def wait_for(self, predicate, timeout: float = 10.0) -> bool:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            with self.cond:
                if predicate():
                    return True
                self.cond.wait(0.05)
        with self.cond:
            return bool(predicate())

    # -- server side ---------------------------------------------------------------

    def _handler(self):
        fake = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *args: object) -> None:  # quiet
                pass

            def _answer(self, status: int, payload: dict) -> None:
                body = json.dumps(payload).encode("utf-8")
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(body)

            def do_POST(self) -> None:  # noqa: N802
                length = int(self.headers.get("Content-Length") or 0)
                raw = self.rfile.read(length)
                match = re.fullmatch(r"/bot([^/]+)/(\w+)", self.path)
                if not match or match.group(1) != fake.token:
                    self._answer(401, {"ok": False, "error_code": 401, "description": "Unauthorized"})
                    return
                method = match.group(2)
                with fake.cond:
                    fake.calls.append(method)
                    scripted = fake.failures.get(method)
                    outcome = scripted.pop(0) if scripted else None
                    fake.cond.notify_all()
                if outcome == "drop":
                    self.close_connection = True
                    try:
                        self.connection.shutdown(2)
                    except OSError:
                        pass
                    return
                if outcome is not None:
                    status, retry = (outcome if isinstance(outcome, tuple) else (outcome, None))
                    payload: dict = {"ok": False, "error_code": status, "description": "scripted"}
                    if retry is not None:
                        payload["parameters"] = {"retry_after": retry}
                    self._answer(status, payload)
                    return
                content_type = self.headers.get("Content-Type") or ""
                if content_type.startswith("multipart/form-data"):
                    self._upload(method, raw)
                    return
                params = json.loads(raw.decode("utf-8") or "{}")
                getattr(self, f"_m_{method}", self._unknown)(params)

            def _unknown(self, _params: dict) -> None:
                self._answer(404, {"ok": False, "error_code": 404, "description": "Not Found"})

            def _m_getMe(self, _params: dict) -> None:  # noqa: N802
                self._answer(200, {"ok": True, "result": {
                    "id": 1, "is_bot": True, "first_name": "Bot", "username": fake.username}})

            def _m_getUpdates(self, params: dict) -> None:  # noqa: N802
                offset = int(params.get("offset") or 0)
                timeout = float(params.get("timeout") or 0)
                deadline = time.monotonic() + timeout
                with fake.cond:
                    fake.offsets.append(offset)
                    # Telegram forgets everything below the offset.
                    fake.updates = [u for u in fake.updates if u["update_id"] >= offset]
                    while not fake.updates and time.monotonic() < deadline:
                        fake.cond.wait(min(0.1, max(0.0, deadline - time.monotonic())))
                    result = list(fake.updates)
                self._answer(200, {"ok": True, "result": result})

            def _m_sendMessage(self, params: dict) -> None:  # noqa: N802
                if fake.reject_html and params.get("parse_mode") == "HTML":
                    self._answer(400, {"ok": False, "error_code": 400,
                                       "description": "Bad Request: can't parse entities"})
                    return
                if len(params.get("text") or "") > 4096:
                    self._answer(400, {"ok": False, "error_code": 400,
                                       "description": "Bad Request: message is too long"})
                    return
                with fake.cond:
                    fake.sent.append({"method": "sendMessage", **params})
                    fake.cond.notify_all()
                self._answer(200, {"ok": True, "result": {"message_id": len(fake.sent)}})

            def _m_sendChatAction(self, params: dict) -> None:  # noqa: N802
                with fake.cond:
                    fake.sent.append({"method": "sendChatAction", **params})
                    fake.cond.notify_all()
                self._answer(200, {"ok": True, "result": True})

            def _upload(self, method: str, raw: bytes) -> None:
                chat = re.search(rb'name="chat_id"\r\n\r\n(-?\d+)\r\n', raw)
                name = re.search(rb'filename="([^"]*)"', raw)
                ctype = re.search(rb'filename="[^"]*"\r\nContent-Type: ([^\r]+)\r\n\r\n', raw)
                start = raw.find(b"\r\n\r\n", raw.find(b"filename=")) + 4
                end = raw.rfind(b"\r\n--")
                with fake.cond:
                    fake.sent.append({
                        "method": method,
                        "chat_id": int(chat.group(1)) if chat else None,
                        "filename": name.group(1).decode() if name else "",
                        "mime_type": ctype.group(1).decode() if ctype else "",
                        "data": raw[start:end],
                    })
                    fake.cond.notify_all()
                self._answer(200, {"ok": True, "result": {"message_id": len(fake.sent)}})

        return Handler
