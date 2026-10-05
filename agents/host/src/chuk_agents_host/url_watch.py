"""The fetch behind a ``watch_url`` automation (docs/WIRE_CONTRACT.md,
"Event triggers").

The host fetches the page itself, on the automation's interval (15 minutes at
the least), and the automation fires only when the page's TEXT changed. Rules:

- plain HTTP(S) GET, no JavaScript, no cookies, no credentials;
- a neutral user agent (:data:`USER_AGENT`) that names no person and no host;
- ``If-None-Match`` / ``If-Modified-Since`` from the last answer, so an
  unchanged page costs the server a ``304``;
- at most :data:`MAX_BYTES` of body are read; the rest is cut (and the cut is
  said in the result);
- redirects are followed by hand, at most :data:`MAX_REDIRECTS`, and every hop
  must name a public address: the host is not a proxy into the user's own
  network (loopback, private, link-local and reserved addresses are refused
  unless the manager was built with ``allow_private``);
- what is compared is the page's visible text (scripts, styles and markup are
  dropped, whitespace collapsed), so a rotating token in a ``<script>`` does
  not count as a change.

Nothing here logs a URL's content. The URL itself is the user's data; the log
lines of the manager carry the automation id only.
"""

from __future__ import annotations

import difflib
import hashlib
import ipaddress
import socket
import ssl
from dataclasses import dataclass
from html.parser import HTMLParser
from typing import Callable
from urllib.parse import urljoin, urlsplit

import httpcore
import httpx

#: Neutral, identity-free (no mail, name, host name or address).
USER_AGENT = "chuk-agents/1.0"
MAX_BYTES = 2 * 1024 * 1024
TIMEOUT_SECONDS = 20.0
MAX_REDIRECTS = 5
#: How much of the page text is kept between checks (for the diff).
SNAPSHOT_CHARS = 64 * 1024
#: The cap of the diff that goes into the fired task's payload.
DIFF_CHARS = 6000
EXCERPT_CHARS = 1500

_SKIP_TAGS = {"script", "style", "noscript", "template", "svg", "head"}
_BLOCK_TAGS = {
    "p", "div", "br", "li", "tr", "td", "th", "h1", "h2", "h3", "h4", "h5", "h6",
    "section", "article", "header", "footer", "table", "ul", "ol", "dd", "dt", "pre",
}


class UrlWatchError(Exception):
    """The fetch failed. The message is short and safe for ``last_error``."""


@dataclass
class FetchResult:
    status: int
    not_modified: bool = False
    text: str = ""
    content_type: str = ""
    etag: str | None = None
    last_modified: str | None = None
    truncated: bool = False
    final_url: str = ""


class _TextExtractor(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self._skip = 0
        self.parts: list[str] = []

    def handle_starttag(self, tag, attrs):  # noqa: ANN001 — HTMLParser signature
        if tag in _SKIP_TAGS:
            self._skip += 1
        elif tag in _BLOCK_TAGS:
            self.parts.append("\n")

    def handle_endtag(self, tag):  # noqa: ANN001
        if tag in _SKIP_TAGS and self._skip:
            self._skip -= 1
        elif tag in _BLOCK_TAGS:
            self.parts.append("\n")

    def handle_data(self, data):  # noqa: ANN001
        if not self._skip:
            self.parts.append(data)


def visible_text(body: bytes, content_type: str, charset: str | None = None) -> str:
    """The text a reader sees: HTML without markup, scripts and styles; any
    other text as it is. Lines are whitespace-collapsed, empty lines dropped."""
    raw = body.decode(charset or "utf-8", errors="replace")
    kind = (content_type or "").split(";")[0].strip().lower()
    if kind in ("text/html", "application/xhtml+xml") or (not kind and "<html" in raw[:2048].lower()):
        parser = _TextExtractor()
        try:
            parser.feed(raw)
            parser.close()
        except Exception:  # noqa: BLE001 — a broken page is still text
            pass
        raw = "".join(parser.parts)
    lines = (" ".join(line.split()) for line in raw.splitlines())
    return "\n".join(line for line in lines if line)


def content_hash(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def text_diff(old: str, new: str, limit: int = DIFF_CHARS) -> str:
    """A compact unified diff of two page texts, cut at ``limit`` chars."""
    lines = difflib.unified_diff(
        old.splitlines(), new.splitlines(), fromfile="before", tofile="now", n=1, lineterm=""
    )
    out = "\n".join(lines)
    if len(out) > limit:
        out = out[:limit] + "\n[diff cut]"
    return out


#: ``resolve(host) -> [address, ...]``. Injected by tests.
Resolver = Callable[[str], list[str]]


def _resolve(host: str) -> list[str]:
    """Every address ``host`` resolves to, in resolver order."""
    try:
        infos = socket.getaddrinfo(host, None, proto=socket.IPPROTO_TCP)
    except (socket.gaierror, UnicodeError, OSError) as exc:
        raise UrlWatchError("the host name does not resolve") from exc
    return [str(info[4][0]) for info in infos]


def _vetted_address(host: str, resolve: Resolver, allow_private: bool) -> str:
    """Resolve ``host`` once and return the one address to connect to.

    Unless ``allow_private`` is set, every address must be a global one. The
    caller pins the connection to the returned address, so a second DNS
    answer (DNS rebinding) can never move the connection somewhere else.
    """
    addresses = resolve(host)
    if not addresses:
        raise UrlWatchError("the host name does not resolve")
    if not allow_private:
        for raw in addresses:
            try:
                address = ipaddress.ip_address(raw.split("%")[0])
            except ValueError:
                raise UrlWatchError("the url points into a private network") from None
            if not address.is_global:
                raise UrlWatchError("the url points into a private network")
    return addresses[0]


class _PinnedBackend(httpcore.NetworkBackend):
    """A network backend that connects only to vetted addresses.

    ``pins`` maps a host name to the address that was checked for it. The
    TCP connection goes to that address. TLS still runs against the host
    name (httpcore passes the URL host as SNI and for certificate checks),
    and the ``Host`` header is not changed. A host without a pin is refused.
    """

    def __init__(self, inner: httpcore.NetworkBackend | None = None) -> None:
        self.inner = inner or httpcore.SyncBackend()
        self.pins: dict[str, str] = {}

    def connect_tcp(
        self,
        host: str,
        port: int,
        timeout: float | None = None,
        local_address: str | None = None,
        socket_options=None,  # noqa: ANN001 — httpcore signature
    ) -> httpcore.NetworkStream:
        address = self.pins.get(host.lower().rstrip("."))
        if address is None:
            raise httpcore.ConnectError("no vetted address for this host")
        return self.inner.connect_tcp(
            address,
            port,
            timeout=timeout,
            local_address=local_address,
            socket_options=socket_options,
        )

    def connect_unix_socket(self, path, timeout=None, socket_options=None):  # noqa: ANN001, ANN201
        raise httpcore.ConnectError("unix sockets are not allowed")

    def sleep(self, seconds: float) -> None:
        self.inner.sleep(seconds)


def _pinned_client(backend: _PinnedBackend, verify: ssl.SSLContext | bool = True) -> httpx.Client:
    """An httpx client whose every TCP connection goes through ``backend``.

    ``trust_env`` is off: a proxy from the environment would make the
    connection go somewhere the pin does not cover.
    """
    transport = httpx.HTTPTransport(verify=verify, retries=0)
    pool = getattr(transport, "_pool", None)
    if pool is None or not hasattr(pool, "_network_backend"):
        # Fail closed if httpx changes its internals.
        raise RuntimeError("httpx transport has no pluggable network backend")
    pool._network_backend = backend
    return httpx.Client(
        transport=transport,
        timeout=TIMEOUT_SECONDS,
        follow_redirects=False,
        trust_env=False,
    )


def fetch_url(
    url: str,
    *,
    etag: str | None = None,
    last_modified: str | None = None,
    allow_private: bool = False,
    client: httpx.Client | None = None,
    resolver: Resolver | None = None,
    network_backend: httpcore.NetworkBackend | None = None,
    verify: ssl.SSLContext | bool = True,
) -> FetchResult:
    """One conditional GET. Raises :class:`UrlWatchError` on any failure.

    Each hop (the first request and every redirect) resolves the host once,
    checks the addresses and pins the connection to the checked address.
    ``client`` replaces the pinned client (tests with a mock transport);
    ``resolver``, ``network_backend`` and ``verify`` are for tests too.
    """
    resolve = resolver or _resolve
    backend = _PinnedBackend(network_backend)
    own = client is None
    http = client or _pinned_client(backend, verify)
    headers = {"User-Agent": USER_AGENT, "Accept": "text/html,text/plain,application/json;q=0.9,*/*;q=0.5"}
    if etag:
        headers["If-None-Match"] = etag
    if last_modified:
        headers["If-Modified-Since"] = last_modified
    current = url
    try:
        for _hop in range(MAX_REDIRECTS + 1):
            parts = urlsplit(current)
            if parts.scheme.lower() not in ("http", "https") or not parts.hostname:
                raise UrlWatchError("a redirect left http(s)")
            try:
                # The IDNA-encoded form, the same one httpcore connects to.
                host = httpx.URL(current).raw_host.decode("ascii").lower().rstrip(".")
            except (httpx.InvalidURL, UnicodeError) as exc:
                raise UrlWatchError("the url is not valid") from exc
            if not host:
                raise UrlWatchError("the url is not valid")
            backend.pins[host] = _vetted_address(host, resolve, allow_private)
            try:
                with http.stream("GET", current, headers=headers) as response:
                    if response.status_code in (301, 302, 303, 307, 308):
                        location = response.headers.get("location")
                        if not location:
                            raise UrlWatchError(f"redirect {response.status_code} without a location")
                        current = urljoin(current, location)
                        continue
                    if response.status_code == 304:
                        return FetchResult(
                            status=304,
                            not_modified=True,
                            etag=response.headers.get("etag") or etag,
                            last_modified=response.headers.get("last-modified") or last_modified,
                            final_url=current,
                        )
                    if response.status_code >= 400:
                        raise UrlWatchError(f"HTTP {response.status_code}")
                    body = bytearray()
                    truncated = False
                    for chunk in response.iter_bytes():
                        body.extend(chunk)
                        if len(body) >= MAX_BYTES:
                            del body[MAX_BYTES:]
                            truncated = True
                            break
                    content_type = response.headers.get("content-type", "")
                    return FetchResult(
                        status=response.status_code,
                        text=visible_text(bytes(body), content_type, response.charset_encoding),
                        content_type=content_type.split(";")[0].strip(),
                        etag=response.headers.get("etag"),
                        last_modified=response.headers.get("last-modified"),
                        truncated=truncated,
                        final_url=current,
                    )
            except httpx.HTTPError as exc:
                raise UrlWatchError(f"fetch failed: {type(exc).__name__}") from exc
        raise UrlWatchError("too many redirects")
    finally:
        if own:
            http.close()


__all__ = [
    "FetchResult",
    "MAX_BYTES",
    "USER_AGENT",
    "UrlWatchError",
    "content_hash",
    "fetch_url",
    "text_diff",
    "visible_text",
]
