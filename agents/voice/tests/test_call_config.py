"""Dispatch metadata parsing, system prompt and greeting (no LiveKit needed)."""

from __future__ import annotations

import json

import call_config
from call_config import CallConfig, build_instructions, greeting_instructions, parse_metadata


def _meta(**kwargs: object) -> str:
    return json.dumps(kwargs)


# ---------------------------------------------------------------------------
# Metadata
# ---------------------------------------------------------------------------


def test_empty_or_bad_metadata_gives_defaults() -> None:
    for raw in (None, "", "not json", json.dumps([1, 2])):
        cfg = parse_metadata(raw)
        assert cfg == CallConfig()
        assert cfg.mode == "chat"
        assert cfg.delegate_available is False
        assert cfg.initiated_by == "user"


def test_full_metadata_is_parsed_and_unknown_keys_ignored() -> None:
    cfg = parse_metadata(
        _meta(
            user_id="u-1",
            mode="agents",
            chat_title="Urlaub",
            agent_name="Mira",
            context="user: hi\nassistant: hallo",
            stt_language="DE",
            delegate_available=True,
            voice_id="v-1",
            llm_model="openai/gpt-oss-120b",
            initiated_by="agent",
            call_id="c-1",
            call_reason="Pizza timer",
            something_new={"x": 1},
        )
    )
    assert cfg.user_id == "u-1"
    assert cfg.app_identity == "chuk-u-1"
    assert cfg.mode == "agents"
    assert cfg.chat_title == "Urlaub"
    assert cfg.agent_name == "Mira"
    assert cfg.context == "user: hi\nassistant: hallo"
    assert cfg.stt_language == "de"
    assert cfg.delegate_available is True
    assert cfg.voice_id == "v-1"
    assert cfg.llm_model == "openai/gpt-oss-120b"
    assert cfg.agent_started is True
    assert cfg.call_id == "c-1"
    assert cfg.call_reason == "Pizza timer"


def test_nulls_and_bad_types_fall_back_to_defaults() -> None:
    cfg = parse_metadata(
        _meta(
            user_id=None,
            mode="video",
            voice_id=None,
            llm_model="",
            delegate_available="yes",
            initiated_by="robot",
            context=123,
        )
    )
    assert cfg.user_id == "default"
    assert cfg.mode == "chat"
    assert cfg.voice_id is None
    assert cfg.llm_model is None
    assert cfg.delegate_available is False
    assert cfg.initiated_by == "user"
    assert cfg.context == ""


def test_context_and_reason_are_capped() -> None:
    cfg = parse_metadata(_meta(context="a" * 100 + "b" * 5000, call_reason="r" * 3000))
    assert len(cfg.context) == call_config.MAX_CONTEXT_CHARS
    # The newest text (the tail) is kept.
    assert cfg.context.endswith("b")
    assert set(cfg.context) == {"b"}
    assert cfg.call_reason is not None
    assert len(cfg.call_reason) == call_config.MAX_CALL_REASON_CHARS


# ---------------------------------------------------------------------------
# System prompt
# ---------------------------------------------------------------------------


def test_context_is_prepended() -> None:
    prompt = build_instructions(CallConfig(context="user: wie wird das Wetter?"))
    assert prompt.startswith("Recent messages of the current chat")
    assert "user: wie wird das Wetter?" in prompt
    assert prompt.index("<chat_context>") < prompt.index("You are")


def test_no_context_block_when_empty() -> None:
    prompt = build_instructions(CallConfig())
    assert "<chat_context>" not in prompt
    assert prompt.startswith("You are a fast, capable voice assistant")


def test_chat_mode_prompt() -> None:
    prompt = build_instructions(CallConfig(mode="chat", chat_title="Rezepte", delegate_available=True))
    assert 'inside the chat titled "Rezepte"' in prompt
    assert "delegate_task to hand the request to the full chat model" in prompt
    assert "Delegation:" in prompt


def test_chat_mode_without_delegation_has_no_delegate_rules() -> None:
    prompt = build_instructions(CallConfig(mode="chat"))
    assert "delegate_task" not in prompt


def test_agents_mode_prompt() -> None:
    prompt = build_instructions(CallConfig(mode="agents", agent_name="Mira", delegate_available=True))
    assert "You are the voice of Mira" in prompt
    assert "Use delegate_task for any real work" in prompt
    assert "Never go quiet to wait for it." in prompt


def test_agents_mode_without_delegation_says_so() -> None:
    prompt = build_instructions(CallConfig(mode="agents", agent_name="Mira"))
    assert "not reachable in this call" in prompt
    assert "delegate_task" not in prompt


def test_language_default() -> None:
    assert "speak German by default" in build_instructions(CallConfig(stt_language="de"))
    assert "speak English by default" in build_instructions(CallConfig(stt_language="en"))
    assert "by default" not in build_instructions(CallConfig())


def test_memory_preamble_is_appended() -> None:
    prompt = build_instructions(CallConfig(), "\n\nFACTS")
    assert prompt.endswith("\n\nFACTS")


# ---------------------------------------------------------------------------
# Agent-started call greeting
# ---------------------------------------------------------------------------


def test_greeting_with_reason() -> None:
    cfg = parse_metadata(_meta(initiated_by="agent", call_reason="Pizza: die 10 Minuten sind um"))
    text = greeting_instructions(cfg)
    assert "Speak first" in text
    assert "Pizza: die 10 Minuten sind um" in text
    assert "one or two short sentences" in text
    assert "listen" in text


def test_greeting_without_reason_asks_what_user_needs() -> None:
    cfg = parse_metadata(_meta(initiated_by="agent", call_reason="  "))
    assert cfg.call_reason is None
    text = greeting_instructions(cfg)
    assert "Speak first" in text
    assert "ask what they need" in text
