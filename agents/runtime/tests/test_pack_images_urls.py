"""The image pack script refuses URLs that are not public http(s)."""

from __future__ import annotations

import importlib.util
import socket
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[2] / "skills" / "builtin" / "web-images" / "pack_images.py"


def _load():
    spec = importlib.util.spec_from_file_location("pack_images", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _resolve_to(address: str):
    def fake(host, port, *args, **kwargs):
        return [(socket.AF_INET, socket.SOCK_STREAM, 6, "", (address, port))]

    return fake


@pytest.mark.parametrize(
    "url",
    ["file:///etc/passwd", "ftp://example.com/a.jpg", "data:image/png;base64,AAAA", "http:///a.jpg"],
)
def test_a_url_that_is_not_http_is_refused(url):
    pack = _load()
    with pytest.raises(ValueError):
        pack.check_public_url(url)


@pytest.mark.parametrize("address", ["127.0.0.1", "169.254.169.254", "10.0.0.5", "192.168.1.2", "::1"])
def test_an_internal_address_is_refused(monkeypatch, address):
    pack = _load()
    monkeypatch.setattr(pack.socket, "getaddrinfo", _resolve_to(address))
    with pytest.raises(ValueError, match="not a public address"):
        pack.check_public_url("https://shop.example/a.jpg")


def test_a_public_address_is_allowed(monkeypatch):
    pack = _load()
    monkeypatch.setattr(pack.socket, "getaddrinfo", _resolve_to("93.184.216.34"))
    pack.check_public_url("https://shop.example/a.jpg")


def test_a_redirect_to_an_internal_address_is_refused(monkeypatch):
    pack = _load()
    monkeypatch.setattr(pack.socket, "getaddrinfo", _resolve_to("169.254.169.254"))
    handler = pack._PublicRedirects()
    with pytest.raises(ValueError):
        handler.redirect_request(None, None, 302, "Found", {}, "http://metadata.internal/latest")
