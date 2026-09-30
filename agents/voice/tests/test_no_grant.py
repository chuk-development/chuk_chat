"""A job without voice_grant sends one text line and leaves; no pipeline."""

from __future__ import annotations

import asyncio
import json

import pytest

import agent
import call_config


class FakeLocalParticipant:
    def __init__(self) -> None:
        self.sent: list[tuple[str, str, dict]] = []

    async def send_text(self, text: str, *, topic: str = "", attributes: dict | None = None, **_: object):
        self.sent.append((text, topic, dict(attributes or {})))


class FakeRoom:
    name = "room-test"

    def __init__(self) -> None:
        self.local_participant = FakeLocalParticipant()


class FakeJob:
    def __init__(self, metadata: str) -> None:
        self.metadata = metadata


class FakeCtx:
    def __init__(self, metadata: dict) -> None:
        self.job = FakeJob(json.dumps(metadata))
        self.room = FakeRoom()
        self.connected = False
        self.shutdown_reason: str | None = None

    async def connect(self) -> None:
        self.connected = True

    async def wait_for_participant(self, identity=None):
        return object()

    def shutdown(self, reason: str = "") -> None:
        self.shutdown_reason = reason


@pytest.fixture(autouse=True)
def _no_sleep(monkeypatch):
    real_sleep = asyncio.sleep

    async def fast_sleep(delay, *a, **k):
        await real_sleep(0)

    monkeypatch.setattr(agent.asyncio, "sleep", fast_sleep)


def _boom(*_a, **_k):
    raise AssertionError("the pipeline must not start without a voice grant")


def test_job_without_grant_says_one_line_and_leaves(monkeypatch) -> None:
    for name in ("AgentSession", "VisionAgent", "_build_llm", "_build_stt", "_build_tts"):
        monkeypatch.setattr(agent, name, _boom)
    monkeypatch.setattr(agent.chuk_proxy, "make_client", _boom)

    ctx = FakeCtx({"user_id": "u1", "mode": "chat", "stt_language": "en"})
    asyncio.run(agent.chuk_voice(ctx))

    assert ctx.connected
    assert ctx.shutdown_reason == "no voice grant"
    [(text, topic, attrs)] = ctx.room.local_participant.sent
    assert text == "Voice is not set up for this account."
    assert topic == "lk.transcription"
    assert attrs["lk.transcription_final"] == "true"
    assert attrs["lk.segment_id"].startswith("SG_")


def test_no_grant_line_is_german_for_german_users() -> None:
    cfg = call_config.parse_metadata(json.dumps({"stt_language": "de-DE"}))
    assert call_config.no_grant_text(cfg) == "Sprachanrufe sind für dieses Konto nicht eingerichtet."


def test_grant_is_parsed_and_kept_out_of_repr() -> None:
    cfg = call_config.parse_metadata(json.dumps({"voice_grant": "  secret-grant  "}))
    assert cfg.voice_grant == "secret-grant"
    assert "secret-grant" not in repr(cfg)
    assert call_config.parse_metadata(json.dumps({"voice_grant": ""})).voice_grant is None
    assert call_config.parse_metadata(None).voice_grant is None
