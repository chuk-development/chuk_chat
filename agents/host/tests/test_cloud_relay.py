"""The cloud pipe: the handshake it sends, the payload it wraps, the credential
it picks, and the QR the phone scans.

No socket and no network: a fake websocket stands in for the relay, exactly as
the party's own tests stand in for the app. What is asserted here is the wire —
the frames this host puts on it and the ones it takes off it — because that wire
is the contract with ``api_server``'s ``/v2/relay/ws``.
"""

from __future__ import annotations

import base64
import json
import uuid

import pytest

from cowork_host.account_store import AccountStore
from cowork_host.cloud_relay import (
    CODE_CONTROLLER_OFFLINE,
    DEFAULT_RELAY_BASE_URL,
    CloudRelayError,
    CloudRelayLink,
    CloudRelayTransport,
    auth_frame,
    new_pairing_channel,
    relay_ws_url,
    unwrap_payload,
    wrap_payload,
)
from cowork_host.pairing_uri import pairing_uri, qr_lines
from cowork_host.protocol import (
    ROLE_CONTROLLER,
    ROLE_EXECUTOR,
    frame_envelope,
    join_message,
    pairing_envelope,
)
from cowork_host.relay import EVENT_JOIN, EVENT_LEAVE


class FakeWebSocket:
    """A relay socket double: records what was sent, replays what to receive."""

    def __init__(self, inbound: list[dict] | None = None) -> None:
        self.sent: list[dict] = []
        self._inbound = list(inbound or [])
        self.closed = False

    # -- what the transport calls --
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
        self.closed = True


def _connector(ws: FakeWebSocket):
    def connect(url: str, **_kwargs):
        connect.url = url
        return ws

    connect.url = None
    return connect


# -- the URL and the credential ---------------------------------------------


def test_relay_url_is_the_documented_endpoint():
    assert relay_ws_url(DEFAULT_RELAY_BASE_URL) == "wss://api.chuk.chat/v2/relay/ws"
    # A base copied out of a browser still works, and a trailing slash is fine.
    assert relay_ws_url("https://api.chuk.chat/") == "wss://api.chuk.chat/v2/relay/ws"
    assert relay_ws_url("http://127.0.0.1:8000") == "ws://127.0.0.1:8000/v2/relay/ws"
    # An already-complete endpoint is not doubled up.
    assert (
        relay_ws_url("wss://api.chuk.chat/v2/relay/ws")
        == "wss://api.chuk.chat/v2/relay/ws"
    )


def test_a_pairing_channel_is_256_bits_of_csprng_and_url_safe():
    channel = new_pairing_channel()
    raw = base64.urlsafe_b64decode(channel + "=" * (-len(channel) % 4))
    assert len(raw) == 32  # 256 bits
    assert set(channel) <= set(
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
    )
    # Two mints never collide (and never repeat a constant).
    assert len({new_pairing_channel() for _ in range(50)}) == 50


def test_the_handshake_carries_one_credential_and_never_both():
    device_id = str(uuid.uuid4())
    bootstrap = auth_frame(device_id=device_id, pairing_channel="chan")
    assert bootstrap == {
        "type": "auth",
        "role": ROLE_EXECUTOR,
        "device_id": device_id,
        "pairing_channel": "chan",
    }
    authed = auth_frame(device_id=device_id, token="jwt", pairing_channel="chan")
    assert authed == {
        "type": "auth",
        "role": ROLE_EXECUTOR,
        "device_id": device_id,
        "token": "jwt",
    }
    with pytest.raises(CloudRelayError):
        auth_frame(device_id=device_id)


def test_a_stored_token_beats_the_pairing_channel():
    """The unauthenticated path runs once per host, ever."""
    transport = CloudRelayTransport(
        device_id=str(uuid.uuid4()),
        token_provider=lambda: "jwt",
        pairing_channel_provider=lambda: "chan",
    )
    assert transport.credential() == ("token", "jwt")

    bootstrap = CloudRelayTransport(
        device_id=str(uuid.uuid4()),
        token_provider=lambda: None,
        pairing_channel_provider=lambda: "chan",
    )
    assert bootstrap.credential() == ("pairing_channel", "chan")

    with pytest.raises(CloudRelayError):
        CloudRelayTransport(device_id=str(uuid.uuid4())).credential()


# -- opening the pipe --------------------------------------------------------


def test_open_sends_the_bootstrap_handshake_then_the_executor_join():
    ws = FakeWebSocket([{"type": "auth_ok"}])
    connect = _connector(ws)
    device_id = str(uuid.uuid4())
    transport = CloudRelayTransport(
        device_id=device_id,
        channel_id="chan-1",
        pairing_channel_provider=lambda: "PAIRING-CHANNEL",
        connect=connect,
    )
    transport.open()

    assert connect.url == "wss://api.chuk.chat/v2/relay/ws"
    handshake, hello = ws.sent
    assert handshake == {
        "type": "auth",
        "role": "executor",
        "device_id": device_id,
        "pairing_channel": "PAIRING-CHANNEL",
    }
    # The hello is the same message the loopback relay gets, inside a payload.
    assert hello["type"] == "cowork_relay"
    assert unwrap_payload(hello) == join_message("chan-1", ROLE_EXECUTOR)


def test_open_uses_the_account_token_once_one_is_stored():
    ws = FakeWebSocket([{"type": "auth_ok"}])
    device_id = str(uuid.uuid4())
    transport = CloudRelayTransport(
        device_id=device_id,
        channel_id="chan-1",
        token_provider=lambda: "supabase.jwt",
        pairing_channel_provider=lambda: "PAIRING-CHANNEL",
        connect=_connector(ws),
    )
    transport.open()
    assert ws.sent[0] == {
        "type": "auth",
        "role": "executor",
        "device_id": device_id,
        "token": "supabase.jwt",
    }
    assert "pairing_channel" not in ws.sent[0]


def test_a_refused_handshake_raises_and_closes():
    ws = FakeWebSocket([{"type": "auth_error", "detail": "Invalid token"}])
    transport = CloudRelayTransport(
        device_id=str(uuid.uuid4()),
        token_provider=lambda: "stale",
        connect=_connector(ws),
    )
    with pytest.raises(CloudRelayError) as excinfo:
        transport.open()
    assert "Invalid token" in str(excinfo.value)
    assert ws.closed


def test_the_credential_never_reaches_the_log():
    logged: list[str] = []
    ws = FakeWebSocket([{"type": "auth_ok"}])
    transport = CloudRelayTransport(
        device_id=str(uuid.uuid4()),
        channel_id="chan-1",
        pairing_channel_provider=lambda: "SECRET-CHANNEL",
        token_provider=lambda: None,
        logger=logged.append,
        connect=_connector(ws),
    )
    transport.open()
    assert logged  # it does say what it is doing
    assert not any("SECRET-CHANNEL" in line for line in logged)


# -- payload wrap / unwrap ---------------------------------------------------


@pytest.mark.parametrize(
    "message",
    [
        join_message("chan-1", ROLE_EXECUTOR),
        pairing_envelope("commit", {"type": "commit", "commitment": "abc"}),
        frame_envelope("c2VhbGVk"),
    ],
)
def test_payload_round_trip_is_byte_identical(message):
    """The payload is exactly what the loopback relay would have carried."""
    frame = wrap_payload(message)
    assert frame["type"] == "cowork_relay"
    assert frame["payload"] == json.dumps(message, separators=(",", ":"))
    assert unwrap_payload(frame) == message


def test_every_frame_carries_its_own_req_id_and_no_target():
    first = wrap_payload({"type": "frame", "frame": "a"})
    second = wrap_payload({"type": "frame", "frame": "b"})
    assert first["req_id"] != second["req_id"]
    # An executor's replies fan out to its own controllers; it addresses nobody.
    assert "target_device_id" not in first


def test_an_object_payload_is_accepted_too():
    """The relay is blind either way; being lenient on receive costs nothing."""
    assert unwrap_payload({"payload": {"type": "frame", "frame": "x"}}) == {
        "type": "frame",
        "frame": "x",
    }
    assert unwrap_payload({"payload": "not json"}) is None
    assert unwrap_payload({}) is None


# -- the link's routing ------------------------------------------------------


def _link(**kwargs) -> tuple[CloudRelayLink, FakeWebSocket]:
    ws = FakeWebSocket()
    return CloudRelayLink(ws, **kwargs), ws


def test_a_relay_frame_yields_exactly_its_party_message():
    link, _ = _link()
    message = pairing_envelope("commit", {"type": "commit"})
    assert link.handle_frame(wrap_payload(message)) == [message]


def test_relay_control_frames_are_not_party_messages():
    link, ws = _link()
    assert link.handle_frame({"type": "auth_ok"}) == []
    assert link.handle_frame({"type": "executor_status", "device_id": "x", "online": True}) == []
    assert link.handle_frame({"type": "ping"}) == []
    assert ws.sent == [{"type": "pong"}]


def test_the_apps_join_payload_is_the_controller_join_event():
    events: list[tuple[str, int]] = []
    link, _ = _link(on_controller_event=lambda event, token: events.append((event, token)))

    out = link.handle_frame(wrap_payload(join_message("chan-1", ROLE_CONTROLLER)))
    assert out == []  # the join is presence, not a party message
    assert events == [(EVENT_JOIN, 1)]
    assert link.controller_token == 1

    # controller_offline is the relay's only honest "the app is gone".
    link.handle_frame({"type": "cowork_error", "code": CODE_CONTROLLER_OFFLINE})
    assert events[-1] == (EVENT_LEAVE, 1)
    assert link.controller_token is None

    # A fresh controller gets a fresh token, so a reconnect is never confused
    # for the session it replaced.
    link.handle_frame(wrap_payload(join_message("chan-1", ROLE_CONTROLLER)))
    assert events[-1] == (EVENT_JOIN, 2)


def test_traffic_from_an_unannounced_controller_still_counts_as_attached():
    events: list[tuple[str, int]] = []
    link, _ = _link(on_controller_event=lambda event, token: events.append((event, token)))
    message = pairing_envelope("pubkey", {"type": "pubkey"})
    assert link.handle_frame(wrap_payload(message)) == [message]
    assert events == [(EVENT_JOIN, 1)]
    # ... and only once.
    link.handle_frame(wrap_payload(message))
    assert events == [(EVENT_JOIN, 1)]


def test_a_refused_frame_is_reported_not_swallowed():
    logged: list[str] = []
    link, _ = _link(logger=logged.append)
    link.handle_frame({"type": "cowork_error", "code": "payload_too_large", "req_id": "r1"})
    assert any("payload_too_large" in line for line in logged)


def test_messages_pumps_frames_off_the_socket():
    message = frame_envelope("c2VhbGVk")
    ws = FakeWebSocket([{"type": "auth_ok"}, wrap_payload(message), {"type": "ping"}])
    link = CloudRelayLink(ws)
    assert list(link.messages()) == [message]


# -- the account store -------------------------------------------------------


def test_the_relay_device_id_is_a_stable_uuid4(tmp_path):
    store = AccountStore(tmp_path / "account.json")
    device_id = store.device_id()
    assert uuid.UUID(device_id).version == 4
    # Stable across processes: the relay keys an executor by it.
    assert AccountStore(tmp_path / "account.json").device_id() == device_id
    assert (tmp_path / "account.json").stat().st_mode & 0o777 == 0o600


def test_the_token_is_persisted_whole_and_read_back(tmp_path):
    store = AccountStore(tmp_path / "account.json")
    assert store.token() is None
    assert store.access_token() is None

    assert store.save_token(
        {
            "type": "account_authentication",
            "access_token": "jwt-1",
            "refresh_token": "refresh-1",
            "user_id": "user-1",
            "supabase_url": "https://db.example",
            "anon_key": "anon",
            "expires_at": 1234.0,
            "unexpected": "dropped",
        }
    )
    reread = AccountStore(tmp_path / "account.json")
    assert reread.access_token() == "jwt-1"
    assert reread.token() == {
        "access_token": "jwt-1",
        "refresh_token": "refresh-1",
        "user_id": "user-1",
        "supabase_url": "https://db.example",
        "anon_key": "anon",
        "expires_at": 1234.0,
    }
    assert (tmp_path / "account.json").stat().st_mode & 0o777 == 0o600


def test_a_rotation_merges_and_never_loses_the_refresh_route(tmp_path):
    """``account_session_rotated`` carries the pair but not the project URL —
    losing that would leave the next process start unable to refresh at all."""
    store = AccountStore(tmp_path / "account.json")
    store.save_token(
        {
            "access_token": "jwt-1",
            "refresh_token": "refresh-1",
            "supabase_url": "https://db.example",
            "anon_key": "anon",
        }
    )
    store.save_token(
        {
            "type": "account_session_rotated",
            "access_token": "jwt-2",
            "refresh_token": "refresh-2",
            "expires_at": 99.0,
        }
    )
    assert AccountStore(tmp_path / "account.json").token() == {
        "access_token": "jwt-2",
        "refresh_token": "refresh-2",
        "supabase_url": "https://db.example",
        "anon_key": "anon",
        "expires_at": 99.0,
    }


def test_half_a_token_is_no_token(tmp_path):
    store = AccountStore(tmp_path / "account.json")
    assert not store.save_token({"access_token": "jwt-only"})
    assert store.token() is None
    assert not store.has_token


def test_clearing_the_token_keeps_the_device_id(tmp_path):
    store = AccountStore(tmp_path / "account.json")
    device_id = store.device_id()
    store.save_token({"access_token": "a", "refresh_token": "b"})
    assert store.clear_token()
    assert store.token() is None
    assert store.device_id() == device_id


# -- the pairing URI and its QR ---------------------------------------------


def test_the_pairing_uri_is_the_documented_one_liner():
    assert (
        pairing_uri(
            pairing_channel="CHAN-256",
            code="a1b2c3d4e5f6a7b8-481516",
            relay_base_url="wss://api.chuk.chat",
        )
        == "cowork://pair?c=CHAN-256&k=a1b2c3d4e5f6a7b8-481516&r=wss%3A%2F%2Fapi.chuk.chat"
    )


def test_the_uri_carries_a_self_hosted_relay():
    uri = pairing_uri(
        pairing_channel="c", code="k", relay_base_url="wss://relay.example.test"
    )
    assert uri.endswith("&r=wss%3A%2F%2Frelay.example.test")


def test_the_qr_encodes_the_uri_and_fits_a_terminal():
    uri = pairing_uri(
        pairing_channel=new_pairing_channel(),
        code="a1b2c3d4e5f6a7b8-481516",
        relay_base_url=DEFAULT_RELAY_BASE_URL,
    )
    lines = qr_lines(uri)
    assert lines, "the QR must render; the code alone is the fallback, not the plan"
    # Square-ish (two module rows per text row) and narrow enough for a terminal.
    assert max(len(line) for line in lines) <= 80
    assert len(lines) <= 45
    # ``qrcode`` pads with a non-breaking space so no terminal collapses a run
    # of light modules and breaks the scan.
    assert all(set(line) <= {" ", "\xa0", "▀", "▄", "█"} for line in lines)
