"""One sandbox browser per box, shared by every thread of its coworker.

A coworker's sandbox (its box) has ONE Chromium profile
(``/workspace/.agents/chrome-profile``), and ``browser-mcp-owner.py`` in the
image refuses a second Playwright MCP server on it ("browser profile still has
a live owner"). Every thread (session key) of the coworker runs in that box.
When each thread built its own MCP manager, each one also started its own
browser server, eagerly, at the start of every task. The first thread kept the
profile, and every other thread of the coworker ran with no browser at all
(bead chuk_chat-wrdv).

:class:`BoxBrowser` is the fix. It is the one connection to the box's browser
server. Each thread's :class:`~chuk_agents_runtime.MCPManager` holds the same
object in place of its own connection (the executor's ``connection_factory``
hands it out), so:

- there is one server per box, and all threads of the box use it;
- the tool calls are serialized: one Playwright page, one caller at a time;
- the server starts on the first browser call (or when the user opens the live
  view), not when a task starts. A thread that never browses starts nothing.

To register the browser tools before the server runs, the tool list of the last
connection is kept, in memory and in a small JSON file next to the executor's
state. Only the first connection ever (no list known yet) starts the server at
task start, to learn the tools.

A thread's manager closes its connections when it is rebuilt or dropped. For a
:class:`BoxBrowser` that is :meth:`close`, which does nothing: the other threads
still use the server. The object is shared by the whole process
(:func:`acquire` / :func:`release`), so two executors that serve the same box
also share it; the server stops when the last executor lets go.
"""

from __future__ import annotations

import json
import logging
import os
import threading
from collections.abc import Callable
from typing import Any

from chuk_agents_runtime import MCPConnection, MCPServerConfig, MCPToolInfo

logger = logging.getLogger(__name__)

#: The launcher every sandbox browser server is exec'd as. Its argv ends
#: ``<container> agents-browser-mcp``.
BROWSER_MCP_LAUNCHER = "agents-browser-mcp"
#: The file, next to the executor's state database, that keeps the browser
#: server's tool list across host restarts.
TOOLS_FILE = "browser-mcp-tools.json"


def box_of(config: MCPServerConfig) -> str | None:
    """The container a sandbox browser entry execs into, or ``None`` for any
    other server (a connector, the user's own browser over the extension)."""
    args = list(getattr(config, "args", None) or [])
    if not getattr(config, "command", None) or len(args) < 2:
        return None
    if args[-1] != BROWSER_MCP_LAUNCHER:
        return None
    return str(args[-2]) or None


def load_tools(path: str | None) -> list[MCPToolInfo]:
    """The cached tool list, or ``[]``. Never raises."""
    if not path:
        return []
    try:
        with open(path, encoding="utf-8") as handle:
            raw = json.load(handle)
    except (OSError, ValueError):
        return []
    tools: list[MCPToolInfo] = []
    if not isinstance(raw, list):
        return []
    for item in raw:
        if not isinstance(item, dict) or not isinstance(item.get("name"), str):
            continue
        tools.append(
            MCPToolInfo(
                name=item["name"],
                description=str(item.get("description") or ""),
                schema=item.get("schema") if isinstance(item.get("schema"), dict) else {},
                annotations=(
                    item.get("annotations") if isinstance(item.get("annotations"), dict) else {}
                ),
            )
        )
    return tools


def tools_data(tools: list[MCPToolInfo]) -> list[dict]:
    """The tool list as it is saved: name, description, schema, annotations."""
    return [
        {
            "name": t.name,
            "description": t.description,
            "schema": t.schema,
            "annotations": t.annotations,
        }
        for t in tools
    ]


def same_tools(a: list[MCPToolInfo], b: list[MCPToolInfo]) -> bool:
    """Equal as saved, not only by name: a changed description or schema is a
    new tool list too."""
    try:
        return json.dumps(tools_data(a), sort_keys=True) == json.dumps(
            tools_data(b), sort_keys=True
        )
    except (TypeError, ValueError):
        return False


def save_tools(path: str | None, tools: list[MCPToolInfo]) -> None:
    """Write the tool list atomically. Best effort: a failure costs the next
    host start one eager connection, nothing else. Each writer has its own
    temp file (pid and thread id), so two executors that save at once never
    write into the same file."""
    if not path or not tools:
        return
    tmp = f"{path}.{os.getpid()}.{threading.get_ident()}.tmp"
    try:
        with open(tmp, "w", encoding="utf-8") as handle:
            json.dump(tools_data(tools), handle)
        os.replace(tmp, path)
    except (OSError, TypeError, ValueError):
        logger.debug("browser tool list not saved", exc_info=True)
        try:
            os.unlink(tmp)
        except OSError:
            pass


class BoxBrowser:
    """The shared, lazily started connection to one box's browser server.

    It has the interface of :class:`~chuk_agents_runtime.MCPConnection` that
    :class:`~chuk_agents_runtime.MCPManager` and the browser helpers use
    (``config``, ``name``, ``tools``, ``error``, ``connected_once``,
    ``alive``, ``start``, ``call``, ``close``).
    """

    def __init__(
        self,
        config: MCPServerConfig,
        *,
        tools_path: str | None = None,
        connect: Callable[[MCPServerConfig], Any] | None = None,
    ) -> None:
        self.config = config
        self._tools_path = tools_path
        self._connect = connect or (lambda c: MCPConnection(c))
        self._conn: Any = None
        self._known: list[MCPToolInfo] = load_tools(tools_path)
        self._error: str | None = None
        #: Held while the server is (re)started: a second caller waits for the
        #: first start instead of starting a second server on the profile.
        self._start_lock = threading.Lock()
        #: One call at a time: the threads share one browser and one page.
        self._call_lock = threading.Lock()
        self._shut = False
        #: Executors that hold this box (:func:`acquire` / :func:`release`).
        self._holders = 0

    # -- what MCPManager reads ---------------------------------------------

    @property
    def name(self) -> str:
        return self.config.name

    @property
    def launched(self) -> bool:
        """The server runs now (it was started and its session is up)."""
        conn = self._conn
        return bool(conn is not None and conn.alive())

    @property
    def tools(self) -> list[MCPToolInfo]:
        conn = self._conn
        if conn is not None and conn.alive():
            return list(conn.tools)
        return list(self._known)

    @property
    def error(self) -> str | None:
        return self._error

    @property
    def connected_once(self) -> bool:
        return bool(self._known)

    def alive(self) -> bool:
        """The browser tools are usable: the server runs, or it can be started
        on the first call (its tool list is known and the last start did not
        fail)."""
        if self._shut:
            return False
        if self.launched:
            return True
        return bool(self._known) and self._error is None

    def adopt(self, config: MCPServerConfig) -> None:
        """A newer entry for the same box (an env such as the retired hostname
        can differ). Used on the next start; a running server is kept."""
        self.config = config

    def start(self) -> bool:
        """Called by every thread's manager at task start. Starts nothing when
        the tool list is known: the server starts on the first call. A start
        that failed before is tried again here, once per task."""
        if self._shut:
            return False
        if self.launched:
            return True
        if self._known and self._error is None:
            return True
        return self.ensure()

    def ensure(self) -> bool:
        """Start the server now, unless it runs already. Never raises."""
        if self._shut:
            return False
        with self._start_lock:
            if self.launched:
                return True
            old, self._conn = self._conn, None
            if old is not None:
                try:
                    old.close()
                except Exception:  # noqa: BLE001 — a dead session must not block a new one
                    pass
            conn = self._connect(self.config)
            try:
                ok = bool(conn.start())
            except Exception as exc:  # noqa: BLE001
                ok = False
                self._error = f"{type(exc).__name__}: {exc}"
            if ok:
                self._conn = conn
                self._error = None
                tools = list(conn.tools)
                if tools and not same_tools(tools, self._known):
                    save_tools(self._tools_path, tools)
                self._known = tools or self._known
                return True
            self._error = getattr(conn, "error", None) or self._error or "browser did not start"
            try:
                conn.close()
            except Exception:  # noqa: BLE001
                pass
            return False

    def call(self, tool: str, arguments: dict | None = None) -> dict:
        """One tool call on the shared server, started first if needed. Calls
        from different threads run one after the other. Never raises."""
        if not self.ensure():
            return {
                "ok": False,
                "server": self.config.name,
                "tool": tool,
                "error": self._error or "browser not available",
            }
        with self._call_lock:
            conn = self._conn
            if conn is None:
                return {
                    "ok": False,
                    "server": self.config.name,
                    "tool": tool,
                    "error": "browser not available",
                }
            return conn.call(tool, arguments)

    def close(self) -> None:
        """A thread's manager lets go. The other threads still use the server,
        so nothing stops here (see :meth:`shutdown`)."""

    def shutdown(self) -> None:
        """Stop the server for good (executor stop)."""
        self._shut = True
        with self._start_lock:
            conn, self._conn = self._conn, None
        if conn is not None:
            try:
                conn.close()
            except Exception:  # noqa: BLE001 — shutdown must not raise
                pass


#: Every box's browser in this process, by container id.
_BOXES: dict[str, BoxBrowser] = {}
_BOXES_LOCK = threading.Lock()


def acquire(box: str, config: MCPServerConfig, *, tools_path: str | None = None) -> BoxBrowser:
    """The process's one :class:`BoxBrowser` of ``box``, made on first use.
    Each executor acquires a box once and releases it when it stops."""
    with _BOXES_LOCK:
        shared = _BOXES.get(box)
        if shared is None or shared._shut:  # noqa: SLF001
            shared = BoxBrowser(config, tools_path=tools_path)
            _BOXES[box] = shared
        else:
            shared.adopt(config)
        shared._holders += 1  # noqa: SLF001
        return shared


def release(box: str, shared: BoxBrowser) -> None:
    """One executor lets go of ``box``; the last one stops its server."""
    with _BOXES_LOCK:
        shared._holders -= 1  # noqa: SLF001
        last = shared._holders <= 0  # noqa: SLF001
        if last and _BOXES.get(box) is shared:
            _BOXES.pop(box, None)
    if last:
        shared.shutdown()


__all__ = [
    "BROWSER_MCP_LAUNCHER",
    "BoxBrowser",
    "acquire",
    "release",
    "TOOLS_FILE",
    "box_of",
    "load_tools",
    "save_tools",
]
