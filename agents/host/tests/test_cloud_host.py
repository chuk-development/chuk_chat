"""The host on the cloud pipe: which credential it presents, what it prints, and
that §15 step 7's token survives to the next process start.

The pipe is swapped, nothing else is. So the tests that matter here are the ones
about the *boundary*: the party runs on a fake pipe with no relay at all, and a
real pairing over the loopback relay is asserted to leave behind exactly what a
later cloud handshake needs.
"""

from __future__ import annotations

import threading
import time

import pytest

from cowork_crypto import Pairing
from cowork_host import LocalHost
from cowork_host.account_store import AccountStore
from cowork_host.cloud_relay import CloudRelayError, CloudRelayTransport, RelayAuthRejected
from cowork_host.identity import HOST_DEVICE_ID, load_or_create_identity
from cowork_host.party import HostParty
from cowork_host.protocol import STEP_COMMIT, TYPE_JOIN

from test_local_run import ControllerDouble, _scripted_model

# A token shaped like the real ``account_authentication`` (docs/WIRE_CONTRACT.md):
# the whole set, because the refresh token is what keeps this host alive for
# months with the app closed.
ACCOUNT_TOKEN = {
    "type": "account_authentication",
    "access_token": "jwt-access-1",
    "refresh_token": "jwt-refresh-1",
    "user_id": "user-123",
    "supabase_url": "https://db.example.test",
    "anon_key": "anon-key",
    "expires_at": time.time() + 3600,
}


def _cloud_host(tmp_path, **kwargs) -> LocalHost:
    return LocalHost(
        port=0,
        workspace_dir=str(tmp_path),
        agent_name="cloud-worker",
        transport="cloud",
        model_factory_override=_scripted_model,
        **kwargs,
    )


# -- what the user sees ------------------------------------------------------


def test_a_cloud_host_points_at_the_relay_not_at_loopback(tmp_path):
    host = _cloud_host(tmp_path, channel_id="testchannel00", digits="428913")
    try:
        assert host.transport_kind == "cloud"
        assert host.url == "wss://api.chuk.chat/v2/relay/ws"
        assert host.pairing_code == "testchannel00-428913"
    finally:
        host.stop()


def test_the_pairing_uri_carries_the_channel_the_code_and_the_relay(tmp_path):
    host = _cloud_host(
        tmp_path,
        channel_id="testchannel00",
        digits="428913",
        relay_base_url="wss://relay.example.test",
    )
    try:
        channel = host.pairing_channel
        assert channel and len(channel) == 43  # 256 bits, url-safe, unpadded
        assert host.pairing_uri == (
            f"cowork://pair?c={channel}&k=testchannel00-428913"
            "&r=wss%3A%2F%2Frelay.example.test"
        )
    finally:
        host.stop()


def test_a_paired_host_offers_no_uri_because_it_offers_no_code(tmp_path):
    """Nothing to scan once the code is gone: the only way back in is the signed
    reconnect handshake."""
    host = _cloud_host(tmp_path, channel_id="testchannel00", digits="428913")
    try:
        assert host.pairing_uri is not None
        host._burn_pairing_code()
        assert host.pairing_channel is None
        assert host.pairing_uri is None
    finally:
        host.stop()


# -- which credential the handshake carries ----------------------------------


def test_an_unprovisioned_host_bootstraps_with_the_pairing_channel(tmp_path):
    host = _cloud_host(tmp_path, channel_id="testchannel00", digits="428913")
    try:
        transport, controller_token, reconnect = host._build_transport()
        assert isinstance(transport, CloudRelayTransport)
        # The cloud relay reports no peers to an executor, and a dropped pipe
        # must come back on its own.
        assert controller_token is None
        assert reconnect is True
        assert transport.credential() == ("pairing_channel", host.pairing_channel)
        # The routing id is the relay's uuid4, never the crypto device id.
        assert transport.device_id != HOST_DEVICE_ID
    finally:
        host.stop()


def test_a_stored_token_replaces_the_pairing_channel_for_good(tmp_path):
    host = _cloud_host(tmp_path, channel_id="testchannel00", digits="428913")
    try:
        host._persist_account_token(ACCOUNT_TOKEN)
        transport, _, _ = host._build_transport()
        assert transport.credential() == ("token", "jwt-access-1")
    finally:
        host.stop()


class _StubSession:
    """Stands in for the provisioned :class:`SupabaseSession`: the host must ask
    it for a token rather than reach for the file, and must let it refresh."""

    def __init__(self, *, expired: bool) -> None:
        self.access_token = "stale-jwt"
        self._expired = expired
        self.refreshed: list[str] = []

    def is_expired(self, **_kwargs) -> bool:
        return self._expired

    def refresh(self, *, reason: str = "token_expired", **_kwargs) -> None:
        self.refreshed.append(reason)
        self._expired = False
        self.access_token = "fresh-jwt"


def test_an_expired_token_is_refreshed_before_the_handshake(tmp_path):
    """A token that died while the host sat disconnected must lead to a refresh,
    not to a socket the relay closes with 1008."""
    host = _cloud_host(tmp_path, channel_id="testchannel00", digits="428913")
    try:
        session = _StubSession(expired=True)
        host._session = session
        assert host._relay_access_token() == "fresh-jwt"
        assert session.refreshed == ["token_expired"]
    finally:
        host.stop()


def test_a_live_token_is_not_spent_on_a_needless_refresh(tmp_path):
    host = _cloud_host(tmp_path, channel_id="testchannel00", digits="428913")
    try:
        session = _StubSession(expired=False)
        host._session = session
        assert host._relay_access_token() == "stale-jwt"
        assert session.refreshed == []
    finally:
        host.stop()


def test_a_failed_refresh_still_offers_the_old_token(tmp_path):
    """Better a handshake the relay refuses (and a redial) than a host that never
    dials at all."""

    class _Failing(_StubSession):
        def refresh(self, **_kwargs):
            raise RuntimeError("gotrue is down")

    host = _cloud_host(tmp_path, channel_id="testchannel00", digits="428913")
    try:
        host._session = _Failing(expired=True)
        assert host._relay_access_token() == "stale-jwt"
    finally:
        host.stop()


# -- the token survives the process ------------------------------------------


def test_pairing_persists_the_account_token_and_the_next_start_reuses_it(tmp_path):
    """§15 step 7 end to end: a real pairing over the loopback relay, then a cloud
    host on the same workspace that authenticates with what it was given."""
    host = LocalHost(
        port=0,
        workspace_dir=str(tmp_path),
        agent_name="test-worker",
        channel_id="testchannel00",
        digits="428913",
        model_factory_override=_scripted_model,
    )
    host.start()
    try:
        controller = ControllerDouble(
            host.url, host.channel_id, host.pairing_code, replay_key="thread-1"
        )
        controller.run("unused: this double asks for a replay, not a run")
        assert host.has_stored_pairing, "the pairing never completed"
    finally:
        host.stop()

    stored = AccountStore(tmp_path / "account.json").token()
    assert stored is not None, "the account token was not persisted"
    assert stored["access_token"] == "mock-access"
    assert stored["refresh_token"] == "mock-refresh"
    assert (tmp_path / "account.json").stat().st_mode & 0o777 == 0o600

    # The next process start: no code, no pairing channel — the ordinary
    # authenticated handshake, with the token the app provisioned.
    again = _cloud_host(
        tmp_path,
        supabase_url="https://db.example.test",
        anon_key="anon-key",
    )
    try:
        assert again.pairing_code is None
        assert again.pairing_channel is None
        transport, _, _ = again._build_transport()
        assert transport.credential() == ("token", "mock-access")
    finally:
        again.stop()


def test_repairing_reopens_the_bootstrap_path_exactly_once_more(tmp_path):
    """``--pair`` may hand this host to a different account, and the relay only
    routes within one. The old token must not survive that."""
    host = _cloud_host(tmp_path, channel_id="testchannel00", digits="428913")
    try:
        host._persist_account_token(ACCOUNT_TOKEN)
    finally:
        host.stop()

    repaired = _cloud_host(tmp_path, force_repair=True)
    try:
        assert AccountStore(tmp_path / "account.json").token() is None
        transport, _, _ = repaired._build_transport()
        kind, value = transport.credential()
        assert kind == "pairing_channel"
        assert value == repaired.pairing_channel
    finally:
        repaired.stop()


def test_a_host_with_neither_credential_says_so(tmp_path):
    host = _cloud_host(tmp_path, channel_id="testchannel00", digits="428913")
    try:
        host._burn_pairing_code()  # code used, and nothing was ever provisioned
        transport, _, _ = host._build_transport()
        with pytest.raises(CloudRelayError):
            transport.credential()
    finally:
        host.stop()


# -- an expired pairing channel ----------------------------------------------


def test_an_expired_code_is_replaced_by_a_fresh_one(tmp_path):
    """A user who walked away comes back to a new code, not a dead terminal."""
    printed: list[str] = []
    host = _cloud_host(tmp_path, channel_id="testchannel00", digits="428913")
    host.set_pairing_reset_listener(lambda: printed.append(host.pairing_uri))
    try:
        first_code = host.pairing_code
        first_channel = host.pairing_channel
        host._on_pairing_channel_expired()

        assert host.pairing_code != first_code
        assert host.pairing_channel != first_channel
        # Same host, same crypto channel: only the code's digits and the bearer
        # capability are new.
        assert host.pairing_code.startswith("testchannel00-")
        assert printed == [host.pairing_uri]
        # And the next dial carries the fresh channel, never the dead one.
        transport, _, _ = host._build_transport()
        assert transport.credential() == ("pairing_channel", host.pairing_channel)
    finally:
        host.stop()


def test_a_paired_host_mints_no_code_when_a_channel_expires(tmp_path):
    """Nothing to replace: the trust record is the way in now."""
    host = _cloud_host(tmp_path, channel_id="testchannel00", digits="428913")
    try:
        host._persist_account_token(ACCOUNT_TOKEN)
        host._trust = object()  # stands in for a stored pairing
        host._burn_pairing_code()
        host._on_pairing_channel_expired()
        assert host.pairing_code is None
        assert host.pairing_channel is None
    finally:
        host._trust = None
        host.stop()


# -- the seam itself ---------------------------------------------------------


class _FakeLink:
    """A pipe with no relay behind it at all."""

    def __init__(self) -> None:
        self.sent: list[dict] = []
        self.closed = False
        self._open = threading.Event()

    def send(self, message: dict) -> None:
        self.sent.append(message)

    def messages(self):
        # Stay open until closed, yielding nothing: this test is about what the
        # party *sends* when a controller shows up.
        self._open.wait(5.0)
        return iter(())

    def close(self) -> None:
        self.closed = True
        self._open.set()


class _FakeTransport:
    def __init__(self, link: _FakeLink) -> None:
        self.link = link
        self.opens = 0

    def open(self):
        self.opens += 1
        return self.link


def test_the_party_publishes_its_commit_on_whatever_pipe_it_is_given(tmp_path):
    """The ceremony does not know what it is talking through. That is the seam."""
    identity = load_or_create_identity(tmp_path / "host_device.key")
    link = _FakeLink()
    party = HostParty(
        transport=_FakeTransport(link),
        channel_id="testchannel00",
        pairing_factory=lambda: Pairing.initiator(
            device_id=HOST_DEVICE_ID,
            device_identity=identity,
            channel_id="testchannel00",
            digits="428913",
        ),
        device_id=HOST_DEVICE_ID,
        device_identity=identity,
        key_version=1,
        build_task_server=lambda *_args: None,
    )
    party.start()
    try:
        deadline = time.monotonic() + 5.0
        party.on_controller_joined(1)
        while time.monotonic() < deadline and not link.sent:
            time.sleep(0.01)
        assert link.sent, "the party sent nothing on the pipe it was handed"
        commit = link.sent[-1]
        assert commit["type"] == "pairing"
        assert commit["step"] == STEP_COMMIT
        assert commit["data"]["type"] == "commit"
        # The fake pipe has no hello of its own; the loopback relay's ``join`` is
        # the transport's business now, not the party's.
        assert all(message.get("type") != TYPE_JOIN for message in link.sent)
    finally:
        party.stop()


# -- a refused credential is replaced, not repeated ---------------------------


class _RejectingTransport:
    """Refuses the first dial the way the relay refuses a dead JWT, then opens."""

    def __init__(self, link, *, refusals: int = 1) -> None:
        self.link = link
        self.tokens_offered: list[str] = []
        self._refusals = refusals
        self.token = "stale-jwt"

    def open(self):
        self.tokens_offered.append(self.token)
        if self._refusals > 0:
            self._refusals -= 1
            raise RelayAuthRejected("Invalid token", token=self.token)
        return self.link


def test_a_refused_token_is_refreshed_and_redialled_without_backoff(tmp_path):
    """The relay said no to this exact token. Sleeping through a backoff and then
    offering the same one again is how a host sits offline for a day
    (bead cowork-fm8w): refresh it, dial again at once."""
    identity = load_or_create_identity(tmp_path / "host_device.key")
    link = _FakeLink()
    transport = _RejectingTransport(link)
    logged: list[str] = []

    def refreshed(token: str) -> bool:
        assert token == "stale-jwt"
        transport.token = "fresh-jwt"
        return True

    party = HostParty(
        transport=transport,
        channel_id="testchannel00",
        pairing_factory=lambda: Pairing.initiator(
            device_id=HOST_DEVICE_ID,
            device_identity=identity,
            channel_id="testchannel00",
            digits="428913",
        ),
        device_id=HOST_DEVICE_ID,
        device_identity=identity,
        key_version=1,
        build_task_server=lambda *_args: None,
        logger=logged.append,
        reconnect=True,
        # A backoff long enough that a test which waits it out would fail.
        backoff_seconds=(30.0,),
        on_auth_rejected=refreshed,
    )
    party.start()
    try:
        deadline = time.monotonic() + 5.0
        while time.monotonic() < deadline and len(transport.tokens_offered) < 2:
            time.sleep(0.01)
        assert transport.tokens_offered[:2] == ["stale-jwt", "fresh-jwt"]
        assert any("credential refreshed" in line for line in logged)
    finally:
        party.stop()


def test_a_refusal_nobody_can_fix_keeps_the_ordinary_backoff(tmp_path):
    """No fresh token means no new attempt to make: hammering the relay every
    few milliseconds would only get this host rate-limited."""
    identity = load_or_create_identity(tmp_path / "host_device.key")
    transport = _RejectingTransport(_FakeLink(), refusals=99)
    logged: list[str] = []

    party = HostParty(
        transport=transport,
        channel_id="testchannel00",
        pairing_factory=lambda: Pairing.initiator(
            device_id=HOST_DEVICE_ID,
            device_identity=identity,
            channel_id="testchannel00",
            digits="428913",
        ),
        device_id=HOST_DEVICE_ID,
        device_identity=identity,
        key_version=1,
        build_task_server=lambda *_args: None,
        logger=logged.append,
        reconnect=True,
        backoff_seconds=(30.0,),
        on_auth_rejected=lambda _token: False,
    )
    party.start()
    try:
        time.sleep(0.3)
        assert len(transport.tokens_offered) == 1
        assert any("redialling in 30s" in line for line in logged)
    finally:
        party.stop()
