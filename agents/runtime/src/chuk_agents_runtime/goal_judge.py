"""The goal judge (CHAT-183, Hermes ``/goal``, docs/agents/GOAL_JUDGE_RUN_MODES.md).

When the agent marks an active goal complete (``update_goal`` with action
``complete``), a cheap model (the housekeeping / aux model) checks the claim
against the goal's objective before the goal is closed:

- ``done``: the goal completes as before.
- ``continue``: the completion is refused. The tool result and one
  user-side ``<goal_judge>`` row carry the judge's short reason, and the agent
  keeps working in the same run.

Hard caps keep it cheap and finite:

- at most :data:`MAX_JUDGE_ROUNDS` judge calls per goal (after that a
  ``complete`` is accepted without a judge);
- at most :data:`MAX_INPUT_CHARS` characters per call and
  :data:`MAX_TOTAL_CHARS` characters per goal;
- no refusal when the run has fewer than :data:`MIN_STEPS_FOR_NUDGE` model
  steps left (the agent could not act on it).

The judge fails open: a model error, a timeout or an answer that is not the
expected JSON accepts the completion and is logged. The verdict is stored in
the goal document (``judge``) and so reaches the app in the ``goal`` frame.
"""

from __future__ import annotations

import json
import logging
import os
import time
from dataclasses import dataclass
from typing import Any

logger = logging.getLogger(__name__)

#: Judge calls one goal may cost.
MAX_JUDGE_ROUNDS = 3
#: Characters of evidence + transcript in one judge call.
MAX_INPUT_CHARS = 12_000
#: Characters all judge calls of one goal may read together.
MAX_TOTAL_CHARS = 40_000
#: A refusal needs at least this many model steps left in the run.
MIN_STEPS_FOR_NUDGE = 2
MAX_REASON_CHARS = 400

VERDICT_DONE = "done"
VERDICT_CONTINUE = "continue"
VERDICT_ERROR = "error"
VERDICT_SKIPPED = "skipped"

#: ``AGENTS_GOAL_JUDGE=0`` turns the judge off (default on).
ENV_JUDGE = "AGENTS_GOAL_JUDGE"


def judge_enabled(environ: Any = None) -> bool:
    env = os.environ if environ is None else environ
    raw = str(env.get(ENV_JUDGE, "")).strip().lower()
    return raw not in ("0", "false", "no", "off")


JUDGE_PROMPT = (
    "You check the work of an AI agent. The agent says it reached a goal. Decide if "
    "the evidence and the transcript show that the WHOLE objective is done.\n"
    "Rules:\n"
    "- Say done when each part of the objective has evidence (a tool result, a file, "
    "a check that passed).\n"
    "- Say continue only when you can name one concrete part that is missing or not "
    "verified. Give that part as the reason, in one or two short sentences, as an "
    "instruction to the agent.\n"
    "- Do not ask for extra polish, more tests than the objective asks for, or work "
    "outside the objective.\n"
    "- When you are not sure, say done.\n"
    'Answer with ONE JSON object and nothing else: {"verdict": "done" | "continue", '
    '"reason": "<short text>"}'
)


@dataclass
class JudgeVerdict:
    verdict: str
    reason: str = ""
    round: int = 0
    chars: int = 0

    @property
    def refuses(self) -> bool:
        return self.verdict == VERDICT_CONTINUE

    def as_dict(self, max_rounds: int = MAX_JUDGE_ROUNDS) -> dict:
        return {
            "verdict": self.verdict,
            "reason": self.reason,
            "round": self.round,
            "max_rounds": max_rounds,
            "at": time.time(),
        }


def build_judge_messages(objective: str, evidence: str, transcript: str, limit: int) -> list[dict]:
    evidence = (evidence or "").strip()
    transcript = (transcript or "").strip()
    head = f"Objective:\n{objective.strip()}\n\nEvidence the agent gives:\n{evidence or '(none)'}\n"
    room = max(0, limit - len(head))
    if len(transcript) > room:
        transcript = "[earlier part cut]\n" + transcript[-room:] if room else ""
    body = head + "\nTranscript of the newest work (tail):\n" + (transcript or "(none)")
    return [
        {"role": "system", "content": JUDGE_PROMPT},
        {"role": "user", "content": body},
    ]


def parse_verdict(text: Any) -> tuple[str, str] | None:
    """``(verdict, reason)`` from the judge's answer, or ``None`` when it is
    not the expected JSON (the caller fails open)."""
    if not isinstance(text, str):
        return None
    start, end = text.find("{"), text.rfind("}")
    if start < 0 or end <= start:
        return None
    try:
        value = json.loads(text[start : end + 1])
    except ValueError:
        return None
    if not isinstance(value, dict):
        return None
    verdict = str(value.get("verdict") or "").strip().lower()
    if verdict not in (VERDICT_DONE, VERDICT_CONTINUE):
        return None
    reason = str(value.get("reason") or "").strip()[:MAX_REASON_CHARS]
    if verdict == VERDICT_CONTINUE and not reason:
        # A refusal without a reason gives the agent nothing to do: fail open.
        return None
    return verdict, reason


class GoalJudge:
    """The judge. ``client`` is a model client (``complete(messages)``) or a
    factory that builds a fresh one per call (closed after the call)."""

    def __init__(
        self,
        client: Any,
        *,
        max_rounds: int = MAX_JUDGE_ROUNDS,
        max_input_chars: int = MAX_INPUT_CHARS,
        max_total_chars: int = MAX_TOTAL_CHARS,
        min_steps: int = MIN_STEPS_FOR_NUDGE,
    ) -> None:
        self._client = client
        self.max_rounds = max(0, int(max_rounds))
        self.max_input_chars = max(500, int(max_input_chars))
        self.max_total_chars = max(self.max_input_chars, int(max_total_chars))
        self.min_steps = max(0, int(min_steps))
        self.calls = 0

    def _client_for_call(self) -> tuple[Any, bool]:
        client = self._client
        if hasattr(client, "complete"):
            return client, False
        if callable(client):
            return client(), True
        raise TypeError("judge client has no complete()")

    def judge(self, objective: str, evidence: str, transcript: str, *, round_no: int) -> JudgeVerdict:
        """One judge call. Never raises: an error is a ``error`` verdict,
        which the controller treats as accept (fail open)."""
        messages = build_judge_messages(objective, evidence, transcript, self.max_input_chars)
        chars = sum(len(m["content"]) for m in messages)
        self.calls += 1
        client = None
        owned = False
        try:
            client, owned = self._client_for_call()
            reply = client.complete(messages)
            text = getattr(reply, "text", reply)
            parsed = parse_verdict(text)
        except Exception as exc:  # noqa: BLE001 — the judge fails open
            logger.info("goal judge failed: %s", type(exc).__name__)
            return JudgeVerdict(VERDICT_ERROR, "the judge did not answer", round_no, chars)
        finally:
            if owned and client is not None:
                close = getattr(client, "close", None)
                if callable(close):
                    try:
                        close()
                    except Exception:  # noqa: BLE001
                        pass
        if parsed is None:
            logger.info("goal judge answer was not the expected JSON; accepting")
            return JudgeVerdict(VERDICT_ERROR, "the judge answer was not readable", round_no, chars)
        return JudgeVerdict(parsed[0], parsed[1], round_no, chars)


def nudge_text(reason: str, round_no: int, max_rounds: int) -> str:
    """The user-side row after a refusal."""
    return (
        "<goal_judge>\n"
        f"A reviewer checked your completion claim (check {round_no} of {max_rounds}) and "
        f"says the goal is not done yet: {json.dumps(reason, ensure_ascii=False)}\n"
        "Work on that part now and verify it. Then call update_goal with action complete "
        "again, with the evidence.\n"
        "</goal_judge>"
    )


def make_judge(source: Any) -> GoalJudge | None:
    """A judge on ``source`` (a client or a factory), or ``None`` when
    there is none or the operator turned it off."""
    if source is None or not judge_enabled():
        return None
    if not (hasattr(source, "complete") or callable(source)):
        return None
    return GoalJudge(source)


__all__ = [
    "GoalJudge",
    "JudgeVerdict",
    "MAX_JUDGE_ROUNDS",
    "build_judge_messages",
    "judge_enabled",
    "make_judge",
    "nudge_text",
    "parse_verdict",
]
