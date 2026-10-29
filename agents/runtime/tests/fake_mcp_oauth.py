"""A local MCP server with its own OAuth 2.1 authorization server, for tests.

It behaves like the hosted connectors the app signs in to (Fastmail in
particular), so the whole sign-in and renewal path can be tested end to end on
loopback, with no account anywhere:

- protected resource metadata (RFC 9728) and authorization server metadata
  (RFC 8414) under ``/.well-known/``;
- dynamic client registration (RFC 7591) at ``/register``; it records the
  ``client_name``, which is what a consent screen would show;
- ``/authorize`` with PKCE (S256). Consent is automatic: this is a test server
  and there is no person. It redirects at once with ``code``, ``state`` and
  ``iss``;
- ``/token`` with ROTATING refresh tokens: each refresh issues a new refresh
  token and makes the old one invalid (``invalid_grant`` on reuse), and the
  access tokens live a short time (``access_ttl``);
- an MCP endpoint (streamable HTTP, JSON replies) at ``/mcp`` with two tools,
  ``echo`` and ``whoami``. A missing or bad bearer gets ``401`` with a
  ``WWW-Authenticate`` challenge;
- admin switches for tests: ``POST /admin/revoke`` kills every grant (the
  provider revoked the sign-in), ``POST /admin/expire`` makes every access
  token lapse now, ``GET /admin/state`` reports counters.

Run it on its own for a manual test against the app::

    python agents/runtime/tests/fake_mcp_oauth.py --port 8765 --access-ttl 60

then add ``http://127.0.0.1:8765/mcp`` by URL in the app's Connectors screen.
Only standard library modules are used.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import secrets
import threading
import time
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlencode, urlsplit

PROTOCOL_VERSION = "2025-06-18"
SCOPES = ["mcp", "offline_access"]


@dataclass
class FakeState:
    access_ttl: float = 60.0
    clients: dict[str, dict] = field(default_factory=dict)
    codes: dict[str, dict] = field(default_factory=dict)
    #: refresh token -> {client_id, family}
    refresh_tokens: dict[str, dict] = field(default_factory=dict)
    #: access token -> {client_id, family, expires}
    access_tokens: dict[str, dict] = field(default_factory=dict)
    revoked_families: set[str] = field(default_factory=set)
    refreshes: int = 0
    invalid_grants: int = 0
    unauthorized: int = 0
    tool_calls: int = 0
    lock: threading.Lock = field(default_factory=threading.Lock)

    def snapshot(self) -> dict:
        with self.lock:
            return {
                "clients": [
                    {"client_id": cid, "client_name": c.get("client_name")}
                    for cid, c in self.clients.items()
                ],
                "refreshes": self.refreshes,
                "invalid_grants": self.invalid_grants,
                "unauthorized": self.unauthorized,
                "tool_calls": self.tool_calls,
                "live_refresh_tokens": len(self.refresh_tokens),
            }

    def issue(self, client_id: str, family: str) -> dict:
        access = "at-" + secrets.token_urlsafe(16)
        refresh = "rt-" + secrets.token_urlsafe(16)
        self.access_tokens[access] = {
            "client_id": client_id,
            "family": family,
            "expires": time.time() + self.access_ttl,
        }
        self.refresh_tokens[refresh] = {"client_id": client_id, "family": family}
        return {
            "access_token": access,
            "token_type": "Bearer",
            "expires_in": int(self.access_ttl),
            "refresh_token": refresh,
            "scope": " ".join(SCOPES),
        }


class _Handler(BaseHTTPRequestHandler):
    server: FakeMcpOAuthServer
    protocol_version = "HTTP/1.1"

    # -- plumbing ---------------------------------------------------------

    @property
    def state(self) -> FakeState:
        return self.server.state

    @property
    def base(self) -> str:
        host, port = self.server.server_address[:2]
        return f"http://{host}:{port}"

    def log_message(self, *args) -> None:
        pass

    def _send(self, status: int, body: dict | str | None = None, headers: dict | None = None) -> None:
        raw = b""
        content_type = "application/json"
        if isinstance(body, dict) or isinstance(body, list):
            raw = json.dumps(body).encode()
        elif isinstance(body, str):
            raw = body.encode()
            content_type = "text/plain"
        self.send_response(status)
        for key, value in (headers or {}).items():
            self.send_header(key, value)
        if raw:
            self.send_header("content-type", content_type)
        self.send_header("content-length", str(len(raw)))
        self.end_headers()
        if raw:
            self.wfile.write(raw)

    def _body(self) -> bytes:
        length = int(self.headers.get("content-length") or 0)
        return self.rfile.read(length) if length else b""

    # -- routes -----------------------------------------------------------

    def do_GET(self) -> None:
        path = urlsplit(self.path).path
        if path.startswith("/.well-known/oauth-protected-resource"):
            return self._send(
                200,
                {
                    "resource": f"{self.base}/mcp",
                    "authorization_servers": [self.base],
                    "scopes_supported": SCOPES,
                    "bearer_methods_supported": ["header"],
                },
            )
        if path.startswith("/.well-known/oauth-authorization-server") or path.startswith(
            "/.well-known/openid-configuration"
        ):
            return self._send(
                200,
                {
                    "issuer": self.base,
                    "authorization_endpoint": f"{self.base}/authorize",
                    "token_endpoint": f"{self.base}/token",
                    "registration_endpoint": f"{self.base}/register",
                    "scopes_supported": SCOPES,
                    "response_types_supported": ["code"],
                    "grant_types_supported": ["authorization_code", "refresh_token"],
                    "code_challenge_methods_supported": ["S256"],
                    "token_endpoint_auth_methods_supported": ["none"],
                },
            )
        if path == "/authorize":
            return self._authorize()
        if path == "/admin/state":
            return self._send(200, self.state.snapshot())
        if path == "/mcp":
            # No server-to-client stream on this server.
            return self._send(405)
        return self._send(404, {"error": "not_found"})

    def do_DELETE(self) -> None:
        self._send(200 if urlsplit(self.path).path == "/mcp" else 404)

    def do_POST(self) -> None:
        path = urlsplit(self.path).path
        if path == "/register":
            return self._register()
        if path == "/token":
            return self._token()
        if path == "/mcp":
            return self._mcp()
        if path == "/admin/revoke":
            with self.state.lock:
                families = {r["family"] for r in self.state.refresh_tokens.values()}
                families |= {a["family"] for a in self.state.access_tokens.values()}
                self.state.revoked_families |= families
            self._body()
            return self._send(200, {"revoked": len(families)})
        if path == "/admin/expire":
            with self.state.lock:
                for record in self.state.access_tokens.values():
                    record["expires"] = 0.0
            self._body()
            return self._send(200, {"ok": True})
        return self._send(404, {"error": "not_found"})

    # -- OAuth ------------------------------------------------------------

    def _register(self) -> None:
        try:
            payload = json.loads(self._body() or b"{}")
        except ValueError:
            return self._send(400, {"error": "invalid_client_metadata"})
        client_id = "client-" + secrets.token_hex(6)
        record = {
            "client_name": payload.get("client_name"),
            "client_uri": payload.get("client_uri"),
            "redirect_uris": list(payload.get("redirect_uris") or []),
        }
        with self.state.lock:
            self.state.clients[client_id] = record
        return self._send(
            201,
            {
                "client_id": client_id,
                "client_name": record["client_name"],
                "redirect_uris": record["redirect_uris"],
                "grant_types": ["authorization_code", "refresh_token"],
                "token_endpoint_auth_method": "none",
            },
        )

    def _authorize(self) -> None:
        query = {k: v[0] for k, v in parse_qs(urlsplit(self.path).query).items()}
        client_id = query.get("client_id", "")
        redirect_uri = query.get("redirect_uri", "")
        with self.state.lock:
            client = self.state.clients.get(client_id)
        if client is None:
            return self._send(400, "unknown client")
        if query.get("code_challenge_method") != "S256" or not query.get("code_challenge"):
            return self._send(400, "PKCE S256 required")
        code = "code-" + secrets.token_urlsafe(12)
        with self.state.lock:
            self.state.codes[code] = {
                "client_id": client_id,
                "redirect_uri": redirect_uri,
                "challenge": query["code_challenge"],
            }
        # Test-only automatic consent: redirect straight back.
        params = urlencode({"code": code, "state": query.get("state", ""), "iss": self.base})
        sep = "&" if "?" in redirect_uri else "?"
        return self._send(302, headers={"location": f"{redirect_uri}{sep}{params}"})

    def _token(self) -> None:
        form = {k: v[0] for k, v in parse_qs(self._body().decode()).items()}
        grant = form.get("grant_type")
        state = self.state
        with state.lock:
            if grant == "authorization_code":
                record = state.codes.pop(form.get("code", ""), None)
                if record is None or record["client_id"] != form.get("client_id"):
                    return self._send(400, {"error": "invalid_grant"})
                verifier = form.get("code_verifier", "")
                digest = (
                    base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest())
                    .decode()
                    .rstrip("=")
                )
                if digest != record["challenge"]:
                    return self._send(400, {"error": "invalid_grant"})
                return self._send(200, state.issue(record["client_id"], secrets.token_hex(4)))
            if grant == "refresh_token":
                state.refreshes += 1
                record = state.refresh_tokens.pop(form.get("refresh_token", ""), None)
                if record is None or record["family"] in state.revoked_families:
                    state.invalid_grants += 1
                    return self._send(400, {"error": "invalid_grant"})
                # Rotation: the old refresh token is gone (popped above), and
                # the access tokens of the family stop working too.
                for token, access in list(state.access_tokens.items()):
                    if access["family"] == record["family"]:
                        del state.access_tokens[token]
                return self._send(200, state.issue(record["client_id"], record["family"]))
        return self._send(400, {"error": "unsupported_grant_type"})

    # -- MCP --------------------------------------------------------------

    def _bearer_client(self) -> str | None:
        header = self.headers.get("authorization", "")
        if not header.startswith("Bearer "):
            return None
        with self.state.lock:
            record = self.state.access_tokens.get(header[len("Bearer "):])
            if record is None or record["family"] in self.state.revoked_families:
                return None
            if record["expires"] <= time.time():
                return None
            return record["client_id"]

    def _mcp(self) -> None:
        body = self._body()
        client_id = self._bearer_client()
        if client_id is None:
            with self.state.lock:
                self.state.unauthorized += 1
            challenge = (
                f'Bearer resource_metadata="{self.base}/.well-known/oauth-protected-resource/mcp", '
                'scope="mcp offline_access"'
            )
            return self._send(401, {"error": "invalid_token"}, {"www-authenticate": challenge})
        try:
            message = json.loads(body or b"{}")
        except ValueError:
            return self._send(400, {"error": "parse error"})
        if "id" not in message:
            # A notification (notifications/initialized): accepted, no reply.
            return self._send(202)
        method = message.get("method")
        result: dict
        if method == "initialize":
            result = {
                "protocolVersion": PROTOCOL_VERSION,
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "fake-mcp-oauth", "version": "1"},
            }
        elif method == "tools/list":
            result = {
                "tools": [
                    {
                        "name": "echo",
                        "description": "Return the text.",
                        "inputSchema": {
                            "type": "object",
                            "properties": {"text": {"type": "string"}},
                            "required": ["text"],
                        },
                    },
                    {
                        "name": "whoami",
                        "description": "Name the signed-in client.",
                        "inputSchema": {"type": "object", "properties": {}},
                    },
                ]
            }
        elif method == "tools/call":
            params = message.get("params") or {}
            with self.state.lock:
                self.state.tool_calls += 1
                client_name = self.state.clients.get(client_id, {}).get("client_name")
            if params.get("name") == "echo":
                text = str((params.get("arguments") or {}).get("text", ""))
            else:
                text = str(client_name)
            result = {"content": [{"type": "text", "text": text}], "isError": False}
        elif method == "ping":
            result = {}
        else:
            return self._send(
                200,
                {"jsonrpc": "2.0", "id": message["id"], "error": {"code": -32601, "message": "no such method"}},
            )
        return self._send(
            200,
            {"jsonrpc": "2.0", "id": message["id"], "result": result},
            {"mcp-session-id": "fake-session"},
        )


class FakeMcpOAuthServer(ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, port: int = 0, *, access_ttl: float = 60.0) -> None:
        super().__init__(("127.0.0.1", port), _Handler)
        self.state = FakeState(access_ttl=access_ttl)
        self._thread: threading.Thread | None = None

    @property
    def base_url(self) -> str:
        host, port = self.server_address[:2]
        return f"http://{host}:{port}"

    @property
    def mcp_url(self) -> str:
        return f"{self.base_url}/mcp"

    def start(self) -> FakeMcpOAuthServer:
        self._thread = threading.Thread(target=self.serve_forever, daemon=True)
        self._thread.start()
        return self

    def stop(self) -> None:
        self.shutdown()
        self.server_close()
        if self._thread is not None:
            self._thread.join(5)

    # -- direct helpers for Python tests ---------------------------------

    def sign_in(self, client_name: str = "Chuk Chat") -> dict:
        """Register a client and mint a first token pair, the way the app's
        browser sign-in ends. Returns the forwarded ``oauth`` entry fields."""
        client_id = "client-" + secrets.token_hex(6)
        with self.state.lock:
            self.state.clients[client_id] = {"client_name": client_name, "redirect_uris": []}
            tokens = self.state.issue(client_id, secrets.token_hex(4))
        return {
            "access_token": tokens["access_token"],
            "oauth": {
                "token_endpoint": f"{self.base_url}/token",
                "client_id": client_id,
                "refresh_token": tokens["refresh_token"],
                "expires_at": time.strftime(
                    "%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() + self.state.access_ttl)
                ),
                "resource": self.mcp_url,
                "scope": " ".join(SCOPES),
            },
        }

    def revoke(self) -> None:
        with self.state.lock:
            families = {r["family"] for r in self.state.refresh_tokens.values()}
            families |= {a["family"] for a in self.state.access_tokens.values()}
            self.state.revoked_families |= families

    def expire_access(self) -> None:
        with self.state.lock:
            for record in self.state.access_tokens.values():
                record["expires"] = 0.0


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--access-ttl", type=float, default=60.0)
    args = parser.parse_args()
    server = FakeMcpOAuthServer(args.port, access_ttl=args.access_ttl)
    print(f"fake MCP OAuth server on {server.mcp_url}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
