"""The URL watch pins every connection to the address it checked.

A hostile DNS server can answer with a public address for the check and
with 127.0.0.1 or 169.254.169.254 for the connect (DNS rebinding). The
fetch resolves each hop once and connects to that address; TLS still
checks the certificate against the host name."""

from __future__ import annotations

import datetime
import ssl
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import httpcore
import pytest
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.x509.oid import NameOID

from chuk_agents_host import url_watch

PUBLIC = "93.184.216.34"


class _Site:
    def __init__(self) -> None:
        self.requests: list[dict] = []
        self.redirect_to: str | None = None


def _serve(state: _Site, tls: ssl.SSLContext | None = None):
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):  # noqa: N802 — http.server API
            state.requests.append({"path": self.path, "host": self.headers.get("Host")})
            if state.redirect_to and self.path == "/moved":
                self.send_response(302)
                self.send_header("Location", state.redirect_to)
                self.end_headers()
                return
            body = b"<p>ok</p>"
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    if tls is not None:
        server.socket = tls.wrap_socket(server.socket, server_side=True)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    return server


class _Recorder(httpcore.NetworkBackend):
    """Records the address the pinned backend asks for, then connects to
    the local test server (it stands in for the public address)."""

    def __init__(self, port: int) -> None:
        self.port = port
        self.addresses: list[str] = []
        self.real = httpcore.SyncBackend()

    def connect_tcp(self, host, port, timeout=None, local_address=None, socket_options=None):  # noqa: ANN001, ANN201
        self.addresses.append(host)
        if host != PUBLIC:
            raise httpcore.ConnectError(f"test refuses {host}")
        return self.real.connect_tcp("127.0.0.1", self.port, timeout=timeout)

    def connect_unix_socket(self, path, timeout=None, socket_options=None):  # noqa: ANN001, ANN201
        raise httpcore.ConnectError("no unix sockets")

    def sleep(self, seconds: float) -> None:
        pass


class _RebindingResolver:
    """Public on the first answer, loopback on every answer after it."""

    def __init__(self, later: str = "127.0.0.1") -> None:
        self.later = later
        self.calls: list[str] = []

    def __call__(self, host: str) -> list[str]:
        self.calls.append(host)
        return [PUBLIC] if len(self.calls) == 1 else [self.later]


@pytest.fixture
def site():
    state = _Site()
    server = _serve(state)
    state.port = server.server_address[1]  # type: ignore[attr-defined]
    try:
        yield state
    finally:
        server.shutdown()
        server.server_close()


def test_a_rebinding_dns_answer_cannot_move_the_connection(site):
    resolver = _RebindingResolver()
    backend = _Recorder(site.port)
    result = url_watch.fetch_url(
        f"http://rebind.example:{site.port}/p", resolver=resolver, network_backend=backend
    )
    assert result.status == 200 and result.text == "ok"
    # Resolved once, connected to the checked address, never to loopback.
    assert resolver.calls == ["rebind.example"]
    assert backend.addresses == [PUBLIC]
    # The Host header still names the host, not the address.
    assert site.requests[0]["host"] == f"rebind.example:{site.port}"


@pytest.mark.parametrize("later", ["127.0.0.1", "169.254.169.254", "::1"])
def test_a_redirect_hop_is_checked_and_pinned_again(site, later):
    site.redirect_to = f"http://rebind.example:{site.port}/final"
    resolver = _RebindingResolver(later)
    backend = _Recorder(site.port)
    with pytest.raises(url_watch.UrlWatchError, match="private network"):
        url_watch.fetch_url(
            f"http://rebind.example:{site.port}/moved", resolver=resolver, network_backend=backend
        )
    assert resolver.calls == ["rebind.example", "rebind.example"]
    assert backend.addresses == [PUBLIC]
    assert [r["path"] for r in site.requests] == ["/moved"]


def test_a_host_with_any_private_address_is_refused_before_a_connect(site):
    backend = _Recorder(site.port)
    with pytest.raises(url_watch.UrlWatchError, match="private network"):
        url_watch.fetch_url(
            "http://mixed.example/",
            resolver=lambda host: [PUBLIC, "10.0.0.1"],
            network_backend=backend,
        )
    assert backend.addresses == []


def test_the_pinned_backend_refuses_a_host_it_has_no_pin_for():
    backend = url_watch._PinnedBackend(httpcore.SyncBackend())
    with pytest.raises(httpcore.ConnectError):
        backend.connect_tcp("unvetted.example", 80)


def test_a_proxy_from_the_environment_is_ignored(monkeypatch, site):
    monkeypatch.setenv("HTTP_PROXY", "http://127.0.0.1:9")
    monkeypatch.setenv("ALL_PROXY", "http://127.0.0.1:9")
    backend = _Recorder(site.port)
    result = url_watch.fetch_url(
        f"http://rebind.example:{site.port}/p", resolver=lambda host: [PUBLIC], network_backend=backend
    )
    assert result.status == 200 and backend.addresses == [PUBLIC]


# -- HTTPS: the certificate is still checked against the host name --------------


def _cert_for(name: str, tmp_path):
    key = ec.generate_private_key(ec.SECP256R1())
    subject = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, name)])
    now = datetime.datetime.now(datetime.timezone.utc)
    cert = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(subject)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - datetime.timedelta(minutes=5))
        .not_valid_after(now + datetime.timedelta(days=1))
        .add_extension(x509.SubjectAlternativeName([x509.DNSName(name)]), critical=False)
        .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
        .sign(key, hashes.SHA256())
    )
    cert_path = tmp_path / "cert.pem"
    key_path = tmp_path / "key.pem"
    cert_path.write_bytes(cert.public_bytes(serialization.Encoding.PEM))
    key_path.write_bytes(
        key.private_bytes(
            serialization.Encoding.PEM,
            serialization.PrivateFormat.PKCS8,
            serialization.NoEncryption(),
        )
    )
    return cert_path, key_path


@pytest.fixture
def tls_site(tmp_path):
    cert_path, key_path = _cert_for("pinned.test", tmp_path)
    server_ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    server_ctx.load_cert_chain(cert_path, key_path)
    state = _Site()
    state.sni: list[str | None] = []

    def sni(sock, name, ctx):  # noqa: ANN001, ANN202
        state.sni.append(name)

    server_ctx.sni_callback = sni
    server = _serve(state, tls=server_ctx)
    state.port = server.server_address[1]  # type: ignore[attr-defined]
    client_ctx = ssl.create_default_context(cafile=str(cert_path))
    state.client_ctx = client_ctx
    try:
        yield state
    finally:
        server.shutdown()
        server.server_close()


def test_https_to_a_pinned_address_still_verifies_the_host_name(tls_site):
    backend = _Recorder(tls_site.port)
    result = url_watch.fetch_url(
        f"https://pinned.test:{tls_site.port}/p",
        resolver=lambda host: [PUBLIC],
        network_backend=backend,
        verify=tls_site.client_ctx,
    )
    assert result.status == 200 and result.text == "ok"
    assert backend.addresses == [PUBLIC]
    # SNI carried the host name, not the pinned address.
    assert tls_site.sni == ["pinned.test"]
    assert tls_site.requests[0]["host"] == f"pinned.test:{tls_site.port}"


def test_https_with_a_certificate_for_another_name_is_refused(tls_site):
    backend = _Recorder(tls_site.port)
    with pytest.raises(url_watch.UrlWatchError, match="fetch failed"):
        url_watch.fetch_url(
            f"https://other.test:{tls_site.port}/p",
            resolver=lambda host: [PUBLIC],
            network_backend=backend,
            verify=tls_site.client_ctx,
        )
    assert tls_site.requests == []
