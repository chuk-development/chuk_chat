"""Getting bytes back out of the sandbox is the shared floor under
``read_document`` and ``send_file_to_user``, so it is tested on its own.

What is pinned: an exact byte-for-byte round trip through a real shell for
content that is binary, larger than one chunk, and not a multiple of the chunk
size; that the size ceiling is checked *before* any byte moves; and that a
truncated command output — the sandbox bounds captured output at 100 000 chars —
is an error rather than a silently short file.
"""

from __future__ import annotations

import os

import pytest

from cowork_agent import (
    LocalEnvironment,
    ProcessResult,
    TransferError,
    fetch_bytes,
    stat_file,
)
from cowork_agent.sandbox_io import CHUNK_BYTES


class TruncatingEnvironment:
    """A ``LocalEnvironment`` whose stdout is cut at ``limit`` characters — what
    the real sandbox does to any command that talks too much."""

    def __init__(self, limit: int) -> None:
        self._inner = LocalEnvironment()
        self._limit = limit

    def run_bash(self, cmd: str, *, timeout: int = 120) -> ProcessResult:
        result = self._inner.run_bash(cmd, timeout=timeout)
        return ProcessResult(
            exit_code=result.exit_code,
            stdout=result.stdout[: self._limit],
            stderr=result.stderr,
            duration_s=result.duration_s,
            timed_out=result.timed_out,
        )


class CountingEnvironment:
    """Records every command so a test can prove what did *not* run."""

    def __init__(self) -> None:
        self._inner = LocalEnvironment()
        self.commands: list[str] = []

    def run_bash(self, cmd: str, *, timeout: int = 120) -> ProcessResult:
        self.commands.append(cmd)
        return self._inner.run_bash(cmd, timeout=timeout)


def test_round_trip_is_byte_exact_across_chunks(tmp_path):
    # Binary, multi-chunk, and deliberately not a chunk multiple.
    blob = os.urandom(CHUNK_BYTES * 2 + 1234)
    path = tmp_path / "payload.bin"
    path.write_bytes(blob)

    fetched = fetch_bytes(LocalEnvironment(), str(path))

    assert fetched.size == len(blob)
    assert fetched.data == blob


def test_round_trip_survives_shell_hostile_content(tmp_path):
    blob = b"$(rm -rf /) `id` 'quote\" \\ \n\x00\xff end"
    path = tmp_path / "nasty.txt"
    path.write_bytes(blob)

    assert fetch_bytes(LocalEnvironment(), str(path)).data == blob


def test_path_with_spaces_and_quotes(tmp_path):
    path = tmp_path / "a file 'with' \"quotes\".txt"
    path.write_bytes(b"ok")

    assert fetch_bytes(LocalEnvironment(), str(path)).data == b"ok"


def test_oversize_is_refused_before_any_transfer(tmp_path):
    path = tmp_path / "big.bin"
    path.write_bytes(b"x" * 5000)
    env = CountingEnvironment()

    with pytest.raises(TransferError) as excinfo:
        fetch_bytes(env, str(path), max_bytes=1000)

    assert "over the" in str(excinfo.value)
    # Exactly one command: the measurement. Nothing was read.
    assert len(env.commands) == 1
    assert "wc -c" in env.commands[0]


def test_truncated_output_is_an_error_not_a_short_file(tmp_path):
    blob = os.urandom(CHUNK_BYTES)
    path = tmp_path / "payload.bin"
    path.write_bytes(blob)

    # Half of the base64 of one chunk: a cut that keeps the data plausible.
    env = TruncatingEnvironment(limit=CHUNK_BYTES)

    with pytest.raises(TransferError) as excinfo:
        fetch_bytes(env, str(path))

    assert "truncated" in str(excinfo.value) or "expected" in str(excinfo.value)


def test_missing_file(tmp_path):
    with pytest.raises(TransferError):
        fetch_bytes(LocalEnvironment(), str(tmp_path / "nope.bin"))


def test_directory_is_not_a_file(tmp_path):
    with pytest.raises(TransferError):
        stat_file(LocalEnvironment(), str(tmp_path))


def test_empty_file_is_refused(tmp_path):
    path = tmp_path / "empty.txt"
    path.write_bytes(b"")

    with pytest.raises(TransferError) as excinfo:
        fetch_bytes(LocalEnvironment(), str(path))

    assert "empty" in str(excinfo.value)
