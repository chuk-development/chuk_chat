"""The database copies hold plaintext conversations: they are private files."""

from __future__ import annotations

import os
import sqlite3
import stat

import pytest

from chuk_agents_bench import snapshot


@pytest.fixture
def source(tmp_path, monkeypatch):
    # Point the live state directory somewhere else, so the source is not live.
    monkeypatch.setenv("AGENTS_HOME", str(tmp_path / "live"))
    path = tmp_path / "src" / "state.db"
    path.parent.mkdir()
    conn = sqlite3.connect(path)
    conn.execute("CREATE TABLE messages (id INTEGER PRIMARY KEY, content TEXT)")
    conn.execute("INSERT INTO messages (content) VALUES ('secret conversation')")
    conn.commit()
    conn.close()
    return path


def _mode(path) -> int:
    return stat.S_IMODE(os.stat(path).st_mode)


def _content(path) -> list[str]:
    conn = sqlite3.connect(path)
    try:
        return [row[0] for row in conn.execute("SELECT content FROM messages")]
    finally:
        conn.close()


def test_snapshot_copy_is_mode_0600_even_with_an_open_umask(source, tmp_path):
    old = os.umask(0)
    try:
        dest = snapshot.snapshot(source, tmp_path / "out" / "copy.db")
    finally:
        os.umask(old)
    assert _mode(dest) == 0o600
    assert _content(dest) == ["secret conversation"]
    assert not (tmp_path / "out" / "copy.db.partial").exists()


def test_copy_file_is_mode_0600_and_replaces_an_old_copy(source, tmp_path):
    dest = tmp_path / "work" / "copy.db"
    dest.parent.mkdir()
    dest.write_bytes(b"")
    os.chmod(dest, 0o644)
    old = os.umask(0)
    try:
        out = snapshot.copy_file(source, dest)
    finally:
        os.umask(old)
    assert _mode(out) == 0o600
    assert _content(out) == ["secret conversation"]
