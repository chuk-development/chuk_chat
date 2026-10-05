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
from dataclasses import dataclass
from html.parser import HTMLParser
from typing import Callable
from urllib.parse import urljoin, urlsplit

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


def _public_host(host: str) -> bool:
    """True when every address ``host`` resolves to is a global one."""
    try:
        infos = socket.getaddrinfo(host, None, proto=socket.IPPROTO_TCP)
    except (socket.gaierror, UnicodeError, OSError) as exc:
        raise UrlWatchError("the host name does not resolve") from exc
    if not infos:
        raise UrlWatchError("the host name does not resolve")
    for info in infos:
        try:
            address = ipaddress.ip_address(info[4][0].split("%")[0])
        except ValueError:
            return False
        if not address.is_global:
            return False
    return True


def fetch_url(
    url: str,
    *,
    etag: str | None = None,
    last_modified: str | None = None,
    allow_private: bool = False,
    client: httpx.Client | None = None,
    host_check: Callable[[str], bool] | None = None,
) -> FetchResult:
    """One conditional GET. Raises :class:`UrlWatchError` on any failure."""
    check = host_check or _public_host
    own = client is None
    http = client or httpx.Client(timeout=TIMEOUT_SECONDS, follow_redirects=False)
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
            if not allow_private and not check(parts.hostname):
                raise UrlWatchError("the url points into a private network")
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
