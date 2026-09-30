"""Dispatch metadata and the per-call system prompt — pure logic, no LiveKit.

The chuk_chat app dispatches this worker with a JSON string in
``ctx.job.metadata``. :func:`parse_metadata` turns it into a :class:`CallConfig`
with safe defaults: unknown keys are ignored, missing or wrongly typed keys get
the default. :func:`build_instructions` then builds the system prompt for the
call's mode, and :func:`greeting_instructions` builds the first reply when the
agent started the call itself.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any

#: The app sends at most this much recent chat text; cut defensively.
MAX_CONTEXT_CHARS = 4000

#: The reason the agent called, as the app sends it; cut defensively.
MAX_CALL_REASON_CHARS = 1000

MODE_CHAT = "chat"
MODE_AGENTS = "agents"

INITIATED_BY_USER = "user"
INITIATED_BY_AGENT = "agent"


@dataclass(frozen=True)
class CallConfig:
    user_id: str = "default"
    mode: str = MODE_CHAT
    chat_title: str | None = None
    agent_name: str | None = None
    context: str = ""
    #: Two-letter language code from the device locale. "de" only when the
    #: app sends none.
    stt_language: str = "de"
    delegate_available: bool = False
    voice_id: str | None = None
    llm_model: str | None = None
    initiated_by: str = INITIATED_BY_USER
    call_id: str | None = None
    call_reason: str | None = None

    @property
    def agent_started(self) -> bool:
        return self.initiated_by == INITIATED_BY_AGENT

    @property
    def app_identity(self) -> str:
        """Participant identity the app joins with."""
        return f"chuk-{self.user_id}"


def _str_or_none(value: Any) -> str | None:
    if isinstance(value, str) and value.strip():
        return value.strip()
    return None


#: Used when the app sends no language.
DEFAULT_LANGUAGE = "de"

#: Language names for the prompt. Other codes are named by their code.
_LANGUAGE_NAMES = {
    "de": "German",
    "en": "English",
    "fr": "French",
    "es": "Spanish",
    "it": "Italian",
    "nl": "Dutch",
    "pl": "Polish",
    "pt": "Portuguese",
    "tr": "Turkish",
    "ru": "Russian",
    "uk": "Ukrainian",
    "sv": "Swedish",
    "da": "Danish",
    "no": "Norwegian",
    "fi": "Finnish",
    "cs": "Czech",
    "ja": "Japanese",
    "ko": "Korean",
    "zh": "Chinese",
    "ar": "Arabic",
    "hi": "Hindi",
}


def normalize_language(value: Any) -> str:
    """Primary language subtag of a locale: "de-DE", "de_DE", "DE" -> "de".

    Missing or unusable input gives :data:`DEFAULT_LANGUAGE`.
    """
    if not isinstance(value, str):
        return DEFAULT_LANGUAGE
    code = value.strip().replace("_", "-").split("-", 1)[0].lower()
    if len(code) in (2, 3) and code.isalpha():
        return code
    return DEFAULT_LANGUAGE


def language_name(code: str) -> str:
    return _LANGUAGE_NAMES.get(code, f"the language with the code '{code}'")


def _tail(text: str, limit: int) -> str:
    """Keep the last ``limit`` characters — the newest messages are at the end."""
    return text if len(text) <= limit else text[-limit:]


def parse_metadata(raw: str | None) -> CallConfig:
    """Build a :class:`CallConfig` from the dispatch metadata string."""
    data: dict[str, Any] = {}
    if raw:
        try:
            decoded = json.loads(raw)
        except (TypeError, ValueError):
            decoded = None
        if isinstance(decoded, dict):
            data = decoded

    mode = data.get("mode")
    if mode not in (MODE_CHAT, MODE_AGENTS):
        mode = MODE_CHAT

    initiated_by = data.get("initiated_by")
    if initiated_by not in (INITIATED_BY_USER, INITIATED_BY_AGENT):
        initiated_by = INITIATED_BY_USER

    context = data.get("context")
    context = _tail(context.strip(), MAX_CONTEXT_CHARS) if isinstance(context, str) else ""

    reason = _str_or_none(data.get("call_reason"))
    if reason is not None:
        reason = reason[:MAX_CALL_REASON_CHARS]

    return CallConfig(
        user_id=_str_or_none(data.get("user_id")) or "default",
        mode=mode,
        chat_title=_str_or_none(data.get("chat_title")),
        agent_name=_str_or_none(data.get("agent_name")),
        context=context,
        stt_language=normalize_language(data.get("stt_language")),
        delegate_available=data.get("delegate_available") is True,
        voice_id=_str_or_none(data.get("voice_id")),
        llm_model=_str_or_none(data.get("llm_model")),
        initiated_by=initiated_by,
        call_id=_str_or_none(data.get("call_id")),
        call_reason=reason,
    )


# ---------------------------------------------------------------------------
# System prompt
# ---------------------------------------------------------------------------

#: Rules that hold in every mode. Taken over unchanged from new-voicemode; only
#: the opening role line moved into the mode blocks below.
BASE_RULES = """\
You speak, and the app next to you renders the detail.

Tools:
- Use them aggressively. If a question touches anything current, factual, \
numeric, or local — weather, news, prices, dates, math, places — call the \
tool. Never answer such a question from memory.
- Call several tools in one turn when the question needs it.
- When the user says "here", "nearby" or names no city, call \
get_device_location first, then the tool that needs the place. If it says \
the location is not available, ask the user for the place.
- Tools already draw a card on screen. Do not read out lists, URLs or tables — \
say the headline answer in one or two sentences and let the card carry the rest.
- Show things when a picture helps. Say it naturally ("ich zeig's dir") and \
call the tool that draws the card: show_place for a place or an address, \
get_weather for weather, search_web for search results, show_list for a list, \
steps or several links.
- If a tool says it failed, tell the user in one short sentence. Do not retry \
it again and again.

Ending the call:
- When the user wants to end the call, call the end_call tool. Judge the \
intent, not the exact words. Examples: "tschüss", "tschüssi", "ciao", "bye", \
"leg auf", "du kannst gehen", "das war's", "danke, reicht", "ich muss los".
- Do not say goodbye before the tool call. The tool tells you to say one short \
goodbye after it, then the call ends.
- Do not end the call when the user only pauses, thanks you in the middle of a \
topic, or talks to someone else. When you are not sure whether the user wants \
to end the call, ask. (This rule is only about ending the call.)

Speech:
- Always reply in the language the user is speaking.
- Keep it short and conversational. This is spoken aloud, not read.
- Never use markdown, asterisks, bullet points, links, or emoji.
- Say numbers the way a person would: "zwanzig Grad", not "20°C".

Interruptions:
- The user can cut you off at any time. When that happens, only the words you \
actually said are kept — the message is trimmed at the exact point of the \
interruption and marked with a trailing "…".
- Seeing "…" at the end of one of your own earlier messages means the user \
never heard the rest of that thought. Don't assume they know it. Pick up from \
where you were cut off, or drop it and answer what they just asked.
- Never repeat a whole sentence they already heard.

When the user shares their camera or screen, describe or answer questions about \
what you currently see.
"""

_DELEGATION_RULES = """\
Delegation:
- delegate_task returns at once. The task then runs without you. Say only a \
few words in the user's language that you are on it ("Mach ich.", "On it."), \
then keep talking or listening as normal. Never go quiet to wait for it.
- Write the task self-contained: the worker does not hear this call. Put in \
every detail the user gave.
- When a result comes in, you are told. Bring it up at the next quiet moment \
in at most two short sentences: the outcome and the key numbers. No filler, \
never "let me know if you need anything else".
- Use check_tasks when the user asks what is still running.
- Reminders and timers ("remind me in 10 minutes", "ruf mich um acht an") go \
to delegate_task, with the exact time and what to remind about. The agent \
schedules them and can call the user back later. You cannot keep a timer \
yourself: it would stop when this call ends.
- Never claim you did the work yourself, and never invent a result.
"""


def _context_block(cfg: CallConfig) -> str:
    if not cfg.context:
        return ""
    return (
        "Recent messages of the current chat, oldest first. Use them to know "
        "what the chat is about. Do not read them out.\n"
        "<chat_context>\n"
        f"{cfg.context}\n"
        "</chat_context>\n\n"
    )


def _role_block(cfg: CallConfig) -> str:
    if cfg.mode == MODE_AGENTS:
        name = cfg.agent_name or "the agent"
        lines = [
            f"You are the voice of {name}, the user's coworker agent. You talk "
            f"to the user as {name}, in the first person.",
        ]
        if cfg.delegate_available:
            lines.append(
                "You are only the voice. The real work happens in the agent "
                "runtime. Use delegate_task for any real work: files, the "
                "browser, research, code, messages, mail, invoices, bookings, "
                "and anything else that needs a tool you do not have. Your own "
                "tools are only for quick answers such as time, weather, or a "
                "calculation."
            )
            lines.append(
                "Call delegate_task AT ONCE, in the same turn, as soon as the "
                "user asks for real work. The agent runtime has the user's "
                "files, memory, mail, contacts, tools and history, and finds "
                "missing details itself. So never ask the user for a file, an "
                "address, an amount or other details that the agent can look "
                "up: pass the request on as the user said it. Ask back only "
                "when the request itself is unclear, for example \"send it\" "
                "with nothing named to send."
            )
        else:
            lines.append(
                "The agent runtime is not reachable in this call. You can only "
                "use your own tools. If the user asks for real work such as "
                "files, the browser, or code, say that you cannot do it right now "
                "and that they can ask again in the chat."
            )
        return " ".join(lines) + "\n\n"

    title = f' titled "{cfg.chat_title}"' if cfg.chat_title else ""
    lines = [
        f"You are a fast, capable voice assistant inside the chat{title} in "
        "the chuk_chat app. Think of yourself as the user's heads-up display.",
    ]
    if cfg.delegate_available:
        lines.append(
            "When your own tools are not enough, use delegate_task to hand the "
            "request to the full chat model. It has web search, image "
            "generation, MCP tools and more."
        )
    return " ".join(lines) + "\n\n"


def _language_block(cfg: CallConfig) -> str:
    name = language_name(cfg.stt_language)
    return (
        f"\nLanguage: the user's device language is {name}. Speak {name} by "
        "default. Switch only when the user clearly speaks another language.\n"
    )


def build_instructions(cfg: CallConfig, memory_preamble: str = "") -> str:
    """System prompt for one call: chat context first, then role and rules."""
    parts = [_context_block(cfg), _role_block(cfg), BASE_RULES]
    if cfg.delegate_available:
        parts.append("\n" + _DELEGATION_RULES)
    parts.append(_language_block(cfg))
    return "".join(parts) + memory_preamble


def greeting_instructions(cfg: CallConfig) -> str:
    """First reply when the agent started the call (``initiated_by == agent``).

    The user just picked up. The assistant greets briefly, says why it called,
    and then listens.
    """
    if cfg.call_reason:
        return (
            "You called the user, and they just picked up. Speak first. Greet "
            "them briefly, then say why you called, based on this reason:\n\n"
            f"{cfg.call_reason}\n\n"
            "Use one or two short sentences in total, for example: \"Hey, your "
            "pizza, the ten minutes are over.\" Then stop and listen. Do not "
            "call any tool for this greeting."
        )
    return (
        "You called the user, and they just picked up. Speak first. Greet them "
        "briefly, say that you called, and ask what they need. Use one or two "
        "short sentences, then stop and listen. Do not call any tool for this "
        "greeting."
    )


def still_there_instructions(cfg: CallConfig) -> str:
    """The user went silent: ask once whether they are still there."""
    example = {"de": "Bist du noch da?", "en": "Are you still there?"}.get(cfg.stt_language)
    hint = f', for example "{example}"' if example else f" in {language_name(cfg.stt_language)}"
    return (
        "The user has been silent for a while. Ask once, in a few words, "
        f"whether they are still there{hint}. Nothing else. Do not call any tool."
    )


def call_limit_goodbye_instructions(cfg: CallConfig) -> str:
    """The call reached its maximum length: say goodbye before hanging up."""
    return (
        "The call has reached its maximum length and ends now. Tell the user "
        "that in one short, friendly sentence, and that they can call again "
        "any time. Do not call any tool."
    )


def away_goodbye_instructions(cfg: CallConfig) -> str:
    """The user stayed silent after the check: say goodbye before hanging up."""
    return (
        "The user did not answer. Say a very short goodbye and that they can "
        "call again any time. One short sentence. Do not call any tool."
    )


# ---------------------------------------------------------------------------
# end_call tool texts
# ---------------------------------------------------------------------------

#: Added to LiveKit's own end_call description (EndCallTool extra_description).
END_CALL_EXTRA_DESCRIPTION = (
    "Decide by intent, in any language and any wording. The user wants to end "
    "the call when they say, for example: tschüss, tschüssi, ciao, bye, leg "
    "auf, du kannst gehen, das war's, danke reicht, ich muss los, bis später. "
    "Do not call it when the user only pauses or says thanks in the middle of "
    "a topic."
)

#: Tool output of end_call. The model speaks this reply, then the call ends.
END_CALL_GOODBYE_INSTRUCTIONS = (
    "The call ends now. Say one short goodbye in the user's language, for "
    "example \"Alles klar, bis später!\". One sentence, nothing else."
)
