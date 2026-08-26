"""OAuth bridge tests (§10).

The backend route does not exist yet (see ``docs/MCP_OAUTH_BACKEND_ROUTE.md``),
so :class:`FakeBackend` implements exactly the documented contract on
``httpx.MockTransport``. When the real route lands, these tests are the
conformance check for it.

What is proven here: a wrong ``state`` is rejected, the comparison really goes
through :func:`hmac.compare_digest`, an expired flow is rejected, a code is
redeemable exactly once, the wait times out instead of hanging, and neither the
code nor the token ever appears in the tool result.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import json
import threading
import time

import httpx

from cowork_agent import oauth_bridge as mod
from cowork_agent.oauth_bridge import (
    BackendOAuthClient,
    CredentialStash,
    OAuthBridge,
    callback_uri,
    config_token_exchange,
    make_oauth_connect_handler,
    pkce_pair,
    register_oauth_tool,
)
from cowork_agent.registry import ToolRegistry


class Session:
    def __init__(self) -> None:
        self.access_token = "account-token"
        self.refreshes = 0

    def refresh(self) -> None:
        self.refreshes += 1


class FakeBackend:
    """The contract of ``docs/MCP_OAUTH_BACKEND_ROUTE.md``, in ~40 lines.

    ``POST /v1/oauth/mcp/start``   -> 200 {state, authorize_url, expires_in}
    ``GET  /v1/oauth/mcp/pending/{state}`` -> 200 {state, code} once,
                                             204 while pending,
                                             410 once consumed or expired.
    """

    def __init__(self, *, expires_in: float = 600.0) -> None:
        self.flows: dict[str, dict] = {}
        self.consumed: set[str] = set()
        self.polls = 0
        self.tokens_issued = 0
        self.expires_in = expires_in

    # the provider redirect, as the backend would receive it
    def callback(self, server: str, state: str, code: str) -> None:
        flow = self.flows.get(state)
        assert flow is not None and flow["server"] == server
        flow["code"] = code

    def handler(self, request: httpx.Request) -> httpx.Response:
        path = request.url.path
        # Our own routes are paid for with the account token. The provider's
        # token endpoint is not ours and gets no account token.
        if path.startswith("/v1/oauth/") and (
            request.headers.get("Authorization") != "Bearer account-token"
        ):
            return httpx.Response(401, json={"error": "bad token"})
        if path == "/v1/oauth/mcp/start" and request.method == "POST":
            body = json.loads(request.content or b"{}")
            server = body["server"]
            # The contract: a server name, never an endpoint or a client id.
            assert "authorize_endpoint" not in body
            assert "client_id" not in body
            assert body.get("code_challenge_method") == "S256"
            state = f"state-for-{server}-{len(self.flows)}"
            self.flows[state] = {
                "server": server,
                "code": None,
                "challenge": body.get("code_challenge"),
            }
            return httpx.Response(
                200,
                json={
                    "state": state,
                    "authorize_url": (
                        f"https://mcp.example.com/authorize?client_id=cid&state={state}"
                        f"&redirect_uri={callback_uri('https://api.chuk.chat', server)}"
                    ),
                    "expires_in": self.expires_in,
                },
            )
        if path.startswith("/v1/oauth/mcp/pending/"):
            self.polls += 1
            state = path.rsplit("/", 1)[-1]
            if state in self.consumed:
                return httpx.Response(410, json={"error": "already used"})
            flow = self.flows.get(state)
            if flow is None:
                return httpx.Response(404, json={"error": "unknown state"})
            if not flow["code"]:
                return httpx.Response(204)
            self.consumed.add(state)
            return httpx.Response(200, json={"state": state, "code": flow["code"]})
        if path == "/token":
            self.tokens_issued += 1
            form = dict(httpx.QueryParams(request.content.decode()))
            assert form["grant_type"] == "authorization_code"
            assert form["redirect_uri"].startswith("https://api.chuk.chat/oauth/callback/")
            # PKCE, checked the way a real provider checks it.
            flow = next(f for f in self.flows.values() if f["code"] == form["code"])
            digest = hashlib.sha256(form["code_verifier"].encode()).digest()
            expected = base64.urlsafe_b64encode(digest).decode().rstrip("=")
            assert expected == flow["challenge"], "PKCE verifier does not match"
            return httpx.Response(200, json={"access_token": f"tok-{form['code']}"})
        return httpx.Response(404, json={"error": f"no route {path}"})

    def client(self) -> httpx.Client:
        return httpx.Client(transport=httpx.MockTransport(self.handler))


# -- correlation -----------------------------------------------------------


def test_a_wrong_state_is_rejected():
    bridge = OAuthBridge()
    flow = bridge.begin("github", "https://example/authorize")
    assert bridge.deliver("not-the-state", "code-1")["ok"] is False
    assert flow.event.is_set() is False
    assert bridge.deliver(flow.state, "code-1")["ok"] is True


def test_the_state_compare_uses_hmac_compare_digest(monkeypatch):
    """Constant time, and provably so: the real comparison is counted."""
    calls: list[tuple[bytes, bytes]] = []
    real = hmac.compare_digest

    class Spy:
        @staticmethod
        def compare_digest(a, b):
            calls.append((a, b))
            return real(a, b)

    monkeypatch.setattr(mod, "hmac", Spy)
    bridge = OAuthBridge()
    flow = bridge.begin("srv", "https://example/authorize")
    bridge.deliver(flow.state, "code")
    assert calls, "state was not compared with hmac.compare_digest"
    assert calls[0][1] == flow.state.encode()


def test_delivery_checks_every_candidate_so_timing_does_not_leak(monkeypatch):
    counted: list[int] = []
    real = hmac.compare_digest

    class Spy:
        @staticmethod
        def compare_digest(a, b):
            counted.append(1)
            return real(a, b)

    monkeypatch.setattr(mod, "hmac", Spy)
    bridge = OAuthBridge()
    flows = [bridge.begin(f"s{i}", "https://example/authorize") for i in range(5)]
    counted.clear()
    bridge.deliver(flows[0].state, "code")
    # The first flow matches, and all five are still compared.
    assert len(counted) == 5


def test_an_expired_flow_is_rejected():
    now = {"t": 1000.0}
    bridge = OAuthBridge(ttl=10.0, clock=lambda: now["t"])
    flow = bridge.begin("srv", "https://example/authorize")
    now["t"] += 11.0
    result = bridge.deliver(flow.state, "code")
    assert result["ok"] is False
    assert "expired" in result["error"]


def test_a_code_is_redeemable_exactly_once():
    bridge = OAuthBridge()
    flow = bridge.begin("srv", "https://example/authorize")
    assert bridge.deliver(flow.state, "code-1")["ok"] is True
    second = bridge.deliver(flow.state, "code-2")
    assert second["ok"] is False
    assert bridge.wait(flow, timeout=1.0)["code"] == "code-1"
    # And the flow is gone, so a late callback finds nothing to unlock.
    assert bridge.deliver(flow.state, "code-3")["ok"] is False


def test_deliver_requires_both_parts():
    bridge = OAuthBridge()
    bridge.begin("srv", "https://example/authorize")
    assert bridge.deliver("", "code")["ok"] is False
    assert bridge.deliver("state", "")["ok"] is False


# -- the wait --------------------------------------------------------------


def test_the_wait_times_out_instead_of_hanging():
    bridge = OAuthBridge()
    flow = bridge.begin("srv", "https://example/authorize")
    started = time.monotonic()
    result = bridge.wait(flow, timeout=0.2)
    assert result["ok"] is False
    assert result["timed_out"] is True
    assert time.monotonic() - started < 5.0


def test_the_wait_is_released_by_a_delivery_from_another_thread():
    bridge = OAuthBridge()
    flow = bridge.begin("srv", "https://example/authorize")

    def deliver_soon() -> None:
        time.sleep(0.05)
        bridge.deliver(flow.state, "code-async")

    threading.Thread(target=deliver_soon, daemon=True).start()
    result = bridge.wait(flow, timeout=10.0)
    assert result == {"ok": True, "server": "srv", "code": "code-async"}


def test_the_wait_gives_up_when_stop_is_pressed():
    """The Stop button reaches into the wait instead of being queued behind it."""
    bridge = OAuthBridge()
    flow = bridge.begin("srv", "https://example/authorize")
    stopped = {"yes": False}

    def press_stop() -> None:
        time.sleep(0.05)
        stopped["yes"] = True

    threading.Thread(target=press_stop, daemon=True).start()
    started = time.monotonic()
    result = bridge.wait(flow, timeout=600.0, cancel=lambda: stopped["yes"])
    assert result["ok"] is False
    assert result["cancelled"] is True
    assert result["timed_out"] is False
    assert time.monotonic() - started < 10.0


def test_the_wait_never_outlives_the_flow():
    now = {"t": 0.0}
    bridge = OAuthBridge(ttl=0.1, clock=lambda: now["t"])
    flow = bridge.begin("srv", "https://example/authorize")
    now["t"] = 5.0
    result = bridge.wait(flow, timeout=30.0)
    assert result["ok"] is False
    assert result["error"] == "authorization expired"


def test_pending_flows_are_pruned():
    now = {"t": 0.0}
    bridge = OAuthBridge(ttl=1.0, clock=lambda: now["t"])
    bridge.begin("a", "https://example/authorize")
    bridge.begin("b", "https://example/authorize")
    assert bridge.pending_states() == 2
    now["t"] = 10.0
    assert bridge.pending_states() == 0


# -- the stash -------------------------------------------------------------


def test_a_flow_never_prints_its_state_or_its_code():
    bridge = OAuthBridge()
    flow = bridge.begin("srv", "https://example/authorize")
    bridge.deliver(flow.state, "the-code")
    printed = repr(flow)
    assert flow.state not in printed
    assert "the-code" not in printed
    assert "srv" in printed


def test_a_cancelled_flow_can_no_longer_be_delivered_to():
    bridge = OAuthBridge()
    flow = bridge.begin("srv", "https://example/authorize")
    bridge.cancel(flow.state)
    assert bridge.deliver(flow.state, "code")["ok"] is False
    assert bridge.pending_states() == 0


def test_the_stash_never_prints_a_token():
    stash = CredentialStash()
    stash.put("srv", "super-secret-token")
    assert "super-secret-token" not in repr(stash)
    assert "super-secret-token" not in str(stash)
    assert stash.get("srv") == "super-secret-token"
    assert stash.servers() == ["srv"]
    stash.forget("srv")
    assert stash.get("srv") is None


# -- the backend client ----------------------------------------------------


def test_start_and_poll_against_the_documented_contract():
    backend = FakeBackend()
    client = BackendOAuthClient(Session(), http_client=backend.client())
    verifier, challenge = pkce_pair()
    started = client.start("github", code_challenge=challenge)
    assert started["ok"] is True
    assert started["authorize_url"].startswith("https://mcp.example.com/authorize")
    assert "redirect_uri=https://api.chuk.chat/oauth/callback/github" in started["authorize_url"]

    assert client.poll(started["state"], wait=0) == {"ok": False, "pending": True}
    backend.callback("github", started["state"], "the-code")
    got = client.poll(started["state"], wait=0)
    assert got["ok"] is True and got["code"] == "the-code"
    # Single use, server side too.
    assert client.poll(started["state"], wait=0)["pending"] is False


def test_an_expired_token_is_refreshed_once():
    session = Session()
    session.access_token = "stale"
    backend = FakeBackend()

    def handler(request: httpx.Request) -> httpx.Response:
        if session.access_token == "stale":
            session.access_token = "account-token"  # the refresh side effect
            return httpx.Response(401, json={"error": "expired"})
        return backend.handler(request)

    client = BackendOAuthClient(
        session, http_client=httpx.Client(transport=httpx.MockTransport(handler))
    )
    assert client.start("srv", code_challenge=pkce_pair()[1])["ok"] is True
    assert session.refreshes == 1


def test_backend_failures_are_reported_not_raised():
    session = Session()
    client = BackendOAuthClient(
        session,
        http_client=httpx.Client(
            transport=httpx.MockTransport(
                lambda request: httpx.Response(503, json={"error": "no oauth provider"})
            )
        ),
    )
    result = client.start("srv")
    assert result["ok"] is False
    assert "no oauth provider" in result["error"]


def test_an_unreachable_backend_is_reported_not_raised():
    def boom(request: httpx.Request) -> httpx.Response:
        raise httpx.ConnectError("nope", request=request)

    client = BackendOAuthClient(
        Session(), http_client=httpx.Client(transport=httpx.MockTransport(boom))
    )
    assert client.start("srv")["ok"] is False
    assert client.poll("state", wait=0)["pending"] is True


# -- the tool, end to end --------------------------------------------------


def wire(*, expires_in: float = 600.0):
    """Everything the tool needs, against the fake backend."""
    backend = FakeBackend(expires_in=expires_in)
    http = backend.client()
    bridge = OAuthBridge()
    stash = CredentialStash()
    links: list[tuple[str, str]] = []
    reconnected: list[str] = []
    handler = make_oauth_connect_handler(
        bridge,
        BackendOAuthClient(Session(), http_client=http),
        stash=stash,
        exchange=config_token_exchange(
            {"github": {"token_url": "https://api.chuk.chat/token", "client_id": "cid"}},
            http_client=http,
        ),
        notify=lambda server, url: links.append((server, url)),
        on_authorized=reconnected.append,
        poll_leg=0.05,
    )
    return backend, handler, stash, links, reconnected


def test_the_tool_authorizes_without_ever_showing_the_credential():
    backend, handler, stash, links, reconnected = wire()

    def authorize_in_the_browser() -> None:
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            for state, flow in list(backend.flows.items()):
                if not flow["code"]:
                    backend.callback(flow["server"], state, "browser-code")
                    return
            time.sleep(0.01)

    threading.Thread(target=authorize_in_the_browser, daemon=True).start()
    result = handler("github", timeout=20)

    assert result == {"ok": True, "server": "github", "authorized": True}
    # The link went to the user, not into the answer.
    assert links and links[0][0] == "github"
    assert "authorize_url" not in result
    # The token is in the stash and nowhere in the tool result.
    assert stash.get("github") == "tok-browser-code"
    assert "browser-code" not in json.dumps(result)
    assert "tok-" not in json.dumps(result)
    assert reconnected == ["github"]
    assert backend.tokens_issued == 1


def test_the_tool_times_out_cleanly_when_the_user_never_authorizes():
    # The flow's own expiry bounds the wait, so this ends in a fraction of a
    # second instead of parking for the product default.
    backend, handler, stash, links, reconnected = wire(expires_in=0.3)
    result = handler("github", timeout=60)
    # Nothing was authorized, and the model is told so plainly.
    assert result["ok"] is False
    assert result["authorized"] is False
    assert stash.servers() == []
    assert reconnected == []


def test_a_server_without_an_oauth_block_says_so_instead_of_half_connecting():
    backend, handler, stash, links, reconnected = wire()

    def authorize() -> None:
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            for state, flow in list(backend.flows.items()):
                if not flow["code"]:
                    backend.callback(flow["server"], state, "code-x")
                    return
            time.sleep(0.01)

    threading.Thread(target=authorize, daemon=True).start()
    result = handler("slack", timeout=20)
    assert result["ok"] is False
    assert "no token exchange" in result["error"] or "exchange failed" in result["error"]
    assert stash.servers() == []


def test_without_a_notifier_the_link_is_returned_so_the_user_can_still_get_it():
    backend = FakeBackend(expires_in=0.3)
    handler = make_oauth_connect_handler(
        OAuthBridge(),
        BackendOAuthClient(Session(), http_client=backend.client()),
        stash=CredentialStash(),
        exchange=lambda server, code, verifier: "token",
        poll_leg=0.05,
    )
    result = handler("github", timeout=60)
    assert result["ok"] is False
    assert result["authorize_url"].startswith("https://mcp.example.com/authorize")


def test_the_tool_is_not_registered_without_a_bridge_or_a_client():
    registry = ToolRegistry()
    register_oauth_tool(registry, None, None)
    assert registry.has("mcp_oauth_connect") is False

    backend = FakeBackend()
    register_oauth_tool(
        registry,
        OAuthBridge(),
        BackendOAuthClient(Session(), http_client=backend.client()),
    )
    assert registry.has("mcp_oauth_connect") is True
    assert registry.spec("mcp_oauth_connect").deferrable is False


def test_an_empty_server_name_is_refused_before_any_request():
    backend = FakeBackend()
    handler = make_oauth_connect_handler(
        OAuthBridge(), BackendOAuthClient(Session(), http_client=backend.client())
    )
    assert handler("  ")["ok"] is False
    assert backend.flows == {}


def test_the_pkce_pair_is_a_valid_s256_challenge():
    verifier, challenge = pkce_pair()
    assert 43 <= len(verifier) <= 128
    digest = hashlib.sha256(verifier.encode()).digest()
    assert challenge == base64.urlsafe_b64encode(digest).decode().rstrip("=")
    assert "=" not in challenge
    # Fresh every time.
    assert pkce_pair()[0] != verifier


def test_the_verifier_never_shows_up_in_the_flow_repr():
    bridge = OAuthBridge()
    verifier, _ = pkce_pair()
    flow = bridge.begin("srv", "https://example/authorize", verifier=verifier)
    assert verifier not in repr(flow)


def test_the_callback_uri_is_the_public_backend_never_localhost():
    uri = callback_uri("https://api.chuk.chat", "github")
    assert uri == "https://api.chuk.chat/oauth/callback/github"
    assert "localhost" not in uri
    assert "127.0.0.1" not in uri
