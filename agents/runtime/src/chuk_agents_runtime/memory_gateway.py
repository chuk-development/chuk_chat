"""The loopback model gateway of the Hindsight memory (§12).

Hindsight is configured with plain strings: one base URL and one static API key
for its LLM and one for its embedder. Our account bearer is not static: it is a
Supabase access token that expires after about an hour and is refreshed
through :class:`~chuk_agents_runtime.backend.SupabaseSession`. A key frozen into
the sidecar's environment at spawn would stop working within the hour.

So the host runs this gateway: a stdlib ``ThreadingHTTPServer`` on
``127.0.0.1:<random port>`` with a random bearer secret. The Hindsight sidecar
talks OpenAI HTTP to it, and the gateway forwards to ``api.chuk.chat``'s own
OpenAI-compatible routes with the **live** account token. A 401/403 refreshes
the session once and retries once. Both routes are the same pattern:

``POST /v1/embeddings``
    Forwarded to ``<api_base_url>/embeddings``. The model and the dimension are
    pinned (``qwen3-embedding-8b`` at 1024 by default): a request for anything
    else is refused, and an upstream answer with the wrong vector size is
    refused too. Query and document vectors can therefore never come from two
    different spaces.

``POST /v1/chat/completions``
    Forwarded to ``<api_base_url>/chat/completions``. The model is pinned to
    the memory model, reasoning is turned off, the output is capped, and
    streaming is refused (Hindsight does not stream). Everything else — tools,
    ``response_format`` (the server forwards it, or drops it for a provider
    that refuses it), temperature — passes through as sent.

Every request of both kinds passes one rate limiter: at most
``rate_per_minute`` requests in any 60-second window (20 by default). The
account allows 60 chat requests and 60 embedding calls per minute, and those
belong to the agent's own turns first; memory is housekeeping.

Inside that budget a **foreground recall comes first**. The host asks the
gateway for a one-time ticket (:meth:`MemoryGateway.issue_ticket`) and puts it
in front of the recall query; Hindsight embeds the query with the query prefix,
the gateway finds ``<prefix>⟦ticket⟧ `` at the start of the input, checks and
burns the ticket, strips it, and forwards the clean query. Only a ticketed
request may use the whole window (and waits briefly). Everything else —
extraction, consolidation (which also runs query-prefixed searches), document
embeddings — may use only ``limit - QUERY_RESERVE`` slots. So neither a burst of
retains nor consolidation can starve the recall a task is waiting for.

The account token only ever goes to the account API: ``api_base_url`` must be
``https`` on the account host (the runtime's own ``api.chuk.chat``), or the
gateway refuses to start.

Time budgets are aligned so one call is never billed twice by a timeout race:
a chat request spends at most ``CHAT_BUDGET_SECONDS`` here (slot wait plus the
upstream call), which is below the LLM timeout the sidecar is given.

Nothing here logs content: counts, status codes and sizes only.
"""

from __future__ import annotations

import collections
import hmac
import json
import logging
import secrets
import threading
import time
from collections.abc import Callable
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any
from urllib.parse import urlparse

import httpx

logger = logging.getLogger(__name__)

#: The memory model: cheap, calls tools, answers JSON. Reasoning is turned off.
DEFAULT_MEMORY_MODEL = "deepseek/deepseek-v4-flash"
#: ``api.chuk.chat``'s OpenAI-compatible base: ``/embeddings`` and
#: ``/chat/completions`` both live under it.
DEFAULT_API_BASE_URL = "https://api.chuk.chat/v1"
DEFAULT_EMBED_BASE_URL = DEFAULT_API_BASE_URL
DEFAULT_EMBED_MODEL = "qwen3-embedding-8b"
DEFAULT_EMBED_DIMS = 1024
DEFAULT_MAX_TOKENS = 8192
DEFAULT_RATE_PER_MINUTE = 20
#: How long a background request waits for a free slot before it gets 429.
DEFAULT_RATE_WAIT_SECONDS = 30.0
#: Slots of every window kept free for ticketed (foreground) recalls.
QUERY_RESERVE = 4
#: A recall is waited on by a task; it waits for a slot this long at most.
QUERY_RATE_WAIT_SECONDS = 8.0
#: A retain chunk is a few thousand characters; this only stops abuse.
MAX_BODY_BYTES = 8 * 1024 * 1024
EMBED_TIMEOUT = httpx.Timeout(30.0, connect=10.0)
#: Everything one chat request may spend here: slot wait plus the upstream
#: call. Must stay below the sidecar's LLM timeout (``SIDECAR_LLM_TIMEOUT``).
CHAT_BUDGET_SECONDS = 210.0
#: The LLM timeout handed to the sidecar (seconds).
SIDECAR_LLM_TIMEOUT = 240
TICKET_OPEN = "\u27e6"
TICKET_CLOSE = "\u27e7"
TICKET_TTL_SECONDS = 60.0
#: Request fields the gateway sets itself or never forwards.
_CHAT_DROP = ("stream", "stream_options", "user", "max_completion_tokens", "provider", "n")


def check_account_url(url: str, allowed_host: str | None = None) -> None:
    """Refuse any base URL that is not ``https`` on the account API host: the
    account token must never reach a third party."""
    allowed = (allowed_host or urlparse(DEFAULT_API_BASE_URL).hostname or "").lower()
    parsed = urlparse(url or "")
    if parsed.scheme != "https" or (parsed.hostname or "").lower() != allowed or parsed.username:
        raise ValueError(
            f"memory route {url!r} refused: the account token only goes to https://{allowed}"
        )


class RateLimiter:
    """At most ``limit`` acquisitions in any ``window`` seconds (a sliding
    window, so a burst can never exceed the limit either)."""

    def __init__(
        self,
        limit: int,
        *,
        window: float = 60.0,
        clock: Callable[[], float] = time.monotonic,
        sleep: Callable[[float], None] = time.sleep,
    ) -> None:
        self._limit = max(1, int(limit))
        self._window = float(window)
        self._clock = clock
        self._sleep = sleep
        self._stamps: collections.deque[float] = collections.deque()
        self._lock = threading.Lock()

    @property
    def limit(self) -> int:
        return self._limit

    def try_acquire(self, reserve: int = 0) -> float:
        """Take a slot now and return 0.0, or return the seconds until one frees.

        ``reserve`` slots of the window are left for others: the caller only
        gets a slot while fewer than ``limit - reserve`` are taken."""
        allowed = max(1, self._limit - max(0, int(reserve)))
        with self._lock:
            now = self._clock()
            while self._stamps and now - self._stamps[0] >= self._window:
                self._stamps.popleft()
            if len(self._stamps) < allowed:
                self._stamps.append(now)
                return 0.0
            oldest_blocking = self._stamps[len(self._stamps) - allowed]
            return max(0.001, self._window - (now - oldest_blocking))

    def acquire(self, timeout: float, *, reserve: int = 0) -> bool:
        """Block until a slot is free or ``timeout`` has passed."""
        deadline = self._clock() + max(0.0, timeout)
        while True:
            wait = self.try_acquire(reserve)
            if wait == 0.0:
                return True
            remaining = deadline - self._clock()
            if remaining <= 0:
                return False
            self._sleep(min(wait, remaining))


class GatewayError(Exception):
    """An error with an HTTP status, answered in the OpenAI error shape."""

    def __init__(self, status: int, message: str, *, code: str | None = None) -> None:
        super().__init__(message)
        self.status = status
        self.message = message
        self.code = code


class MemoryGateway:
    """See the module docstring. ``start()`` binds, ``stop()`` closes.

    ``session_provider`` returns the live account session (or ``None`` while
    there is none — every call is then answered 503 and Hindsight retries it
    later). Tests inject an ``httpx`` client with a mock transport.
    """

    def __init__(
        self,
        session_provider: Callable[[], Any],
        *,
        model_id: str = DEFAULT_MEMORY_MODEL,
        api_base_url: str = DEFAULT_API_BASE_URL,
        embed_model: str = DEFAULT_EMBED_MODEL,
        embed_dims: int = DEFAULT_EMBED_DIMS,
        max_tokens: int = DEFAULT_MAX_TOKENS,
        reasoning_effort: str | None = "none",
        query_prefix: str = "",
        allowed_host: str | None = None,
        rate_per_minute: int = DEFAULT_RATE_PER_MINUTE,
        rate_wait_seconds: float = DEFAULT_RATE_WAIT_SECONDS,
        http_client: httpx.Client | None = None,
        limiter: RateLimiter | None = None,
    ) -> None:
        self._session_provider = session_provider
        self.model_id = model_id
        check_account_url(api_base_url, allowed_host)
        base = api_base_url.rstrip("/")
        self._embed_url = base + "/embeddings"
        self._chat_url = base + "/chat/completions"
        self.embed_model = embed_model
        self.embed_dims = int(embed_dims)
        self._max_tokens = int(max_tokens)
        self._reasoning_effort = reasoning_effort
        self._query_prefix = query_prefix
        self._rate_wait = float(rate_wait_seconds)
        self._limiter = limiter or RateLimiter(rate_per_minute)
        self._http = http_client or httpx.Client(timeout=EMBED_TIMEOUT)
        self._owns_http = http_client is None
        self.secret = secrets.token_urlsafe(32)
        self._tickets: dict[str, float] = {}
        self._tickets_lock = threading.Lock()
        self._server: ThreadingHTTPServer | None = None
        self._thread: threading.Thread | None = None
        self.stats: collections.Counter[str] = collections.Counter()

    # -- lifecycle -------------------------------------------------------

    def start(self) -> "MemoryGateway":
        if self._server is not None:
            return self
        gateway = self

        class Handler(_Handler):
            owner = gateway

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        server.daemon_threads = True
        self._server = server
        self._thread = threading.Thread(
            target=server.serve_forever, name="memory-gateway", daemon=True
        )
        self._thread.start()
        return self

    @property
    def port(self) -> int:
        if self._server is None:
            raise RuntimeError("gateway not started")
        return int(self._server.server_address[1])

    @property
    def base_url(self) -> str:
        """The OpenAI base URL Hindsight is pointed at (``…/v1``)."""
        return f"http://127.0.0.1:{self.port}/v1"

    def stop(self) -> None:
        server, self._server = self._server, None
        if server is not None:
            server.shutdown()
            server.server_close()
        if self._owns_http:
            self._http.close()

    # -- shared plumbing -----------------------------------------------------

    # -- foreground recall tickets ---------------------------------------------

    def issue_ticket(self) -> str:
        """A one-time marker for one foreground recall query: put it in front
        of the query text (``f"{marker}{query}"``)."""
        token = secrets.token_hex(8)
        now = time.monotonic()
        with self._tickets_lock:
            for old in [t for t, exp in self._tickets.items() if exp < now]:
                del self._tickets[old]
            self._tickets[token] = now + TICKET_TTL_SECONDS
        return f"{TICKET_OPEN}{token}{TICKET_CLOSE} "

    def _take_ticket(self, text: str) -> tuple[str, bool]:
        """Strip a ticket from ``<prefix>⟦token⟧ query``; ``True`` when it was a
        live ticket (burnt here)."""
        prefix = self._query_prefix
        if not prefix or not text.startswith(prefix + TICKET_OPEN):
            return text, False
        rest = text[len(prefix) + 1 :]
        end = rest.find(TICKET_CLOSE + " ", 0, 40)
        if end < 0:
            return text, False
        token, query = rest[:end], rest[end + 2 :]
        with self._tickets_lock:
            expiry = self._tickets.pop(token, None)
        return prefix + query, expiry is not None and expiry >= time.monotonic()

    def check_auth(self, header: str | None) -> None:
        expected = f"Bearer {self.secret}"
        if not header or not hmac.compare_digest(header.encode(), expected.encode()):
            raise GatewayError(401, "invalid gateway key", code="unauthorized")

    def _slot(self, *, query: bool = False) -> float:
        """Wait for a slot; returns the seconds waited."""
        started = time.monotonic()
        if query:
            ok = self._limiter.acquire(min(self._rate_wait, QUERY_RATE_WAIT_SECONDS))
        else:
            reserve = QUERY_RESERVE if self._limiter.limit > QUERY_RESERVE else 0
            ok = self._limiter.acquire(self._rate_wait, reserve=reserve)
        if ok:
            return time.monotonic() - started
        self.stats["rate_limited"] += 1
        raise GatewayError(
            429,
            f"memory traffic is limited to {self._limiter.limit} requests per minute",
            code="rate_limited",
        )

    def _session(self) -> Any:
        session = self._session_provider()
        if session is None or not getattr(session, "access_token", None):
            raise GatewayError(503, "no account session", code="no_session")
        return session

    def _forward(self, url: str, payload: dict, *, timeout: httpx.Timeout) -> httpx.Response:
        """POST with the live token; on 401/403 refresh once and retry once."""
        session = self._session()
        token = session.access_token
        response = self._post(url, payload, token, timeout)
        if response.status_code in (401, 403):
            self.stats["refresh"] += 1
            try:
                session.refresh(seen_token=token)
            except TypeError:
                session.refresh()
            except Exception as exc:  # noqa: BLE001 — a dead session is a 503, not a crash
                raise GatewayError(
                    503, f"account session refresh failed: {type(exc).__name__}", code="no_session"
                ) from None
            response = self._post(url, payload, session.access_token, timeout)
        if response.status_code >= 400:
            self.stats["upstream_error"] += 1
        return response

    def _post(self, url: str, payload: dict, token: str, timeout: httpx.Timeout) -> httpx.Response:
        try:
            return self._http.post(
                url,
                json=payload,
                headers={"Authorization": f"Bearer {token}"},
                timeout=timeout,
            )
        except httpx.HTTPError as exc:
            self.stats["upstream_error"] += 1
            raise GatewayError(502, f"upstream unreachable: {type(exc).__name__}") from None

    # -- the two routes --------------------------------------------------

    def embeddings(self, body: dict) -> tuple[int, bytes]:
        model = body.get("model") or self.embed_model
        if model != self.embed_model:
            raise GatewayError(400, f"this gateway serves only {self.embed_model}")
        dims = body.get("dimensions")
        if dims is not None:
            try:
                wanted = int(dims)
            except (TypeError, ValueError):
                raise GatewayError(400, "`dimensions` must be an integer") from None
            if wanted != self.embed_dims:
                raise GatewayError(400, f"this gateway serves only {self.embed_dims} dimensions")
        inputs = body.get("input")
        if isinstance(inputs, str):
            ok = bool(inputs.strip())
        elif isinstance(inputs, list):
            ok = bool(inputs) and all(isinstance(i, str) and i.strip() for i in inputs)
        else:
            ok = False
        if not ok:
            raise GatewayError(400, "`input` must be a non-empty string or list of strings")
        texts = [inputs] if isinstance(inputs, str) else list(inputs)
        taken = [self._take_ticket(t) for t in texts]
        cleaned = [text for text, _ in taken]
        ticketed = bool(taken) and all(ok for _, ok in taken)
        self.stats["recalls" if ticketed else "background_embeddings"] += 1
        self._slot(query=ticketed)
        # Floats, always: the vector size is checked below, and the OpenAI
        # client decodes a float list as happily as base64.
        payload = {
            "model": self.embed_model,
            "input": cleaned[0] if isinstance(inputs, str) else cleaned,
            "dimensions": self.embed_dims,
        }
        response = self._forward(self._embed_url, payload, timeout=EMBED_TIMEOUT)
        self.stats["embeddings"] += 1
        if response.status_code != 200:
            return response.status_code, response.content
        try:
            data = response.json().get("data") or []
            sizes = {len(item.get("embedding") or []) for item in data}
        except (ValueError, AttributeError):
            raise GatewayError(502, "embeddings upstream returned no JSON") from None
        if sizes and sizes != {self.embed_dims}:
            raise GatewayError(
                502,
                f"embeddings upstream returned {sorted(sizes)} dimensions, "
                f"expected {self.embed_dims}",
            )
        return 200, response.content

    def chat_payload(self, body: dict) -> dict:
        """The request as it is forwarded: model pinned, reasoning off, output
        capped, no streaming."""
        if body.get("stream"):
            raise GatewayError(400, "streaming is not supported by the memory gateway")
        messages = body.get("messages")
        if not isinstance(messages, list) or not messages:
            raise GatewayError(400, "`messages` must be a non-empty list")
        requested = body.get("max_completion_tokens") or body.get("max_tokens")
        try:
            cap = min(int(requested), self._max_tokens) if requested else self._max_tokens
        except (TypeError, ValueError):
            cap = self._max_tokens
        payload = {k: v for k, v in body.items() if k not in _CHAT_DROP}
        payload["model"] = self.model_id
        payload["max_tokens"] = max(1, cap)
        if self._reasoning_effort is not None:
            payload["reasoning_effort"] = self._reasoning_effort
        return payload

    def chat(self, body: dict) -> tuple[int, bytes]:
        payload = self.chat_payload(body)
        waited = self._slot()
        remaining = max(5.0, CHAT_BUDGET_SECONDS - waited)
        response = self._forward(
            self._chat_url, payload, timeout=httpx.Timeout(remaining, connect=10.0)
        )
        self.stats["chat"] += 1
        return response.status_code, response.content


class _Handler(BaseHTTPRequestHandler):
    owner: MemoryGateway
    protocol_version = "HTTP/1.1"
    server_version = "chuk-memory-gateway"

    def log_message(self, format: str, *args: Any) -> None:  # noqa: A002 — stdlib name
        # The default writes every request line to stderr. Counts live in
        # ``stats``; content never gets logged.
        return

    def _send(self, status: int, body: bytes, *, retry_after: int | None = None) -> None:
        try:
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            if retry_after is not None:
                self.send_header("Retry-After", str(retry_after))
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            # The caller gave up (its own timeout) before the answer was ready.
            self.owner.stats["client_gone"] += 1
            self.close_connection = True

    def _error(self, error: GatewayError) -> None:
        payload = {"error": {"message": error.message, "type": "gateway_error", "code": error.code}}
        self._send(
            error.status,
            json.dumps(payload).encode(),
            retry_after=30 if error.status == 429 else None,
        )

    def do_GET(self) -> None:  # noqa: N802 — stdlib name
        if self.path.rstrip("/") in ("/health", "/v1/health"):
            self._send(200, b'{"ok":true}')
            return
        self._error(GatewayError(404, "not found"))

    def do_POST(self) -> None:  # noqa: N802 — stdlib name
        owner = self.owner
        try:
            owner.check_auth(self.headers.get("Authorization"))
            length = int(self.headers.get("Content-Length") or 0)
            if length <= 0 or length > MAX_BODY_BYTES:
                raise GatewayError(413 if length > MAX_BODY_BYTES else 400, "bad request body")
            try:
                body = json.loads(self.rfile.read(length))
            except ValueError:
                raise GatewayError(400, "request body is not JSON") from None
            if not isinstance(body, dict):
                raise GatewayError(400, "request body must be an object")
            path = self.path.split("?", 1)[0].rstrip("/")
            if path.endswith("/embeddings"):
                status, content = owner.embeddings(body)
            elif path.endswith("/chat/completions"):
                status, content = owner.chat(body)
            else:
                raise GatewayError(404, "not found")
            owner.stats[f"http_{status}"] += 1
            self._send(status, content, retry_after=30 if status == 429 else None)
        except GatewayError as error:
            owner.stats[f"http_{error.status}"] += 1
            self._error(error)
        except Exception as exc:  # noqa: BLE001 — never kill the server thread
            logger.warning("memory gateway request failed: %s", type(exc).__name__)
            self._error(GatewayError(500, "internal gateway error"))
