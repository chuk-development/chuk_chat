"""``send_file_to_user``: the agent-side half of pushing a produced file into
the chat thread.

What is pinned: the bytes reach the sink byte-exact (binary, multi-chunk), the
size ceiling is enforced before anything moves, the displayed name cannot carry
a path, a sink that raises becomes a normal tool failure, and the tool result
never carries the content — that would put the whole file into the prompt on
every following turn.
"""

from __future__ import annotations

import os

import pytest

from cowork_agent import (
    LocalEnvironment,
    SentFile,
    ToolRegistry,
    make_send_file_handler,
    register_send_file,
    render_tool_docs,
    sanitize_name,
)
from cowork_agent.files_out import MAX_FILE_BYTES
from cowork_agent.sandbox_io import CHUNK_BYTES


class Sink:
    def __init__(self, raises: Exception | None = None) -> None:
        self.received: list[SentFile] = []
        self.raises = raises

    def __call__(self, sent: SentFile) -> None:
        if self.raises is not None:
            raise self.raises
        self.received.append(sent)


def _handler(sink, **kwargs):
    return make_send_file_handler(LocalEnvironment(), sink, **kwargs)


def test_binary_content_reaches_the_sink_byte_exact(tmp_path):
    blob = os.urandom(CHUNK_BYTES * 2 + 77)
    path = tmp_path / "clip.bin"
    path.write_bytes(blob)
    sink = Sink()

    result = _handler(sink)(str(path))

    assert result["ok"] is True
    assert sink.received[0].data == blob
    assert sink.received[0].size == len(blob)


def test_mime_type_comes_from_the_name(tmp_path):
    path = tmp_path / "report.csv"
    path.write_text("a,b\n1,2\n", encoding="utf-8")
    sink = Sink()

    result = _handler(sink)(str(path))

    assert result["mime_type"] == "text/csv"
    assert sink.received[0].mime_type == "text/csv"


def test_unknown_extension_falls_back_to_octet_stream(tmp_path):
    path = tmp_path / "thing.zzz"
    path.write_bytes(b"data")
    sink = Sink()

    assert _handler(sink)(str(path))["mime_type"] == "application/octet-stream"


def test_result_never_carries_the_content(tmp_path):
    """The result goes into the prompt on every following turn (§7.9)."""
    path = tmp_path / "secretish.bin"
    path.write_bytes(b"CONTENT-MARKER" * 100)
    sink = Sink()

    result = _handler(sink)(str(path))

    flat = repr(result)
    assert "CONTENT-MARKER" not in flat
    assert "data" not in result
    assert result["bytes"] == 1400


def test_oversize_is_refused(tmp_path):
    path = tmp_path / "big.bin"
    path.write_bytes(b"x" * 5000)
    sink = Sink()

    result = _handler(sink, max_bytes=1000)(str(path))

    assert result["ok"] is False
    assert "over the 1000 byte limit" in result["error"]
    assert sink.received == []


def test_default_ceiling_is_the_documented_one():
    assert MAX_FILE_BYTES == 8 * 1024 * 1024


def test_a_raising_sink_is_a_tool_failure_not_a_crash(tmp_path):
    path = tmp_path / "a.txt"
    path.write_bytes(b"hi")
    sink = Sink(raises=ValueError("file is over the event limit"))

    result = _handler(sink)(str(path))

    assert result["ok"] is False
    assert "could not send" in result["error"]
    assert "over the event limit" in result["error"]


def test_missing_file(tmp_path):
    sink = Sink()
    result = _handler(sink)(str(tmp_path / "nope.txt"))

    assert result["ok"] is False
    assert sink.received == []


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ("/etc/passwd", "passwd"),
        ("../../escape.txt", "escape.txt"),
        ("dir/sub/report.pdf", "report.pdf"),
        ("C:\\Windows\\evil.exe", "evil.exe"),
        ("bad\nname\ttab.txt", "bad_name_tab.txt"),
        ("..", "fallback"),
        ("", "fallback"),
        ("   ", "fallback"),
    ],
)
def test_name_sanitizing(raw, expected):
    assert sanitize_name(raw, fallback="fallback") == expected


def test_shown_name_never_contains_a_separator(tmp_path):
    path = tmp_path / "in.txt"
    path.write_bytes(b"hi")
    sink = Sink()

    result = _handler(sink)(str(path), name="../../../etc/shadow")

    assert result["name"] == "shadow"
    assert "/" not in sink.received[0].name


def test_long_name_is_capped(tmp_path):
    path = tmp_path / "in.txt"
    path.write_bytes(b"hi")
    sink = Sink()

    result = _handler(sink)(str(path), name="x" * 400 + ".txt")

    assert len(result["name"]) <= 120
    assert result["name"].endswith(".txt")


def test_registered_only_with_a_sink():
    with_sink = ToolRegistry()
    register_send_file(with_sink, LocalEnvironment(), Sink())
    assert with_sink.has("send_file_to_user")
    assert "send_file_to_user" in render_tool_docs(with_sink)

    without = ToolRegistry()
    register_send_file(without, LocalEnvironment(), None)
    assert not without.has("send_file_to_user")
    assert "send_file_to_user" not in render_tool_docs(without)
