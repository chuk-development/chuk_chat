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


def test_language_follows_the_device_locale() -> None:
    assert "Speak German by default" in build_instructions(CallConfig(stt_language="de"))
    assert "Speak English by default" in build_instructions(CallConfig(stt_language="en"))
    assert "Speak French by default" in build_instructions(parse_metadata(_meta(stt_language="fr-FR")))
    # No language from the app: German.
    assert "Speak German by default" in build_instructions(parse_metadata(_meta()))


def test_stt_language_is_normalized_and_defaults_to_german() -> None:
    assert parse_metadata(_meta(stt_language="en_US")).stt_language == "en"
    assert parse_metadata(_meta(stt_language="de-DE")).stt_language == "de"
    assert parse_metadata(_meta(stt_language="FR")).stt_language == "fr"
    assert parse_metadata(_meta(stt_language=None)).stt_language == "de"
    assert parse_metadata(_meta(stt_language="")).stt_language == "de"
    assert parse_metadata(_meta(stt_language=42)).stt_language == "de"
    assert parse_metadata(None).stt_language == "de"
    assert call_config.language_name("xx") == "the language with the code 'xx'"


def test_prompt_has_no_device_status_and_handles_missing_location() -> None:
    prompt = build_instructions(CallConfig())
    assert "own device" not in prompt
    assert "get_device_status" not in prompt
    assert "get_device_location" in prompt
    assert "ask the user for the place" in prompt


def test_reminders_go_to_delegate_task_only_with_a_delegate() -> None:
    with_delegate = build_instructions(CallConfig(delegate_available=True))
    assert "Reminders and timers" in with_delegate
    assert "can call the user back later" in with_delegate
    assert "Reminders and timers" not in build_instructions(CallConfig())


def test_call_limit_goodbye() -> None:
    text = call_config.call_limit_goodbye_instructions(CallConfig())
    assert "maximum length" in text
    assert "Do not call any tool" in text


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


# ---------------------------------------------------------------------------
# User away
# ---------------------------------------------------------------------------


def test_still_there_prompt_follows_language() -> None:
    assert "Bist du noch da?" in call_config.still_there_instructions(CallConfig(stt_language="de"))
    assert "Bist du noch da?" in call_config.still_there_instructions(CallConfig())
    assert "Are you still there?" in call_config.still_there_instructions(CallConfig(stt_language="en"))
    assert "in French" in call_config.still_there_instructions(CallConfig(stt_language="fr"))


def test_away_goodbye_prompt() -> None:
    text = call_config.away_goodbye_instructions(CallConfig())
    assert "goodbye" in text
    assert "Do not call any tool" in text


def test_prompt_mentions_end_call() -> None:
    assert "call the end_call tool" in build_instructions(CallConfig())


# ---------------------------------------------------------------------------
# end_call: intent, not keywords
# ---------------------------------------------------------------------------


def test_end_call_prompt_is_intent_based() -> None:
    prompt = build_instructions(CallConfig())
    assert "Judge the intent, not the exact words" in prompt
    for phrase in ("tschüssi", "ciao", "leg auf", "du kannst gehen", "das war's", "danke, reicht"):
        assert phrase in prompt
    assert "Do not say goodbye before the tool call" in prompt


def test_end_call_tool_texts() -> None:
    desc = call_config.END_CALL_EXTRA_DESCRIPTION
    assert desc.startswith("Decide by intent")
    for phrase in ("tschüss", "ciao", "bye", "du kannst gehen", "das war's"):
        assert phrase in desc
    goodbye = call_config.END_CALL_GOODBYE_INSTRUCTIONS
    assert "one short goodbye" in goodbye
    assert "Alles klar, bis später!" in goodbye
    # The goodbye follows the language of the call, not a fixed German line.
    assert "language the user speaks" in goodbye
    assert "Alright, talk soon!" in goodbye


def test_prompt_asks_for_cards_when_visual_helps() -> None:
    prompt = build_instructions(CallConfig())
    assert "ich zeig's dir" in prompt
    for tool in ("show_place", "get_weather", "search_web", "show_list"):
        assert tool in prompt


# ---------------------------------------------------------------------------
# Agents mode: delegate at once, do not ask for details
# ---------------------------------------------------------------------------


def test_agents_mode_delegates_at_once_without_asking_for_details() -> None:
    prompt = build_instructions(CallConfig(mode="agents", agent_name="Mira", delegate_available=True))
    assert "Call delegate_task AT ONCE, in the same turn" in prompt
    assert "finds missing details itself" in prompt
    assert "never ask the user for a file" in prompt
    assert "Ask back only when the request itself is unclear" in prompt
    assert '"send it"' in prompt
    # The short "on it" line, then the conversation goes on.
    assert "Say only a few words in the user's language that you are on it" in prompt
    assert "keep talking or listening as normal" in prompt


def test_ask_when_unsure_is_scoped_to_ending_the_call() -> None:
    prompt = build_instructions(CallConfig(mode="agents", agent_name="Mira", delegate_available=True))
    assert "When you are not sure, ask." not in prompt
    assert "When you are not sure whether the user wants to end the call, ask." in prompt
    assert "(This rule is only about ending the call.)" in prompt


def test_chat_mode_has_no_agents_delegate_at_once_rule() -> None:
    assert "AT ONCE" not in build_instructions(CallConfig(mode="chat", delegate_available=True))


def test_delegation_rules_keep_result_announcements_short() -> None:
    prompt = build_instructions(CallConfig(mode="agents", agent_name="Mira", delegate_available=True))
    assert "in at most two short sentences: the outcome and the key numbers" in prompt
    assert 'never "let me know if you need anything else"' in prompt
