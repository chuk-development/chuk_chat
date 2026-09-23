"""The host's own account session, and how a dead one heals without a pairing.

The bug: the host ran on the app's refresh token. Supabase rotates refresh
tokens, so after three days offline ``account.json`` held a dead one, the relay
refused the handshake, and no app could reach the host to give it a new one.

These tests pin the two halves of the fix:

* a dead refresh token sends the relay dial to the heal channel, which the
  paired app can claim, and a network fault does not;
* the host's own session (``session_kind: host``) is never replaced by the
  app's token, is refreshed by the host alone, and is never reported back.

No network and no relay: GoTrue is an ``httpx.MockTransport`` or a stub, and
the relay socket is a fake.
"""

from __future__ import annotations

import base64
import json
import time
import uuid

import httpx
import pytest
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from chuk_agents_runtime import SupabaseSession
from chuk_agents_runtime.backend import SupabaseAuthError

from chuk_agents_host import LocalHost
from chuk_agents_host.cloud_relay import (
    TYPE_PAIR_BOUND,
    TYPE_PAIR_EXPIRED,
    CloudRelayTransport,
    unwrap_payload,
)
from chuk_agents_host.host_credential import (
    KIND_ACCESS_ONLY,
    KIND_APP,
    KIND_HOST,
    TYPE_HOST_SESSION_REQUEST,
    decide,
    derive_heal_channel,
    frame_kind,
    refresh_is_dead,
    stored_kind,
)
from chuk_agents_host.pairing_store import HostTrust
from chuk_agents_host.protocol import ROLE_EXECUTOR, join_message

from test_local_run import _scripted_model

CHANNEL_ID = "testchannel00"
CHANNEL_KEY = bytes(range(32))

APP_FRAME = {
    "type": "account_authentication",
    "access_token": "app-access",
    "refresh_token": "app-refresh",
    "user_id": "user-1",
    "supabase_url": "https://db.example.test",
    "anon_key": "anon",
    "expires_at": time.time() + 3600,
}
HOST_FRAME = {
    **APP_FRAME,
    "access_token": "host-access",
    "refresh_token": "host-refresh",
    "session_kind": "host",
}
ACCESS_ONLY_FRAME = {k: v for k, v in APP_FRAME.items() if k != "refresh_token"}


# -- the heal channel ----------------------------------------------------------


def test_the_heal_channel_is_256_bits_url_safe_and_deterministic():
    channel = derive_heal_channel(CHANNEL_KEY, CHANNEL_ID)
    assert len(channel) == 43
    assert set(channel) <= set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    )
    assert channel == derive_heal_channel(CHANNEL_KEY, CHANNEL_ID)


def test_the_heal_channel_matches_the_apps_derivation():
    # The same vector is asserted in test/services/agents/agents_heal_channel_test.dart.
    assert (
        derive_heal_channel(bytes(range(32)), "0123456789abcdef")
        == "P6dK7KJxfD_xxCQuKe-OjUhdpol5n_UHLtRlMQPHnHk"
    )


def test_the_heal_channel_depends_on_the_key_and_the_channel():
    base = derive_heal_channel(CHANNEL_KEY, CHANNEL_ID)
    assert derive_heal_channel(bytes(32), CHANNEL_ID) != base
    assert derive_heal_channel(CHANNEL_KEY, "otherchannel00") != base


def test_the_heal_channel_does_not_expose_the_key():
    channel = derive_heal_channel(CHANNEL_KEY, CHANNEL_ID)
    assert base64.urlsafe_b64encode(CHANNEL_KEY).decode().rstrip("=") != channel


def test_a_malformed_key_has_no_heal_channel():
    with pytest.raises(ValueError):
        derive_heal_channel(b"short", CHANNEL_ID)
    with pytest.raises(ValueError):
        derive_heal_channel(CHANNEL_KEY, "")


# -- classifying credentials ------------------------------------------------


@pytest.mark.parametrize(
    ("status", "dead"),
    [(400, True), (401, True), (403, True), (429, False), (500, False), (503, False), (None, False)],
)
def test_only_a_definite_refusal_is_a_dead_refresh_token(status, dead):
    assert refresh_is_dead(SupabaseAuthError("x", status=status)) is dead


def test_a_network_error_is_not_a_dead_refresh_token():
    assert refresh_is_dead(RuntimeError("connection reset")) is False


def test_frame_kinds():
    assert frame_kind(HOST_FRAME) == KIND_HOST
    assert frame_kind(APP_FRAME) == KIND_APP
    assert frame_kind(ACCESS_ONLY_FRAME) == KIND_ACCESS_ONLY
    # The mark alone does not make a pair: no refresh token, no host session.
    assert frame_kind({**ACCESS_ONLY_FRAME, "session_kind": "host"}) == KIND_ACCESS_ONLY
    assert frame_kind({"type": "account_authentication"}) is None
    assert frame_kind("nope") is None


def test_stored_kind_reads_the_mark_and_defaults_to_the_app():
    assert stored_kind({"session_kind": "host"}) == KIND_HOST
    assert stored_kind({"access_token": "a"}) == KIND_APP
    assert stored_kind(None) is None


def test_a_live_host_session_is_never_replaced_by_an_app_token():
    for frame in (APP_FRAME, ACCESS_ONLY_FRAME):
        decision = decide(frame, current_kind=KIND_HOST, dead=False)
        assert decision.adopt is False
        assert decision.persist is False
        assert decision.kind == KIND_HOST


def test_a_dead_host_session_takes_what_the_app_sends_and_asks_for_more():
    decision = decide(ACCESS_ONLY_FRAME, current_kind=KIND_HOST, dead=True)
    assert decision.adopt and decision.want_host_session
    assert decision.kind == KIND_ACCESS_ONLY and decision.persist is False


def test_a_host_session_always_wins():
    for kind in (None, KIND_APP, KIND_HOST, KIND_ACCESS_ONLY):
        decision = decide(HOST_FRAME, current_kind=kind, dead=False)
        assert decision.adopt and decision.persist and decision.kind == KIND_HOST
        assert decision.want_host_session is False


def test_an_old_app_keeps_working_and_is_asked_for_a_host_session():
    decision = decide(APP_FRAME, current_kind=None, dead=False)
    assert decision.adopt and decision.persist and decision.kind == KIND_APP
    assert decision.want_host_session is True


# -- the relay transport ----------------------------------------------------


class FakeWebSocket:
    def __init__(self, inbound: list[dict] | None = None) -> None:
        self.sent: list[dict] = []
        self._inbound = list(inbound or [])

    def send(self, raw: str) -> None:
        self.sent.append(json.loads(raw))

    def recv(self, timeout: float | None = None) -> str:
        if not self._inbound:
            raise TimeoutError("no frame queued")
        return json.dumps(self._inbound.pop(0))

    def __iter__(self):
        while self._inbound:
            yield json.dumps(self._inbound.pop(0))

    def close(self) -> None:
        pass


def test_the_heal_channel_is_the_last_credential_tried():
    transport = CloudRelayTransport(
        device_id=str(uuid.uuid4()),
        token_provider=lambda: None,
        pairing_channel_provider=lambda: None,
        heal_channel_provider=lambda: "HEAL",
    )
    assert transport.credential() == ("heal_channel", "HEAL")
    transport = CloudRelayTransport(
        device_id=str(uuid.uuid4()),
        token_provider=lambda: "jwt",
        heal_channel_provider=lambda: "HEAL",
    )
    assert transport.credential() == ("token", "jwt")


def test_a_healing_host_parks_like_a_pairing_one_and_reaches_nobody():
    logs: list[str] = []
    expired: list[bool] = []
    ws = FakeWebSocket([{"type": "auth_ok", "mode": "pairing", "expires_in": 300}])
    device_id = str(uuid.uuid4())
    transport = CloudRelayTransport(
        device_id=device_id,
        channel_id=CHANNEL_ID,
        heal_channel_provider=lambda: "HEAL-CHANNEL",
        on_pairing_expired=lambda: expired.append(True),
        logger=logs.append,
        connect=lambda url, **_kw: ws,
    )
    link = transport.open()
    # The wire is the first-pairing door, unchanged: the relay needs no change.
    assert ws.sent == [
        {"type": "auth", "role": "executor", "device_id": device_id,
         "pairing_channel": "HEAL-CHANNEL"}
    ]
    assert link.claimed is False
    assert link.pending == [join_message(CHANNEL_ID, ROLE_EXECUTOR)]
    assert any("heal channel" in line for line in logs)
    assert not any("HEAL-CHANNEL" in line for line in logs)
    # No "scan the code" warning: there is no code.
    assert link._warning is None

    # The paired app claims it: the host is an ordinary executor again.
    link.handle_frame({"type": TYPE_PAIR_BOUND})
    assert link.claimed is True
    assert unwrap_payload(ws.sent[-1]) == join_message(CHANNEL_ID, ROLE_EXECUTOR)


def test_an_expired_heal_channel_is_parked_again_not_replaced():
    expired: list[bool] = []
    ws = FakeWebSocket([{"type": "auth_ok", "mode": "pairing", "expires_in": 300}])
    transport = CloudRelayTransport(
        device_id=str(uuid.uuid4()),
        channel_id=CHANNEL_ID,
        heal_channel_provider=lambda: "HEAL-CHANNEL",
        on_pairing_expired=lambda: expired.append(True),
        connect=lambda url, **_kw: ws,
    )
    link = transport.open()
    link.handle_frame({"type": TYPE_PAIR_EXPIRED})
    # The host would mint a new pairing code on this callback; a heal channel
    # is derived, so nothing is minted and the next dial parks on it again.
    assert expired == []


# -- the host ---------------------------------------------------------------


def _trust() -> HostTrust:
    return HostTrust(
        channel_id=CHANNEL_ID,
        channel_key=CHANNEL_KEY,
        peer_device_id="app-device",
        peer_public_key=Ed25519PrivateKey.generate().public_key(),
    )


class _Sealed:
    def __init__(self, raw: bytes) -> None:
        self._raw = raw

    def to_bytes(self) -> bytes:
        return self._raw


class _FakeSealer:
    def seal(self, plaintext: bytes) -> _Sealed:
        return _Sealed(plaintext)


class _FakeParty:
    def __init__(self, *, attached: bool) -> None:
        self.controller_attached = attached
        self.frames: list[dict] = []

    def send_result_frame(self, frame_b64: str) -> None:
        if self.controller_attached:
            self.frames.append(json.loads(base64.b64decode(frame_b64)))


def _gotrue(status: int, calls: list[str] | None = None) -> httpx.Client:
    def handler(request: httpx.Request) -> httpx.Response:
        if calls is not None:
            calls.append(request.url.path)
        if status != 200:
            return httpx.Response(status, json={"error": "invalid_grant"})
        return httpx.Response(
            200,
            json={
                "access_token": "fresh-access",
                "refresh_token": "fresh-refresh",
                "expires_in": 3600,
            },
        )

    return httpx.Client(transport=httpx.MockTransport(handler))


@pytest.fixture
def host(tmp_path):
    made: list[LocalHost] = []

    def build(*, paired: bool = True, stored: dict | None = None, attached: bool = False):
        h = LocalHost(
            port=0,
            workspace_dir=str(tmp_path),
            agent_name="t",
            channel_id=CHANNEL_ID,
            digits="428913",
            transport="cloud",
            model_factory_override=_scripted_model,
        )
        if stored is not None:
            h._persist_account_token(stored, kind=stored.get("session_kind") or KIND_APP)
            h._credential_kind = stored_kind(h._account.token())
        if paired:
            h._trust = _trust()
            h._burn_pairing_code()
        party = _FakeParty(attached=attached)
        h._party = party  # type: ignore[assignment]
        h._sealer = _FakeSealer()  # type: ignore[assignment]
        made.append(h)
        return h, party

    yield build
    for h in made:
        h._party = None
        h.stop()


def _expired(frame: dict) -> dict:
    return {**frame, "expires_at": time.time() - 60}


def _use_gotrue(h: LocalHost, status: int, calls: list[str] | None = None) -> SupabaseSession:
    session = h._account_session()
    assert session is not None
    session.http_client = _gotrue(status, calls)
    return session


def test_a_dead_refresh_token_parks_a_paired_host_on_its_heal_channel(host):
    """The owner's machine on 2026-09-23: expired access token, refused refresh."""
    h, _ = host(stored=_expired(APP_FRAME))
    _use_gotrue(h, 400)

    transport, _, _ = h._build_transport()
    assert transport.credential() == (
        "heal_channel",
        derive_heal_channel(CHANNEL_KEY, CHANNEL_ID),
    )
    assert h._credential_dead is True
    # The dead token is kept, not deleted: the paired app replaces it.
    assert h._account.token()["refresh_token"] == "app-refresh"


def test_a_network_fault_is_not_mistaken_for_a_dead_token(host):
    h, _ = host(stored=_expired(APP_FRAME))
    _use_gotrue(h, 503)
    transport, _, _ = h._build_transport()
    assert transport.credential() == ("token", "app-access")
    assert h._credential_dead is False


def test_an_unpaired_host_has_no_heal_channel(host):
    h, _ = host(paired=False, stored=_expired(APP_FRAME))
    _use_gotrue(h, 400)
    assert h._relay_access_token() == "app-access"
    assert h._current_heal_channel() is None


def test_a_paired_host_without_any_token_heals_too(host):
    h, _ = host(stored=None)
    transport, _, _ = h._build_transport()
    assert transport.credential()[0] == "heal_channel"


def test_a_refused_handshake_with_a_dead_refresh_token_redials_at_once(host):
    h, _ = host(stored=APP_FRAME)
    _use_gotrue(h, 400)
    assert h._refresh_rejected_token("app-access") is True
    assert h._credential_dead is True
    assert h._relay_access_token() is None


def test_a_refused_handshake_on_a_network_fault_keeps_the_backoff(host):
    h, _ = host(stored=APP_FRAME)
    _use_gotrue(h, 502)
    assert h._refresh_rejected_token("app-access") is False
    assert h._credential_dead is False


def test_a_dead_token_is_retried_rarely_and_recovers(host, monkeypatch):
    h, _ = host(stored=_expired(APP_FRAME))
    calls: list[str] = []
    session = _use_gotrue(h, 400, calls)
    assert h._relay_access_token() is None
    assert len(calls) == 1
    # Within the retry window nothing is spent on a token known to be dead.
    assert h._relay_access_token() is None
    assert len(calls) == 1
    # After it, one more try; this time GoTrue takes it.
    h._heal_retry_at = 0.0
    session.http_client = _gotrue(200, calls)
    assert h._relay_access_token() == "fresh-access"
    assert h._credential_dead is False
    assert h._current_heal_channel() is None


def test_a_dead_session_during_a_run_asks_the_attached_app(host):
    h, party = host(stored=APP_FRAME, attached=True)
    h._on_session_refresh_failed(SupabaseAuthError("gotrue refresh_token failed: 400", status=400))
    assert h._credential_dead is True
    assert party.frames == [{"type": TYPE_HOST_SESSION_REQUEST, "reason": "credential_dead"}]


def test_the_runtime_session_reports_a_refused_refresh(host):
    h, _ = host(stored=_expired(APP_FRAME))
    session = _use_gotrue(h, 400)
    with pytest.raises(SupabaseAuthError) as info:
        session.refresh(reason="token_expired")
    assert info.value.status == 400
    assert h._credential_dead is True


# -- provisioning -----------------------------------------------------------


def _live_session(h: LocalHost, frame: dict) -> SupabaseSession:
    session = SupabaseSession(
        access_token=frame["access_token"],
        refresh_token=frame.get("refresh_token", ""),
        supabase_url=frame["supabase_url"],
        anon_key=frame["anon_key"],
        expires_at=frame.get("expires_at"),
    )
    h._session = session
    h._wire_session(session)
    return session


def test_the_app_heals_the_host_with_a_session_of_its_own(host):
    h, party = host(stored=_expired(APP_FRAME), attached=False)
    _use_gotrue(h, 400)
    assert h._relay_access_token() is None  # dead, parked on the heal channel
    party.controller_attached = True  # the app claimed the heal channel

    # The app reached it through the heal channel and provisions: first its
    # access token (a new app never sends its refresh token any more) ...
    token, want = h._provision_token(ACCESS_ONLY_FRAME)
    assert want is True
    assert h._credential_kind == KIND_ACCESS_ONLY
    _live_session(h, token)
    h._ask_for_host_session("provisioned_without_own_session")
    assert party.frames[-1]["type"] == TYPE_HOST_SESSION_REQUEST

    # ... then the session it minted for the host.
    h._on_reprovision(dict(HOST_FRAME))
    assert h._credential_kind == KIND_HOST
    assert h._credential_dead is False
    stored = h._account.token()
    assert stored["refresh_token"] == "host-refresh"
    assert stored["session_kind"] == "host"
    assert h._relay_access_token() == "host-access"
    assert h._current_heal_channel() is None


def test_an_old_apps_pair_never_replaces_the_hosts_own_session(host):
    h, _ = host(stored=HOST_FRAME)
    session = _live_session(h, HOST_FRAME)
    h._on_reprovision(dict(APP_FRAME))
    h._on_reprovision(dict(ACCESS_ONLY_FRAME))
    assert session.access_token == "host-access"
    assert session.refresh_token == "host-refresh"
    stored = h._account.token()
    assert stored["refresh_token"] == "host-refresh"
    assert stored["session_kind"] == "host"


def test_a_build_with_a_live_host_session_uses_it_not_the_frame(host):
    h, _ = host(stored={k: v for k, v in HOST_FRAME.items() if k != "anon_key"})
    token, want = h._provision_token(APP_FRAME)
    assert want is False
    assert token["refresh_token"] == "host-refresh"
    # Filled from the frame when the stored set lacks it.
    assert token["anon_key"] == "anon"
    assert h._account.token()["refresh_token"] == "host-refresh"


def test_an_old_app_is_served_the_old_way_and_asked_for_a_host_session(host):
    h, party = host(stored=None, attached=True)
    token, want = h._provision_token(APP_FRAME)
    assert token is APP_FRAME and want is True
    assert h._credential_kind == KIND_APP
    assert h._account.token()["session_kind"] == "app"


def test_the_host_refreshes_its_own_session_even_with_the_app_attached(host):
    h, party = host(stored=HOST_FRAME, attached=True)
    session = _live_session(h, HOST_FRAME)
    session.http_client = _gotrue(200)
    session.refresh(reason="token_expired")
    assert session.access_token == "fresh-access"
    # Persisted for the next start, and NOT reported: nobody else holds it.
    stored = h._account.token()
    assert stored["refresh_token"] == "fresh-refresh"
    assert stored["session_kind"] == "host"
    assert all(f["type"] != "account_session_rotated" for f in party.frames)
    assert h._pending_session_rotation is None


def test_the_apps_session_is_still_not_spent_while_the_app_is_attached(host):
    h, _ = host(stored=APP_FRAME, attached=True)
    session = _live_session(h, APP_FRAME)
    assert session.may_self_refresh() is False
    h._party.controller_attached = False
    assert session.may_self_refresh() is True


def test_an_access_token_alone_is_never_refreshed_here(host):
    h, _ = host(stored=None, attached=False)
    h._provision_token(ACCESS_ONLY_FRAME)
    session = _live_session(h, ACCESS_ONLY_FRAME)
    assert session.may_self_refresh() is False


def test_an_expired_access_token_alone_sends_the_dial_to_the_heal_channel(host):
    h, _ = host(stored=None)
    h._provision_token(_expired(ACCESS_ONLY_FRAME))
    _live_session(h, _expired(ACCESS_ONLY_FRAME))
    assert h._relay_access_token() is None
    assert h._current_heal_channel() == derive_heal_channel(CHANNEL_KEY, CHANNEL_ID)


def test_host_session_requests_are_rate_limited(host):
    h, party = host(stored=None, attached=True)
    assert h._ask_for_host_session("a") is True
    assert h._ask_for_host_session("b") is False
    h._host_session_asked_at = time.monotonic() - 3600
    assert h._ask_for_host_session("c") is True
    assert [f["reason"] for f in party.frames] == ["a", "c"]


def test_no_request_goes_out_without_an_app(host):
    h, party = host(stored=None, attached=False)
    assert h._ask_for_host_session("a") is False
    # Not counted as asked, so the first attach still gets it.
    assert h._host_session_asked_at is None


def _jwt(claims: dict) -> str:
    body = base64.urlsafe_b64encode(json.dumps(claims).encode()).decode().rstrip("=")
    return f"h.{body}.s"


def test_a_replaced_host_session_is_signed_out(host, monkeypatch):
    h, _ = host(stored=None)
    started: list[str] = []

    class _Thread:
        def __init__(self, target, name, daemon):
            started.append(name)

        def start(self):
            pass

    import chuk_agents_host.host as host_module

    monkeypatch.setattr(host_module.threading, "Thread", _Thread)
    old = _jwt({"session_id": "s-old"})
    new_session = SupabaseSession(
        access_token=_jwt({"session_id": "s-new"}), refresh_token="r",
        supabase_url="https://db.example.test", anon_key="anon",
    )
    h._revoke_session_quietly(old, new_session)
    assert started == ["agents-host-revoke"]
    # The same session, or one we cannot identify, is left alone.
    h._revoke_session_quietly(_jwt({"session_id": "s-new"}), new_session)
    h._revoke_session_quietly("not-a-jwt", new_session)
    assert started == ["agents-host-revoke"]


def test_a_rebuild_takes_the_live_host_session_over_a_stale_file(host):
    h, _ = host(stored=HOST_FRAME)
    session = _live_session(h, HOST_FRAME)
    # The host rotated in memory, and the write to account.json failed.
    session.access_token, session.refresh_token = "rotated-access", "rotated-refresh"
    token, want = h._provision_token(APP_FRAME)
    assert want is False
    assert token["access_token"] == "rotated-access"
    assert token["refresh_token"] == "rotated-refresh"


def test_a_new_apps_ack_of_a_rotation_is_its_access_token(host):
    h, _ = host(stored=APP_FRAME)
    _live_session(h, APP_FRAME)
    h._pending_session_rotation = {
        "type": "account_session_rotated",
        "access_token": "rot-access",
        "refresh_token": "rot-refresh",
    }
    h._note_incoming_token({"access_token": "other"})
    assert h._pending_session_rotation is not None
    h._note_incoming_token({"access_token": "rot-access"})
    assert h._pending_session_rotation is None


def test_taking_a_host_session_drops_a_pending_rotation(host):
    h, _ = host(stored=APP_FRAME)
    _live_session(h, APP_FRAME)
    h._pending_session_rotation = {"access_token": "x", "refresh_token": "y"}
    h._on_reprovision(dict(HOST_FRAME))
    assert h._pending_session_rotation is None


def test_any_accepted_refresh_ends_the_dead_state(host):
    h, _ = host(stored=APP_FRAME)
    session = _live_session(h, APP_FRAME)
    h._credential_dead = True
    session.http_client = _gotrue(200)
    session.refresh(reason="token_expired")
    assert h._credential_dead is False
