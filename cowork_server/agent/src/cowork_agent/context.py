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

**Shape rules.** The head (system prompt + the original request) stays verbatim
— it is the task definition. The tail is kept by **token budget, not message
count**, because "the last 10 messages" is meaningless when one of them is a
50k-token log. A ``tool_call``/``tool_result`` pair is never split by any
boundary: an orphaned tool result confuses every provider and an orphaned call
makes some of them error outright.

**Anti-thrashing.** If the last two passes each saved under 10%, the ladder
stops trying: paying an aux model to shave 3% off every round is a leak, not a
saving.
"""

from __future__ import annotations

import hashlib
import json
import re
from dataclasses import dataclass, field
from typing import Any, Protocol, runtime_checkable

from .think_scrubber import scrub_history

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
  not call any tool, do not emit a <tool_call> block.
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


class AuxSummarizer:
    """Wraps any :class:`~cowork_agent.model.ModelClient` as the cheap aux model.

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

    # Tier 1 caps.
    max_tool_result_tokens: int = 1_000
    max_tool_arg_chars: int = 2_000
    dedup_min_chars: int = 200

    # Anti-thrashing: skip once the last ``thrash_window`` passes each saved less
    # than ``thrash_min_savings``.
    thrash_min_savings: float = 0.10
    thrash_window: int = 2

    enabled: bool = True

    @property
    def effective_input_budget(self) -> int:
        return max(1, self.context_length - self.reserved_output)

    @property
    def tail_budget(self) -> int:
        if self.tail_token_budget is not None:
            return max(0, self.tail_token_budget)
        return max(1, int(self.effective_input_budget * self.tail_budget_fraction))


@dataclass
class CompressionStats:
    """What one :meth:`ContextLadder.compress` call did."""

    tier: int = 0
    pressure: float = 0.0
    tokens_before: int = 0
    tokens_after: int = 0
    skipped_reason: str | None = None

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


def _canonical(content: Any) -> str:
    return _content_text(content)


def _digest(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8", "replace")).hexdigest()[:16]


def _is_dup_marker(content: Any) -> bool:
    return isinstance(content, dict) and DUP_KEY in content


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
    ever drawn between units, which is what makes "never split a
    tool_call/tool_result pair" a property of the data model rather than a
    check bolted on afterwards.
    """
    return [i for i, m in enumerate(messages) if m.get("role") != "tool"]


def _head_end(messages: list[dict], head_messages: int) -> int:
    """Head boundary, snapped forward to the next unit boundary so a verbatim
    head never ends between an assistant tool_call and its result."""
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
        cost = sum(estimate_message_tokens(m) for m in unit)
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

    _summary: str | None = field(default=None, init=False, repr=False)
    _summarized_upto: int = field(default=0, init=False, repr=False)
    _calibration: float = field(default=1.0, init=False, repr=False)
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

    def prepare(self, messages: list[dict]) -> list[dict]:
        """The loop's one call: scrub stale reasoning, then compress under
        pressure. Returns the message list to send."""
        scrubbed = scrub_history(messages)
        out = self.compress(scrubbed)
        self._last_estimate = self._measure(out)
        return out

    # -- measurement ------------------------------------------------------

    def _measure(self, messages: list[dict]) -> int:
        return estimate_messages_tokens(messages) + self.config.tool_schema_tokens

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

    def compress(self, messages: list[dict]) -> list[dict]:
        cfg = self.config
        before = self._measure(messages)
        pressure = self._pressure(before)
        stats = CompressionStats(tier=0, pressure=pressure, tokens_before=before, tokens_after=before)

        if not cfg.enabled:
            stats.skipped_reason = "disabled"
            self._last_stats = stats
            return messages
        if pressure < cfg.tier1_threshold:
            stats.skipped_reason = "below_threshold"
            self._last_stats = stats
            return messages
        intended_tier = (
            2 if self.summarizer is not None and pressure >= cfg.tier2_threshold else 1
        )
        if self._thrashing(intended_tier):
            stats.skipped_reason = "anti_thrash"
            self._last_stats = stats
            return messages

        # A shorter history than we already summarized means a different run.
        if len(messages) < self._summarized_upto:
            self._summary = None
            self._summarized_upto = 0

        head_end = _head_end(messages, cfg.head_messages)
        raw_tail_start, raw_exempt_start = _tail_start(messages, cfg.tail_budget)
        tail_start = max(head_end, raw_tail_start)
        exempt_start = max(head_end, raw_exempt_start)

        # -- tier 1: deterministic, no LLM ---------------------------------
        working = self._tier1(messages, exempt_start)
        stats.tier = 1

        # -- tier 2/3: aux-model summary of the middle ---------------------
        had_summary = self._summary is not None
        if (
            self.summarizer is not None
            and self._pressure(self._measure(working)) >= cfg.tier2_threshold
            and tail_start > head_end
        ):
            summarized = self._summarize_middle(working, head_end, tail_start)
            if summarized is not None:
                working = summarized
                stats.tier = 3 if had_summary else 2

        after = self._measure(working)
        stats.tokens_after = after
        self._last_stats = stats
        self._pass_savings.append((stats.tier, stats.saved_ratio))
        return working

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

    def _summarize_middle(
        self, messages: list[dict], head_end: int, tail_start: int
    ) -> list[dict] | None:
        assert self.summarizer is not None
        # Tier 3: only the slice that has aged since the last pass is sent; the
        # rest is already represented by the existing summary.
        slice_start = head_end
        previous = self._summary
        if previous and self._summarized_upto > head_end:
            slice_start = min(self._summarized_upto, tail_start)

        new_slice = messages[slice_start:tail_start]
        if new_slice:
            # Redact BEFORE the transcript leaves the machine, and redact what
            # comes back. The model is asked to redact too, but is not trusted to.
            transcript = redact_secrets(render_transcript(new_slice))
            summary = self.summarizer.summarize(transcript, previous)
            summary = redact_secrets(summary).strip()
            if not summary:
                return None
            self._summary = summary
            self._summarized_upto = tail_start
        elif not previous:
            return None

        head = messages[:head_end]
        summary_message = {
            "role": "user",
            "content": SUMMARY_PREFIX + (self._summary or ""),
        }
        rebuilt = head + [summary_message] + messages[tail_start:]
        return self._repair_dangling_refs(rebuilt, messages)

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
