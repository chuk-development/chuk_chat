"""``<workspace>/transcript/`` — the agent's long-term search (bead cowork-2tq.2)."""

from __future__ import annotations

import json
import os
import stat

from cowork_agent import StateStore, TranscriptExporter
from cowork_agent.transcript_export import render_row, thread_filename


def _seed(store: StateStore, key: str = "thread-a") -> int:
    sid = store.route(key)
    store.append_message(sid, "system", {"role": "system", "content": "the frozen prompt"})
    store.append_message(sid, "user", {"role": "user", "content": "make a file"})
    store.append_message(
        sid,
        "memory",
        {"role": "user", "content": "[memory recall]\n- the user likes tabs"},
    )
    store.append_message(
        sid,
        "assistant",
        {
            "role": "assistant",
            "reasoning": "I should write it",
            "tool_calls": [
                {
                    "id": "call_1",
                    "type": "function",
                    "function": {"name": "write_file", "arguments": {"path": "a.txt", "content": "hi"}},
                }
            ],
        },
    )
    store.append_message(
        sid,
        "tool",
        {"role": "tool", "tool_call_id": "call_1", "name": "write_file", "content": {"ok": True, "path": "a.txt"}},
    )
    store.append_message(sid, "assistant", {"role": "assistant", "content": "done, it is a.txt"})
    return sid


def test_export_writes_the_thread_as_markdown_and_moves_the_cursor(tmp_path):
    store = StateStore(str(tmp_path / "s.db"))
    _seed(store)
    exporter = TranscriptExporter(tmp_path / "ws")

    written = exporter.export(store, "thread-a")
    assert written == 6
    text = exporter.path_for("thread-a").read_text(encoding="utf-8")
    assert text.startswith("# Transcript · thread `thread-a`")
    # Every side of the thread is there, in order, with a timestamp heading.
    assert "· user\n\nmake a file" in text
    assert "_thinking:_ I should write it" in text
    assert "**call** `write_file` (call_1)" in text and '"path":"a.txt"' in text
    assert "**result** `write_file` (call_1)" in text and '{"ok":true,"path":"a.txt"}' in text
    assert "done, it is a.txt" in text
    # The frozen system prompt is not a turn; a runtime row is one line.
    assert "the frozen prompt" not in text
    assert "_[memory]_ [memory recall] - the user likes tabs" in text
    # The cursor is the last exported row id.
    cursors = json.loads((exporter.directory / ".cursor.json").read_text())
    assert cursors["thread-a"] == store.max_message_id(store.route("thread-a"))

    # Nothing new: nothing written, file unchanged.
    assert exporter.export(store, "thread-a") == 0
    assert exporter.path_for("thread-a").read_text(encoding="utf-8") == text


def test_export_appends_only_the_new_rows(tmp_path):
    store = StateStore(str(tmp_path / "s.db"))
    sid = _seed(store)
    exporter = TranscriptExporter(tmp_path / "ws")
    exporter.export(store, "thread-a")

    store.append_message(sid, "user", {"role": "user", "content": "and now delete it"})
    assert exporter.export(store, "thread-a") == 1
    text = exporter.path_for("thread-a").read_text(encoding="utf-8")
    assert text.count("· user") == 2
    assert text.count("make a file") == 1


def test_the_transcript_is_read_only_between_appends(tmp_path):
    """After every append the file is 0444 and the folder 0555; the exporter
    unlocks for its own write and locks again — so a plain rm or > from the
    agent's shell is refused, while the next export still gets through."""
    store = StateStore(str(tmp_path / "s.db"))
    sid = _seed(store)
    exporter = TranscriptExporter(tmp_path / "ws")
    exporter.export(store, "thread-a")

    target = exporter.path_for("thread-a")
    assert stat.S_IMODE(target.stat().st_mode) == 0o444
    assert stat.S_IMODE(exporter.directory.stat().st_mode) == 0o555
    assert exporter.is_locked("thread-a")
    if os.getuid() != 0:
        assert not os.access(target, os.W_OK)
        assert not os.access(exporter.directory, os.W_OK)

    store.append_message(sid, "user", {"role": "user", "content": "more"})
    assert exporter.export(store, "thread-a") == 1
    assert "more" in target.read_text(encoding="utf-8")
    assert stat.S_IMODE(target.stat().st_mode) == 0o444
    assert stat.S_IMODE(exporter.directory.stat().st_mode) == 0o555


def test_results_are_clipped_and_scrubbed(tmp_path):
    store = StateStore(str(tmp_path / "s.db"))
    sid = store.route("t")
    store.append_message(sid, "user", {"role": "user", "content": "run it"})
    store.append_message(
        sid,
        "tool",
        {"role": "tool", "tool_call_id": "c", "name": "run_command", "content": {"stdout": "x" * 5000}},
    )
    exporter = TranscriptExporter(tmp_path / "ws", scrub=lambda text: text.replace("run it", "[scrubbed]"))
    exporter.export(store, "t")
    text = exporter.path_for("t").read_text(encoding="utf-8")
    assert "[scrubbed]" in text and "run it" not in text
    assert "_[clipped: " in text
    assert text.count("x") < 2_100


def test_event_rows_are_one_line_without_blobs(tmp_path):
    rendered = render_row(
        "event",
        {"type": "file", "name": "report.csv", "data": "AAAA", "size": 3},
        created_at=0.0,
    )
    assert rendered.startswith("- **file**")
    assert "AAAA" not in rendered and "report.csv" in rendered


def test_thread_filename_is_safe():
    assert thread_filename("thread-1") == "thread-1.md"
    assert thread_filename("../etc/passwd") == "etc-passwd.md"
    assert thread_filename("") == "default.md"
