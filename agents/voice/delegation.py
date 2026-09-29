"""Task bookkeeping for ``delegate_task`` — pure logic, no LiveKit import.

The voice worker has no tools for real work (files, browser, code, the full
chat model). It hands such a request to the chuk_chat app over RPC:

    worker ── perform_rpc("chuk.delegate", {"task": ...}) ──▶ app
    worker ◀── {"task_id": ..., "status": "started"} ─────── app
    ... the conversation goes on ...
    worker ◀── rpc "chuk.task_result" {"task_id", "status", "result"} ── app
    worker ── {"ok": true} ─────────────────────────────────▶ app

This module holds everything about that exchange that can be tested without a
room: payload encoding and decoding, the pending/done ledger, and the text the
LLM gets when a result arrives. ``agent.py`` and ``tools.py`` only wire it up.

The app is the source of truth for tasks. The ledger here is a local mirror, so
the agent can answer "what are you still working on" without a round trip.
"""

from __future__ import annotations

import json
import time
from collections.abc import Callable
from dataclasses import dataclass
from typing import Any

#: RPC method the app registers. The worker calls it to start a task.
DELEGATE_METHOD = "chuk.delegate"

#: RPC method the worker registers. The app calls it with the task result.
TASK_RESULT_METHOD = "chuk.task_result"

#: Seconds the worker waits for the app to accept a task (not for the result).
DELEGATE_TIMEOUT = 10.0

#: A result is cut to this length before it enters the LLM context.
MAX_RESULT_CHARS = 6000

#: Task text is cut to this length in spoken lists and announcements.
SHORT_TASK_CHARS = 80

PENDING = "pending"
DONE = "done"
FAILED = "failed"

_TRUNCATION_MARK = " […]"


def truncate(text: str, limit: int = MAX_RESULT_CHARS) -> str:
    """Cut ``text`` to at most ``limit`` characters, marker included."""
    if len(text) <= limit:
        return text
    return text[: max(0, limit - len(_TRUNCATION_MARK))] + _TRUNCATION_MARK


def short_task(text: str, limit: int = SHORT_TASK_CHARS) -> str:
    """One-line, short form of a task text for lists and announcements."""
    flat = " ".join(text.split())
    if len(flat) <= limit:
        return flat
    return flat[: limit - 1].rstrip() + "…"


def normalize_status(status: Any) -> str:
    """Map the app's status to ``done`` or ``failed``.

    The contract allows only ``done`` and ``failed``. ``error`` also counts as
    a failure. Any other value (or none) counts as done, because the app sent a
    result and the user wants to hear it.
    """
    if isinstance(status, str) and status.strip().lower() in ("failed", "error"):
        return FAILED
    return DONE


# ---------------------------------------------------------------------------
# Wire format
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class DelegateResponse:
    task_id: str | None
    error: str | None

    @property
    def ok(self) -> bool:
        return self.task_id is not None and self.error is None


def parse_delegate_response(raw: Any) -> DelegateResponse:
    """Decode the app's answer to ``chuk.delegate``.

    Accepts the raw JSON string or an already decoded dict. Expected shapes are
    ``{"task_id": str, "status": "started"}`` or ``{"error": str}``.
    """
    data = raw
    if isinstance(raw, (str, bytes)):
        try:
            data = json.loads(raw)
        except (TypeError, ValueError):
            return DelegateResponse(None, "invalid response from the app")
    if not isinstance(data, dict):
        return DelegateResponse(None, "invalid response from the app")

    error = data.get("error")
    if error:
        return DelegateResponse(None, str(error))

    task_id = data.get("task_id")
    if not isinstance(task_id, str) or not task_id.strip():
        return DelegateResponse(None, "the app returned no task id")
    return DelegateResponse(task_id.strip(), None)


@dataclass(frozen=True)
class TaskResult:
    task_id: str
    status: str
    result: str


def parse_task_result(raw: str | bytes) -> TaskResult:
    """Decode a ``chuk.task_result`` payload.

    Raises ``ValueError`` when the payload is not JSON or has no ``task_id``.
    The result text is truncated to :data:`MAX_RESULT_CHARS` here, so no caller
    can forget it.
    """
    try:
        data = json.loads(raw)
    except (TypeError, ValueError) as e:
        raise ValueError(f"payload is not JSON: {e}") from e
    if not isinstance(data, dict):
        raise ValueError("payload is not a JSON object")

    task_id = data.get("task_id")
    if not isinstance(task_id, str) or not task_id.strip():
        raise ValueError("payload has no task_id")

    result = data.get("result")
    if result is None:
        result = ""
    elif not isinstance(result, str):
        result = json.dumps(result, ensure_ascii=False)

    return TaskResult(
        task_id=task_id.strip(),
        status=normalize_status(data.get("status")),
        result=truncate(result),
    )


# ---------------------------------------------------------------------------
# Ledger
# ---------------------------------------------------------------------------


@dataclass
class DelegatedTask:
    task_id: str
    text: str
    started_at: float
    status: str = PENDING
    result: str | None = None
    finished_at: float | None = None
    #: False when the result came in for an id this worker never started.
    known: bool = True

    @property
    def is_pending(self) -> bool:
        return self.status == PENDING


class TaskBook:
    """Local mirror of the tasks this call handed to the app."""

    def __init__(self, clock: Callable[[], float] = time.time) -> None:
        self._clock = clock
        self._tasks: dict[str, DelegatedTask] = {}

    def __len__(self) -> int:
        return len(self._tasks)

    def get(self, task_id: str) -> DelegatedTask | None:
        return self._tasks.get(task_id)

    @property
    def tasks(self) -> list[DelegatedTask]:
        return list(self._tasks.values())

    @property
    def pending(self) -> list[DelegatedTask]:
        return [t for t in self._tasks.values() if t.is_pending]

    @property
    def finished(self) -> list[DelegatedTask]:
        return [t for t in self._tasks.values() if not t.is_pending]

    def start(self, task_id: str, text: str) -> DelegatedTask:
        """Record a task the app accepted. It stays pending until a result."""
        task = DelegatedTask(task_id=task_id, text=text, started_at=self._clock())
        self._tasks[task_id] = task
        return task

    def resolve(self, task_id: str, status: str, result: str) -> DelegatedTask:
        """Record a result and return the task it belongs to.

        An unknown ``task_id`` does not change the ledger: the returned record
        has ``known=False`` and is not stored. The caller still announces it,
        because the app is the source of truth.
        """
        status = normalize_status(status)
        result = truncate(result)
        now = self._clock()

        task = self._tasks.get(task_id)
        if task is None:
            return DelegatedTask(
                task_id=task_id,
                text="",
                started_at=now,
                status=status,
                result=result,
                finished_at=now,
                known=False,
            )

        task.status = status
        task.result = result
        task.finished_at = now
        return task

    def summary(self) -> str:
        """Speakable status of all tasks, for the ``check_tasks`` tool."""
        if not self._tasks:
            return "No delegated tasks in this call."
        now = self._clock()
        lines: list[str] = []
        for t in self._tasks.values():
            if t.is_pending:
                state = f"pending for {int(now - t.started_at)} seconds"
            else:
                state = t.status
            lines.append(f"Task {t.task_id}: {short_task(t.text)} ({state}).")
        return " ".join(lines)


# ---------------------------------------------------------------------------
# Text for the LLM
# ---------------------------------------------------------------------------


def started_line(task_id: str) -> str:
    """What ``delegate_task`` returns to the LLM when the app accepted it."""
    return (
        f"Task started (id {task_id}). Tell the user in one short sentence that "
        "you are on it; the result comes later. Do not wait for it. Keep the "
        "conversation going."
    )


def failed_to_start_line(error: str) -> str:
    """What ``delegate_task`` returns when the hand-off did not work."""
    return (
        f"Could not hand the task over: {short_task(error, 160)}. Tell the user "
        "briefly that it did not work and offer to try again."
    )


def announcement_for(task: DelegatedTask) -> str:
    """Instructions for the proactive reply that voices a task result."""
    if task.known and task.text:
        what = f"The task you handed off ({short_task(task.text)})"
    else:
        what = "A task you handed off earlier"

    if task.status == FAILED:
        reason = task.result or "no reason given"
        return (
            f"{what} failed. Reason:\n\n{reason}\n\n"
            "Tell the user briefly that it did not work out and offer to try "
            "again. One or two spoken sentences."
        )

    result = task.result or "(the task returned no text)"
    return (
        f"{what} is done. Here is the result:\n\n{result}\n\n"
        "Bring it up now, unprompted. Open by referring back to what the user "
        "asked for, then give the answer in two or three spoken sentences. Do "
        "not read it out verbatim, and do not read out lists, links or code."
    )
