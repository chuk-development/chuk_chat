"""Research item 39: the untrusted notice, cross-origin redirects, and the
DNS pin (the address that passed the check is the one the socket opens).

No socket and no DNS: the network backend under the pinned client is fake.
"""

from __future__ import annotations

import httpcore
import httpx
import pytest

from chuk_agents_runtime.web_fetch import (
    UNTRUSTED_NOTICE,
    PinnedBackend,
    make_web_fetch_handler,
)

PUBLIC = "93.184.216.34"


class _Stream(httpcore.NetworkStream):
    def __init__(self, reply: bytes, log: list) -> None:
        self._reply = reply
        self._log = log

    def write(self, buffer: bytes, timeout=None) -> None:
        self._log.append(buffer)

    def read(self, max_bytes: int, timeout=None) -> bytes:
        chunk, self._reply = self._reply[:max_bytes], self._reply[max_bytes:]
        return chunk

    def close(self) -> None:
        pass

    def get_extra_info(self, info: str):
        return None


class _Backend(httpcore.NetworkBackend):
    """Records every connect; answers with a canned HTTP/1.1 response."""

    def __init__(self, body: bytes = b"<html><title>T</title><p>hello</p></html>") -> None:
        self.connects: list[tuple[str, int]] = []
        self.written: list[bytes] = []
        self._body = body

    def connect_tcp(self, host, port, timeout=None, local_address=None, socket_options=None):
        self.connects.append((host, port))
        head = (
            b"HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n"
            + f"Content-Length: {len(self._body)}\r\nConnection: close\r\n\r\n".encode()
        )
        return _Stream(head + self._body, self.written)

    def sleep(self, seconds: float) -> None:
        pass


def test_the_connection_goes_to_the_validated_address_not_a_rebound_one():
    """The resolver answers public first and loopback afterwards (a
    rebinding DNS). The socket must open to the public address, and the
    name stays in the Host header."""
    answers = iter([[PUBLIC], ["127.0.0.1"], ["127.0.0.1"]])
    calls: list[str] = []

    def rebinding(host: str, port: int):
        calls.append(host)
        return next(answers)

    backend = _Backend()
    fetch = make_web_fetch_handler(resolve=rebinding, network_backend=backend)
    result = fetch("http://rebind.test/page")
    assert result["ok"] is True, result
    assert backend.connects == [(PUBLIC, 80)]
    assert calls == ["rebind.test"]  # resolved once, by us, never again by httpx
    request = b"".join(backend.written)
    assert b"Host: rebind.test" in request


def test_a_host_without_a_pin_is_refused():
    inner = _Backend()
    backend = PinnedBackend({"a.test": PUBLIC}, inner)
    with pytest.raises(httpcore.ConnectError):
        backend.connect_tcp("b.test", 80)
    with pytest.raises(httpcore.ConnectError):
        PinnedBackend({"a.test": "10.0.0.1"}, inner).connect_tcp("a.test", 80)
    backend.connect_tcp("a.test", 443)
    assert inner.connects == [(PUBLIC, 443)]


def test_every_success_starts_with_the_untrusted_notice():
    backend = _Backend()
    fetch = make_web_fetch_handler(resolve=lambda h, p: [PUBLIC], network_backend=backend)
    result = fetch("http://a.test/")
    assert next(iter(result)) == "notice"
    assert result["notice"] == UNTRUSTED_NOTICE
    assert "hello" in result["content"]
    assert "cross_origin_redirect" not in result


def _mock_fetch(pages):
    def handle(request: httpx.Request) -> httpx.Response:
        resp = pages.get(str(request.url))
        if resp is None:
            return httpx.Response(404, text="missing")
        return httpx.Response(resp.status_code, headers=resp.headers, content=resp.content)

    return make_web_fetch_handler(
        http_client=httpx.Client(transport=httpx.MockTransport(handle)),
        resolve=lambda h, p: [PUBLIC],
    )


def test_a_cross_origin_redirect_is_named():
    pages = {
        "https://short.test/x": httpx.Response(302, headers={"location": "https://other.test/landing"}),
        "https://other.test/landing": httpx.Response(
            200, headers={"content-type": "text/plain"}, text="landed"
        ),
    }
    result = _mock_fetch(pages)("https://short.test/x")
    assert result["ok"] is True
    assert result["cross_origin_redirect"] == {
        "from": "https://short.test:443",
        "to": "https://other.test:443",
    }
    assert result["redirects"] == ["https://other.test/landing"]


def test_a_same_origin_redirect_is_not_flagged():
    pages = {
        "https://a.test/old": httpx.Response(301, headers={"location": "/new"}),
        "https://a.test/new": httpx.Response(200, headers={"content-type": "text/plain"}, text="x"),
    }
    result = _mock_fetch(pages)("https://a.test/old")
    assert result["ok"] is True and "cross_origin_redirect" not in result


def test_a_failure_carries_no_notice():
    result = _mock_fetch({})("https://a.test/none")
    assert result["ok"] is False and "notice" not in result
