"""Task bookkeeping for delegate_task / chuk.task_result (no LiveKit needed)."""

from __future__ import annotations

import json

import pytest

import delegation
from delegation import (
    DONE,
    FAILED,
    MAX_RESULT_CHARS,
    PENDING,
    TaskBook,
    announcement_for,
    parse_delegate_response,
    parse_task_result,
)


class FakeClock:
    def __init__(self, now: float = 1000.0) -> None:
        self.now = now

    def __call__(self) -> float:
        return self.now


# ---------------------------------------------------------------------------
# Ledger
# ---------------------------------------------------------------------------


def test_start_then_result_marks_task_done() -> None:
    clock = FakeClock()
    book = TaskBook(clock=clock)

    task = book.start("t1", "Fasse die PDF im Downloads-Ordner zusammen")
    assert task.status == PENDING
    assert [t.task_id for t in book.pending] == ["t1"]
    assert book.finished == []

    clock.now += 42
    resolved = book.resolve("t1", "done", "Die PDF handelt von X.")

    assert resolved is task
    assert resolved.known is True
    assert resolved.status == DONE
    assert resolved.result == "Die PDF handelt von X."
    assert resolved.finished_at == 1042.0
    assert book.pending == []
    assert [t.task_id for t in book.finished] == ["t1"]


def test_unknown_task_id_is_ignored_by_the_ledger() -> None:
    book = TaskBook()
    book.start("t1", "task one")

    record = book.resolve("nope", "done", "some result")

    # The ledger is unchanged: t1 is still pending, "nope" is not stored.
    assert record.known is False
    assert book.get("nope") is None
    assert len(book) == 1
    assert [t.task_id for t in book.pending] == ["t1"]
    # The record still carries the result, so it can be announced.
    assert record.status == DONE
    assert record.result == "some result"


def test_failed_status_marks_task_failed() -> None:
    book = TaskBook()
    book.start("t1", "open the browser")

    task = book.resolve("t1", "failed", "browser not reachable")

    assert task.status == FAILED
    assert task.result == "browser not reachable"
    assert book.pending == []


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ("done", DONE),
        ("failed", FAILED),
        ("error", FAILED),
        ("FAILED", FAILED),
        (None, DONE),
        ("completed", DONE),
    ],
)
def test_status_normalization(raw: object, expected: str) -> None:
    assert delegation.normalize_status(raw) == expected


def test_result_is_truncated_to_6000_chars() -> None:
    book = TaskBook()
    book.start("t1", "long task")

    task = book.resolve("t1", "done", "x" * 20_000)

    assert task.result is not None
    assert len(task.result) == MAX_RESULT_CHARS == 6000
    assert task.result.endswith("[…]")


def test_short_result_is_not_truncated() -> None:
    text = "y" * MAX_RESULT_CHARS
    assert delegation.truncate(text) == text


def test_summary_lists_pending_and_done_tasks() -> None:
    clock = FakeClock()
    book = TaskBook(clock=clock)
    assert book.summary() == "No delegated tasks in this call."

    book.start("a1", "write the report")
    book.start("b2", "book a table\nfor two")
    book.resolve("b2", "done", "booked")
    clock.now += 30

    summary = book.summary()
    assert "Task a1: write the report (pending for 30 seconds)." in summary
    assert "Task b2: book a table for two (done)." in summary


# ---------------------------------------------------------------------------
# Wire format
# ---------------------------------------------------------------------------


def test_parse_delegate_response_started() -> None:
    resp = parse_delegate_response(json.dumps({"task_id": "abc", "status": "started"}))
    assert resp.ok
    assert resp.task_id == "abc"
    assert resp.error is None


def test_parse_delegate_response_accepts_decoded_dict() -> None:
    assert parse_delegate_response({"task_id": "abc", "status": "started"}).task_id == "abc"


@pytest.mark.parametrize(
    ("raw", "error_part"),
    [
        (json.dumps({"error": "agents host offline"}), "agents host offline"),
        (json.dumps({"status": "started"}), "no task id"),
        ("not json", "invalid response"),
        (json.dumps(["a"]), "invalid response"),
    ],
)
def test_parse_delegate_response_errors(raw: str, error_part: str) -> None:
    resp = parse_delegate_response(raw)
    assert not resp.ok
    assert resp.task_id is None
    assert resp.error is not None and error_part in resp.error


def test_parse_task_result_truncates_and_normalizes() -> None:
    payload = json.dumps({"task_id": " t1 ", "status": "done", "result": "z" * 7000, "extra": 1})
    res = parse_task_result(payload)
    assert res.task_id == "t1"
    assert res.status == DONE
    assert len(res.result) == MAX_RESULT_CHARS


def test_parse_task_result_missing_result_is_empty() -> None:
    res = parse_task_result(json.dumps({"task_id": "t1", "status": "failed"}))
    assert res.status == FAILED
    assert res.result == ""


@pytest.mark.parametrize("raw", ["{bad", json.dumps({"status": "done"}), json.dumps("str")])
def test_parse_task_result_rejects_bad_payload(raw: str) -> None:
    with pytest.raises(ValueError):
        parse_task_result(raw)


# ---------------------------------------------------------------------------
# Text for the LLM
# ---------------------------------------------------------------------------


def test_started_line_returns_immediately_wording() -> None:
    line = delegation.started_line("t9")
    assert line.startswith("Task started (id t9).")
    assert "result comes later" in line
    assert "Do not wait" in line


def test_announcement_for_done_task() -> None:
    book = TaskBook()
    book.start("t1", "summarize the PDF")
    text = announcement_for(book.resolve("t1", "done", "It is about solar panels."))

    assert "The task you handed off (summarize the PDF) is done." in text
    assert "It is about solar panels." in text
    assert "unprompted" in text
    assert "two or three spoken sentences" in text


def test_announcement_for_failed_task() -> None:
    book = TaskBook()
    book.start("t1", "open the browser")
    text = announcement_for(book.resolve("t1", "failed", "no browser"))

    assert "The task you handed off (open the browser) failed." in text
    assert "no browser" in text
    assert "offer to try again" in text


def test_announcement_for_unknown_task() -> None:
    text = announcement_for(TaskBook().resolve("ghost", "done", "result text"))
    assert text.startswith("A task you handed off earlier is done.")
    assert "result text" in text


def test_announcement_contains_truncated_result_only() -> None:
    book = TaskBook()
    book.start("t1", "big job")
    text = announcement_for(book.resolve("t1", "done", "q" * 50_000))
    assert text.count("q") == MAX_RESULT_CHARS - len(" […]")
