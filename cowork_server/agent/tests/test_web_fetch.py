"""``web_fetch`` fetches a URL the *model* chose, so every safety rule gets its
own test.

Nothing here opens a socket or asks DNS anything: the transport is an
:class:`httpx.MockTransport` and the resolver is a dict lookup.
"""

from __future__ import annotations

import ipaddress

import httpx
import pytest

from cowork_agent import (
    LocalEnvironment,
    ToolRegistry,
    html_to_markdown,
    is_blocked_address,
    make_web_fetch_handler,
    register_builtin_tools,
    render_tool_docs,
    validate_url,
)
from cowork_agent.web_fetch import FETCH_CAP, UrlRejected

PUBLIC = "93.184.216.34"


def _resolver(mapping: dict[str, list[str]] | None = None):
    """A fake DNS. An IP literal resolves to itself, as the real resolver does;
    any other unknown host resolves to a public address."""
    table = mapping or {}

    def resolve(host: str, port: int) -> list[str]:
        if host in table:
            return table[host]
        try:
            ipaddress.ip_address(host)
        except ValueError:
            return [PUBLIC]
        return [host]

    return resolve


def _handler(pages: dict[str, httpx.Response], seen: list | None = None):
    def handle(request: httpx.Request) -> httpx.Response:
        if seen is not None:
            seen.append(request)
        key = str(request.url)
        response = pages.get(key)
        if response is None:
            return httpx.Response(404, text="missing")
        # A MockTransport response object can only be consumed once.
        return httpx.Response(
            response.status_code,
            headers=response.headers,
            content=response.content,
        )

    return handle


def _fetch(pages, *, resolve=None, seen=None, **kwargs):
    return make_web_fetch_handler(
        http_client=httpx.Client(transport=httpx.MockTransport(_handler(pages, seen))),
        resolve=resolve or _resolver(),
        **kwargs,
    )


def _html(body: str) -> httpx.Response:
    return httpx.Response(200, headers={"content-type": "text/html"}, text=body)


# -- happy path ---------------------------------------------------------------


def test_html_comes_back_as_markdown_with_the_title():
    page = _html(
        "<html><head><title>Docs</title><style>b{}</style></head>"
        "<body><h1>Hello</h1><p>Some <strong>text</strong> and a "
        '<a href="https://a.test/x">link</a>.</p>'
        "<ul><li>one</li><li>two</li></ul>"
        "<script>alert(1)</script></body></html>"
    )
    result = _fetch({"https://ok.test/": page})("https://ok.test/")

    assert result["ok"] is True
    assert result["status"] == 200
    assert result["title"] == "Docs"
    assert result["truncated"] is False
    content = result["content"]
    assert "# Hello" in content
    assert "**text**" in content
    assert "[link](https://a.test/x)" in content
    assert "- one" in content and "- two" in content
    # script and style bodies are never worth a token
    assert "alert(1)" not in content
    assert "b{}" not in content


def test_plain_text_is_returned_unchanged():
    page = httpx.Response(200, headers={"content-type": "text/plain"}, text="raw body")
    result = _fetch({"https://ok.test/t": page})("https://ok.test/t")
    assert result["content"] == "raw body"
    assert result["content_type"] == "text/plain"


def test_json_is_normalised_not_converted():
    page = httpx.Response(
        200, headers={"content-type": "application/json"}, text='{"b":1,"a":[2]}'
    )
    result = _fetch({"https://ok.test/j": page})("https://ok.test/j")
    assert result["ok"] is True
    assert '"b": 1' in result["content"]


def test_a_non_utf8_charset_is_honoured():
    page = httpx.Response(
        200,
        headers={"content-type": "text/plain; charset=iso-8859-1"},
        content="Grüße".encode("iso-8859-1"),
    )
    result = _fetch({"https://ok.test/e": page})("https://ok.test/e")
    assert result["content"] == "Grüße"


# -- scheme / URL rules -------------------------------------------------------


@pytest.mark.parametrize(
    "url",
    [
        "file:///etc/passwd",
        "ftp://example.test/x",
        "data:text/html,<b>hi</b>",
        "gopher://example.test/",
        "javascript:alert(1)",
        "//example.test/x",
        "example.test/x",
    ],
)
def test_only_http_and_https_are_allowed(url):
    result = _fetch({})(url)
    assert result["ok"] is False
    assert "scheme not allowed" in result["error"] or "no host" in result["error"]


def test_empty_url_is_rejected():
    assert _fetch({})("   ")["error"] == "url is empty"


def test_a_url_with_embedded_credentials_is_rejected():
    result = _fetch({})("https://user:secret@example.test/")
    assert result["ok"] is False
    assert "credentials" in result["error"]
    # the rejection message must not leak the password back into the prompt
    assert "secret" not in result["error"]


def test_a_url_without_a_host_is_rejected():
    with pytest.raises(UrlRejected):
        validate_url("http:///path", resolve=_resolver())


def test_a_malformed_url_is_rejected_not_raised():
    result = _fetch({})("http://[::1")
    assert result["ok"] is False
    assert "malformed" in result["error"]


def test_an_out_of_range_port_is_rejected():
    result = _fetch({})("https://example.test:99999/")
    assert result["ok"] is False
    assert "port" in result["error"]


# -- SSRF ---------------------------------------------------------------------


@pytest.mark.parametrize(
    "address",
    [
        "127.0.0.1",  # loopback
        "127.0.0.53",
        "10.0.0.5",  # 10/8
        "172.16.0.1",  # 172.16/12
        "172.31.255.254",
        "192.168.1.1",  # 192.168/16
        "169.254.0.1",  # link-local
        "169.254.169.254",  # cloud metadata
        "100.64.0.1",  # CGNAT
        "0.0.0.0",  # unspecified
        "224.0.0.1",  # multicast
        "::1",  # IPv6 loopback
        "::",  # IPv6 unspecified
        "fc00::1",  # IPv6 unique local
        "fd12:3456::1",
        "fe80::1",  # IPv6 link-local
        "::ffff:127.0.0.1",  # IPv4-mapped loopback
        "::ffff:10.0.0.1",  # IPv4-mapped private
        "not-an-ip",
    ],
)
def test_private_and_local_addresses_are_blocked(address):
    assert is_blocked_address(address) is True


@pytest.mark.parametrize("address", [PUBLIC, "8.8.8.8", "2606:4700:4700::1111"])
def test_public_addresses_pass(address):
    assert is_blocked_address(address) is False


def test_a_host_name_that_resolves_into_the_private_range_is_blocked():
    """The check is on the resolved address, not on the name — `localtest.me`
    style names point at 127.0.0.1 and must not get through."""
    fetch = _fetch({}, resolve=_resolver({"sneaky.test": ["127.0.0.1"]}))
    result = fetch("https://sneaky.test/admin")
    assert result["ok"] is False
    assert "blocked address" in result["error"]


def test_one_bad_address_among_several_blocks_the_host():
    fetch = _fetch({}, resolve=_resolver({"mixed.test": [PUBLIC, "169.254.169.254"]}))
    assert fetch("https://mixed.test/")["ok"] is False


def test_a_host_that_does_not_resolve_is_rejected():
    def resolve(host: str, port: int) -> list[str]:
        return []

    assert _fetch({}, resolve=resolve)("https://nowhere.test/")["ok"] is False


def test_the_literal_metadata_url_is_blocked():
    result = _fetch({})("http://169.254.169.254/latest/meta-data/")
    assert result["ok"] is False
    assert "blocked address" in result["error"]


# -- redirects ----------------------------------------------------------------


def test_a_redirect_chain_is_followed_and_reported():
    pages = {
        "https://a.test/1": httpx.Response(302, headers={"location": "/2"}),
        "https://a.test/2": httpx.Response(
            301, headers={"location": "https://b.test/3"}
        ),
        "https://b.test/3": httpx.Response(
            200, headers={"content-type": "text/plain"}, text="end"
        ),
    }
    result = _fetch(pages)("https://a.test/1")
    assert result["ok"] is True
    assert result["content"] == "end"
    assert result["url"] == "https://b.test/3"
    assert result["redirects"] == ["https://a.test/2", "https://b.test/3"]


def test_a_redirect_into_the_private_range_is_blocked_at_the_hop():
    pages = {
        "https://a.test/1": httpx.Response(
            302, headers={"location": "http://169.254.169.254/latest/"}
        ),
    }
    result = _fetch(pages)("https://a.test/1")
    assert result["ok"] is False
    assert "blocked address" in result["error"]


def test_a_redirect_to_another_scheme_is_blocked():
    pages = {
        "https://a.test/1": httpx.Response(
            302, headers={"location": "file:///etc/passwd"}
        ),
    }
    assert _fetch(pages)("https://a.test/1")["ok"] is False


def test_a_redirect_loop_stops_at_the_limit():
    pages = {
        "https://a.test/loop": httpx.Response(
            302, headers={"location": "https://a.test/loop"}
        ),
    }
    seen: list = []
    result = _fetch(pages, seen=seen, max_redirects=3)("https://a.test/loop")
    assert result["ok"] is False
    assert "too many redirects" in result["error"]
    assert len(seen) == 4  # the first request plus three hops


def test_a_redirect_without_a_location_is_an_error():
    pages = {"https://a.test/1": httpx.Response(302)}
    result = _fetch(pages)("https://a.test/1")
    assert result["ok"] is False
    assert "location" in result["error"]


# -- content type -------------------------------------------------------------


@pytest.mark.parametrize(
    "mime",
    [
        "application/pdf",
        "image/png",
        "application/octet-stream",
        "video/mp4",
        "application/zip",
    ],
)
def test_binary_content_types_are_refused(mime):
    pages = {
        "https://a.test/f": httpx.Response(
            200, headers={"content-type": mime}, content=b"\x00\x01"
        )
    }
    result = _fetch(pages)("https://a.test/f")
    assert result["ok"] is False
    assert "content type not allowed" in result["error"]


@pytest.mark.parametrize(
    "mime",
    [
        "text/html",
        "text/plain",
        "text/markdown",
        "text/csv",
        "application/json",
        "application/ld+json",
        "application/xml",
        "application/xhtml+xml",
        "image/svg+xml",
    ],
)
def test_text_like_content_types_pass(mime):
    pages = {
        "https://a.test/f": httpx.Response(
            200, headers={"content-type": mime}, text="body"
        )
    }
    assert _fetch(pages)("https://a.test/f")["ok"] is True


# -- size, truncation, timeout, HTTP errors -----------------------------------


def test_the_body_is_cut_while_reading_not_after():
    big = "x" * 50_000
    pages = {
        "https://a.test/big": httpx.Response(
            200, headers={"content-type": "text/plain"}, text=big
        )
    }
    result = _fetch(pages, max_bytes=1000)("https://a.test/big")
    assert result["truncated"] is True
    assert result["bytes_read"] <= 1000


def test_max_chars_bounds_the_returned_text():
    pages = {
        "https://a.test/big": httpx.Response(
            200, headers={"content-type": "text/plain"}, text="y" * 5000
        )
    }
    result = _fetch(pages)("https://a.test/big", max_chars=100)
    assert len(result["content"]) == 100
    assert result["truncated"] is True


def test_max_chars_can_never_exceed_the_hard_cap():
    pages = {
        "https://a.test/big": httpx.Response(
            200, headers={"content-type": "text/plain"}, text="y" * (FETCH_CAP + 500)
        )
    }
    result = _fetch(pages)("https://a.test/big", max_chars=10**9)
    assert len(result["content"]) == FETCH_CAP
    assert result["truncated"] is True


def test_an_http_error_status_is_reported():
    pages = {
        "https://a.test/gone": httpx.Response(
            404, headers={"content-type": "text/html"}, text="nope"
        )
    }
    result = _fetch(pages)("https://a.test/gone")
    assert result == {
        "ok": False,
        "url": "https://a.test/gone",
        "status": 404,
        "error": "HTTP 404",
    }


def test_a_timeout_is_an_error_not_an_exception():
    def handle(request: httpx.Request) -> httpx.Response:
        raise httpx.ReadTimeout("slow", request=request)

    handler = make_web_fetch_handler(
        http_client=httpx.Client(transport=httpx.MockTransport(handle)),
        resolve=_resolver(),
    )
    assert handler("https://a.test/") == {
        "ok": False,
        "url": "https://a.test/",
        "error": "request timed out",
    }


def test_a_connection_failure_is_an_error_not_an_exception():
    def handle(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("refused", request=request)

    handler = make_web_fetch_handler(
        http_client=httpx.Client(transport=httpx.MockTransport(handle)),
        resolve=_resolver(),
    )
    result = handler("https://a.test/")
    assert result["ok"] is False
    assert "ConnectError" in result["error"]


# -- the HTML converter -------------------------------------------------------


def test_headings_lists_code_and_tables_convert():
    markdown, _ = html_to_markdown(
        "<h2>T</h2><ol><li>a</li><li>b</li></ol>"
        "<pre><code>x = 1\ny = 2</code></pre>"
        "<p>inline <code>v</code></p>"
        "<table><tr><td>c1</td><td>c2</td></tr></table>"
        "<hr><em>done</em>"
    )
    assert "## T" in markdown
    assert "1. a" in markdown and "2. b" in markdown
    assert "```" in markdown and "x = 1\ny = 2" in markdown
    assert "`v`" in markdown
    assert "c1 | c2" in markdown
    assert "---" in markdown
    assert "_done_" in markdown


def test_entities_are_decoded_and_blank_lines_collapsed():
    markdown, _ = html_to_markdown(
        "<p>a &amp; b</p>\n\n\n<div></div><div></div><p>tail</p>"
    )
    assert "a & b" in markdown
    assert "\n\n\n" not in markdown


def test_broken_html_still_yields_text():
    markdown, _ = html_to_markdown("<p>open <b>bold</p></div><<>")
    assert "open" in markdown and "bold" in markdown


def test_relative_links_are_resolved_against_the_page_url():
    """A relative href is useless to an agent — it cannot fetch `/api`."""
    markdown, _ = html_to_markdown(
        '<a href="/api">a</a><a href="b.html">b</a><img src="/l.png" alt="L">',
        base_url="https://docs.test/guide/index.html",
    )
    assert "[a](https://docs.test/api)" in markdown
    assert "[b](https://docs.test/guide/b.html)" in markdown
    assert "![L](https://docs.test/l.png)" in markdown


def test_the_fetched_page_url_is_the_link_base():
    pages = {
        "https://docs.test/guide/": _html('<p><a href="../x">x</a></p>'),
    }
    result = _fetch(pages)("https://docs.test/guide/")
    assert "[x](https://docs.test/x)" in result["content"]


def test_javascript_links_lose_their_href():
    markdown, _ = html_to_markdown('<a href="javascript:alert(1)">click</a>')
    assert "javascript" not in markdown
    assert "[click]" in markdown


# -- registration -------------------------------------------------------------


def test_web_fetch_is_always_registered_and_documented():
    registry = ToolRegistry()
    register_builtin_tools(registry, LocalEnvironment())
    assert registry.available("web_fetch") is True
    docs = render_tool_docs(registry)
    assert "## web_fetch" in docs
    assert "`url` (string, required)" in docs


def test_dispatch_wraps_the_tool_and_coerces_max_chars():
    pages = {
        "https://a.test/x": httpx.Response(
            200, headers={"content-type": "text/plain"}, text="z" * 500
        )
    }
    registry = ToolRegistry()
    register_builtin_tools(
        registry,
        LocalEnvironment(),
        fetch_http_client=httpx.Client(transport=httpx.MockTransport(_handler(pages))),
        resolve=_resolver(),
    )
    result = registry.dispatch(
        "web_fetch", {"url": "https://a.test/x", "max_chars": "50"}
    )
    assert result["ok"] is True
    assert len(result["content"]) == 50


def test_a_non_string_url_is_rejected_not_raised():
    assert _fetch({})({"not": "a url"})["ok"] is False
    assert _fetch({})(None)["error"] == "url is empty"
