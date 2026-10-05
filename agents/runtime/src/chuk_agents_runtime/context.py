"""Context / long-run cost ladder (§7.3) — the money lever for long runs.

A long autonomous run does not get expensive because the model thinks hard. It
gets expensive because every round re-sends the whole transcript, and the
transcript is mostly waste: the same file read three times, a 200 KB build log,
a tool call carrying an inlined blob of base64.

The ladder attacks that in cost order, cheapest first, and only under pressure.

**Trigger.** Pressure is measured against the *effective input budget*
(``context_length - reserved_output``) and counts **prompt tokens only**.
Completion and reasoning tokens are deliberately ignored: a thinking model can
burn 20k reasoning tokens on a turn without adding a single token to the next
prompt, and letting those count would fire the ladder on a transcript that is
still small. Real ``prompt_tokens`` from the backend's ``usage`` frame are used
where available — not directly (they lag by the messages appended since), but as
a **calibration ratio** against this module's own deterministic estimate, so the
pressure figure tracks the provider's real tokenizer.

**Tier 1 — deterministic, no LLM, low threshold.** Byte-identical tool results
are deduplicated and replaced by a back-reference (lossless: see
:func:`expand_back_references`), oversized tool outputs outside the tail are
truncated, and bloated tool-call arguments are cut. This reclaims most of the
waste before a single cent is spent on an aux model.

**Tier 2 — cheap aux-model summary of the middle.** At ~50% pressure the middle
of the transcript is folded into one fixed-template summary (Goal / Constraints /
Completed / Active / Blocked / Decisions / Files / Critical). The prompt carries
a "summarize, don't answer" preamble, **forced past-tense anchoring** so a
resumed run does not re-issue actions that already happened, and a redaction
instruction — backed by :func:`redact_secrets`, which scrubs the transcript
*before* it leaves the machine and scrubs the model's reply again after. The
model is never trusted to redact.

**Tier 3 — iterative re-summarization.** Later passes *update* the existing
summary with only the newly-aged slice of transcript, instead of regenerating it
from the whole middle. Cheaper each pass, and it keeps earlier decisions stable.
An update is made only when it is needed: while the summary plus the
newly-aged slice (verbatim) plus the tail stays under the tier-2 threshold, the
summary is reused and no aux call blocks the turn. With a
:class:`SummaryStore` the summary also outlives the run, so the next task of
the session starts from it instead of folding the whole middle again.

**Shape rules.** The head (system prompt + the original request) stays verbatim
— it is the task definition. The tail is kept by **token budget, not message
count**, because "the last 10 messages" is meaningless when one of them is a
50k-token log. An assistant ``tool_calls`` turn and its ``role:"tool"`` results
are never split by any boundary: an orphaned tool result confuses every provider
and an orphaned call makes some of them error outright.

**Anti-thrashing.** If the last two passes each saved under 10%, the ladder
stops trying: paying an aux model to shave 3% off every round is a leak, not a
saving.

**Summaries off the turn path (cowork-z9mo).** With a ``summarizer_factory``
and a :class:`SummaryStore`, a needed summary is made on a background thread
and persisted; the turn does not wait for it. The turn sends what it already
has (the last valid summary plus the aged slice verbatim, or the tier-1
payload) as long as that stays under ``hard_threshold`` of the budget. Only a
payload over that hard ceiling waits for one blocking aux call, and that is
logged as a warning. After a run, :meth:`ContextLadder.plan_ahead` starts the
job if the next turn would need a summary, so the next turn only loads it.

**Idle rule (cowork-z9mo).** A user message that arrives after a pause of at
least ``idle_drop_seconds`` drops every tool call and tool result before it;
the conversation text stays. The provider cache is cold after such a pause
anyway, so the rewrite costs nothing, and the answers say what the agent did.
"""

from __future__ import annotations

from collections.abc import Callable

import hashlib
import json
import logging
import re
import threading
import time
from dataclasses import dataclass, field
from typing import Any, Protocol, runtime_checkable

from .think_scrubber import scrub_history

logger = logging.getLogger(__name__)

# -- token accounting ---------------------------------------------------------

DEFAULT_CONTEXT_LENGTH = 128_000
DEFAULT_RESERVED_OUTPUT = 4_096

# Bytes per token for the deterministic estimate. Deliberately a plain constant:
# the estimate only has to be *proportional*, because the calibration ratio from
# the backend's real ``prompt_tokens`` corrects the scale.
_CHARS_PER_TOKEN = 4
# Per-message wire overhead (role, separators, framing).
_MESSAGE_OVERHEAD_TOKENS = 4


def estimate_tokens(text: str | None) -> int:
    """Deterministic token estimate for a string. No tokenizer, no network."""
    if not text:
        return 0
    return max(1, (len(text) + _CHARS_PER_TOKEN - 1) // _CHARS_PER_TOKEN)


def _content_text(content: Any) -> str:
    if content is None:
        return ""
    if isinstance(content, str):
        return content
    return json.dumps(content, sort_keys=True, separators=(",", ":"))


def estimate_message_tokens(message: dict) -> int:
    """Estimate one message, tool-call arguments included."""
    total = _MESSAGE_OVERHEAD_TOKENS
    total += estimate_tokens(str(message.get("role", "")))
    total += estimate_tokens(_content_text(message.get("content")))
    name = message.get("name")
    if name:
        total += estimate_tokens(str(name))
    for call in message.get("tool_calls") or []:
        total += estimate_tokens(_content_text(call))
    return total


def estimate_messages_tokens(messages: list[dict]) -> int:
    return sum(estimate_message_tokens(m) for m in messages)


# Keys that carry *input* tokens. Everything else in a usage dict — completion,
# reasoning, total — is ignored on purpose (see the module docstring).
_PROMPT_TOKEN_KEYS = ("prompt_tokens", "input_tokens", "promptTokens", "inputTokens")


# Keys that carry a pre-summed *total* for the turn, if the backend reports one.
_TOTAL_TOKEN_KEYS = ("total_tokens", "totalTokens")

# Keys that carry *output* tokens, summed with the prompt tokens when no total
# is reported. Cost is driven by both halves, so a spend budget counts both —
# unlike the context-pressure figure, which reads prompt tokens only.
_COMPLETION_TOKEN_KEYS = (
    "completion_tokens",
    "output_tokens",
    "completionTokens",
    "outputTokens",
)


def _first_int(usage: dict, keys: tuple[str, ...]) -> int | None:
    for key in keys:
        value = usage.get(key)
        if isinstance(value, bool):
            continue
        if isinstance(value, (int, float)) and value >= 0:
            return int(value)
        if isinstance(value, str):
            try:
                parsed = int(value.strip())
            except ValueError:
                continue
            if parsed >= 0:
                return parsed
    return None


def total_tokens_from_usage(usage: dict | None) -> int:
    """Total tokens a turn spent — prompt + completion — for a **spend** budget.

    Prefers a backend-reported ``total_tokens``; otherwise sums the prompt and
    completion halves. Missing or unparseable fields count as zero, so a usage
    frame the backend forgot to send cannot silently exhaust a budget — it just
    does not advance it. This is deliberately different from
    :func:`prompt_tokens_from_usage`, which the context ladder uses and which
    must read input tokens only.
    """
    if not isinstance(usage, dict):
        return 0
    total = _first_int(usage, _TOTAL_TOKEN_KEYS)
    if total is not None:
        return total
    prompt = _first_int(usage, _PROMPT_TOKEN_KEYS) or 0
    completion = _first_int(usage, _COMPLETION_TOKEN_KEYS) or 0
    return prompt + completion


def prompt_tokens_from_usage(usage: dict | None) -> int | None:
    """Pull **prompt tokens only** out of a backend ``usage`` payload.

    Returns ``None`` when the payload carries no input-token field, so a usage
    frame that only reports reasoning/completion tokens cannot move the pressure
    figure at all.
    """
    if not isinstance(usage, dict):
        return None
    for key in _PROMPT_TOKEN_KEYS:
        value = usage.get(key)
        if isinstance(value, bool):
            continue
        if isinstance(value, (int, float)) and value >= 0:
            return int(value)
        if isinstance(value, str):
            try:
                parsed = int(value.strip())
            except ValueError:
                continue
            if parsed >= 0:
                return parsed
    return None


# -- secret redaction ---------------------------------------------------------

REDACTED = "[REDACTED]"

# Bounded, backtracking-free patterns. Order matters: the key=value rule runs
# last so the specific token shapes win first.
_SECRET_PATTERNS: tuple[tuple[re.Pattern[str], str], ...] = (
    (
        re.compile(
            r"-----BEGIN[A-Z ]{0,40}PRIVATE KEY-----[\s\S]{0,20000}?"
            r"-----END[A-Z ]{0,40}PRIVATE KEY-----"
        ),
        REDACTED,
    ),
    (re.compile(r"\bsk-[A-Za-z0-9_\-]{16,}"), REDACTED),
    (re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}"), REDACTED),
    (re.compile(r"\bxox[baprs]-[A-Za-z0-9\-]{10,}"), REDACTED),
    (re.compile(r"\bAKIA[0-9A-Z]{16}\b"), REDACTED),
    (re.compile(r"\bAIza[0-9A-Za-z_\-]{30,}"), REDACTED),
    (
        re.compile(r"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"),
        REDACTED,
    ),
    # `Authorization: Bearer <token>` — the scheme word is kept, the token goes.
    (re.compile(r"(?i)\b(bearer)\s+[A-Za-z0-9._\-]{8,}"), r"\1 " + REDACTED),
)

# `api_key: "…"` / `"token":"…"` / `password=…` / `Authorization: Bearer …`.
# The closing quote is deliberately NOT consumed, so redacting a JSON blob leaves
# it valid JSON.
_SECRET_ASSIGNMENT = re.compile(
    r"(?i)\b(api[_\-]?key|secret[_\-]?key|secret|password|passwd|pwd|token|"
    r"access[_\-]?token|refresh[_\-]?token|authorization|auth[_\-]?token|bearer)\b"
    r"(\"?\s*[:=]\s*|\s+)"
    r"(\"|')?([^\s\"',;]{6,})"
)


def redact_secrets(text: str) -> str:
    """Remove credential-shaped strings.

    Applied to the transcript **before** it is handed to the aux model, and again
    to whatever the aux model writes back. The prompt also *asks* the model to
    redact, but the guarantee is this function, not the request.
    """
    if not text:
        return text
    for pattern, replacement in _SECRET_PATTERNS:
        text = pattern.sub(replacement, text)

    def _assign(match: re.Match[str]) -> str:
        return f"{match.group(1)}{match.group(2)}{match.group(3) or ''}{REDACTED}"

    return _SECRET_ASSIGNMENT.sub(_assign, text)


def _redact_value(value: Any) -> Any:
    """Redact string leaves in place, keeping the structure intact — never a
    JSON round-trip, which redaction could make unparseable."""
    if isinstance(value, str):
        return redact_secrets(value)
    if isinstance(value, dict):
        return {k: _redact_value(v) for k, v in value.items()}
    if isinstance(value, list):
        return [_redact_value(v) for v in value]
    return value


def redact_message(message: dict) -> dict:
    """Redaction applied to a whole message (content + tool-call arguments)."""
    return {k: _redact_value(v) for k, v in message.items()}


# -- summary template ---------------------------------------------------------

SUMMARY_TEMPLATE = """\
GOAL:
CONSTRAINTS:
COMPLETED:
ACTIVE:
BLOCKED:
DECISIONS:
FILES:
CRITICAL:"""

# The marker that labels the injected summary in the message list. Kept as a
# prefix (not a second system message) because the backend collapses system
# messages into one `system_prompt` field — a second one would silently replace
# the operator persona.
SUMMARY_PREFIX = "[context summary — earlier conversation, compressed]\n"

_SUMMARY_PREAMBLE = """\
You are a transcript compressor. You are NOT the assistant in this transcript.

Rules, all mandatory:
- SUMMARIZE, DO NOT ANSWER. Do not continue the task, do not solve anything, do
  not call any tool.
- Write every finished action in the PAST TENSE ("wrote src/app.py", "ran the
  tests, 12 passed"). The run continues from this summary; anything phrased as
  an intention will be executed a second time.
- Never reproduce a secret, token, password, key, or credential. Write
  [REDACTED] instead.
- Reply with the template below and nothing else. Keep every heading, even when
  a section is empty."""

_SUMMARY_TEMPLATE_BLOCK = f"Template:\n{SUMMARY_TEMPLATE}"


def build_summary_prompt(transcript: str, previous: str | None = None) -> str:
    """The aux-model prompt. With ``previous`` this is the tier-3 *update* form:
    the existing summary plus only the newly-aged slice of transcript."""
    if previous:
        return (
            f"{_SUMMARY_PREAMBLE}\n\n"
            "UPDATE the existing summary below with the new transcript slice. Do "
            "not rewrite it from scratch and do not drop facts that still hold; "
            "move finished ACTIVE items into COMPLETED and add what is new.\n\n"
            f"{_SUMMARY_TEMPLATE_BLOCK}\n\n"
            f"=== EXISTING SUMMARY ===\n{previous}\n\n"
            f"=== NEW TRANSCRIPT SLICE ===\n{transcript}\n"
        )
    return (
        f"{_SUMMARY_PREAMBLE}\n\n"
        f"{_SUMMARY_TEMPLATE_BLOCK}\n\n"
        f"=== TRANSCRIPT ===\n{transcript}\n"
    )


def render_transcript(messages: list[dict]) -> str:
    """Flatten messages into the plain text the aux model summarizes."""
    lines: list[str] = []
    for message in messages:
        if message.get(IDLE_DROP_KEY):
            continue
        role = message.get("role", "?")
        if role == "tool":
            name = message.get("name", "tool")
            lines.append(f"[tool:{name}] {_content_text(message.get('content'))}")
            continue
        text = _content_text(message.get("content"))
        if text:
            lines.append(f"[{role}] {text}")
        for call in message.get("tool_calls") or []:
            fn = call.get("function", {}) if isinstance(call, dict) else {}
            lines.append(
                f"[{role}:call] {fn.get('name', '?')} {_content_text(fn.get('arguments'))}"
            )
    return "\n".join(lines)


# -- aux summarizer -----------------------------------------------------------


@runtime_checkable
class Summarizer(Protocol):
    def summarize(self, transcript: str, previous: str | None) -> str: ...


@runtime_checkable
class SummaryStore(Protocol):
    """Where a session's compaction summary outlives the run that made it.

    The executor builds a fresh ladder for every task. Without a store, each
    task started with no summary and paid a blocking aux-model call to fold
    the same middle again (bead chuk_chat-p5xm: 100-180 s before a "hi" was
    answered). The row is only a cache: it is used only while
    ``prefix_digest`` still matches the stored history, so a stale or foreign
    row costs one fresh summary and never a wrong context.
    """

    def load_context_summary(self, session_id: int) -> dict | None: ...

    def save_context_summary(
        self,
        session_id: int,
        *,
        summary: str,
        summarized_upto: int,
        prefix_digest: str,
        only_if_covers_more: bool = False,
        replaces: dict | None = None,
    ) -> bool | None:
        """Store the row. With ``only_if_covers_more`` the store must do an
        atomic compare-and-set: replace an existing row only when it covers
        fewer messages, or when it is still exactly ``replaces``."""
        ...


class AuxSummarizer:
    """Wraps any :class:`~chuk_agents_runtime.model.ModelClient` as the cheap aux model.

    The aux model is a *different, cheaper* model than the one driving the run —
    summarizing a transcript is not the job the frontier model is paid for.
    """

    def __init__(self, client: Any) -> None:
        self._client = client

    def summarize(self, transcript: str, previous: str | None) -> str:
        prompt = build_summary_prompt(transcript, previous)
        response = self._client.complete([{"role": "user", "content": prompt}])
        text = getattr(response, "text", None)
        return (text or "").strip()

    def close(self) -> None:
        """Release the wrapped client (a background job owns its own)."""
        close = getattr(self._client, "close", None)
        if callable(close):
            close()


# -- configuration ------------------------------------------------------------


@dataclass(frozen=True)
class LadderConfig:
    """Every knob of the ladder. Defaults are the plan's numbers."""

    context_length: int = DEFAULT_CONTEXT_LENGTH
    reserved_output: int = DEFAULT_RESERVED_OUTPUT
    # Out-of-band tool schemas (function-calling APIs). On the `/v2/ws` path the
    # tool docs live inside the system prompt and are already counted with it —
    # this is for deployments where the schemas ride beside the messages. Either
    # way, tool-schema tokens count toward pressure.
    tool_schema_tokens: int = 0

    tier1_threshold: float = 0.30
    tier2_threshold: float = 0.50

    # Head kept verbatim: the system prompt and the original request.
    head_messages: int = 2
    # Tail kept by TOKEN budget, not message count. ``None`` -> a fraction of the
    # effective input budget.
    tail_token_budget: int | None = None
    tail_budget_fraction: float = 0.25
    # The fraction is only an upper bound: the tail is re-sent verbatim in
    # every round, so 25% of a 128k budget (~30k tokens) was the floor of
    # every request. Capped at this many tokens.
    tail_token_cap: int = 10_000

    # Tier 1 caps.
    max_tool_result_tokens: int = 1_000
    max_tool_arg_chars: int = 2_000
    dedup_min_chars: int = 200

    # Anti-thrashing: skip once the last ``thrash_window`` passes each saved less
    # than ``thrash_min_savings``.
    thrash_min_savings: float = 0.10
    thrash_window: int = 2

    # Hard ceiling (cowork-z9mo): with a background summarizer, a turn sends
    # what it has while that stays under this pressure, and waits for a
    # blocking aux call only above it. Below 1.0 because the estimate is rough.
    hard_threshold: float = 0.90
    # After a run, refresh the summary in the background already when the
    # next payload is within this much pressure of the tier-2 threshold.
    plan_headroom: float = 0.05
    # A user message after a pause this long (seconds) drops the tool calls
    # and tool results before it. 0 turns the rule off.
    idle_drop_seconds: float = 1800.0

    enabled: bool = True

    @property
    def effective_input_budget(self) -> int:
        return max(1, self.context_length - self.reserved_output)

    @property
    def tail_budget(self) -> int:
        if self.tail_token_budget is not None:
            return max(0, self.tail_token_budget)
        return max(
            1,
            min(self.tail_token_cap, int(self.effective_input_budget * self.tail_budget_fraction)),
        )


@dataclass
class CompressionStats:
    """What one :meth:`ContextLadder.compress` call did."""

    tier: int = 0
    pressure: float = 0.0
    tokens_before: int = 0
    tokens_after: int = 0
    skipped_reason: str | None = None
    #: A needed summary went to the background; the turn did not wait.
    deferred: bool = False
    #: The turn waited for an aux call (no background, or over the ceiling).
    blocking_aux: bool = False
    #: Messages whose tool traffic the idle rule dropped.
    idle_dropped: int = 0

    @property
    def saved(self) -> int:
        return max(0, self.tokens_before - self.tokens_after)

    @property
    def saved_ratio(self) -> float:
        if self.tokens_before <= 0:
            return 0.0
        return self.saved / self.tokens_before


# -- back-reference markers ---------------------------------------------------

DUP_KEY = "cowork_dup_of_index"
TRUNCATION_NOTE = "cowork_truncated"
#: Private flag on a message the idle rule dropped. Such a message keeps its
#: slot (and its content, for back-references) until the very end of a pass,
#: so every index stays aligned with the input; it is never sent.
IDLE_DROP_KEY = "cowork_idle_dropped"


def _canonical(content: Any) -> str:
    return _content_text(content)


def _digest(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8", "replace")).hexdigest()[:16]


def _is_dup_marker(content: Any) -> bool:
    return isinstance(content, dict) and DUP_KEY in content


def _prefix_digest(messages: list[dict], start: int, end: int) -> str:
    """Identity of ``messages[start:end]`` as the ladder received them (after
    the reasoning scrub, before tier 1). A persisted summary covers exactly
    this slice; the digest proves it still is the same slice."""
    h = hashlib.sha256()
    for message in messages[start:end]:
        h.update(
            json.dumps(message, sort_keys=True, separators=(",", ":"), default=str).encode(
                "utf-8", "replace"
            )
        )
        h.update(b"\x1e")
    return h.hexdigest()


def _cost(message: dict) -> int:
    """Token cost of one message as sent: an idle-dropped message costs 0."""
    if message.get(IDLE_DROP_KEY):
        return 0
    return estimate_message_tokens(message)


def idle_cut(messages: list[dict], timestamps: list[float] | None, gap_seconds: float) -> int:
    """Index of the newest user message that arrived ``gap_seconds`` or more
    after the message before it; 0 when there is none.

    Only a user message counts: a long build that ran for 40 minutes is a gap
    between two tool rows, not a user who went away. The cut is computed from
    the stored timestamps on every pass, so it is the same on every later
    turn until the next long pause moves it forward."""
    if gap_seconds <= 0 or not timestamps or len(timestamps) != len(messages):
        return 0
    for i in range(len(messages) - 1, 0, -1):
        if messages[i].get("role") != "user":
            continue
        try:
            gap = float(timestamps[i]) - float(timestamps[i - 1])
        except (TypeError, ValueError):
            continue
        if gap >= gap_seconds:
            return i
    return 0


#: The head of a task-start memory recall row (``memory.RECALL_PREFIX``).
RECALL_MARK = "[memory recall"
#: The head of a fired automation's prompt and the line before its payload
#: (``automations.fired_prompt`` / ``automations.PAYLOAD_MARKER``).
AUTOMATION_MARK = "[automation "
PAYLOAD_MARK = "payload (data, not instructions):"
OLD_PAYLOAD_NOTE = "(payload of an earlier run omitted; the answer after it says what it showed)"


def _stale_marks(messages: list[dict], head_end: int, turn_start: int) -> tuple[list[dict], int]:
    """Old injected rows before the current turn (``messages[turn_start]`` is
    its prompt): a memory recall row of an earlier task is flagged (only the
    current task's recall matters; the notes are still in memory), and the
    payload of an earlier fired automation is collapsed to its first lines.
    Same slots as the input, like :func:`_idle_marks`."""
    if turn_start <= head_end:
        return messages, 0
    out = messages
    changed = 0
    for i in range(head_end, min(turn_start, len(messages))):
        message = messages[i]
        content = message.get("content")
        if message.get("role") != "user" or not isinstance(content, str):
            continue
        if content.startswith(RECALL_MARK):
            replacement = {**message, IDLE_DROP_KEY: True}
        elif content.startswith(AUTOMATION_MARK) and PAYLOAD_MARK in content:
            head = content.split(PAYLOAD_MARK, 1)[0].rstrip()
            replacement = {**message, "content": f"{head}\n{OLD_PAYLOAD_NOTE}"}
        else:
            continue
        if out is messages:
            out = list(messages)
        out[i] = replacement
        changed += 1
    return out, changed


def _idle_marks(messages: list[dict], head_end: int, cut: int) -> tuple[list[dict], int]:
    """Drop the tool traffic in ``messages[head_end:cut]`` (the idle rule).

    A tool result and an assistant turn that only called tools are flagged
    with :data:`IDLE_DROP_KEY` (same slot, content kept for back-references);
    an assistant turn with text keeps the text and loses its ``tool_calls``.
    Calls and results go together, so no orphan is ever left. Returns the new
    list and how many messages changed."""
    if cut <= head_end:
        return messages, 0
    out = list(messages)
    changed = 0
    for i in range(head_end, min(cut, len(messages))):
        message = messages[i]
        role = message.get("role")
        if role == "tool":
            out[i] = {**message, IDLE_DROP_KEY: True}
            changed += 1
        elif role == "assistant" and message.get("tool_calls"):
            text = message.get("content")
            if isinstance(text, str) and text.strip():
                out[i] = {k: v for k, v in message.items() if k != "tool_calls"}
            else:
                out[i] = {**message, IDLE_DROP_KEY: True}
            changed += 1
    return out, changed


# -- background summaries -------------------------------------------------------


class BackgroundSummaries:
    """Process-wide bookkeeping of the background summary jobs (cowork-z9mo).

    At most one job per ``(store, session)``: a second request while one runs
    is refused, and the caller goes on with what it has. Every finished job
    bumps the key's generation, which tells a live ladder to re-read the
    stored summary before its next pass."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._running: dict[tuple, threading.Thread] = {}
        self._generation: dict[tuple, int] = {}

    def running(self, key: tuple) -> bool:
        with self._lock:
            thread = self._running.get(key)
            return thread is not None and thread.is_alive()

    def generation(self, key: tuple) -> int:
        with self._lock:
            return self._generation.get(key, 0)

    def start(self, key: tuple, job: Callable[[], None]) -> bool:
        """Run ``job`` on a daemon thread unless one already runs for ``key``."""

        def body() -> None:
            try:
                job()
            except Exception:  # noqa: BLE001 — a background job never raises
                logger.warning("background summary failed", exc_info=True)
            finally:
                with self._lock:
                    self._generation[key] = self._generation.get(key, 0) + 1
                    if self._running.get(key) is threading.current_thread():
                        del self._running[key]

        with self._lock:
            current = self._running.get(key)
            if current is not None and current.is_alive():
                return False
            thread = threading.Thread(target=body, name="agents-context-summary", daemon=True)
            self._running[key] = thread
        thread.start()
        return True

    def wait(self, key: tuple, timeout: float | None = None) -> bool:
        """Block until the job for ``key`` ends (tests, shutdown). True when
        none runs any more."""
        with self._lock:
            thread = self._running.get(key)
        if thread is None:
            return True
        thread.join(timeout)
        return not thread.is_alive()


_BACKGROUND = BackgroundSummaries()


def background_summaries() -> BackgroundSummaries:
    """The process-wide :class:`BackgroundSummaries`."""
    return _BACKGROUND


def _summary_message(summary: str) -> dict:
    return {"role": "user", "content": SUMMARY_PREFIX + summary}


def _covers_more(row: dict, source: list[dict], head_end: int, upto: int) -> bool:
    """True when a stored summary row is a newer, valid one than a background
    result covering ``source[head_end:upto]``: it covers more, and either it
    came from a longer history or its digest matches this one."""
    row_upto = row.get("summarized_upto")
    if not isinstance(row_upto, int) or row_upto <= upto:
        return False
    if row_upto > len(source):
        return True
    return _prefix_digest(source, head_end, row_upto) == row.get("prefix_digest")


def expand_back_references(messages: list[dict]) -> list[dict]:
    """Resolve every dedup marker back to the content it points at.

    This is what makes tier-1 dedup **lossless**: the omitted bytes are not gone,
    they are one hop away in the same list. Used by tests to prove it and by the
    ladder itself to repair a marker whose target was later summarized away.
    """
    out: list[dict] = []
    for message in messages:
        content = message.get("content")
        if not _is_dup_marker(content):
            out.append(message)
            continue
        index = content.get(DUP_KEY)
        if not isinstance(index, int) or not (0 <= index < len(messages)):
            out.append(message)
            continue
        clone = dict(message)
        clone["content"] = messages[index].get("content")
        out.append(clone)
    return out


# -- pair-safe boundaries -----------------------------------------------------


def _has_tool_calls(message: dict) -> bool:
    return bool(message.get("tool_calls"))


def _unit_starts(messages: list[dict]) -> list[int]:
    """Indices where an atomic *unit* begins.

    A unit is one non-tool message plus every tool result that follows it — i.e.
    an assistant ``tool_calls`` turn welded to its results. Boundaries are only
    ever drawn between units, which is what makes "never split a call from its
    result" a property of the data model rather than a check bolted on
    afterwards.
    """
    return [i for i, m in enumerate(messages) if m.get("role") != "tool"]


def _head_end(messages: list[dict], head_messages: int) -> int:
    """Head boundary, snapped forward to the next unit boundary so a verbatim
    head never ends between an assistant tool call and its result."""
    end = min(max(0, head_messages), len(messages))
    while end < len(messages) and messages[end].get("role") == "tool":
        end += 1
    return end


def _tail_start(messages: list[dict], budget: int) -> tuple[int, int]:
    """Tail boundary by **token budget**, in whole units.

    Returns ``(tail_start, exempt_start)``. Units are taken from the end while
    they fit the budget, so the tail is pair-safe by construction and holds its
    budget. If not even the newest unit fits — one 200k-token build log — the
    newest unit is still kept (the model needs the result it just received) but
    ``exempt_start`` is set past it, so tier 1 truncates it like any other
    oversized output instead of blowing the budget.
    """
    starts = _unit_starts(messages)
    if not starts:
        return len(messages), len(messages)

    bounds = starts + [len(messages)]
    used = 0
    chosen = len(messages)
    for k in range(len(starts) - 1, -1, -1):
        unit = messages[bounds[k] : bounds[k + 1]]
        cost = sum(_cost(m) for m in unit)
        if used + cost > budget:
            break
        used += cost
        chosen = bounds[k]
    if chosen < len(messages):
        return chosen, chosen
    # Nothing fit: keep the newest unit, but do not exempt it from truncation.
    return starts[-1], len(messages)


# -- the ladder ---------------------------------------------------------------


@dataclass
class ContextLadder:
    """The cost ladder. One instance per run; it carries the summary state.

    Stateless with respect to message identity — :meth:`compress` runs on the
    full append-only history every round and rebuilds its output from scratch, so
    a compressed payload is never persisted and a bug can never corrupt the
    stored transcript.
    """

    config: LadderConfig = field(default_factory=LadderConfig)
    summarizer: Summarizer | None = None
    #: Fired with every NEW tier-2/3 summary text, after it replaced the middle
    #: of the live context. The memory layer keeps its facts (§12), so what left
    #: the window is still recallable. Best-effort: a raising hook is swallowed.
    #: A background summary fires it on the background thread.
    on_summary: Callable[[str], None] | None = None
    #: Keeps the summary across runs of one session (see :class:`SummaryStore`).
    #: Used only when :meth:`prepare` is given a ``session_id``.
    summary_store: SummaryStore | None = None
    #: Builds a private summarizer for one background job (cowork-z9mo). Set
    #: together with a :attr:`summary_store` and a session, a needed summary is
    #: made off the turn path; unset, the ladder blocks on :attr:`summarizer`
    #: exactly as before. The job closes what it built (``close()``).
    summarizer_factory: Callable[[], Summarizer] | None = None

    _summary: str | None = field(default=None, init=False, repr=False)
    _summarized_upto: int = field(default=0, init=False, repr=False)
    # Digest of the scrubbed input slice ``[head_end:_summarized_upto]`` that
    # ``_summary`` covers. ``None`` = not checked against a history yet.
    _summary_digest: str | None = field(default=None, init=False, repr=False)
    _session_id: int | None = field(default=None, init=False, repr=False)
    # Background generation of this session when the summary was last read
    # from the store. A newer generation means a job wrote a fresher one.
    _loaded_generation: int = field(default=0, init=False, repr=False)
    _calibration: float = field(default=1.0, init=False, repr=False)
    # Tokens the idle/stale passes removed without flagging, this pass.
    _decision_extra: int = field(default=0, init=False, repr=False)
    _last_estimate: int = field(default=0, init=False, repr=False)
    # (tier that ran, ratio saved) per pass — the tier matters, see _thrashing.
    _pass_savings: list[tuple[int, float]] = field(
        default_factory=list, init=False, repr=False
    )
    _last_stats: CompressionStats = field(
        default_factory=CompressionStats, init=False, repr=False
    )

    # -- observation ------------------------------------------------------

    @property
    def summary(self) -> str | None:
        return self._summary

    @property
    def last_stats(self) -> CompressionStats:
        return self._last_stats

    @property
    def calibration(self) -> float:
        return self._calibration

    def record_usage(self, usage: dict | None) -> None:
        """Feed back the backend's ``usage`` frame.

        Only ``prompt_tokens`` is read. The value is not used as the pressure
        directly (it lags by whatever was appended since the call) but as a
        calibration ratio against the estimate of the payload that produced it,
        so the estimator tracks the provider's real tokenizer.
        """
        observed = prompt_tokens_from_usage(usage)
        if observed is None or observed <= 0 or self._last_estimate <= 0:
            return
        self._calibration = observed / self._last_estimate

    # -- entry point ------------------------------------------------------

    def prepare(
        self,
        messages: list[dict],
        *,
        session_id: int | None = None,
        timestamps: list[float] | None = None,
        turn_start: int | None = None,
    ) -> list[dict]:
        """The loop's one call: scrub stale reasoning, then compress under
        pressure. Returns the message list to send.

        ``session_id`` names the stored session ``messages`` came from. With a
        :attr:`summary_store`, the session's last summary is picked up on the
        first call and every new one is written back, so the next run does not
        pay the aux model again for a middle that did not change.

        ``timestamps`` are the stored ``created_at`` of ``messages`` (same
        length); they drive the idle rule (:func:`idle_cut`). ``turn_start``
        is the index of the current task's prompt; injected rows of earlier
        tasks before it are dropped or collapsed (:func:`_stale_marks`)."""
        if session_id is not None and session_id != self._session_id:
            self._bind_session(session_id)
        scrubbed = scrub_history(messages)
        cut = idle_cut(scrubbed, timestamps, self.config.idle_drop_seconds)
        out = self.compress(scrubbed, idle_cut=cut, turn_start=turn_start or 0)
        self._last_estimate = self._measure(out)
        return out

    def plan_ahead(self, messages: list[dict], *, session_id: int) -> bool:
        """After a run (cowork-z9mo): if the next turn would need a new
        summary, start it now on a background thread, so the next turn only
        loads it from the store. ``messages`` are the stored rows exactly as
        :meth:`prepare` would get them. Never blocks; True when a job started.

        The trigger is the tier-2 threshold minus ``plan_headroom``: the next
        turn adds at least a user message, and a summary refreshed a little
        early costs a cheap background call, never the user's time."""
        cfg = self.config
        if not cfg.enabled or self.summarizer_factory is None or self.summary_store is None:
            return False
        if session_id != self._session_id:
            self._bind_session(session_id)
        scrubbed = scrub_history(messages)
        head_end = _head_end(scrubbed, cfg.head_messages)
        self._refresh_from_background()
        self._check_summary(scrubbed, head_end)
        raw_tail_start, raw_exempt_start = _tail_start(scrubbed, cfg.tail_budget)
        tail_start = max(head_end, raw_tail_start)
        exempt_start = max(head_end, raw_exempt_start)
        if tail_start <= head_end:
            return False
        working = self._tier1(scrubbed, exempt_start)
        trigger = cfg.tier2_threshold - cfg.plan_headroom
        if self._pressure(self._measure(working)) < trigger:
            return False
        slice_start, previous = self._slice_start(head_end, tail_start)
        new_slice = working[slice_start:tail_start]
        if not new_slice:
            return False
        if previous:
            kept = working[:head_end] + [_summary_message(previous)] + working[slice_start:]
            if self._pressure(self._measure(kept)) < trigger:
                return False
        return self._schedule(scrubbed, working, head_end, slice_start, tail_start, previous)

    def wait_background(self, timeout: float | None = None) -> bool:
        """Block until this session's background summary job (if any) ends.
        For tests and an orderly shutdown; a turn never calls it."""
        if self.summary_store is None or self._session_id is None:
            return True
        return background_summaries().wait(self._job_key(), timeout)

    def _bind_session(self, session_id: int) -> None:
        self._session_id = session_id
        self._summary = None
        self._summarized_upto = 0
        self._summary_digest = None
        self._loaded_generation = background_summaries().generation(self._job_key())
        self._load_from_store()

    def _load_from_store(self) -> None:
        if self.summary_store is None or self._session_id is None:
            return
        try:
            row = self.summary_store.load_context_summary(self._session_id)
        except Exception:  # noqa: BLE001 — a cache miss, never a failed turn
            logger.warning(
                "context ladder: loading the stored summary for session %s failed",
                self._session_id,
                exc_info=True,
            )
            row = None
        if not row:
            return
        summary = row.get("summary")
        upto = row.get("summarized_upto")
        digest = row.get("prefix_digest")
        if isinstance(summary, str) and summary and isinstance(upto, int) and upto > 0 and digest:
            self._summary = summary
            self._summarized_upto = upto
            self._summary_digest = str(digest)

    def _job_key(self) -> tuple:
        store = self.summary_store
        where = getattr(store, "_path", None) or id(store)
        return (where, self._session_id)

    def _refresh_from_background(self) -> None:
        """A background job finished since the summary was read: take the
        stored one (it is the newest; this ladder persists its own too)."""
        if self.summary_store is None or self._session_id is None:
            return
        generation = background_summaries().generation(self._job_key())
        if generation == self._loaded_generation:
            return
        self._loaded_generation = generation
        self._load_from_store()

    def _can_defer(self) -> bool:
        return (
            self.summarizer_factory is not None
            and self.summary_store is not None
            and self._session_id is not None
        )

    def _persist_summary(self, messages: list[dict], head_end: int) -> None:
        self._summary_digest = _prefix_digest(messages, head_end, self._summarized_upto)
        if self.summary_store is None or self._session_id is None or not self._summary:
            return
        try:
            self.summary_store.save_context_summary(
                self._session_id,
                summary=self._summary,
                summarized_upto=self._summarized_upto,
                prefix_digest=self._summary_digest,
            )
        except Exception:  # noqa: BLE001 — losing the cache costs time, not data
            logger.warning(
                "context ladder: storing the summary for session %s failed",
                self._session_id,
                exc_info=True,
            )

    def _check_summary(self, messages: list[dict], head_end: int) -> None:
        """Drop a summary that no longer covers ``messages``: a shorter history
        (a different run), or a persisted summary whose slice changed under it
        (a regenerate, an edited row). The next pass makes a fresh one."""
        if self._summary is None:
            return
        upto = self._summarized_upto
        if len(messages) < upto or (
            self._summary_digest is not None
            and _prefix_digest(messages, head_end, upto) != self._summary_digest
        ):
            self._summary = None
            self._summarized_upto = 0
            self._summary_digest = None

    # -- measurement ------------------------------------------------------

    def _measure(self, messages: list[dict]) -> int:
        """What ``messages`` cost as sent (flagged messages are free)."""
        return sum(_cost(m) for m in messages) + self.config.tool_schema_tokens

    def _measure_all(self, messages: list[dict]) -> int:
        """Flagged messages count too."""
        return estimate_messages_tokens(messages) + self.config.tool_schema_tokens

    def _decision_size(self, messages: list[dict]) -> int:
        """The size the tier decisions use: as if the idle rule and the stale
        row pass had not run, so they can only make the payload smaller."""
        return self._measure_all(messages) + self._decision_extra

    def _pressure(self, tokens: int) -> float:
        return (tokens * self._calibration) / self.config.effective_input_budget

    def _thrashing(self, intended_tier: int) -> bool:
        """True when the last ``thrash_window`` passes each saved less than
        ``thrash_min_savings`` — *at this tier or higher*.

        The tier check is what keeps the guard from misfiring: two lean tier-1
        passes say nothing about whether the tier-2 summary would pay off, so
        they must not lock out an escalation that has never been tried.
        """
        cfg = self.config
        if cfg.thrash_window <= 0 or len(self._pass_savings) < cfg.thrash_window:
            return False
        recent = self._pass_savings[-cfg.thrash_window :]
        return all(
            tier >= intended_tier and saved < cfg.thrash_min_savings
            for tier, saved in recent
        )

    # -- the ladder proper -------------------------------------------------

    def compress(
        self, messages: list[dict], *, idle_cut: int = 0, turn_start: int = 0
    ) -> list[dict]:
        cfg = self.config
        before = self._measure(messages)
        stats = CompressionStats(tier=0, pressure=0.0, tokens_before=before, tokens_after=before)

        if not cfg.enabled:
            stats.pressure = self._pressure(before)
            stats.skipped_reason = "disabled"
            self._last_stats = stats
            return messages

        head_end = _head_end(messages, cfg.head_messages)
        # The idle rule and the stale injected rows first. Flagged messages
        # keep their slot until the end, so every index below is an input
        # index. They only ever REMOVE from the payload: every tier decision
        # below is made on the unflagged size (``_measure_all``), so the
        # result is never larger than without them (a drop that lowered the
        # pressure under tier 2 left the whole middle verbatim).
        marked, stats.idle_dropped = _idle_marks(messages, head_end, idle_cut)
        marked, stale = _stale_marks(marked, head_end, turn_start)
        stats.idle_dropped += stale
        # What the two passes shrank without flagging (a collapsed payload, a
        # turn that lost its tool calls); added back for the tier decisions.
        self._decision_extra = max(0, self._measure_all(messages) - self._measure_all(marked))
        pressure = self._pressure(self._measure_all(messages))
        stats.pressure = pressure

        if pressure < cfg.tier1_threshold:
            stats.skipped_reason = "below_threshold"
            return self._finish(marked, stats, record=False)
        intended_tier = (
            2 if self.summarizer is not None and pressure >= cfg.tier2_threshold else 1
        )
        if self._thrashing(intended_tier):
            stats.skipped_reason = "anti_thrash"
            return self._finish(marked, stats, record=False)

        # A background job may have written a fresher summary since this
        # ladder read it; then check that the summary still covers this
        # history (a shorter or changed one means it does not).
        self._refresh_from_background()
        self._check_summary(messages, head_end)

        raw_tail_start, raw_exempt_start = _tail_start(marked, cfg.tail_budget)
        tail_start = max(head_end, raw_tail_start)
        exempt_start = max(head_end, raw_exempt_start)

        # -- tier 1: deterministic, no LLM ---------------------------------
        working = self._tier1(marked, exempt_start)
        stats.tier = 1

        # -- tier 2/3: aux-model summary of the middle ---------------------
        had_summary = self._summary is not None
        if (
            self.summarizer is not None
            and self._pressure(self._decision_size(working)) >= cfg.tier2_threshold
            and tail_start > head_end
        ):
            covered = (self._summary, self._summarized_upto)
            summarized = self._summarize_middle(
                working, head_end, tail_start, source=messages, stats=stats
            )
            if summarized is not None:
                working = summarized
                stats.tier = 3 if had_summary else 2
            if (self._summary, self._summarized_upto) != covered:
                # A new summary was paid for: remember what it covers (on the
                # scrubbed input, which tier 1 has not touched) and keep it.
                self._persist_summary(messages, head_end)

        return self._finish(working, stats, record=True)

    def _finish(self, working: list[dict], stats: CompressionStats, *, record: bool) -> list[dict]:
        """Remove what the idle rule flagged, keep back-references valid, and
        close the pass's stats."""
        out = working
        if any(m.get(IDLE_DROP_KEY) for m in working):
            out = self._repair_dangling_refs(
                [m for m in working if not m.get(IDLE_DROP_KEY)], working
            )
        stats.tokens_after = self._measure(out)
        self._last_stats = stats
        if record:
            self._pass_savings.append((stats.tier, stats.saved_ratio))
        return out

    # -- tier 1 -----------------------------------------------------------

    def _tier1(self, messages: list[dict], exempt_start: int) -> list[dict]:
        """Deterministic pass. ``exempt_start`` marks where the truncation
        exemption begins — the newest work stays byte-exact, because that is what
        the model is reasoning about right now. Dedup applies everywhere, since
        it is lossless."""
        cfg = self.config
        out: list[dict] = []
        seen: dict[str, int] = {}
        for i, message in enumerate(messages):
            role = message.get("role")
            in_tail = i >= exempt_start

            if message.get(IDLE_DROP_KEY):
                # Never sent: neither a dedup target nor worth truncating.
                out.append(message)
                continue

            if role == "tool":
                content = message.get("content")
                canonical = _canonical(content)
                # Dedup is lossless and therefore also safe inside the tail.
                if len(canonical) >= cfg.dedup_min_chars:
                    key = _digest(canonical)
                    first = seen.get(key)
                    if first is not None:
                        clone = dict(message)
                        clone["content"] = {
                            DUP_KEY: first,
                            "note": (
                                f"identical to the result at message #{first}; "
                                "omitted to save context"
                            ),
                            "bytes": len(canonical),
                        }
                        out.append(clone)
                        continue
                    seen[key] = i
                if not in_tail:
                    truncated = _truncate_content(
                        content, cfg.max_tool_result_tokens
                    )
                    if truncated is not None:
                        clone = dict(message)
                        clone["content"] = truncated
                        out.append(clone)
                        continue
                out.append(message)
                continue

            if role == "assistant" and _has_tool_calls(message) and not in_tail:
                trimmed = _trim_tool_call_args(message, cfg.max_tool_arg_chars)
                out.append(trimmed if trimmed is not None else message)
                continue

            out.append(message)
        return out

    # -- tier 2 / 3 -------------------------------------------------------

    def _slice_start(self, head_end: int, tail_start: int) -> tuple[int, str | None]:
        """Where the not-yet-summarized slice begins, and the summary before it.
        Tier 3: only the slice that has aged since the last pass is sent; the
        rest is already represented by the existing summary."""
        previous = self._summary
        if previous and self._summarized_upto > head_end:
            return min(self._summarized_upto, tail_start), previous
        return head_end, previous

    def _summarize_middle(
        self,
        messages: list[dict],
        head_end: int,
        tail_start: int,
        *,
        source: list[dict] | None = None,
        stats: CompressionStats | None = None,
    ) -> list[dict] | None:
        assert self.summarizer is not None
        cfg = self.config
        slice_start, previous = self._slice_start(head_end, tail_start)

        new_slice = messages[slice_start:tail_start]
        head = messages[:head_end]
        kept: list[dict] | None = None
        if previous:
            # Tier 3 is paid only when it is needed. While the summary plus the
            # newly-aged slice (sent verbatim) plus the tail is still under the
            # tier-2 threshold, the summary is reused as it is: the model sees
            # more of the conversation, not less, and the turn does not block on
            # the aux model for a slice of a few messages. Without this, every
            # round that moved the tail by one unit paid a blocking aux call
            # (bead chuk_chat-p5xm).
            kept = head + [_summary_message(previous)] + messages[slice_start:]
            if not new_slice or self._pressure(self._decision_size(kept)) < cfg.tier2_threshold:
                return self._repair_dangling_refs(kept, messages)
        if not new_slice:
            return None

        if self._can_defer() and source is not None:
            # cowork-z9mo: the summary is made in the background and the turn
            # goes on with what it has, as long as that fits the hard ceiling.
            candidate = kept if kept is not None else messages
            pressure = self._pressure(self._measure(candidate))
            if pressure < cfg.hard_threshold:
                self._schedule(source, messages, head_end, slice_start, tail_start, previous)
                if stats is not None:
                    stats.deferred = True
                if kept is not None:
                    return self._repair_dangling_refs(kept, messages)
                return None
            logger.warning(
                "context ladder: blocking aux summary for session %s: the payload "
                "without it is at %.0f%% of the input budget (hard ceiling %.0f%%)",
                self._session_id,
                pressure * 100,
                cfg.hard_threshold * 100,
            )
        if stats is not None:
            stats.blocking_aux = True

        # Redact BEFORE the transcript leaves the machine, and redact what
        # comes back. The model is asked to redact too, but is not trusted to.
        transcript = redact_secrets(render_transcript(new_slice))
        started = time.monotonic()
        summary = self.summarizer.summarize(transcript, previous)
        summary = redact_secrets(summary).strip()
        logger.info(
            "context ladder: blocking aux summary took %.0f ms (%d transcript chars)",
            (time.monotonic() - started) * 1000,
            len(transcript),
        )
        if not summary:
            return None
        self._summary = summary
        self._summarized_upto = tail_start
        if self.on_summary is not None:
            try:
                self.on_summary(summary)
            except Exception:  # noqa: BLE001 — memory must never break compaction
                pass

        rebuilt = head + [_summary_message(self._summary)] + messages[tail_start:]
        return self._repair_dangling_refs(rebuilt, messages)

    def _schedule(
        self,
        source: list[dict],
        working: list[dict],
        head_end: int,
        slice_start: int,
        tail_start: int,
        previous: str | None,
    ) -> bool:
        """Start the background job that summarizes ``working[slice_start:
        tail_start]`` (onto ``previous``) and stores it as covering
        ``source[head_end:tail_start]``. The transcript is rendered and
        redacted here, so the job thread only waits on the model. False when
        a job for this session already runs (the caller does not wait)."""
        factory = self.summarizer_factory
        store = self.summary_store
        session_id = self._session_id
        if factory is None or store is None or session_id is None:
            return False
        key = self._job_key()
        if background_summaries().running(key):
            return False
        transcript = redact_secrets(render_transcript(working[slice_start:tail_start]))
        digest = _prefix_digest(source, head_end, tail_start)
        on_summary = self.on_summary

        def job() -> None:
            try:
                run_job()
            finally:
                # The job thread ends here; its per-thread SQLite connection
                # must not stay open until the garbage collector finds it.
                close_conn = getattr(store, "close_thread_connection", None)
                if callable(close_conn):
                    try:
                        close_conn()
                    except Exception:  # noqa: BLE001 — cleanup must not raise
                        logger.warning(
                            "context ladder: closing the job's store connection failed",
                            exc_info=True,
                        )

        def run_job() -> None:
            started = time.monotonic()
            summarizer = factory()
            try:
                summary = redact_secrets(summarizer.summarize(transcript, previous) or "").strip()
            finally:
                close = getattr(summarizer, "close", None)
                if callable(close):
                    try:
                        close()
                    except Exception:  # noqa: BLE001 — cleanup must not raise
                        pass
            if not summary:
                return
            row = store.load_context_summary(session_id)
            if row and _covers_more(row, source, head_end, tail_start):
                # The turn path made a newer one meanwhile (a blocking call
                # over the ceiling); a background result never replaces it.
                return
            # Compare-and-set: the row can change between the read above and
            # this write. The store replaces it only when it still covers
            # less, or is still the stale row read above.
            written = store.save_context_summary(
                session_id,
                summary=summary,
                summarized_upto=tail_start,
                prefix_digest=digest,
                only_if_covers_more=True,
                replaces=row or None,
            )
            if written is False:
                logger.info(
                    "context ladder: background summary for session %s dropped; "
                    "a newer one was stored meanwhile",
                    session_id,
                )
                return
            logger.info(
                "context ladder: background summary for session %s stored in %.0f ms "
                "(%d transcript chars, covers %d messages)",
                session_id,
                (time.monotonic() - started) * 1000,
                len(transcript),
                tail_start,
            )
            if on_summary is not None:
                try:
                    on_summary(summary)
                except Exception:  # noqa: BLE001 — memory must never break compaction
                    pass

        return background_summaries().start(key, job)

    @staticmethod
    def _repair_dangling_refs(rebuilt: list[dict], source: list[dict]) -> list[dict]:
        """Keep dedup markers resolvable after the middle is summarized away.

        Two things break otherwise: a marker whose target was summarized away
        resolves to nothing, and every surviving marker's index is stale because
        the list got shorter. So: re-point survivors at their new index, and
        inline the content of the ones whose target is gone. The output list is
        self-consistent — :func:`expand_back_references` still restores it.
        """
        new_index_by_id = {id(m): i for i, m in enumerate(rebuilt)}
        out: list[dict] = []
        for message in rebuilt:
            content = message.get("content")
            if not _is_dup_marker(content):
                out.append(message)
                continue
            index = content.get(DUP_KEY)
            target = (
                source[index]
                if isinstance(index, int) and 0 <= index < len(source)
                else None
            )
            new_index = new_index_by_id.get(id(target)) if target is not None else None
            clone = dict(message)
            if new_index is not None:
                marker = dict(content)
                marker[DUP_KEY] = new_index
                marker["note"] = (
                    f"identical to the result at message #{new_index}; "
                    "omitted to save context"
                )
                clone["content"] = marker
            else:
                clone["content"] = target.get("content") if target is not None else content
            out.append(clone)
        return out


# -- tier-1 helpers -----------------------------------------------------------


def _truncate_str(text: str, max_chars: int) -> str:
    if len(text) <= max_chars:
        return text
    keep = max(1, max_chars // 2)
    dropped = len(text) - (keep * 2)
    return f"{text[:keep]}\n…[{dropped} chars dropped by the context ladder]…\n{text[-keep:]}"


def _truncate_content(content: Any, max_tokens: int) -> Any | None:
    """Truncate an oversized tool result. Returns ``None`` when it already fits."""
    max_chars = max(1, max_tokens * _CHARS_PER_TOKEN)
    if isinstance(content, str):
        if len(content) <= max_chars:
            return None
        return _truncate_str(content, max_chars)
    if isinstance(content, dict):
        if len(_canonical(content)) <= max_chars:
            return None
        strings = [k for k, v in content.items() if isinstance(v, str)]
        clone = dict(content)
        if strings:
            per_value = max(80, max_chars // len(strings))
            for key in strings:
                clone[key] = _truncate_str(clone[key], per_value)
        if len(_canonical(clone)) > max_chars:
            clone = {
                TRUNCATION_NOTE: _truncate_str(_canonical(content), max_chars),
                "bytes": len(_canonical(content)),
            }
        return clone
    text = _canonical(content)
    if len(text) <= max_chars:
        return None
    return _truncate_str(text, max_chars)


def _trim_tool_call_args(message: dict, max_chars: int) -> dict | None:
    """Cut oversized string arguments out of an assistant turn's tool calls.

    Models inline whole files into ``write_file`` arguments; once the call has
    been executed the argument body is dead weight in every later round.
    """
    changed = False
    calls: list[Any] = []
    for call in message.get("tool_calls") or []:
        if not isinstance(call, dict):
            calls.append(call)
            continue
        fn = call.get("function")
        if not isinstance(fn, dict):
            calls.append(call)
            continue
        args = fn.get("arguments")
        new_args: Any = args
        if isinstance(args, str) and len(args) > max_chars:
            new_args = _truncate_str(args, max_chars)
        elif isinstance(args, dict):
            trimmed = {}
            local_changed = False
            for key, value in args.items():
                if isinstance(value, str) and len(value) > max_chars:
                    trimmed[key] = _truncate_str(value, max_chars)
                    local_changed = True
                else:
                    trimmed[key] = value
            new_args = trimmed if local_changed else args
        if new_args is not args:
            changed = True
            call_clone = dict(call)
            fn_clone = dict(fn)
            fn_clone["arguments"] = new_args
            call_clone["function"] = fn_clone
            calls.append(call_clone)
        else:
            calls.append(call)
    if not changed:
        return None
    clone = dict(message)
    clone["tool_calls"] = calls
    return clone
