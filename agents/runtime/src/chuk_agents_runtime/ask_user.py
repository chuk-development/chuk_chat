"""Timed ``ask_user`` for agents (DeepSeek harness idea 45,
``packages/interaction/tool-ask-user/src/timed.ts``; docs/WIRE_CONTRACT.md
"Questions to the user").

The agent asks one batch of short questions. The app shows them as a card;
the run waits up to ``timeout`` seconds. Three outcomes:

- an answer batch: ``{"answers": [{"id", "selected": [...], "custom"?}]}``.
  An item with empty ``selected`` and no ``custom`` means the user SKIPPED
  that question: continue without it, do not ask it again, and do not read
  the skip as permission.
- the wait ran out: ``{"pending": true, "callId", "message"}`` (the text of
  :data:`PENDING_NOTICE`). The card stays answerable. A later answer comes
  back as a user message tagged ``answer_to_pending_question`` with this
  call id.
- the run stopped: an error.

The wait pauses while the app reports the card on screen (``ask_visible``):
a user reading the questions is not a user who went away.
"""

from __future__ import annotations

from typing import Any, Protocol

from .registry import ToolRegistry, current_call_id

ASK_USER = "ask_user"

DEFAULT_TIMEOUT_SECONDS = 120
MAX_TIMEOUT_SECONDS = 86_400
#: ``timeout: -1``: wait until the user answers (or the run stops).
NO_TIMEOUT = -1

MAX_QUESTIONS = 6
MAX_OPTIONS = 8
MAX_QUESTION_CHARS = 500
MAX_LABEL_CHARS = 120
MAX_DESCRIPTION_CHARS = 300
MAX_HEADER_CHARS = 40
RECOMMENDED = "(Recommended)"

SKIPPED_GUIDANCE = (
    "An answer item with empty selected and no custom means the user skipped that question: "
    "continue without it, do not ask it again, and do not treat the skip as permission."
)

#: The ``message`` of a pending result (harness ``timed.ts``).
PENDING_NOTICE = (
    "No answer batch arrived before the timeout. This is pending, not a skipped answer. "
    "Continue useful independent work. The user can still answer; their reply will be a user "
    "message identified as answer_to_pending_question with this callId and the original "
    "questions. Do not treat this as permission."
)

ASK_USER_SCHEMA = {
    "type": "object",
    "description": (
        "Ask the user brief, self-contained questions about missing information, a "
        "preference or a decision. Put a recommended option first, label ending "
        "\"(Recommended)\". " + SKIPPED_GUIDANCE + " A pending result means no answer "
        "came before the timeout; the user can still answer later."
    ),
    "properties": {
        "questions": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "id": {"type": "string"},
                    "question": {"type": "string"},
                    "header": {"type": "string", "description": "Short heading."},
                    "options": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "properties": {
                                "label": {"type": "string"},
                                "description": {"type": "string"},
                            },
                            "required": ["label"],
                        },
                    },
                    "multi_select": {"type": "boolean"},
                },
                "required": ["id", "question"],
            },
        },
        "timeout": {
            "type": "integer",
            "description": "Seconds to wait (default 120); -1 only when the answer is required.",
        },
    },
    "required": ["questions"],
}


class QuestionBackend(Protocol):
    """The executor's half. ``ask`` blocks until an answer batch, the
    timeout or a stop. Returns ``{"answers": [...]}``, ``{"pending": True}``
    or ``{"stopped": True}``."""

    def ask(self, call_id: str, questions: list[dict], timeout: int) -> dict: ...


class QuestionError(ValueError):
    pass


def _text(value: Any, limit: int) -> str:
    if not isinstance(value, str):
        return ""
    return " ".join(value.split())[:limit]


def validate_questions(raw: Any) -> list[dict]:
    """The canonical question batch, or :class:`QuestionError`."""
    if isinstance(raw, str):
        import json

        try:
            raw = json.loads(raw)
        except ValueError:
            raise QuestionError("questions must be a non-empty list") from None
    if not isinstance(raw, list) or not raw:
        raise QuestionError("questions must be a non-empty list")
    if len(raw) > MAX_QUESTIONS:
        raise QuestionError(f"at most {MAX_QUESTIONS} questions per call")
    out: list[dict] = []
    ids: set[str] = set()
    for item in raw:
        if not isinstance(item, dict):
            raise QuestionError("each question must be an object with id and question")
        qid = _text(item.get("id"), 64)
        if not qid:
            raise QuestionError("each question needs a non-empty id")
        if qid in ids:
            raise QuestionError(f"question id {qid!r} must be unique within this call")
        ids.add(qid)
        question = _text(item.get("question"), MAX_QUESTION_CHARS)
        if not question:
            raise QuestionError(f"question {qid!r} has no text")
        clean: dict[str, Any] = {"id": qid, "question": question}
        header = _text(item.get("header"), MAX_HEADER_CHARS)
        if header:
            clean["header"] = header
        options = item.get("options")
        if options is not None:
            if not isinstance(options, list) or len(options) > MAX_OPTIONS:
                raise QuestionError(f"question {qid!r}: options must be a list of at most {MAX_OPTIONS}")
            labels: list[dict] = []
            seen: set[str] = set()
            for position, option in enumerate(options):
                if not isinstance(option, dict):
                    raise QuestionError(f"question {qid!r}: each option needs a label")
                label = _text(option.get("label"), MAX_LABEL_CHARS)
                if not label:
                    raise QuestionError(f"question {qid!r}: each option needs a label")
                if label in seen:
                    raise QuestionError(f"question {qid!r}: duplicate option {label!r}")
                seen.add(label)
                if label.endswith(RECOMMENDED) and position != 0:
                    raise QuestionError(
                        f"question {qid!r}: put the {RECOMMENDED} option first"
                    )
                entry = {"label": label}
                description = _text(option.get("description"), MAX_DESCRIPTION_CHARS)
                if description:
                    entry["description"] = description
                labels.append(entry)
            if labels:
                clean["options"] = labels
        if item.get("multi_select") is True or str(item.get("multi_select")).lower() == "true":
            clean["multi_select"] = True
        out.append(clean)
    return out


def validate_timeout(value: Any) -> int:
    if value is None or value == "":
        return DEFAULT_TIMEOUT_SECONDS
    try:
        timeout = int(value)
    except (TypeError, ValueError):
        raise QuestionError("timeout must be -1 or a whole number of seconds") from None
    if timeout == NO_TIMEOUT:
        return timeout
    if timeout < 1 or timeout > MAX_TIMEOUT_SECONDS:
        raise QuestionError(f"timeout must be -1 or between 1 and {MAX_TIMEOUT_SECONDS} seconds")
    return timeout


def clean_answers(raw: Any, questions: list[dict]) -> list[dict]:
    """The app's answer batch, checked against the questions: one item per
    question (a missing one is a skip), options only from those offered."""
    by_id: dict[str, dict] = {}
    if isinstance(raw, list):
        for item in raw:
            if isinstance(item, dict) and isinstance(item.get("id"), str):
                by_id[item["id"]] = item
    out: list[dict] = []
    for question in questions:
        item = by_id.get(question["id"], {})
        offered = [o["label"] for o in question.get("options", [])]
        selected_raw = item.get("selected") if isinstance(item.get("selected"), list) else []
        selected = [s for s in selected_raw if isinstance(s, str) and s in offered]
        if not question.get("multi_select"):
            selected = selected[:1]
        answer: dict[str, Any] = {"id": question["id"], "selected": selected}
        custom = item.get("custom")
        if isinstance(custom, str) and custom.strip():
            answer["custom"] = custom.strip()[:2_000]
        out.append(answer)
    return out


def late_answer_prompt(call_id: str, questions: list[dict], answers: list[dict]) -> str:
    """The user message a late answer becomes (``answer_to_pending_question``)."""
    import json

    body = json.dumps({"callId": call_id, "questions": questions, "answers": answers},
                      ensure_ascii=False)
    return (
        f"<answer_to_pending_question callId=\"{call_id}\">\n{body}\n"
        "</answer_to_pending_question>"
    )


def register_ask_user_tool(registry: ToolRegistry, backend: QuestionBackend | None) -> None:
    """``ask_user`` against one run-bound backend. ``None`` registers
    nothing (no app to show the card). Deferred (prompt budget)."""
    if backend is None:
        return

    def ask_user(questions: Any = None, timeout: Any = None) -> dict:
        try:
            batch = validate_questions(questions)
            wait = validate_timeout(timeout)
        except QuestionError as exc:
            return {"ok": False, "error": str(exc)}
        call_id = current_call_id() or "ask"
        try:
            result = backend.ask(call_id, batch, wait)
        except Exception:  # noqa: BLE001 — never hand raw exception text to the model
            return {"ok": False, "error": "the question could not be shown to the user"}
        if not isinstance(result, dict):
            return {"ok": False, "error": "the question could not be shown to the user"}
        if result.get("pending"):
            return {"pending": True, "callId": call_id, "message": PENDING_NOTICE}
        if result.get("stopped"):
            return {"ok": False, "error": "the run is stopping; the question was withdrawn"}
        answers = result.get("answers")
        if not isinstance(answers, list):
            return {"ok": False, "error": "the question could not be shown to the user"}
        return {"answers": answers}

    registry.register(ASK_USER, ASK_USER_SCHEMA, ask_user, deferrable=True)
