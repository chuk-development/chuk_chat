"""Dashboard-mediated OAuth bridge for MCP servers (§10).

The problem: an MCP server that wants OAuth hands its client a redirect URI —
almost always ``http://localhost:<port>/callback``. Inside a sandbox that URI is
unreachable from the user's browser. There is no inbound port, and opening one
(a tunnel, a reverse proxy) would be a hole in the exact wall the sandbox is.

The fix, and it is not a workaround: **do not route the redirect into the
sandbox at all.**

1. The agent asks the backend to open a flow. The backend registers the pending
   flow under an opaque ``state`` and returns the provider's authorize URL, whose
   ``redirect_uri`` is the backend's own **public** URL,
   ``https://api.chuk.chat/oauth/callback/{server}``.
2. The user opens that URL in a normal browser on a normal machine and
   authorizes. The provider redirects to the backend — a public HTTPS endpoint
   that exists to be redirected to.
3. The backend correlates the callback to the pending flow with a
   **constant-time ``state`` compare**, keeps it for one single read, and hands
   **only the ``code``** onward.
4. The sandboxed agent is parked in an **Event-gated wait** with a timeout. The
   code arrives, the event fires, the wait returns. No inbound port, no tunnel,
   no polling loop the model has to drive.

This module is the **client half**, complete and tested. The backend route it
needs **does not exist yet** — the only OAuth in ``api_server`` today is
GitHub's *device* flow (``/v1/user/github/connect/init`` + ``/connect/poll``,
``github_oauth.py``), which has no redirect at all. See
``docs/MCP_OAUTH_BACKEND_ROUTE.md`` for the exact routes to add; the fake backend
in ``tests/test_oauth_bridge.py`` implements that contract, so the day the routes
land the client needs no change.

Security properties, all enforced here and all tested:

- ``state`` is 256 bits from :mod:`secrets` and compared with
  :func:`hmac.compare_digest`. A wrong state is rejected, and rejected without
  leaking how much of it was right.
- A flow **expires** (default 10 minutes). A late callback is refused.
- A code is **single use**. The second delivery is refused, and the second read
  of a consumed flow returns nothing.
- **PKCE S256, with the agent owning the verifier.** The agent generates the
  verifier, sends only the challenge to the backend, and is the only party that
  ever holds the verifier — so a stolen ``code`` is useless to anyone else, and
  no secret has to travel *back* over the bridge.
- The request that opens a flow carries the **server name only**. A sandbox
  cannot name its own authorize endpoint or client id: our backend would then be
  handing the user a trustworthy-looking link to somebody else's login page.
- The ``code`` never appears in a tool result, in the prompt, or in the journal.
  The tool answers "authorized", not "here is the credential".

**The one honest exception to "no raw secret in the sandbox" (§10).** For our own
integrations the rule holds absolutely: the token lives server-side and the
backend performs the call. An MCP server is different — it is a third-party
process that speaks OAuth itself, so *something* in the client position must hold
its access token. That something is :class:`CredentialStash`:

- memory only, never written to disk, never journaled, never in a tool result;
- keyed per server, so one server's token is not another's;
- ``repr`` redacted, so a traceback or a debug print cannot spill it;
- scoped to the run — the process dies, the token is gone.

That is a smaller blast radius than a token in an env var or a config file, and
it is the price of supporting MCP at all. Prefer a native tool (§9).
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import secrets
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass, field
from typing import Any, Protocol

import httpx

from .registry import ToolRegistry
from .web_search import DEFAULT_BASE_URL, TokenSession

#: Backend routes (to be implemented — see docs/MCP_OAUTH_BACKEND_ROUTE.md).
START_PATH = "/v1/oauth/mcp/start"
PENDING_PATH = "/v1/oauth/mcp/pending"

#: How long a started flow stays valid. Long enough for a human to find their
#: password manager, short enough that a stale authorize URL is dead.
DEFAULT_TTL = 600.0
#: How long the agent parks on the event before giving up. A wait that never ends
#: is a hung run, which on a phone looks exactly like a broken product.
DEFAULT_WAIT_TIMEOUT = 300.0
#: One long-poll leg against the backend. Shorter than the wait, so a wait is
#: several legs and a dropped connection costs one leg.
POLL_LEG = 25.0
#: How often the Event-gated wait comes up for air to check the Stop predicate.
WAIT_SLICE = 0.5

STATE_BYTES = 32
#: RFC 7636 allows 43–128 characters; 64 random bytes lands at 86.
VERIFIER_BYTES = 64


def pkce_pair() -> tuple[str, str]:
    """``(code_verifier, code_challenge)`` for PKCE S256.

    The **agent** owns the verifier, because the agent is what performs the token
    exchange. It is generated here, kept in the flow, and sent only to the
    provider's token endpoint; the backend sees the challenge, never the
    verifier, so nothing has to hand a secret back over the bridge.
    """
    verifier = secrets.token_urlsafe(VERIFIER_BYTES)
    digest = hashlib.sha256(verifier.encode("ascii")).digest()
    challenge = base64.urlsafe_b64encode(digest).decode("ascii").rstrip("=")
    return verifier, challenge


class Clock(Protocol):
    def __call__(self) -> float: ...


# -- the stash -------------------------------------------------------------


class CredentialStash:
    """In-memory, per-server token store. See the module docstring for why this
    exists at all and what bounds it."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._tokens: dict[str, str] = {}

    def put(self, server: str, token: str) -> None:
        with self._lock:
            self._tokens[str(server)] = str(token)

    def get(self, server: str) -> str | None:
        with self._lock:
            return self._tokens.get(str(server))

    def forget(self, server: str) -> None:
        with self._lock:
            self._tokens.pop(str(server), None)

    def servers(self) -> list[str]:
        with self._lock:
            return sorted(self._tokens)

    def __repr__(self) -> str:
        with self._lock:
            return f"<CredentialStash servers={sorted(self._tokens)} tokens=redacted>"

    __str__ = __repr__


# -- pending flows ---------------------------------------------------------


@dataclass
class OAuthFlow:
    """One in-flight authorization. The event is the whole mechanism."""

    server: str
    state: str
    authorize_url: str
    expires_at: float
    event: threading.Event = field(default_factory=threading.Event, repr=False)
    code: str | None = field(default=None, repr=False)
    #: The PKCE verifier for this flow. Never leaves the process except in the
    #: token request itself.
    verifier: str = field(default="", repr=False)
    used: bool = False

    def __repr__(self) -> str:
        # The state is a CSRF token and the code is a credential. Neither belongs
        # in a log line.
        return f"<OAuthFlow server={self.server!r} used={self.used}>"


class OAuthBridge:
    """The sandbox side of the bridge: pending flows, the constant-time
    correlation, and the Event-gated wait.

    Deliberately transport-free. :meth:`deliver` is called by whatever channel
    brought the code — the backend long-poll below, or a push over the executor's
    control channel — so a new channel needs no new correlation logic, and the
    tests need no network.
    """

    def __init__(self, *, ttl: float = DEFAULT_TTL, clock: Clock = time.monotonic) -> None:
        self._ttl = float(ttl)
        self._clock = clock
        self._lock = threading.Lock()
        self._flows: dict[str, OAuthFlow] = {}

    # -- flow lifecycle ---------------------------------------------------

    def new_state(self) -> str:
        return secrets.token_urlsafe(STATE_BYTES)

    def begin(
        self,
        server: str,
        authorize_url: str,
        *,
        state: str | None = None,
        ttl: float | None = None,
        verifier: str = "",
    ) -> OAuthFlow:
        flow = OAuthFlow(
            server=str(server),
            state=state or self.new_state(),
            authorize_url=str(authorize_url),
            expires_at=self._clock() + float(ttl if ttl is not None else self._ttl),
            verifier=verifier,
        )
        with self._lock:
            self._prune_locked()
            self._flows[flow.state] = flow
        return flow

    def cancel(self, state: str) -> None:
        with self._lock:
            self._flows.pop(state, None)

    def pending_states(self) -> int:
        with self._lock:
            self._prune_locked()
            return len(self._flows)

    def _prune_locked(self) -> None:
        now = self._clock()
        for state, flow in list(self._flows.items()):
            if flow.expires_at < now and not flow.event.is_set():
                del self._flows[state]

    # -- correlation ------------------------------------------------------

    def deliver(self, state: str, code: str) -> dict:
        """Correlate a callback to a pending flow and release its wait.

        The state comparison uses :func:`hmac.compare_digest` against **every**
        candidate, and does not stop at the first match. A dictionary lookup
        would be simpler and would leak: the time to answer would depend on how
        many leading characters of a guessed state were right.
        """
        presented = state if isinstance(state, str) else ""
        code_text = code if isinstance(code, str) else ""
        if not presented or not code_text:
            return {"ok": False, "error": "state and code are required"}

        presented_bytes = presented.encode("utf-8", "ignore")
        with self._lock:
            matched: OAuthFlow | None = None
            for flow in self._flows.values():
                if hmac.compare_digest(flow.state.encode("utf-8"), presented_bytes):
                    matched = flow
            if matched is None:
                return {"ok": False, "error": "unknown or already used state"}
            if matched.used or matched.event.is_set():
                return {"ok": False, "error": "code already delivered"}
            if matched.expires_at < self._clock():
                del self._flows[matched.state]
                return {"ok": False, "error": "authorization flow expired"}
            matched.code = code_text
            matched.used = True
            matched.event.set()
            server = matched.server
        return {"ok": True, "server": server}

    # -- the wait ---------------------------------------------------------

    def wait(
        self,
        flow: OAuthFlow,
        timeout: float = DEFAULT_WAIT_TIMEOUT,
        *,
        cancel: Callable[[], bool] | None = None,
    ) -> dict:
        """Park until the code arrives, the flow expires, ``timeout`` runs out,
        or ``cancel`` says stop. Returns the code — to the *caller inside the
        agent*, never to the model. Consumes the flow either way, so one
        authorize URL is good for one authorization.

        ``cancel`` is the Stop button. Without it a five-minute wait would sit
        through a Stop, because the agent loop only polls its kill switch between
        tool calls; so the wait is sliced and the predicate checked each slice.
        """
        # Bounded by both the caller's patience and the flow's own expiry, so a
        # 30-minute timeout on a 10-minute flow still returns in 10 minutes.
        budget = min(max(0.0, float(timeout)), max(0.0, flow.expires_at - self._clock()))
        fired = False
        stopped = False
        deadline = time.monotonic() + budget
        while True:
            slice_s = min(WAIT_SLICE, max(0.0, deadline - time.monotonic()))
            fired = flow.event.wait(slice_s)
            if fired:
                break
            if cancel is not None and cancel():
                stopped = True
                break
            if time.monotonic() >= deadline:
                break
        with self._lock:
            self._flows.pop(flow.state, None)
        if not fired:
            expired = flow.expires_at <= self._clock()
            if stopped:
                error = "authorization cancelled"
            elif expired:
                error = "authorization expired"
            else:
                error = "authorization timed out"
            return {
                "ok": False,
                "server": flow.server,
                "error": error,
                "timed_out": not expired and not stopped,
                "cancelled": stopped,
            }
        code = flow.code or ""
        flow.code = None  # do not keep a credential alive in a live object
        return {"ok": True, "server": flow.server, "code": code}


# -- the backend channel ---------------------------------------------------


class BackendOAuthClient:
    """Talks to the routes documented in ``docs/MCP_OAUTH_BACKEND_ROUTE.md``.

    Two calls: start a flow, then long-poll for its code. The account token pays
    for both, the same way :mod:`cowork_agent.web_search` does; a 401/403 is
    retried once after a refresh.
    """

    def __init__(
        self,
        session: TokenSession,
        *,
        base_url: str = DEFAULT_BASE_URL,
        http_client: httpx.Client | None = None,
        timeout: float = 30.0,
    ) -> None:
        self._session = session
        self._base = base_url.rstrip("/")
        self._client = http_client
        self._timeout = timeout

    def _request(self, method: str, path: str, **kwargs: Any) -> httpx.Response:
        def once() -> httpx.Response:
            client = self._client or httpx.Client(timeout=self._timeout)
            try:
                return client.request(
                    method,
                    f"{self._base}{path}",
                    headers={"Authorization": f"Bearer {self._session.access_token}"},
                    **kwargs,
                )
            finally:
                if self._client is None:
                    client.close()

        response = once()
        if response.status_code in (401, 403):
            self._session.refresh()
            response = once()
        return response

    def start(
        self,
        server: str,
        *,
        scopes: list[str] | None = None,
        code_challenge: str | None = None,
    ) -> dict:
        """Open a flow. Returns ``{ok, state, authorize_url, expires_in}``.

        The request carries the **server name only** — never an authorize
        endpoint and never a client id. Which provider a name means, and with
        which client credentials, is a server-side registry: a sandbox that could
        name its own authorize endpoint could make our backend hand the user a
        trustworthy-looking link to a phishing page.
        """
        payload: dict[str, Any] = {"server": str(server)}
        if scopes:
            payload["scopes"] = [str(s) for s in scopes]
        if code_challenge:
            payload["code_challenge"] = str(code_challenge)
            payload["code_challenge_method"] = "S256"
        try:
            response = self._request("POST", START_PATH, json=payload)
        except Exception as exc:  # noqa: BLE001
            return {"ok": False, "error": f"backend unreachable: {type(exc).__name__}"}
        if response.status_code != 200:
            return {"ok": False, "error": _error_text(response), "status": response.status_code}
        try:
            body = response.json()
        except ValueError:
            return {"ok": False, "error": "backend sent no JSON"}
        url = body.get("authorize_url")
        state = body.get("state")
        if not url or not state:
            return {"ok": False, "error": "backend response has no authorize_url/state"}
        return {
            "ok": True,
            "state": str(state),
            "authorize_url": str(url),
            "expires_in": float(body.get("expires_in") or DEFAULT_TTL),
        }

    def poll(self, state: str, *, wait: float = POLL_LEG) -> dict:
        """One long-poll leg. ``{ok: True, code: ...}`` once, then ``gone``."""
        try:
            response = self._request(
                "GET",
                f"{PENDING_PATH}/{state}",
                params={"wait": int(max(0, wait))},
                timeout=max(self._timeout, wait + 10.0),
            )
        except Exception as exc:  # noqa: BLE001
            return {"ok": False, "pending": True, "error": f"poll failed: {type(exc).__name__}"}
        if response.status_code == 200:
            try:
                body = response.json()
            except ValueError:
                return {"ok": False, "pending": False, "error": "backend sent no JSON"}
            code = body.get("code")
            if not code:
                return {"ok": False, "pending": True}
            return {"ok": True, "code": str(code), "state": str(body.get("state") or state)}
        if response.status_code in (202, 204):
            return {"ok": False, "pending": True}
        if response.status_code in (404, 410):
            return {"ok": False, "pending": False, "error": "flow expired or already used"}
        return {"ok": False, "pending": False, "error": _error_text(response)}


def _error_text(response: httpx.Response) -> str:
    try:
        body = response.json()
    except ValueError:
        body = None
    if isinstance(body, dict):
        detail = body.get("error") or body.get("detail")
        if detail:
            return str(detail)[:300]
    return (response.text or f"HTTP {response.status_code}")[:300]


# -- the token exchange ----------------------------------------------------


#: ``(server, code, code_verifier) -> access token``. The step that turns the
#: delivered code into a usable credential. Injected, because it is the one place
#: a third-party secret exists and it must be replaceable (and, in tests, fake).
TokenExchange = Callable[[str, str, str], "str | None"]


def http_token_exchange(
    token_url: str,
    *,
    client_id: str,
    redirect_uri: str,
    client_secret: str | None = None,
    http_client: httpx.Client | None = None,
    timeout: float = 30.0,
) -> TokenExchange:
    """A plain RFC 6749 ``authorization_code`` exchange against an MCP server's
    own token endpoint. The returned token goes straight into the stash and is
    never returned to the model."""

    def exchange(server: str, code: str, code_verifier: str = "") -> str | None:
        data = {
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirect_uri,
            "client_id": client_id,
        }
        if code_verifier:
            data["code_verifier"] = code_verifier
        if client_secret:
            data["client_secret"] = client_secret
        client = http_client or httpx.Client(timeout=timeout)
        try:
            response = client.post(token_url, data=data)
        except Exception:  # noqa: BLE001
            return None
        finally:
            if http_client is None:
                client.close()
        if response.status_code != 200:
            return None
        try:
            body = response.json()
        except ValueError:
            return None
        token = body.get("access_token")
        return str(token) if token else None

    return exchange


def callback_uri(base_url: str, server: str) -> str:
    """The redirect the provider is given: the backend's **public** URL. Never a
    localhost port, never a tunnel into the sandbox (§10)."""
    return f"{base_url.rstrip('/')}/oauth/callback/{server}"


def config_token_exchange(
    oauth_by_server: dict[str, dict],
    *,
    base_url: str = DEFAULT_BASE_URL,
    http_client: httpx.Client | None = None,
) -> TokenExchange:
    """Exchange for servers that declared an ``oauth`` block in ``mcp.json``.

    A server with no block cannot be exchanged for, which surfaces as
    "no token exchange configured" instead of a silent half-connected state.
    """

    def exchange(server: str, code: str, code_verifier: str = "") -> str | None:
        config = oauth_by_server.get(server) or {}
        token_url = config.get("token_url")
        client_id = config.get("client_id")
        if not token_url or not client_id:
            return None
        return http_token_exchange(
            str(token_url),
            client_id=str(client_id),
            redirect_uri=callback_uri(base_url, server),
            client_secret=(
                str(config["client_secret"]) if config.get("client_secret") else None
            ),
            http_client=http_client,
        )(server, code, code_verifier)

    return exchange


# -- the tool --------------------------------------------------------------

#: Where the authorize URL goes. The executor binds this to the chat thread, the
#: same channel ``send_file_to_user`` uses, so the link reaches the phone instead
#: of only the transcript.
LinkNotifier = Callable[[str, str], None]

OAUTH_CONNECT_SCHEMA = {
    "type": "object",
    "description": (
        "Connect an MCP server that needs the user to sign in. It opens the "
        "sign-in page for the user, then waits until they finish. The result "
        "says whether it worked; you never see the credential. Call it when a "
        "tool of that server fails because it is not authorized."
    ),
    "properties": {
        "server": {
            "type": "string",
            "description": "Name of the MCP server, as configured.",
        },
        "timeout": {
            "type": "integer",
            "description": "Seconds to wait for the user to finish signing in.",
            "default": int(DEFAULT_WAIT_TIMEOUT),
        },
    },
    "required": ["server"],
}


def make_oauth_connect_handler(
    bridge: OAuthBridge,
    client: BackendOAuthClient,
    *,
    stash: CredentialStash | None = None,
    exchange: TokenExchange | None = None,
    notify: LinkNotifier | None = None,
    on_authorized: Callable[[str], None] | None = None,
    cancel: Callable[[], bool] | None = None,
    poll_leg: float = POLL_LEG,
):
    """Build the ``mcp_oauth_connect`` handler.

    The shape of the answer is the point: ``{"ok": true, "authorized": true}``.
    Not the code, not the token, not the state. What the model needs to know is
    whether it may retry the tool call.
    """

    def mcp_oauth_connect(server: str, timeout: int = int(DEFAULT_WAIT_TIMEOUT)) -> dict:
        name = (server or "").strip()
        if not name:
            return {"ok": False, "error": "server is required"}
        try:
            budget = max(10.0, min(float(timeout), 1800.0))
        except (TypeError, ValueError):
            budget = DEFAULT_WAIT_TIMEOUT

        verifier, challenge = pkce_pair()
        started = client.start(name, code_challenge=challenge)
        if not started.get("ok"):
            return {"ok": False, "server": name, "error": started.get("error", "start failed")}

        flow = bridge.begin(
            name,
            started["authorize_url"],
            state=started["state"],
            ttl=min(float(started.get("expires_in") or DEFAULT_TTL), budget),
            verifier=verifier,
        )

        delivered_to_user = False
        if notify is not None:
            try:
                notify(name, flow.authorize_url)
                delivered_to_user = True
            except Exception:  # noqa: BLE001 — fall back to returning the link
                delivered_to_user = False

        # Pull the code across from the backend on a worker, and park the agent
        # on the event. The event is what the wait is gated on, so a push channel
        # can satisfy the same wait without this poller.
        stop = threading.Event()

        def pump() -> None:
            deadline = time.monotonic() + budget
            while not stop.is_set() and time.monotonic() < deadline:
                leg = client.poll(flow.state, wait=min(poll_leg, max(1.0, deadline - time.monotonic())))
                if leg.get("ok"):
                    bridge.deliver(leg.get("state") or flow.state, leg.get("code", ""))
                    return
                if not leg.get("pending"):
                    return

        worker = threading.Thread(target=pump, name=f"oauth-pump-{name}", daemon=True)
        worker.start()
        try:
            result = bridge.wait(flow, timeout=budget, cancel=cancel)
        finally:
            stop.set()

        if not result.get("ok"):
            answer = {
                "ok": False,
                "server": name,
                "authorized": False,
                "error": result.get("error", "authorization failed"),
            }
            if not delivered_to_user:
                answer["authorize_url"] = flow.authorize_url
            return answer

        code = result.get("code") or ""
        if exchange is None or stash is None:
            # No exchange wired: the flow completed, but nothing can hold a
            # token. Say so rather than claim success.
            return {
                "ok": False,
                "server": name,
                "authorized": False,
                "error": "no token exchange configured for this server",
            }
        token = exchange(name, code, flow.verifier)
        if not token:
            return {
                "ok": False,
                "server": name,
                "authorized": False,
                "error": "token exchange failed",
            }
        stash.put(name, token)
        if on_authorized is not None:
            try:
                on_authorized(name)
            except Exception:  # noqa: BLE001 — a reconnect failure is reported by the tool call
                pass
        return {"ok": True, "server": name, "authorized": True}

    return mcp_oauth_connect


def register_oauth_tool(
    registry: ToolRegistry,
    bridge: OAuthBridge | None,
    client: BackendOAuthClient | None,
    *,
    stash: CredentialStash | None = None,
    exchange: TokenExchange | None = None,
    notify: LinkNotifier | None = None,
    on_authorized: Callable[[str], None] | None = None,
    cancel: Callable[[], bool] | None = None,
) -> None:
    """Register ``mcp_oauth_connect``.

    Without a bridge or a backend client there is nothing to connect through, so
    the tool is not registered and the model is never told about it.
    """
    if bridge is None or client is None:
        return
    registry.register(
        "mcp_oauth_connect",
        OAUTH_CONNECT_SCHEMA,
        make_oauth_connect_handler(
            bridge,
            client,
            stash=stash,
            exchange=exchange,
            notify=notify,
            on_authorized=on_authorized,
            cancel=cancel,
        ),
    )
