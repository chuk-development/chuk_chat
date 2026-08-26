"""MCP client — the fallback protocol (§9).

MCP is **not** the primary integration path. A hand-built API tool with
revocable credential delegation (§10) beats an MCP server every time, because we
control the schema, the token never enters the sandbox, and the result is shaped
for the model. MCP exists for the long tail: a service nobody wrote a tool for
yet, and a server the user already runs.

What this module is:

- The **official ``mcp`` Python SDK** as the client, with **all three
  transports** — ``stdio`` (a local subprocess), ``sse`` (legacy HTTP+SSE) and
  ``streamable_http`` (the current HTTP transport).
- One **persistent transport thread per server**: the thread owns an asyncio
  loop, the loop owns the transport and the ``ClientSession``, and the session
  therefore lives across tool calls. Handshake and tool listing happen once, not
  once per call. Calls arrive from the agent's synchronous loop through
  :func:`asyncio.run_coroutine_threadsafe`.
- Configuration from a **file in the workspace** (``mcp.json`` or
  ``.cowork/mcp.json``), in the same shape editors already use::

      {
        "mcpServers": {
          "sqlite":  {"command": "uvx", "args": ["mcp-server-sqlite", "--db", "x.db"]},
          "tickets": {"url": "https://mcp.example.com/mcp"},
          "legacy":  {"url": "https://mcp.example.com/sse", "transport": "sse"}
        }
      }

  ``command`` means stdio. A ``url`` means streamable HTTP unless
  ``"transport": "sse"`` says otherwise.
- Tools land in the registry as ``mcp__<server>__<tool>`` with the server's own
  JSON schema, marked **deferrable** so Tool Search (§7.2) can hide them from
  the prompt when there are many.

**A broken server never breaks the start.** Connect failures are caught,
recorded in :attr:`MCPManager.errors`, and that server simply contributes no
tools. A server that dies later fails its ``check_fn``, so
:func:`cowork_agent.prompt.render_tool_docs` drops its tools from the prompt.

Credentials (§10): this module never reads a secret from disk or from the
environment of its own accord. An HTTP server's bearer token, if any, comes from
an injected ``token_provider`` — in production the in-memory stash of
:mod:`cowork_agent.oauth_bridge`, which is the documented exception to "no raw
secret in the sandbox" and is bounded there. A user *can* still put a key in an
``env`` or ``headers`` block of ``mcp.json``; that is their choice and it is a
plaintext secret in the workspace, which is exactly what §10 avoids. Prefer
``mcp_oauth_connect``, or a native tool.
"""

from __future__ import annotations

import asyncio
import inspect
import json
import re
import threading
from datetime import timedelta
from collections.abc import Callable
from contextlib import AsyncExitStack
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .registry import ToolRegistry

# Where a workspace keeps its server list, most specific first.
CONFIG_NAMES = (".cowork/mcp.json", "mcp.json")

STDIO = "stdio"
SSE = "sse"
HTTP = "http"
TRANSPORTS = (STDIO, SSE, HTTP)

#: Cap on one tool result. An MCP server can return a whole database dump and
#: the result travels straight into the prompt.
RESULT_CAP = 20_000
#: Cap on a tool description taken from a server. Level-1 prompt weight.
DESCRIPTION_CAP = 800
#: A server that advertises hundreds of tools would drown the registry.
MAX_TOOLS_PER_SERVER = 200

CONNECT_TIMEOUT = 20.0
CALL_TIMEOUT = 120.0
#: How long ``close`` waits for the transport thread to unwind before giving up.
CLOSE_TIMEOUT = 10.0

TOOL_PREFIX = "mcp__"
_UNSAFE = re.compile(r"[^A-Za-z0-9_]+")

#: ``(server, tool) -> bearer token or None``. Satisfied by
#: :class:`cowork_agent.oauth_bridge.CredentialStash`.
TokenProvider = Callable[[str], "str | None"]


def _read_timeout(seconds: float) -> Any:
    """``ClientSession(read_timeout_seconds=...)`` takes a ``timedelta`` in the
    ``mcp`` 1.x line and a float in 2.x. browser-use 0.13.7 pins ``mcp==1.26.0``,
    so the runtime has to satisfy both instead of picking a winner: read the
    annotation of the installed SDK and hand over what it asks for."""
    from mcp import ClientSession  # imported late: the SDK is an optional dep

    parameter = inspect.signature(ClientSession.__init__).parameters.get(
        "read_timeout_seconds"
    )
    hint = "" if parameter is None else str(parameter.annotation)
    if "timedelta" in hint:
        return timedelta(seconds=seconds)
    return seconds


def _clip(value: Any, cap: int) -> str:
    text = value if isinstance(value, str) else ("" if value is None else str(value))
    text = text.strip()
    return text if len(text) <= cap else text[:cap].rstrip() + "…[truncated]"


def sanitize(part: str) -> str:
    """Make one name segment safe for a tool name. Models copy tool names
    verbatim, so a space or a slash in a server name is a broken call."""
    return _UNSAFE.sub("_", (part or "").strip()).strip("_") or "unnamed"


def tool_name(server: str, tool: str) -> str:
    return f"{TOOL_PREFIX}{sanitize(server)}__{sanitize(tool)}"


# -- configuration ---------------------------------------------------------


@dataclass
class MCPServerConfig:
    """One configured server. Validated at load time, never at call time."""

    name: str
    transport: str = STDIO
    # stdio
    command: str | None = None
    args: list[str] = field(default_factory=list)
    env: dict[str, str] = field(default_factory=dict)
    cwd: str | None = None
    # sse / http
    url: str | None = None
    headers: dict[str, str] = field(default_factory=dict)
    #: Optional OAuth block for a server that authorizes its own clients:
    #: ``{"token_url": ..., "client_id": ..., "scopes": [...]}``. The redirect
    #: URI is never configured here — it is always the backend's public callback
    #: (§10, :mod:`cowork_agent.oauth_bridge`).
    oauth: dict[str, Any] = field(default_factory=dict)
    enabled: bool = True
    connect_timeout: float = CONNECT_TIMEOUT
    call_timeout: float = CALL_TIMEOUT

    def validate(self) -> str | None:
        """Return an error string, or ``None`` when the config can be started."""
        if self.transport not in TRANSPORTS:
            return f"unknown transport {self.transport!r}"
        if self.transport == STDIO:
            if not self.command:
                return "stdio server needs a 'command'"
        elif not self.url:
            return f"{self.transport} server needs a 'url'"
        elif not str(self.url).lower().startswith(("http://", "https://")):
            return "url must be http:// or https://"
        return None


def _one_config(name: str, raw: Any) -> MCPServerConfig:
    if not isinstance(raw, dict):
        raise ValueError("server entry must be an object")
    url = raw.get("url") or raw.get("endpoint")
    declared = str(raw.get("transport") or raw.get("type") or "").strip().lower()
    if declared in ("streamable-http", "streamable_http", "http", "https"):
        declared = HTTP
    if declared not in TRANSPORTS:
        # Infer: a command is a subprocess, a URL is HTTP. An `/sse` path is the
        # legacy transport often enough that the guess is worth making.
        if raw.get("command"):
            declared = STDIO
        elif url:
            declared = SSE if str(url).rstrip("/").endswith("/sse") else HTTP
        else:
            declared = STDIO
    env = raw.get("env") or {}
    headers = raw.get("headers") or {}
    return MCPServerConfig(
        name=name,
        transport=declared,
        command=raw.get("command"),
        args=[str(a) for a in (raw.get("args") or [])],
        env={str(k): str(v) for k, v in env.items()} if isinstance(env, dict) else {},
        cwd=raw.get("cwd"),
        url=url,
        headers=(
            {str(k): str(v) for k, v in headers.items()}
            if isinstance(headers, dict)
            else {}
        ),
        oauth=dict(raw["oauth"]) if isinstance(raw.get("oauth"), dict) else {},
        enabled=bool(raw.get("enabled", True)) and not bool(raw.get("disabled", False)),
        connect_timeout=float(raw.get("connect_timeout", CONNECT_TIMEOUT)),
        call_timeout=float(raw.get("call_timeout", CALL_TIMEOUT)),
    )


def parse_mcp_config(text: str) -> tuple[list[MCPServerConfig], list[str]]:
    """Parse a config document. Returns ``(configs, errors)``.

    A malformed entry costs that entry, not the file: one typo in one server
    must not take the other servers — or the run — down with it.
    """
    errors: list[str] = []
    try:
        body = json.loads(text)
    except ValueError as exc:
        return [], [f"mcp config is not valid JSON: {exc}"]
    if not isinstance(body, dict):
        return [], ["mcp config must be a JSON object"]
    servers = body.get("mcpServers")
    if not isinstance(servers, dict):
        servers = body.get("servers")
    if not isinstance(servers, dict):
        return [], ["mcp config has no 'mcpServers' object"]

    configs: list[MCPServerConfig] = []
    for name, raw in servers.items():
        try:
            config = _one_config(str(name), raw)
        except ValueError as exc:
            errors.append(f"{name}: {exc}")
            continue
        problem = config.validate()
        if problem:
            errors.append(f"{name}: {problem}")
            continue
        configs.append(config)
    return configs, errors


def load_mcp_config(
    workspace: str | None,
) -> tuple[list[MCPServerConfig], list[str]]:
    """Read the workspace's server list. No file → no servers, no error."""
    if not workspace:
        return [], []
    for relative in CONFIG_NAMES:
        path = Path(workspace) / relative
        try:
            if not path.is_file():
                continue
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError as exc:
            return [], [f"{path}: {exc}"]
        configs, errors = parse_mcp_config(text)
        return configs, [f"{relative}: {e}" for e in errors]
    return [], []


# -- one connection --------------------------------------------------------


@dataclass
class MCPToolInfo:
    name: str
    description: str
    schema: dict


class MCPConnection:
    """One server, one thread, one long-lived ``ClientSession``.

    The thread is the whole point. The MCP SDK is asyncio and its transports are
    async context managers that must be entered and exited **in the same task**;
    a per-call ``asyncio.run`` would therefore re-spawn the subprocess, redo the
    handshake and re-list the tools on every single call. Here one task inside
    one loop opens the transport, initializes, lists the tools, and then parks on
    a stop event, so every later call is one round trip on an established
    session.
    """

    def __init__(
        self,
        config: MCPServerConfig,
        *,
        token_provider: TokenProvider | None = None,
    ) -> None:
        self.config = config
        self._token_provider = token_provider
        self._thread: threading.Thread | None = None
        self._loop: asyncio.AbstractEventLoop | None = None
        self._session: Any = None
        self._stop: asyncio.Event | None = None
        self._ready = threading.Event()
        self._tools: list[MCPToolInfo] = []
        self._error: str | None = None
        self._closed = False

    # -- lifecycle --------------------------------------------------------

    @property
    def name(self) -> str:
        return self.config.name

    @property
    def error(self) -> str | None:
        return self._error

    @property
    def tools(self) -> list[MCPToolInfo]:
        return list(self._tools)

    def alive(self) -> bool:
        """The ``check_fn`` behind every tool of this server."""
        if self._closed or self._error is not None:
            return False
        thread = self._thread
        return bool(
            self._ready.is_set()
            and self._session is not None
            and thread is not None
            and thread.is_alive()
        )

    def start(self) -> bool:
        """Connect, handshake and list tools. Returns ``False`` and sets
        :attr:`error` instead of raising — one unreachable server must not stop
        the agent from starting."""
        if self._thread is not None:
            return self.alive()
        problem = self.config.validate()
        if problem:
            self._error = problem
            return False
        self._thread = threading.Thread(
            target=self._serve,
            name=f"mcp-{sanitize(self.config.name)}",
            daemon=True,
        )
        self._thread.start()
        if not self._ready.wait(self.config.connect_timeout + 5.0):
            self._error = self._error or "connect timed out"
            return False
        return self.alive()

    def close(self) -> None:
        self._closed = True
        loop, stop, thread = self._loop, self._stop, self._thread
        if loop is not None and stop is not None and not loop.is_closed():
            try:
                loop.call_soon_threadsafe(stop.set)
            except RuntimeError:
                pass
        if thread is not None:
            thread.join(CLOSE_TIMEOUT)
        self._session = None

    # -- the transport thread ---------------------------------------------

    def _serve(self) -> None:
        try:
            asyncio.run(self._session_task())
        except Exception as exc:  # noqa: BLE001 — the thread reports, never raises
            self._error = f"{type(exc).__name__}: {exc}"
        finally:
            self._session = None
            # Unblock a `start()` that is still waiting on a failed connect.
            self._ready.set()

    async def _session_task(self) -> None:
        from mcp import ClientSession

        self._loop = asyncio.get_running_loop()
        self._stop = asyncio.Event()
        async with AsyncExitStack() as stack:
            try:
                streams = await asyncio.wait_for(
                    stack.enter_async_context(self._transport()),
                    timeout=self.config.connect_timeout,
                )
                # Two streams, or two plus transport extras depending on the
                # transport. Only the first two are the session's.
                read, write = streams[0], streams[1]
                session = await stack.enter_async_context(
                    ClientSession(
                        read, write, read_timeout_seconds=_read_timeout(self.config.call_timeout)
                    )
                )
                await asyncio.wait_for(
                    session.initialize(), timeout=self.config.connect_timeout
                )
                listed = await asyncio.wait_for(
                    session.list_tools(), timeout=self.config.connect_timeout
                )
            except asyncio.TimeoutError:
                self._error = "connect timed out"
                return
            except Exception as exc:  # noqa: BLE001
                self._error = f"{type(exc).__name__}: {_clip(exc, 300)}"
                return
            self._tools = _tool_infos(listed)
            self._session = session
            self._error = None
            self._ready.set()
            # Park. The session stays open until close() sets the stop event, so
            # every tool call reuses this handshake.
            await self._stop.wait()

    def _transport(self):
        """The one place the three transports differ."""
        config = self.config
        if config.transport == STDIO:
            from mcp import StdioServerParameters
            from mcp.client.stdio import get_default_environment, stdio_client

            # Merged, not replaced: handing the SDK a bare ``{"API_KEY": ...}``
            # would launch the server without PATH or HOME, which breaks most of
            # them in a way that looks like "the server is broken".
            environment = {**get_default_environment(), **config.env}
            return stdio_client(
                StdioServerParameters(
                    command=config.command or "",
                    args=list(config.args),
                    env=environment,
                    cwd=config.cwd,
                )
            )
        headers = self._http_headers()
        if config.transport == SSE:
            from mcp.client.sse import sse_client

            return sse_client(
                config.url or "",
                headers=headers or None,
                timeout=config.connect_timeout,
            )
        from mcp.client.streamable_http import streamable_http_client

        return streamable_http_client(
            config.url or "", http_client=self._http_client(headers)
        )

    def _http_client(self, headers: dict[str, str]):
        """The streamable-HTTP transport takes a client, not headers, so auth
        rides on a client built here."""
        import httpx

        return httpx.AsyncClient(
            headers=headers or None,
            timeout=self.config.call_timeout,
            follow_redirects=True,
        )

    def _http_headers(self) -> dict[str, str]:
        headers = dict(self.config.headers)
        token = None
        if self._token_provider is not None:
            try:
                token = self._token_provider(self.config.name)
            except Exception:  # noqa: BLE001 — a stash miss is not a failure
                token = None
        if token:
            headers["Authorization"] = f"Bearer {token}"
        return headers

    # -- calls ------------------------------------------------------------

    def call(self, tool: str, arguments: dict | None = None) -> dict:
        """Call one tool on the live session. Never raises."""
        session, loop = self._session, self._loop
        if not self.alive() or session is None or loop is None:
            return {
                "ok": False,
                "server": self.config.name,
                "tool": tool,
                "error": self._error or "mcp server not connected",
            }
        timeout = self.config.call_timeout
        future = None
        try:
            future = asyncio.run_coroutine_threadsafe(
                session.call_tool(tool, dict(arguments or {})), loop
            )
            result = future.result(timeout=timeout + 5.0)
        except TimeoutError:
            # Cancel it, or a hung server keeps a request alive on the session
            # for the rest of the run.
            if future is not None:
                future.cancel()
            return {
                "ok": False,
                "server": self.config.name,
                "tool": tool,
                "error": f"mcp call timed out after {timeout:.0f}s",
            }
        except Exception as exc:  # noqa: BLE001
            return {
                "ok": False,
                "server": self.config.name,
                "tool": tool,
                "error": f"{type(exc).__name__}: {_clip(exc, 500)}",
            }
        return _normalize_result(self.config.name, tool, result)


def _tool_infos(listed: Any) -> list[MCPToolInfo]:
    tools = getattr(listed, "tools", None) or []
    infos: list[MCPToolInfo] = []
    for tool in tools[:MAX_TOOLS_PER_SERVER]:
        name = getattr(tool, "name", "") or ""
        if not name:
            continue
        schema = getattr(tool, "input_schema", None) or getattr(tool, "inputSchema", None)
        if not isinstance(schema, dict):
            schema = {"type": "object", "properties": {}}
        infos.append(
            MCPToolInfo(
                name=name,
                description=_clip(getattr(tool, "description", ""), DESCRIPTION_CAP),
                schema=schema,
            )
        )
    return infos


def _normalize_result(server: str, tool: str, result: Any) -> dict:
    """Flatten an SDK ``CallToolResult`` into the plain dict shape every other
    tool in this runtime returns, bounded so one call cannot blow the context."""
    blocks = getattr(result, "content", None) or []
    chunks: list[str] = []
    for block in blocks:
        text = getattr(block, "text", None)
        if isinstance(text, str) and text:
            chunks.append(text)
            continue
        kind = getattr(block, "type", None) or type(block).__name__
        chunks.append(f"[{kind} content omitted]")
    payload: dict[str, Any] = {
        "ok": not bool(getattr(result, "is_error", False)),
        "server": server,
        "tool": tool,
        "content": _clip("\n".join(chunks), RESULT_CAP),
    }
    structured = getattr(result, "structured_content", None)
    if isinstance(structured, dict) and structured:
        try:
            encoded = json.dumps(structured)
        except (TypeError, ValueError):
            encoded = ""
        payload["structured"] = (
            structured if 0 < len(encoded) <= RESULT_CAP else {"truncated": True}
        )
    if not payload["ok"]:
        payload["error"] = payload.pop("content") or "mcp tool reported an error"
    return payload


# -- the manager -----------------------------------------------------------


def _tool_schema(server: str, info: MCPToolInfo) -> dict:
    """Wrap a server's input schema as one of ours: same top-level shape, so
    ``render_tool_block`` documents it and the registry coerces its args."""
    properties = info.schema.get("properties")
    required = info.schema.get("required")
    description = info.description or f"Tool {info.name} of the MCP server {server}."
    return {
        "type": "object",
        "description": f"[MCP: {server}] {description}",
        "properties": properties if isinstance(properties, dict) else {},
        "required": [str(r) for r in required] if isinstance(required, list) else [],
    }


class MCPManager:
    """Owns every configured connection and puts their tools in the registry."""

    def __init__(
        self,
        configs: list[MCPServerConfig] | None = None,
        *,
        errors: list[str] | None = None,
        token_provider: TokenProvider | None = None,
        connection_factory: Callable[[MCPServerConfig], MCPConnection] | None = None,
    ) -> None:
        self.configs = list(configs or [])
        self.errors: list[str] = list(errors or [])
        self.connections: dict[str, MCPConnection] = {}
        self._token_provider = token_provider
        self._factory = connection_factory or (
            lambda config: MCPConnection(config, token_provider=token_provider)
        )
        self._registered: set[str] = set()

    @classmethod
    def from_workspace(
        cls,
        workspace: str | None,
        *,
        token_provider: TokenProvider | None = None,
        connection_factory: Callable[[MCPServerConfig], MCPConnection] | None = None,
    ) -> "MCPManager":
        configs, errors = load_mcp_config(workspace)
        return cls(
            configs,
            errors=errors,
            token_provider=token_provider,
            connection_factory=connection_factory,
        )

    def start(self) -> dict[str, bool]:
        """Connect every enabled server. Returns ``{name: connected}``.

        A failure is recorded and skipped. This function does not raise, because
        the alternative is an agent that will not start because a side-quest MCP
        server is down.
        """
        status: dict[str, bool] = {}
        for config in self.configs:
            if not config.enabled:
                continue
            if config.name in self.connections:
                status[config.name] = self.connections[config.name].alive()
                continue
            connection = self._factory(config)
            self.connections[config.name] = connection
            try:
                ok = connection.start()
            except Exception as exc:  # noqa: BLE001
                ok = False
                connection._error = f"{type(exc).__name__}: {exc}"  # noqa: SLF001
            status[config.name] = ok
            if not ok:
                self.errors.append(
                    f"{config.name}: not available ({connection.error or 'unknown error'})"
                )
        return status

    def register(self, registry: ToolRegistry) -> list[str]:
        """Register the tools of every connected server.

        Returns the registered names. A server that failed to connect
        contributes nothing — a tool documented to the model that can only fail
        is worse than an absent one. Everything registered here is
        ``deferrable=True``: MCP tools are exactly the surface Tool Search
        (§7.2) is allowed to hide.
        """
        registered: list[str] = []
        for name, connection in self.connections.items():
            if not connection.alive():
                continue
            for info in connection.tools:
                full = tool_name(name, info.name)
                if full in self._registered:
                    continue
                if registry.has(full):
                    self.errors.append(f"{name}: duplicate tool name {full}, skipped")
                    continue
                registry.register(
                    full,
                    _tool_schema(name, info),
                    # Bound to the manager, not to this connection object, so a
                    # reconnect (after an OAuth sign-in, say) is picked up by
                    # every already-registered tool of that server.
                    _make_handler(self, name, info.name),
                    check_fn=_make_check(self, name),
                    deferrable=True,
                )
                self._registered.add(full)
                registered.append(full)
        return registered

    # -- call routing -----------------------------------------------------

    def is_alive(self, server: str) -> bool:
        connection = self.connections.get(server)
        return bool(connection and connection.alive())

    def call(self, server: str, tool: str, arguments: dict | None = None) -> dict:
        connection = self.connections.get(server)
        if connection is None:
            return {
                "ok": False,
                "server": server,
                "tool": tool,
                "error": f"mcp server not configured: {server}",
            }
        return connection.call(tool, arguments)

    def reconnect(self, server: str) -> bool:
        """Drop and re-open one server's session.

        The step after an OAuth sign-in: the transport is rebuilt, so the new
        bearer token from the stash is picked up on the handshake. Already
        registered tools keep working because they route through this manager.
        """
        config = next((c for c in self.configs if c.name == server), None)
        if config is None:
            return False
        old = self.connections.pop(server, None)
        if old is not None:
            try:
                old.close()
            except Exception:  # noqa: BLE001
                pass
        connection = self._factory(config)
        self.connections[server] = connection
        try:
            ok = connection.start()
        except Exception as exc:  # noqa: BLE001
            connection._error = f"{type(exc).__name__}: {exc}"  # noqa: SLF001
            ok = False
        return ok

    def status(self) -> list[dict]:
        """What the operator sees: one row per configured server."""
        rows: list[dict] = []
        for config in self.configs:
            connection = self.connections.get(config.name)
            rows.append(
                {
                    "server": config.name,
                    "transport": config.transport,
                    "connected": bool(connection and connection.alive()),
                    "tools": len(connection.tools) if connection else 0,
                    "error": (connection.error if connection else None)
                    or ("disabled" if not config.enabled else None),
                }
            )
        return rows

    def close(self) -> None:
        for connection in self.connections.values():
            try:
                connection.close()
            except Exception:  # noqa: BLE001 — shutdown must not raise
                pass


def _make_handler(manager: "MCPManager", server: str, tool: str):
    def handler(**kwargs: Any) -> dict:
        return manager.call(server, tool, kwargs)

    return handler


def _make_check(manager: "MCPManager", server: str):
    def check() -> bool:
        return manager.is_alive(server)

    return check


def register_mcp_tools(
    registry: ToolRegistry,
    manager: MCPManager | None,
) -> list[str]:
    """Start the configured servers and register what answered.

    Returns the registered tool names, so the caller can measure the deferrable
    prompt surface (§7.2).
    """
    if manager is None:
        return []
    manager.start()
    return manager.register(registry)
