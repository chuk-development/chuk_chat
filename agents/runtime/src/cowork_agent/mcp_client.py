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
import hashlib
import inspect
import json
import os
import re
import threading
import time
from datetime import UTC, datetime, timedelta
from collections.abc import Callable, Sequence
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

#: ``(server_name, config) -> None``, called when a refresh came back with a
#: DIFFERENT refresh token than the one that was spent. The provider has killed
#: the old one at that moment, so the device's copy is now dead: the executor
#: uses this to send the new one back to the app (``mcp_credentials``,
#: docs/WIRE_CONTRACT.md). Rotation is the only event worth reporting — a server
#: that only issues a new access token has told us nothing the app cannot work
#: out for itself.
RotationListener = Callable[[str, "MCPServerConfig"], None]


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


# The native tool-calling contract requires ``^[a-zA-Z0-9_-]{1,64}$`` for a
# function name (chuk_chat docs/NATIVE_TOOL_CALLING.md). A long server + tool
# pair overflows that easily, and an over-long name in ``tools[]`` makes the
# provider reject EVERY request of the run, not just one call.
MAX_TOOL_NAME = 64
_HASH_LEN = 8


def tool_name(server: str, tool: str) -> str:
    """``mcp__<server>__<tool>``, capped at 64 characters.

    An over-long name keeps a prefix and gets a short deterministic hash of the
    full name appended, so it stays unique, stable across runs (``tool_call`` /
    ``tool_describe`` resolve the same string every time) and within the contract.
    """
    name = f"{TOOL_PREFIX}{sanitize(server)}__{sanitize(tool)}"
    if len(name) <= MAX_TOOL_NAME:
        return name
    digest = hashlib.sha1(name.encode("utf-8")).hexdigest()[:_HASH_LEN]
    return f"{name[: MAX_TOOL_NAME - _HASH_LEN - 1]}_{digest}"


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
    #: A resolved bearer token for an HTTP/streamable-HTTP server, attached as
    #: ``Authorization: Bearer <token>`` on every request. This is the forwarded
    #: credential channel: the Flutter host resolves each connection's live token
    #: at task launch and it rides in the sealed ``mcp_servers`` payload. A live
    #: ``token_provider`` (the OAuth stash) still wins over this static value, and
    #: the stdio path never sees it. ``None`` -> today's behavior.
    auth_token: str | None = None
    #: Optional OAuth block. Two shapes share this field, told apart by their
    #: keys, because both describe "how this server authorizes":
    #:
    #: * The §10 bridge shape, from ``mcp.json``:
    #:   ``{"token_url": ..., "client_id": ..., "scopes": [...]}``. The redirect
    #:   URI is never configured here — it is always the backend's public
    #:   callback (:mod:`cowork_agent.oauth_bridge`).
    #: * The forwarded device shape, from the app's sealed ``mcp_servers``
    #:   payload: ``{"token_endpoint": ..., "client_id": ..., "client_secret"?,
    #:   "refresh_token": ..., "expires_at"?, "resource"?, "scope"?, "issuer"?}``
    #:   (docs/WIRE_CONTRACT.md). The user already signed in on the device; this
    #:   is what lets the host mint its own access tokens afterwards.
    #:
    #: ``refresh_access_token`` reads the second shape only, and
    #: :func:`cowork_agent.oauth_bridge.config_token_exchange` reads the first
    #: only, so a block of one shape is inert in the other's code path.
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
        auth_token=(str(raw["auth_token"]) if raw.get("auth_token") else None),
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


# -- forwarded (host-configured) servers -----------------------------------

#: ``auth`` kinds a forwarded ``mcp_servers`` entry may declare. ``appSession``
#: authenticates with the executor's own account bearer (a connector the backend
#: brokers, e.g. GitHub at ``${api}/v1/mcp/github``); ``oauth`` forwards the
#: device's own resolved token; ``none`` (or absent) is unauthenticated.
AUTH_APP_SESSION = "appSession"
AUTH_OAUTH = "oauth"
AUTH_NONE = "none"


def configs_from_entries(
    entries: list[dict] | None,
    *,
    account_token: str | None = None,
) -> tuple[list[MCPServerConfig], list[str]]:
    """Turn the forwarded ``mcp_servers`` list into validated server configs.

    Each entry is ``{name, url, transport, auth, access_token?}`` (``headers``
    and ``env`` are honored too, matching ``mcp.json``). The bearer is resolved
    per ``auth``: an ``appSession`` connector uses ``account_token`` (the
    executor's account, resolved server-side); an ``oauth`` connector uses the
    entry's own forwarded ``access_token``. A malformed entry costs that entry,
    not the batch — it is recorded in the returned errors and skipped, so one
    bad server never crashes the task.
    """
    configs: list[MCPServerConfig] = []
    errors: list[str] = []
    for index, raw in enumerate(entries or []):
        label = f"mcp_servers[{index}]"
        if not isinstance(raw, dict):
            errors.append(f"{label}: entry must be an object")
            continue
        name = str(raw.get("name") or "").strip()
        if not name:
            errors.append(f"{label}: missing 'name'")
            continue
        try:
            config = _one_config(name, raw)
        except ValueError as exc:
            errors.append(f"{name}: {exc}")
            continue
        auth = str(raw.get("auth") or "").strip()
        token: str | None = None
        if auth == AUTH_APP_SESSION:
            token = account_token or None
        elif auth == AUTH_OAUTH:
            token = str(raw["access_token"]) if raw.get("access_token") else None
        if token:
            config.auth_token = token
        # An oauth entry may arrive with no ``access_token`` at all and only an
        # ``oauth`` block: the app has the sign-in but let the bearer lapse
        # while it was closed. That entry is NOT unauthenticated — the first
        # request mints a token from ``oauth.refresh_token``
        # (:meth:`MCPConnection._http_headers`). ``_one_config`` already carried
        # the block over; dropping the entry here is the bug this replaced.
        problem = config.validate()
        if problem:
            errors.append(f"{name}: {problem}")
            continue
        configs.append(config)
    return configs, errors


#: How long before the stated expiry a token is treated as already dead, so a
#: call does not race the clock on its way to the server.
TOKEN_SKEW = timedelta(seconds=30)
#: The shortest gap between two unforced refreshes of one server. It exists for
#: a server whose tokens live no longer than :data:`TOKEN_SKEW`: such a token is
#: "expired" the moment it arrives, and without a floor every single request
#: would mint another one. A 401 still forces a refresh through this.
REFRESH_FLOOR = 30.0


def _parse_expiry(raw: Any) -> datetime | None:
    """The ``expires_at`` of an ``oauth`` block as an aware UTC datetime.

    The app sends ISO 8601 in UTC. A stamp with no zone is read as UTC too:
    guessing the host's local zone would silently shift the expiry by hours,
    and reading it early only costs one extra refresh.
    """
    if not raw:
        return None
    try:
        parsed = datetime.fromisoformat(str(raw).replace("Z", "+00:00"))
    except ValueError:
        return None
    return parsed if parsed.tzinfo else parsed.replace(tzinfo=UTC)


def token_expired(oauth: dict[str, Any] | None) -> bool:
    """True when the ``oauth`` block says its access token has lapsed.

    No ``expires_at`` means "no opinion", which reads as live — an unexpiring
    token is a real thing, and refreshing a working token on every task would
    be worse than the occasional 401.
    """
    expires_at = _parse_expiry((oauth or {}).get("expires_at"))
    if expires_at is None:
        return False
    return datetime.now(UTC) >= expires_at - TOKEN_SKEW


def refresh_access_token(
    oauth: dict[str, Any] | None,
    *,
    timeout: float = 20.0,
) -> tuple[str | None, dict[str, Any]]:
    """Mint a fresh access token from a forwarded ``oauth`` block (RFC 6749).

    This is what lets a run outlive the app. The device signed in once, in a
    browser, and handed over the refresh token, the token endpoint and the
    client it registered; from here on the executor renews the access token
    itself, with the app closed and nobody to consent to anything.

    Returns ``(token, oauth)``. On success ``oauth`` is a copy carrying the new
    ``expires_at`` and, when the server rotated it, the new ``refresh_token``.
    On any failure the token is ``None`` and the block comes back unchanged —
    this never raises, because a connector that cannot renew must cost that
    connector and not the task.
    """
    block = dict(oauth or {})
    refresh_token = str(block.get("refresh_token") or "")
    token_endpoint = str(block.get("token_endpoint") or "")
    if not refresh_token or not token_endpoint:
        return None, block

    import httpx

    client_id = str(block.get("client_id") or "")
    client_secret = block.get("client_secret")
    body = {
        "grant_type": "refresh_token",
        "refresh_token": refresh_token,
    }
    if client_id:
        body["client_id"] = client_id
    for optional in ("resource", "scope"):
        value = block.get(optional)
        if value:
            body[optional] = str(value)

    try:
        response = httpx.post(
            token_endpoint,
            data=body,
            headers={"accept": "application/json"},
            # The client secret goes in the Basic header, not the body: a
            # server that issued one usually insists on it there.
            auth=(client_id, str(client_secret)) if client_secret else None,
            timeout=timeout,
            follow_redirects=True,
        )
        if response.status_code >= 400:
            return None, block
        payload = response.json()
    except Exception:  # noqa: BLE001 — a dead refresh is a dead connector, not a crash
        return None, block

    if not isinstance(payload, dict):
        return None, block
    token = str(payload.get("access_token") or "")
    if not token:
        return None, block

    updated = dict(block)
    # Servers may rotate the refresh token, or keep the old one.
    rotated = payload.get("refresh_token")
    if rotated:
        updated["refresh_token"] = str(rotated)
    expires_in = payload.get("expires_in")
    seconds: int | None
    try:
        seconds = int(expires_in) if expires_in is not None else None
    except (TypeError, ValueError):
        seconds = None
    if seconds is not None:
        updated["expires_at"] = (
            datetime.now(UTC) + timedelta(seconds=seconds)
        ).isoformat()
    else:
        updated.pop("expires_at", None)
    scope = payload.get("scope")
    if scope:
        updated["scope"] = str(scope)
    return token, updated


#: A refused credential, as it shows up in a transport error string. ``401`` is
#: matched only as a standalone word: a plain substring test also fired on a URL
#: path like ``/mcp/401k-planner`` and on port ``4010``, and a needless refresh
#: spends the refresh token, which a rotating server then invalidates.
_UNAUTHORIZED = re.compile(
    r"(?<!\w)401(?!\w)|unauthorized|invalid_token|invalid_grant", re.IGNORECASE
)


def _looks_unauthorized(error: str | None) -> bool:
    """Whether an error reads as "the server refused this credential"."""
    return bool(error) and bool(_UNAUTHORIZED.search(error))


#: Query parameters are where an API-key connector keeps the user's key: the
#: app forwards it on the URL rather than as a bearer. Transport errors quote
#: the URL, and an error string is what ``MCPManager.status`` calls "what the
#: operator sees", so the values are stripped before an error is recorded.
_QUERY_VALUE = re.compile(r"([?&][^=&\s]+=)[^&\s]+")


def _redact(text: str) -> str:
    """An error string with any query-parameter values removed."""
    return _QUERY_VALUE.sub(r"\1<redacted>", text)


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
        on_credentials_rotated: RotationListener | None = None,
    ) -> None:
        self.config = config
        self._token_provider = token_provider
        self._on_rotated = on_credentials_rotated
        #: Serializes token refreshes. Two tool calls that both see an expired
        #: token must not both spend the refresh token — some servers rotate it
        #: and invalidate the old one, so the loser would be left holding a
        #: dead credential.
        self._refresh_lock = threading.Lock()
        #: When the last successful refresh landed (monotonic). A server that
        #: issues a very short-lived token — ``expires_in`` at or under the skew
        #: — would otherwise be "already expired" the instant it answers, and
        #: every request would spend another refresh token on it.
        self._refreshed_at: float | None = None
        self._thread: threading.Thread | None = None
        self._loop: asyncio.AbstractEventLoop | None = None
        self._session: Any = None
        self._stop: asyncio.Event | None = None
        self._ready = threading.Event()
        self._tools: list[MCPToolInfo] = []
        self._error: str | None = None
        self._closed = False
        #: True once a handshake has succeeded. It separates "this server is
        #: unreachable" from "this session dropped": the second is worth
        #: redialing on the next task, the first only wastes a connect timeout.
        self._connected_once = False

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

    @property
    def connected_once(self) -> bool:
        """Whether this server ever completed a handshake."""
        return self._connected_once

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
                self._error = _redact(f"{type(exc).__name__}: {_clip(exc, 300)}")
                return
            self._tools = _tool_infos(listed)
            self._session = session
            self._error = None
            self._connected_once = True
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
        """The request headers, with the bearer resolved.

        Precedence, in order: a live OAuth token from the stash; the forwarded
        bearer while it has not lapsed; a token minted here from the forwarded
        refresh material; and, if that fails, the forwarded bearer anyway — the
        server is the authority on whether it is still good, and a request that
        gets a 401 is better than one sent with no credential at all.
        """
        headers = dict(self.config.headers)
        token = None
        if self._token_provider is not None:
            try:
                token = self._token_provider(self.config.name)
            except Exception:  # noqa: BLE001 — a stash miss is not a failure
                token = None
        if not token:
            forwarded = self.config.auth_token or None
            if forwarded and not token_expired(self.config.oauth):
                token = forwarded
            else:
                token = self.refresh_token() or forwarded
        if token:
            headers["Authorization"] = f"Bearer {token}"
        return headers

    def refresh_token(self, *, force: bool = False) -> str | None:
        """Mint a new access token from the forwarded ``oauth`` block.

        Returns the token, or ``None`` when there is no refresh material or the
        server refused. The new token and the possibly rotated refresh token are
        written back onto the config, so the rest of the task uses them and the
        executor can forward the fresh state on.

        ``force`` skips the "is it expired" question, which is what a 401 means:
        the server has already told us the token is no good, whatever its stated
        expiry said.
        """
        with self._refresh_lock:
            oauth = self.config.oauth
            if not oauth.get("refresh_token"):
                return None
            # Another caller may have refreshed while this one waited on the
            # lock; a token that is live again needs no second round trip.
            if not force and self.config.auth_token:
                if not token_expired(oauth):
                    return self.config.auth_token
                minted = self._refreshed_at
                if minted is not None and time.monotonic() - minted < REFRESH_FLOOR:
                    return self.config.auth_token
            token, updated = refresh_access_token(oauth)
            if not token:
                return None
            rotated = updated.get("refresh_token") != oauth.get("refresh_token")
            self.config.auth_token = token
            self.config.oauth = updated
            self._refreshed_at = time.monotonic()
        # Outside the lock: the listener writes a frame, and the executor takes
        # this same lock when it adopts credentials from a task payload.
        if rotated and self._on_rotated is not None:
            try:
                self._on_rotated(self.config.name, self.config)
            except Exception:  # noqa: BLE001 — reporting must not fail a call
                pass
        return token

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
            error = _redact(f"{type(exc).__name__}: {_clip(exc, 500)}")
            # The SDK can close its reader while our transport thread remains
            # parked on _stop. Do not keep advertising that session as alive.
            # The next call/task can reconnect; never replay an arbitrary tool
            # whose side effects may already have happened before disconnection.
            if isinstance(exc, (BrokenPipeError, ConnectionError)) or (
                type(exc).__name__ in ("McpError", "MCPError")
                and "connection closed" in str(exc).lower()
            ):
                self._error = error
            return {
                "ok": False,
                "server": self.config.name,
                "tool": tool,
                "error": error,
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
        on_credentials_rotated: RotationListener | None = None,
        connection_factory: Callable[[MCPServerConfig], MCPConnection] | None = None,
    ) -> None:
        self.configs = list(configs or [])
        self.errors: list[str] = list(errors or [])
        self.connections: dict[str, MCPConnection] = {}
        self._token_provider = token_provider
        self._on_rotated = on_credentials_rotated
        self._factory = connection_factory or (
            lambda config: MCPConnection(
                config,
                token_provider=token_provider,
                on_credentials_rotated=on_credentials_rotated,
            )
        )
        self._registered: set[str] = set()

    @classmethod
    def from_workspace(
        cls,
        workspace: str | None,
        *,
        token_provider: TokenProvider | None = None,
        on_credentials_rotated: RotationListener | None = None,
        connection_factory: Callable[[MCPServerConfig], MCPConnection] | None = None,
    ) -> "MCPManager":
        configs, errors = load_mcp_config(workspace)
        return cls(
            configs,
            errors=errors,
            token_provider=token_provider,
            on_credentials_rotated=on_credentials_rotated,
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
                # A manager is cached per session and started again for every
                # task. A server that died during the last task must get a
                # chance to come back, or its tools are simply absent from the
                # prompt for the rest of the session.
                status[config.name] = self._revive(config.name)
                continue
            connection = self._factory(config)
            self.connections[config.name] = connection
            try:
                ok = connection.start()
            except Exception as exc:  # noqa: BLE001
                ok = False
                connection._error = _redact(f"{type(exc).__name__}: {exc}")  # noqa: SLF001
            if not ok and self._retry_with_fresh_token(config.name):
                ok = True
            status[config.name] = ok
            if not ok:
                connection = self.connections[config.name]
                self.errors.append(
                    f"{config.name}: not available ({connection.error or 'unknown error'})"
                )
        return status

    def _revive(self, server: str) -> bool:
        """Whether [server] is usable, redialing it once if it is not.

        Called on an already-known connection. A refused credential is renewed
        and redialed; a session that dropped after a good handshake is redialed
        as it is; a server that never answered at all is left alone, because
        redialing it costs a full connect timeout on every task and it has
        already had its chance.
        """
        connection = self.connections.get(server)
        if connection is None:
            return False
        if connection.alive():
            return True
        if self._retry_with_fresh_token(server):
            return True
        if connection.connected_once:
            return self.reconnect(server)
        return False

    def _retry_with_fresh_token(self, server: str, *, refused: bool = False) -> bool:
        """After a refused handshake, mint a new token and dial again, once.

        This is the case the whole forwarded ``oauth`` block exists for: the app
        is closed, the bearer it handed over has died, and the server answers
        the handshake with a 401. Nobody can open a browser, so the executor
        renews the token itself and reconnects. A server that refuses for any
        other reason is left alone — retrying a 404 achieves nothing.
        """
        connection = self.connections.get(server)
        if connection is None:
            return False
        # ``refused`` is the caller saying "the server just answered a call with
        # a 401", which the connection itself cannot know: a tool-call failure
        # leaves the session up and ``error`` unset.
        if not refused and not _looks_unauthorized(connection.error):
            return False
        if connection.refresh_token(force=True) is None:
            return False
        return self.reconnect(server)

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
                if registry.has(full):
                    # Present in THIS registry already. If it is one of ours, this
                    # is a re-registration into the same registry — skip silently.
                    # If it is not ours, it is a real name clash worth recording,
                    # once. A per-session manager is registered into a fresh
                    # registry each task, so ``self._registered`` must not
                    # short-circuit that — the registry is the source of truth.
                    if full not in self._registered:
                        self.errors.append(
                            f"{name}: duplicate tool name {full}, skipped"
                        )
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
        # A long task can outlive the token the session was opened with. If the
        # session went down on a refused handshake, renew and redial before
        # telling the model the tool is gone.
        if not connection.alive() and self._revive(server):
            connection = self.connections.get(server, connection)
        result = connection.call(tool, arguments)
        # The headers are fixed when the transport is built, so a token that
        # lapses mid-session cannot be renewed in place — the server answers the
        # call with a 401 while the session stays up and healthy-looking. That is
        # the normal case for a run that outlives its token, so it is worth one
        # renew-and-redial before the model is told the tool failed.
        if result.get("ok") is False and _looks_unauthorized(result.get("error")):
            if self._retry_with_fresh_token(server, refused=True):
                return self.connections.get(server, connection).call(tool, arguments)
        return result

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
            connection._error = _redact(f"{type(exc).__name__}: {exc}")  # noqa: SLF001
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


# -- forcing the browser GUI open (bead cowork-bxvh) --------------------------
#
# ``@playwright/mcp`` starts **no browser** when it starts. It launches Chromium
# on the first browser tool call and not a moment earlier — verified on a live
# sandbox container: ``playwright-mcp`` and Xvfb running, x11vnc serving the
# display, and not a single chrome process on it. The app's live view streams
# that display, so a session where nobody has called a browser tool yet shows an
# empty root window: the black rectangle the user reported.
#
# The fix is one harmless tool call, made when the server connects, off the
# critical path. From then on there is a real window on the display for the
# whole session.
#
# Which call: ``browser_tabs {"action": "list"}``. Listing the tabs needs a
# browser, so the server launches one (measured in a container from
# ``Dockerfile.browser``: 0 windows on ``:99`` before the call, 2 after), and
# unlike a navigation it throws nothing away — the next task in the same
# session finds the page the last one left open, which is the whole point of
# the persistent profile. ``browser_navigate about:blank`` is the fallback for
# a server without ``browser_tabs``.

#: The side-effect-free call that launches the browser.
BROWSER_OPEN_TOOL = "browser_tabs"
BROWSER_OPEN_ARGS: dict[str, Any] = {"action": "list"}
#: The fallback, for a Playwright-family server without ``browser_tabs``.
BROWSER_LAUNCH_TOOL = "browser_navigate"
#: Where that fallback navigation goes. ``about:blank`` is free and offline.
BROWSER_HOME_ENV = "COWORK_BROWSER_HOME"
DEFAULT_BROWSER_HOME = "about:blank"
#: Set to 0/false to keep the old lazy behaviour (no window until the agent
#: browses). The default is on: the user asked for the GUI to open every time.
BROWSER_AUTO_OPEN_ENV = "COWORK_BROWSER_AUTO_OPEN"

_FALSE = {"0", "false", "no", "off"}


def browser_home(url: str | None = None) -> str:
    """The URL the forced first navigation goes to."""
    text = (url or os.environ.get(BROWSER_HOME_ENV, "")).strip()
    return text or DEFAULT_BROWSER_HOME


def auto_open_enabled(value: str | None = None) -> bool:
    """Should a connected browser server be opened on sight? Default yes."""
    raw = value if value is not None else os.environ.get(BROWSER_AUTO_OPEN_ENV, "")
    return raw.strip().lower() not in _FALSE


def open_call(tools: Sequence[str], *, url: str | None = None) -> tuple[str, dict] | None:
    """The call that launches a browser on a server offering ``tools``.

    ``None`` when the server is not a browser at all, which is every other MCP
    server in the config and must cost nothing.
    """
    names = set(tools)
    if BROWSER_OPEN_TOOL in names:
        return BROWSER_OPEN_TOOL, dict(BROWSER_OPEN_ARGS)
    if BROWSER_LAUNCH_TOOL in names:
        return BROWSER_LAUNCH_TOOL, {"url": browser_home(url)}
    return None


def browser_servers(manager: MCPManager | None) -> list[str]:
    """Names of the connected servers that can launch a browser."""
    if manager is None:
        return []
    names: list[str] = []
    for name, connection in manager.connections.items():
        if not connection.alive():
            continue
        if open_call([info.name for info in connection.tools]) is not None:
            names.append(name)
    return names


def open_browser_gui(manager: MCPManager | None, *, url: str | None = None) -> list[str]:
    """Make every connected browser server put a window on its display.

    Blocking, and never raises: :meth:`MCPManager.call` reports a failure as a
    result, and a browser that refuses to open must not take the run down with
    it. Returns the servers that answered ``ok``.
    """
    opened: list[str] = []
    for name in browser_servers(manager):
        connection = manager.connections[name]
        call = open_call([info.name for info in connection.tools], url=url)
        if call is None:  # pragma: no cover - browser_servers just said it has one
            continue
        tool, arguments = call
        if manager.call(name, tool, arguments).get("ok"):
            opened.append(name)
    return opened


def open_browser_gui_async(
    manager: MCPManager | None, *, url: str | None = None
) -> threading.Thread | None:
    """:func:`open_browser_gui` on a daemon thread, or ``None`` when there is
    nothing to open.

    Off the critical path on purpose: launching Chromium costs a second or two
    and the first model round must not wait for it. The window appears while the
    agent is still reading its prompt.
    """
    if not auto_open_enabled() or not browser_servers(manager):
        return None
    thread = threading.Thread(
        target=lambda: open_browser_gui(manager, url=url),
        name="browser-gui-open",
        daemon=True,
    )
    thread.start()
    return thread


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
