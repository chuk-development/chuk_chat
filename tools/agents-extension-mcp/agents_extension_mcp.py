#!/usr/bin/env python3
"""``agents-extension-mcp`` — the agent's browser, when the browser is the user's.

The executor already knows how to hand the agent an MCP server for a browser:
today that is ``agents-browser-mcp`` inside the sandbox, driving Chromium on an
Xvfb display. This is the same shape with a different thing behind it — the
add-on in the browser the user already has open.

Because the tool names are the ones the agent's browser tools already carry, the
rest of Agents cannot tell the difference: ``protocol.browser_state_from_tool``,
``run_state.browser_open``, the app's ``BrowserPresence`` and every replayed
transcript keep working unchanged.

Two protocols meet here, both JSON-RPC-ish over a pipe:

* **stdout/stdin** — MCP, spoken to the agent. Only the three methods a client
  actually needs: ``initialize``, ``tools/list``, ``tools/call``.
* **a unix socket** — newline-delimited JSON, spoken to
  ``agents-browser-bridge``, which the browser starts on its own when the add-on
  connects. We are the server end; the bridge dials in.

No third-party package: the MCP stdio framing is line-delimited JSON-RPC 2.0,
which is short enough to write out and much easier to test than to install.
"""

from __future__ import annotations

import json
import os
import queue
import socket
import sys
import threading
import uuid
from pathlib import Path
from typing import Any

PROTOCOL_VERSION = "2025-06-18"
SERVER_NAME = "playwright"  # what the tool prefix must say; see the docstring.
DEFAULT_SOCKET = Path(os.path.expanduser("~/.agents/browser-bridge.sock"))
CALL_TIMEOUT_SECONDS = float(os.environ.get("AGENTS_BROWSER_CMD_TIMEOUT", "45"))

# The tools the agent sees. Names and shapes mirror the add-on's vocabulary in
# extension/src/protocol.js; keep the two in step.
TOOLS: list[dict[str, Any]] = [
    {
        "name": "browser_navigate",
        "description": "Open a URL in the tab this coworker drives.",
        "inputSchema": {
            "type": "object",
            "properties": {"url": {"type": "string"}},
            "required": ["url"],
        },
    },
    {
        "name": "browser_navigate_back",
        "description": "Go back one entry in that tab's history.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "browser_snapshot",
        "description": (
            "Read the page as a list of nodes, each with a ref you can click or type "
            "into. Only what changed since the last snapshot of the same page is "
            "returned; pass full=true for everything."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {"full": {"type": "boolean"}},
        },
    },
    {
        "name": "browser_click",
        "description": "Click a node, named by ref, by CSS selector, or by an [x, y] point.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "ref": {"type": "string"},
                "selector": {"type": "string"},
                "point": {"type": "array", "items": {"type": "number"}},
            },
        },
    },
    {
        "name": "browser_type",
        "description": "Type into a node. Without ref/selector/point it types into whatever has focus.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "text": {"type": "string"},
                "ref": {"type": "string"},
                "selector": {"type": "string"},
                "point": {"type": "array", "items": {"type": "number"}},
                "submit": {"type": "boolean"},
            },
            "required": ["text"],
        },
    },
    {
        "name": "browser_press_key",
        "description": "Press one key, e.g. Enter, Tab, Escape, ArrowDown.",
        "inputSchema": {
            "type": "object",
            "properties": {"key": {"type": "string"}},
            "required": ["key"],
        },
    },
    {
        "name": "browser_scroll",
        "description": "Scroll the page. dy is pixels, positive is down.",
        "inputSchema": {
            "type": "object",
            "properties": {"dy": {"type": "number"}, "dx": {"type": "number"}},
        },
    },
    {
        "name": "browser_take_screenshot",
        "description": "A PNG of the visible page, base64. Prefer browser_snapshot: it is far cheaper.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "browser_tabs",
        "description": (
            "list: every tab in the user's browser. select: take over one of them by "
            "tabId — use this when the user says the page is already open. new: a fresh "
            "tab of your own. close: close the one you drive."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "action": {"type": "string", "enum": ["list", "select", "new", "close"]},
                "tabId": {"type": "integer"},
            },
            "required": ["action"],
        },
    },
    {
        "name": "browser_close",
        "description": "Let go of the tab and stop driving.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "browser_handoff",
        "description": "Give the tab back to the user, with a reason. Use this instead of pushing through a sign-in.",
        "inputSchema": {
            "type": "object",
            "properties": {"reason": {"type": "string"}},
        },
    },
    {
        "name": "browser_report_wall",
        "description": "Report a bot wall or a captcha and stop, rather than retrying around it.",
        "inputSchema": {
            "type": "object",
            "properties": {"kind": {"type": "string"}},
            "required": ["kind"],
        },
    },
]


class Bridge:
    """The socket the browser's bridge dials into, and the replies it sends back."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self.conn: socket.socket | None = None
        self.attached: dict[str, Any] | None = None
        self.pending: dict[str, queue.Queue] = {}
        self.lock = threading.Lock()
        self.listener = self._listen()

    def _listen(self) -> socket.socket:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        if self.path.exists():
            self.path.unlink()
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(str(self.path))
        server.listen(1)
        os.chmod(self.path, 0o600)  # only this user's browser may dial in
        threading.Thread(target=self._accept_forever, args=(server,), daemon=True).start()
        return server

    def _accept_forever(self, server: socket.socket) -> None:
        while True:
            try:
                conn, _ = server.accept()
            except OSError:
                return
            with self.lock:
                self.conn = conn
            threading.Thread(target=self._read_forever, args=(conn,), daemon=True).start()

    def _read_forever(self, conn: socket.socket) -> None:
        buffer = b""
        try:
            while True:
                chunk = conn.recv(1 << 16)
                if not chunk:
                    break
                buffer += chunk
                while b"\n" in buffer:
                    line, buffer = buffer.split(b"\n", 1)
                    if line.strip():
                        self._on_frame(json.loads(line.decode("utf-8")))
        except (OSError, ValueError, json.JSONDecodeError):
            pass
        finally:
            with self.lock:
                if self.conn is conn:
                    self.conn = None
                    self.attached = None

    def _on_frame(self, frame: dict[str, Any]) -> None:
        kind = frame.get("type")
        if kind == "browser_attach":
            self.attached = frame
            return
        if kind == "browser_result":
            waiter = self.pending.pop(str(frame.get("cmd_id")), None)
            if waiter is not None:
                waiter.put(frame)

    @property
    def ready(self) -> bool:
        return self.conn is not None

    def call(self, op: str, args: dict[str, Any]) -> dict[str, Any]:
        with self.lock:
            conn = self.conn
        if conn is None:
            raise RuntimeError(
                "the Agents add-on is not connected to this browser. Ask the user to "
                "open their browser with the add-on installed, then try again."
            )
        cmd_id = uuid.uuid4().hex[:12]
        waiter: queue.Queue = queue.Queue(maxsize=1)
        self.pending[cmd_id] = waiter
        payload = {"type": "browser_cmd", "cmd_id": cmd_id, "op": op, "args": args}
        conn.sendall(json.dumps(payload, separators=(",", ":")).encode("utf-8") + b"\n")
        try:
            frame = waiter.get(timeout=CALL_TIMEOUT_SECONDS)
        except queue.Empty:
            self.pending.pop(cmd_id, None)
            raise RuntimeError(f"{op}: the browser did not answer within {CALL_TIMEOUT_SECONDS:.0f}s")
        if not frame.get("ok"):
            raise RuntimeError(str(frame.get("error") or f"{op} failed"))
        return frame.get("data") or {}


def result_text(data: dict[str, Any]) -> str:
    """What the model reads. Compact JSON; a screenshot keeps its own shape."""
    return json.dumps(data, separators=(",", ":"), ensure_ascii=False)


def handle(request: dict[str, Any], bridge: Bridge) -> dict[str, Any] | None:
    method = request.get("method")
    request_id = request.get("id")

    if method == "initialize":
        return reply(request_id, {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {"tools": {}},
            "serverInfo": {"name": SERVER_NAME, "version": "0.1.0"},
        })

    if method in ("notifications/initialized", "initialized"):
        return None  # a notification carries no id and wants no answer

    if method == "ping":
        return reply(request_id, {})

    if method == "tools/list":
        return reply(request_id, {"tools": TOOLS})

    if method == "tools/call":
        params = request.get("params") or {}
        name = str(params.get("name") or "")
        args = params.get("arguments") or {}
        if not any(tool["name"] == name for tool in TOOLS):
            return reply(request_id, {
                "content": [{"type": "text", "text": f"unknown tool {name}"}],
                "isError": True,
            })
        try:
            data = bridge.call(name, args)
        except Exception as err:  # a failed tool call is a result, not a crash
            return reply(request_id, {
                "content": [{"type": "text", "text": str(err)}],
                "isError": True,
            })
        return reply(request_id, {"content": [{"type": "text", "text": result_text(data)}]})

    return error(request_id, -32601, f"unknown method {method}")


def reply(request_id: Any, result: dict[str, Any]) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": request_id, "result": result}


def error(request_id: Any, code: int, message: str) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}}


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    path = Path(argv[0]) if argv else Path(os.environ.get("AGENTS_BRIDGE_SOCKET", str(DEFAULT_SOCKET)))
    bridge = Bridge(path)
    print(f"agents-extension-mcp: waiting for the add-on on {path}", file=sys.stderr, flush=True)

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
        except json.JSONDecodeError:
            continue
        response = handle(request, bridge)
        if response is not None:
            sys.stdout.write(json.dumps(response, separators=(",", ":")) + "\n")
            sys.stdout.flush()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
