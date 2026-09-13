"""Account session sync between host and app (bead cowork-c91).

Supabase rotates the refresh token on every use, and host and app held the same
pair — so whichever side refreshed killed the other's token, and a host task
died with SupabaseAuthError. The host now (a) asks the attached app to
re-provision instead of refreshing itself (``reprovision_request``), (b) wakes a
waiting refresh when the app's ``account_authentication`` lands, and (c) when it
had to refresh on its own (nobody attached) reports the rotated pair back
(``account_session_rotated``), pending until the app sends it back. No relay,
no network: the party and the sealer are fakes.
"""

from __future__ import annotations

import base64
import json

from chuk_agents_runtime import SupabaseSession

from chuk_agents_host.host import LocalHost


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
        if not self.controller_attached:
            return  # the real party drops frames while detached
        self.frames.append(json.loads(base64.b64decode(frame_b64)))


def _host(tmp_path, *, attached: bool) -> tuple[LocalHost, _FakeParty]:
    host = LocalHost(
        port=0,
        workspace_dir=str(tmp_path),
        agent_name="t",
        channel_id="testchannel00",
        digits="428913",
        model_factory_override=lambda: None,
    )
    party = _FakeParty(attached=attached)
    host._party = party  # type: ignore[assignment]
    host._sealer = _FakeSealer()  # type: ignore[assignment]
    host._session = SupabaseSession(
        access_token="a1",
        refresh_token="rt-1",
        supabase_url="https://proj.supabase.co",
        anon_key="anon",
    )
    return host, party


def test_a_refresh_with_the_app_attached_asks_it_to_reprovision(tmp_path):
    host, party = _host(tmp_path, attached=True)
    host._request_reprovision("token_expired")
    assert party.frames == [{"type": "reprovision_request", "reason": "token_expired"}]


def test_the_apps_token_frame_wakes_a_waiting_refresh_and_updates_the_pair(tmp_path):
    host, _party = _host(tmp_path, attached=True)
    session = host._session
    before = session.generation

    host._on_reprovision(
        {"type": "account_authentication", "access_token": "a2", "refresh_token": "rt-2"}
    )

    assert session.access_token == "a2" and session.refresh_token == "rt-2"
    assert session.generation == before + 1  # the waiter in refresh() wakes


def test_a_host_side_rotation_is_reported_when_attached_and_pending_when_not(tmp_path):
    host, party = _host(tmp_path, attached=False)
    session = host._session
    session.access_token, session.refresh_token = "a-host", "rt-host"

    host._on_session_self_refreshed(session)

    assert party.frames == []  # nobody to tell yet
    assert host._pending_session_rotation["refresh_token"] == "rt-host"

    party.controller_attached = True
    host._flush_pending_session_rotation()  # the next connect
    assert len(party.frames) == 1
    frame = party.frames[0]
    assert frame["type"] == "account_session_rotated"
    assert frame["access_token"] == "a-host" and frame["refresh_token"] == "rt-host"
    assert "rotated_at" in frame

    # Not acked yet: another connect sends it again.
    host._flush_pending_session_rotation()
    assert len(party.frames) == 2


def test_the_app_acks_a_rotation_by_sending_the_pair_back(tmp_path):
    host, party = _host(tmp_path, attached=True)
    session = host._session
    session.access_token, session.refresh_token = "a-host", "rt-host"
    host._on_session_self_refreshed(session)
    assert host._pending_session_rotation is not None

    # A frame with a DIFFERENT refresh token is not the ack (an old client).
    host._on_reprovision({"type": "account_authentication", "refresh_token": "rt-stale"})
    assert host._pending_session_rotation is not None

    # The adopted pair coming back is.
    host._on_reprovision(
        {"type": "account_authentication", "access_token": "a-host", "refresh_token": "rt-host"}
    )
    assert host._pending_session_rotation is None
    host._flush_pending_session_rotation()
    assert sum(1 for f in party.frames if f["type"] == "account_session_rotated") == 1


def test_host_frames_are_dropped_not_raised_without_a_controller(tmp_path):
    host, party = _host(tmp_path, attached=False)
    assert host._send_host_payload({"type": "reprovision_request", "reason": "x"}) is False
    assert party.frames == []
