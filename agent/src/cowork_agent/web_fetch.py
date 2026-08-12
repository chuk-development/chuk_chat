"""``web_fetch`` — read one web page as Markdown (§9).

Local, no backend: the sandbox fetches the URL itself. That keeps a page read
off the account's rate limits, but it also means the agent controls the target
of an outbound request from inside our network. So the tool is hardened, and
the hardening is the point of this module.

What it enforces, in order:

1. **Scheme allowlist** — ``http`` and ``https`` only. ``file:``, ``ftp:``,
   ``data:``, ``gopher:`` and friends are rejected before anything is opened.
   A URL with embedded credentials (``https://user:pw@host``) is rejected too.
2. **SSRF block, after DNS** — the host name is resolved and *every* returned
   address must be public. Private, loopback, link-local (incl. the cloud
   metadata address ``169.254.169.254``), CGNAT, multicast, reserved and
   unspecified ranges are refused, for IPv4 and IPv6 (``::1``, ``fc00::/7``),
   including IPv4-mapped and 6to4 forms. A name that resolves to ``127.0.0.1``
   is therefore blocked just like the literal.
3. **Per-hop revalidation** — redirects are followed manually, at most
   :data:`MAX_REDIRECTS` of them, and every hop runs the full check again. A
   public URL that redirects to ``http://169.254.169.254/`` does not get out.
4. **Timeout** — one deadline for the whole request.
5. **Size limit while reading** — the body is streamed and cut at
   :data:`MAX_BYTES`. Nothing is buffered whole and shortened afterwards, so a
   1 GB response cannot exhaust memory first.
6. **Content-type allowlist** — HTML, plain text, Markdown, JSON and XML.
   Binaries (PDF, images, ``application/octet-stream``) are refused; those go
   through the document/vision path, not through this tool.
7. **Bounded result** — the Markdown is capped at :data:`FETCH_CAP` characters
   (the ``READ_CAP`` pattern of :mod:`cowork_agent.tools`) and the result
   carries ``truncated`` so the model knows the page continues.

Residual risk, stated plainly: the address is validated and then httpx resolves
the name again when it connects, so a DNS entry that changes between the two
(rebinding) is not covered here. Closing it needs connection-level pinning,
which belongs in the sandbox's egress policy, not in a tool.

HTML becomes Markdown through a small :class:`html.parser.HTMLParser` subclass —
stdlib only, no new dependency for a job this size.
"""

from __future__ import annotations

import ipaddress
import json
import re
import socket
from collections.abc import Callable, Iterable
from html.parser import HTMLParser
from urllib.parse import urljoin, urlsplit

import httpx

from .registry import ToolRegistry

# -- limits -------------------------------------------------------------------

# Character cap on the returned text. A page result goes straight into the
# prompt, so it is bounded exactly like ``tools.READ_CAP``.
FETCH_CAP = 40_000
# Byte cap on the download itself, enforced while streaming.
MAX_BYTES = 2_000_000
MAX_REDIRECTS = 5
DEFAULT_TIMEOUT = 20.0
MAX_TIMEOUT = 60.0

ALLOWED_SCHEMES = ("http", "https")

# Exact types we accept, plus the ``text/*``, ``*+json`` and ``*+xml`` families.
ALLOWED_CONTENT_TYPES = (
    "text/html",
    "text/plain",
    "text/markdown",
    "text/xml",
    "application/json",
    "application/ld+json",
    "application/xml",
    "application/xhtml+xml",
)

# Written out even though :mod:`ipaddress` already classifies most of them:
# these are the ranges the tool promises to block, and the tests check each one.
BLOCKED_NETWORKS = tuple(
    ipaddress.ip_network(cidr)
    for cidr in (
        "0.0.0.0/8",
        "10.0.0.0/8",
        "100.64.0.0/10",
        "127.0.0.0/8",
        "169.254.0.0/16",  # link-local, incl. 169.254.169.254 cloud metadata
        "172.16.0.0/12",
        "192.0.0.0/24",
        "192.168.0.0/16",
        "198.18.0.0/15",
        "224.0.0.0/4",
        "240.0.0.0/4",
        "::/128",
        "::1/128",
        "fc00::/7",
        "fe80::/10",
        "ff00::/8",
    )
)

USER_AGENT = "CoWorkAgent/0.1 (+https://chuk.chat)"

WEB_FETCH_SCHEMA = {
    "type": "object",
    "description": (
        "Fetch one web page or API response and return it as Markdown or plain "
        "text. Use it after `web_search` to read a result, or directly when you "
        "already know the URL. Only http and https, only text-like content "
        "(HTML, text, Markdown, JSON, XML). The result is truncated at 40000 "
        "characters."
    ),
    "properties": {
        "url": {
            "type": "string",
            "description": "Full URL, starting with http:// or https://.",
        },
        "max_chars": {
            "type": "integer",
            "description": "Return at most this many characters.",
            "default": FETCH_CAP,
        },
    },
    "required": ["url"],
}


class UrlRejected(Exception):
    """The URL failed a safety rule. Never leaves this module as an exception —
    the handler turns it into an error envelope."""


Resolver = Callable[[str, int], Iterable[str]]


# -- address checks -----------------------------------------------------------


def _default_resolver(host: str, port: int) -> list[str]:
    """Resolve a host to every address it answers with."""
    try:
        infos = socket.getaddrinfo(host, port, proto=socket.IPPROTO_TCP)
    except socket.gaierror as exc:
        raise UrlRejected(f"cannot resolve host: {host}") from exc
    addresses = []
    for info in infos:
        sockaddr = info[4]
        if sockaddr:
            # IPv6 sockaddr may carry a %scope suffix.
            addresses.append(str(sockaddr[0]).split("%", 1)[0])
    if not addresses:
        raise UrlRejected(f"cannot resolve host: {host}")
    return addresses


def _unwrap_v6(ip: ipaddress._BaseAddress):
    """Reduce IPv4-mapped / 6to4 / Teredo IPv6 forms to the IPv4 address they
    carry, so ``::ffff:127.0.0.1`` cannot slip past the IPv4 rules."""
    if isinstance(ip, ipaddress.IPv6Address):
        for candidate in (ip.ipv4_mapped, ip.sixtofour):
            if candidate is not None:
                return candidate
        teredo = ip.teredo
        if teredo is not None:
            return teredo[1]
    return ip


def is_blocked_address(address: str) -> bool:
    """True when an IP must not be fetched. Unparseable input counts as blocked."""
    try:
        ip = ipaddress.ip_address(address)
    except ValueError:
        return True
    ip = _unwrap_v6(ip)
    if (
        ip.is_private
        or ip.is_loopback
        or ip.is_link_local
        or ip.is_multicast
        or ip.is_reserved
        or ip.is_unspecified
    ):
        return True
    return any(ip in network for network in BLOCKED_NETWORKS if ip.version == network.version)


def validate_url(url: str, *, resolve: Resolver) -> str:
    """Run every URL rule. Returns the URL, or raises :class:`UrlRejected`."""
    # The model can send anything; a wrong type must be a rejection, not a crash.
    text = (url if isinstance(url, str) else str(url or "")).strip()
    if not text:
        raise UrlRejected("url is empty")
    try:
        parts = urlsplit(text)
    except ValueError as exc:  # e.g. an unterminated IPv6 literal
        raise UrlRejected("url is malformed") from exc
    scheme = parts.scheme.lower()
    if scheme not in ALLOWED_SCHEMES:
        raise UrlRejected(f"scheme not allowed: {scheme or '(none)'}")
    if parts.username or parts.password:
        raise UrlRejected("url with embedded credentials is not allowed")
    host = parts.hostname
    if not host:
        raise UrlRejected("url has no host")
    try:
        port = parts.port or (443 if scheme == "https" else 80)
    except ValueError as exc:  # out-of-range port
        raise UrlRejected("url has an invalid port") from exc

    addresses = list(resolve(host, port))
    if not addresses:
        raise UrlRejected(f"cannot resolve host: {host}")
    for address in addresses:
        if is_blocked_address(address):
            raise UrlRejected(f"blocked address for host {host}: {address}")
    return text


# -- content type -------------------------------------------------------------


def _split_content_type(raw: str) -> tuple[str, str]:
    """``"text/html; charset=iso-8859-1"`` -> ``("text/html", "iso-8859-1")``."""
    main, _, rest = (raw or "").partition(";")
    mime = main.strip().lower()
    charset = ""
    for piece in rest.split(";"):
        key, _, value = piece.partition("=")
        if key.strip().lower() == "charset":
            charset = value.strip().strip('"').lower()
    return mime, charset


def is_allowed_content_type(mime: str) -> bool:
    if not mime:
        # No header at all: treat it as text, the body is bounded anyway.
        return True
    if mime in ALLOWED_CONTENT_TYPES:
        return True
    return mime.startswith("text/") or mime.endswith(("+json", "+xml"))


# -- HTML -> Markdown ---------------------------------------------------------

_SKIP_TAGS = {
    "script",
    "style",
    "noscript",
    "template",
    "svg",
    "canvas",
    "iframe",
    "object",
    "embed",
    "form",
    "nav",
    "aside",
}
_BLOCK_TAGS = {
    "p",
    "div",
    "section",
    "article",
    "header",
    "footer",
    "main",
    "ul",
    "ol",
    "dl",
    "table",
    "blockquote",
    "figure",
    "figcaption",
    "address",
}
_HEADINGS = {"h1": 1, "h2": 2, "h3": 3, "h4": 4, "h5": 5, "h6": 6}
_WS = re.compile(r"[ \t\r\f\v]+")
_BLANKS = re.compile(r"\n{3,}")


class _MarkdownExtractor(HTMLParser):
    """Turn HTML into readable Markdown. Deliberately small: headings, lists,
    links, emphasis, code, tables as pipe rows. Navigation, scripts and styles
    are dropped — they are pure token cost."""

    def __init__(self, base_url: str = "") -> None:
        super().__init__(convert_charrefs=True)
        self._base_url = base_url
        self.title = ""
        self._out: list[str] = []
        self._skip_depth = 0
        self._pre_depth = 0
        self._in_title = False
        self._link_stack: list[str] = []
        self._list_stack: list[list] = []  # [marker, counter]

    # -- output helpers ---------------------------------------------------

    def _emit(self, text: str) -> None:
        self._out.append(text)

    def _absolute(self, link: str) -> str:
        """Make a link usable: a relative href the agent cannot fetch is worth
        nothing, so it is resolved against the page URL when we know it."""
        if not link or not self._base_url:
            return link
        try:
            return urljoin(self._base_url, link)
        except ValueError:
            return link

    def _break(self) -> None:
        """Start a new block, without stacking blank lines."""
        tail = "".join(self._out[-3:])
        if not tail.endswith("\n\n") and self._out:
            self._emit("\n\n")

    # -- parser callbacks -------------------------------------------------

    def handle_starttag(self, tag: str, attrs: list) -> None:
        if tag in _SKIP_TAGS:
            self._skip_depth += 1
            return
        if self._skip_depth:
            return
        attributes = {k.lower(): (v or "") for k, v in attrs}

        if tag == "title":
            self._in_title = True
            return
        if tag == "br":
            self._emit("\n")
            return
        if tag == "hr":
            self._break()
            self._emit("---")
            self._break()
            return
        if tag == "img":
            alt = attributes.get("alt", "").strip()
            src = self._absolute(attributes.get("src", "").strip())
            if alt:
                self._emit(f"![{alt}]({src})" if src else f"![{alt}]")
            return
        if tag in _HEADINGS:
            self._break()
            self._emit("#" * _HEADINGS[tag] + " ")
            return
        if tag in ("ul", "ol"):
            self._break()
            self._list_stack.append(["1." if tag == "ol" else "-", 0])
            return
        if tag == "li":
            self._emit("\n")
            depth = max(0, len(self._list_stack) - 1)
            self._emit("  " * depth)
            if self._list_stack:
                context = self._list_stack[-1]
                if context[0] == "1.":
                    context[1] += 1
                    self._emit(f"{context[1]}. ")
                else:
                    self._emit("- ")
            else:
                self._emit("- ")
            return
        if tag == "pre":
            self._break()
            self._emit("```\n")
            self._pre_depth += 1
            return
        if tag == "code" and not self._pre_depth:
            self._emit("`")
            return
        if tag in ("strong", "b"):
            self._emit("**")
            return
        if tag in ("em", "i"):
            self._emit("_")
            return
        if tag == "a":
            href = attributes.get("href", "").strip()
            if href.lower().startswith(("javascript:", "data:")):
                href = ""
            self._link_stack.append(self._absolute(href))
            self._emit("[")
            return
        if tag == "tr":
            self._emit("\n")
            return
        if tag in _BLOCK_TAGS:
            self._break()

    def handle_startendtag(self, tag: str, attrs: list) -> None:
        # `<br/>`, `<img/>`, `<hr/>`: start behaviour, no matching end tag.
        if tag in ("br", "hr", "img"):
            self.handle_starttag(tag, attrs)

    def handle_endtag(self, tag: str) -> None:
        if tag in _SKIP_TAGS:
            self._skip_depth = max(0, self._skip_depth - 1)
            return
        if self._skip_depth:
            return
        if tag == "title":
            self._in_title = False
            return
        if tag in _HEADINGS:
            self._break()
            return
        if tag in ("ul", "ol"):
            if self._list_stack:
                self._list_stack.pop()
            self._break()
            return
        if tag == "pre":
            self._pre_depth = max(0, self._pre_depth - 1)
            self._emit("\n```")
            self._break()
            return
        if tag == "code" and not self._pre_depth:
            self._emit("`")
            return
        if tag in ("strong", "b"):
            self._emit("**")
            return
        if tag in ("em", "i"):
            self._emit("_")
            return
        if tag == "a":
            href = self._link_stack.pop() if self._link_stack else ""
            self._emit(f"]({href})" if href else "]")
            return
        if tag in ("td", "th"):
            self._emit(" | ")
            return
        if tag in _BLOCK_TAGS:
            self._break()

    def handle_data(self, data: str) -> None:
        if self._skip_depth:
            return
        if self._in_title:
            self.title = (self.title + data).strip()
            return
        if self._pre_depth:
            self._emit(data)
            return
        text = _WS.sub(" ", data.replace("\n", " "))
        if not text.strip():
            # Keep one separating space between inline elements.
            if self._out and not self._out[-1].endswith((" ", "\n")):
                self._emit(" ")
            return
        self._emit(text)

    # -- result -----------------------------------------------------------

    def markdown(self) -> str:
        lines = []
        for line in "".join(self._out).split("\n"):
            line = line.rstrip()
            if line.endswith(" |"):  # trailing cell separator of a table row
                line = line[:-2].rstrip()
            lines.append(line)
        return _BLANKS.sub("\n\n", "\n".join(lines)).strip()


def html_to_markdown(html: str, base_url: str = "") -> tuple[str, str]:
    """Return ``(markdown, title)``. ``base_url`` turns relative links into
    absolute ones the agent can fetch. Malformed HTML never raises: the parser
    is forgiving and anything it cannot place is dropped."""
    parser = _MarkdownExtractor(base_url)
    try:
        parser.feed(html)
        parser.close()
    except Exception:
        # A parse failure must not fail the tool — fall back to the raw text.
        return html.strip(), parser.title
    return parser.markdown(), parser.title


# -- the fetch ----------------------------------------------------------------


def _decode(data: bytes, charset: str) -> str:
    for encoding in (charset, "utf-8"):
        if not encoding:
            continue
        try:
            return data.decode(encoding)
        except (LookupError, UnicodeDecodeError):
            continue
    return data.decode("utf-8", "replace")


def _read_bounded(response: httpx.Response, max_bytes: int) -> tuple[bytes, bool]:
    """Stream the body, stop at ``max_bytes``. The cut happens while reading, so
    an oversized response is never held in memory whole."""
    chunks: list[bytes] = []
    total = 0
    truncated = False
    for chunk in response.iter_bytes():
        chunks.append(chunk)
        total += len(chunk)
        if total > max_bytes:
            truncated = True
            break
    data = b"".join(chunks)
    if len(data) > max_bytes:
        data = data[:max_bytes]
        truncated = True
    return data, truncated


def make_web_fetch_handler(
    *,
    http_client: httpx.Client | None = None,
    resolve: Resolver | None = None,
    max_bytes: int = MAX_BYTES,
    max_redirects: int = MAX_REDIRECTS,
    timeout: float = DEFAULT_TIMEOUT,
):
    """Build the ``web_fetch`` handler.

    ``http_client`` and ``resolve`` are injection points: the tests pass an
    :class:`httpx.MockTransport` client and a fake resolver, so no test ever
    touches the network or DNS.
    """
    resolver = resolve or _default_resolver

    def _client() -> tuple[httpx.Client, bool]:
        if http_client is not None:
            return http_client, False
        return httpx.Client(timeout=timeout, follow_redirects=False), True

    def web_fetch(url: str, max_chars: int = FETCH_CAP) -> dict:
        try:
            cap = max(1, min(int(max_chars), FETCH_CAP))
        except (TypeError, ValueError):
            cap = FETCH_CAP

        client, owned = _client()
        current = url
        hops: list[str] = []
        try:
            for _ in range(max_redirects + 1):
                current = validate_url(current, resolve=resolver)
                with client.stream(
                    "GET",
                    current,
                    headers={
                        "User-Agent": USER_AGENT,
                        "Accept": "text/html,text/plain,application/json;q=0.9,*/*;q=0.1",
                    },
                    follow_redirects=False,
                    timeout=min(float(timeout), MAX_TIMEOUT),
                ) as response:
                    if response.status_code in (301, 302, 303, 307, 308):
                        location = response.headers.get("location", "").strip()
                        if not location:
                            raise UrlRejected("redirect without a location header")
                        current = urljoin(current, location)
                        hops.append(current)
                        continue

                    if response.status_code >= 400:
                        return {
                            "ok": False,
                            "url": current,
                            "status": response.status_code,
                            "error": f"HTTP {response.status_code}",
                        }

                    mime, charset = _split_content_type(
                        response.headers.get("content-type", "")
                    )
                    if not is_allowed_content_type(mime):
                        return {
                            "ok": False,
                            "url": current,
                            "status": response.status_code,
                            "error": f"content type not allowed: {mime}",
                        }

                    raw, size_truncated = _read_bounded(response, max_bytes)

                text = _decode(raw, charset)
                title = ""
                if mime in ("text/html", "application/xhtml+xml"):
                    text, title = html_to_markdown(text, base_url=current)
                elif mime.endswith(("json", "+json")):
                    text = _pretty_json(text)

                truncated = size_truncated
                if len(text) > cap:
                    text = text[:cap]
                    truncated = True

                result = {
                    "ok": True,
                    "url": current,
                    "status": response.status_code,
                    "content_type": mime,
                    "content": text,
                    "truncated": truncated,
                    "bytes_read": len(raw),
                }
                if title:
                    result["title"] = title[:200]
                if hops:
                    result["redirects"] = hops
                return result

            return {
                "ok": False,
                "url": current,
                "error": f"too many redirects (limit {max_redirects})",
            }
        except UrlRejected as exc:
            return {"ok": False, "url": url, "error": str(exc)}
        except httpx.TimeoutException:
            return {"ok": False, "url": current, "error": "request timed out"}
        except httpx.HTTPError as exc:
            return {
                "ok": False,
                "url": current,
                "error": f"request failed: {type(exc).__name__}",
            }
        finally:
            if owned:
                client.close()

    return web_fetch


def _pretty_json(text: str) -> str:
    """JSON stays JSON, just normalised. Invalid JSON is passed through."""
    try:
        return json.dumps(json.loads(text), indent=2, ensure_ascii=False)
    except (ValueError, TypeError):
        return text


def register_web_fetch(
    registry: ToolRegistry,
    *,
    http_client: httpx.Client | None = None,
    resolve: Resolver | None = None,
) -> None:
    """Register ``web_fetch``. It needs no account and no backend, so it is
    always available."""
    registry.register(
        "web_fetch",
        WEB_FETCH_SCHEMA,
        make_web_fetch_handler(http_client=http_client, resolve=resolve),
    )
