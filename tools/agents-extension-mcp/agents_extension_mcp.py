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
* **a unix socket** — newline-delimited JSON. Two ways, picked at start:

  - **broker** (the normal case under a host): the host owns the add-on's
    socket for its whole life (``chuk_agents_executor.user_browser``), and this
    server dials the host's client socket and names its coworker
    (``AGENTS_BROWSER_SESSION``). The host lets one coworker hold the browser
    at a time and enforces the user's Stop.
  - **standalone** (a socket path on the command line, or no host running):
    this server owns the socket and ``agents-browser-bridge``, which the browser
    starts on its own when the add-on connects, dials in.

Both sockets live in ``$XDG_RUNTIME_DIR/chuk-agents`` (``~/.agents`` without
it). Keep :func:`socket_dir` in step with ``user_browser.socket_dir`` and the
bridge.

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
CALL_TIMEOUT_SECONDS = float(os.environ.get("AGENTS_BROWSER_CMD_TIMEOUT", "45"))


def socket_dir() -> Path:
    """``$XDG_RUNTIME_DIR/chuk-agents`` (private tmpfs), else ``~/.agents``."""
    runtime = os.environ.get("XDG_RUNTIME_DIR")
    if runtime and os.path.isdir(runtime):
        return Path(runtime) / "chuk-agents"
    return Path(os.path.expanduser("~/.agents"))


def bridge_socket_path() -> Path:
    override = os.environ.get("AGENTS_BRIDGE_SOCKET")
    return Path(override).expanduser() if override else socket_dir() / "browser-bridge.sock"


def broker_socket_path() -> Path:
    override = os.environ.get("AGENTS_BROWSER_BROKER_SOCKET")
    return Path(override).expanduser() if override else socket_dir() / "browser-broker.sock"


DEFAULT_SOCKET = bridge_socket_path()

#: MCP tool annotations: the reads say so, so a client that reads hints does
#: not put them behind an approval. The acting tools are approved by the host
#: (``browser_act``), not by a hint.
_READ_ONLY = {"readOnlyHint": True}

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
        "annotations": _READ_ONLY,
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
        "annotations": _READ_ONLY,
        "description": "A PNG of the visible page, base64. Prefer browser_snapshot: it is far cheaper.",
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "browser_tabs",
        "description": (
            "list: every tab in the user's browser, one line each as "
            "'- <tabId>: [Title](url)'; the one you drive says (current). select: take "
            "over one of them by tabId (the user is asked first) — use this when the user "
            "says the page is already open. new: a fresh tab of your own. close: let go of "
            "the one you drive (a tab the user gave you stays open)."
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
    """Standalone: the socket the browser's bridge dials into, and the replies
    it sends back."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self.conn: socket.socket | None = None
        self.attached: dict[str, Any] | None = None
        self.pending: dict[str, queue.Queue] = {}
        self.lock = threading.Lock()
        self.listener = self._listen()

    def _listen(self) -> socket.socket:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        try:
            os.chmod(self.path.parent, 0o700)
        except OSError:
            pass
        if self.path.exists():
            probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                probe.settimeout(0.5)
                probe.connect(str(self.path))
            except OSError:
                self.path.unlink()  # a dead socket from an earlier run
            else:
                raise RuntimeError(f"{self.path} is in use by a running Agents host")
            finally:
                probe.close()
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


class BrokerClient:
    """Broker mode: this coworker's line to the host's browser broker.

    Dials lazily and again after a drop, so a host restart costs one failed
    call, not the session."""

    def __init__(self, path: Path, session: str) -> None:
        self.path = path
        self.session = session
        self.conn: socket.socket | None = None
        self.pending: dict[str, queue.Queue] = {}
        self.lock = threading.Lock()

    @property
    def ready(self) -> bool:
        return self._connect() is not None

    def _connect(self) -> socket.socket | None:
        with self.lock:
            if self.conn is not None:
                return self.conn
            try:
                conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                conn.connect(str(self.path))
                hello = {"type": "client_hello", "session": self.session}
                conn.sendall(json.dumps(hello).encode("utf-8") + b"\n")
            except OSError:
                return None
            self.conn = conn
        threading.Thread(target=self._read_forever, args=(conn,), daemon=True).start()
        return conn

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
                    if not line.strip():
                        continue
                    frame = json.loads(line.decode("utf-8"))
                    if isinstance(frame, dict) and frame.get("type") == "browser_result":
                        waiter = self.pending.pop(str(frame.get("cmd_id")), None)
                        if waiter is not None:
                            waiter.put(frame)
        except (OSError, ValueError):
            pass
        finally:
            with self.lock:
                if self.conn is conn:
                    self.conn = None
            for key in list(self.pending):
                waiter = self.pending.pop(key, None)
                if waiter is not None:
                    waiter.put({"ok": False, "error": "the Agents host closed the browser line"})

    def call(self, op: str, args: dict[str, Any]) -> dict[str, Any]:
        conn = self._connect()
        if conn is None:
            raise RuntimeError(
                "the Agents host is not running its browser broker. Ask the user to "
                "start Agents on this computer, then try again."
            )
        cmd_id = uuid.uuid4().hex[:12]
        waiter: queue.Queue = queue.Queue(maxsize=1)
        self.pending[cmd_id] = waiter
        payload = {"type": "browser_cmd", "cmd_id": cmd_id, "op": op, "args": args}
        try:
            conn.sendall(json.dumps(payload, separators=(",", ":")).encode("utf-8") + b"\n")
        except OSError:
            self.pending.pop(cmd_id, None)
            raise RuntimeError("the Agents host closed the browser line; try again")
        try:
            frame = waiter.get(timeout=CALL_TIMEOUT_SECONDS)
        except queue.Empty:
            self.pending.pop(cmd_id, None)
            raise RuntimeError(f"{op}: the browser did not answer within {CALL_TIMEOUT_SECONDS:.0f}s")
        if not frame.get("ok"):
            raise RuntimeError(str(frame.get("error") or f"{op} failed"))
        return frame.get("data") or {}


def _short_url(url: str) -> str:
    """A tab the coworker does not hold shows without query and fragment:
    a sign-in link or a reset token in another tab is none of its business."""
    cut = len(url)
    for mark in ("?", "#"):
        at = url.find(mark)
        if at != -1:
            cut = min(cut, at)
    return url[:cut]


def _md(text: Any) -> str:
    return str(text or "").replace("[", "(").replace("]", ")").replace("\n", " ").strip()


def tabs_text(data: dict[str, Any]) -> str:
    """``browser_tabs list`` in the Playwright line form the host already
    reads (``chuk_agents_runtime.takeover.current_tab_url``): one tab a line,
    ``(current)`` on the tab this coworker drives."""
    driving = data.get("driving")
    lines = ["### Open tabs in the user's browser"]
    for tab in data.get("tabs") or []:
        if not isinstance(tab, dict):
            continue
        tab_id = tab.get("id")
        url = str(tab.get("url") or "")
        mine = tab_id == driving and driving is not None
        shown = url if mine else _short_url(url)
        flag = "(current) " if mine else ""
        lines.append(f"- {tab_id}: {flag}[{_md(tab.get('title')) or 'untitled'}]({shown})")
    if len(lines) == 1:
        lines.append("(no tabs)")
    lines.append("")
    lines.append(
        "To work in one of these, call browser_tabs with action \"select\" and its tabId "
        "(the number before the colon). The user is asked first."
    )
    return "\n".join(lines)


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
        if name == "browser_tabs" and isinstance(args, dict) and args.get("action") == "list":
            return reply(request_id, {"content": [{"type": "text", "text": tabs_text(data)}]})
        return reply(request_id, {"content": [{"type": "text", "text": result_text(data)}]})

    return error(request_id, -32601, f"unknown method {method}")


def reply(request_id: Any, result: dict[str, Any]) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": request_id, "result": result}


def error(request_id: Any, code: int, message: str) -> dict[str, Any]:
    return {"jsonrpc": "2.0", "id": request_id, "error": {"code": code, "message": message}}


def connect(argv: list[str]) -> Bridge | BrokerClient:
    """A socket path on the command line = standalone on that path.

    Started by a host (``AGENTS_BROWSER_SESSION`` set): always the host's
    broker, also when its socket is missing right now. The client dials
    lazily, so a broker that comes up later is found, and until then every
    call fails with "not running its broker". It never falls back to binding
    the bridge socket itself: that would take the browser around the
    broker's rules (one holder, Stop, the session's name).

    Without a session (a person running it by hand): the broker when it
    runs, else standalone on the default path."""
    if argv:
        return Bridge(Path(argv[0]))
    broker = broker_socket_path()
    session = os.environ.get("AGENTS_BROWSER_SESSION", "")
    if session:
        return BrokerClient(broker, session)
    if broker.exists():
        return BrokerClient(broker, "default")
    return Bridge(bridge_socket_path())


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    bridge = connect(argv)
    where = bridge.path
    mode = "the Agents host" if isinstance(bridge, BrokerClient) else "the add-on"
    print(f"agents-extension-mcp: talking to {mode} on {where}", file=sys.stderr, flush=True)

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
