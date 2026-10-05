"""A consistent copy of the live state database.

The host writes ``executor-state.db`` in WAL mode while it runs. A plain ``cp``
of the main file can miss the newest pages (they sit in the ``-wal`` file) or
copy a torn page. SQLite's online backup API copies a consistent snapshot, so
it is used here.

The rules for the live file:

- Open it read-only (``mode=ro``), with a short busy timeout.
- Copy, then close at once. No handle stays open on the live file.
- Every other part of the bench reads the COPY, never the live file.
"""

from __future__ import annotations

import os
import sqlite3
import time
from pathlib import Path

#: The file name the host gives its state database.
STATE_DB_NAME = "executor-state.db"

#: How long the backup waits for a lock before it gives up, in seconds.
BUSY_TIMEOUT_S = 5.0


def live_state_dir() -> Path:
    """The host state directory: ``$AGENTS_HOME``, else
    ``$XDG_DATA_HOME/chuk-agents``, else ``~/.local/share/chuk-agents``."""
    explicit = os.environ.get("AGENTS_HOME")
    if explicit:
        return Path(explicit).expanduser()
    data_home = os.environ.get("XDG_DATA_HOME") or str(Path.home() / ".local" / "share")
    return Path(data_home).expanduser() / "chuk-agents"


def live_db_path() -> Path:
    return live_state_dir() / STATE_DB_NAME


def repo_root() -> Path:
    """The chuk_chat checkout this package lives in (``agents/bench/src/...``)."""
    return Path(__file__).resolve().parents[4]


def default_scratch_dir() -> Path:
    """``<repo>/_scratch/bench``. ``_scratch/`` is git-ignored. Outside a
    checkout (a non-editable install) it is ``./_scratch/bench``."""
    root = repo_root()
    if not (root / ".git").exists():
        root = Path.cwd()
    return root / "_scratch" / "bench"


def is_live_path(path: str | os.PathLike) -> bool:
    """True when ``path`` is inside the live state directory."""
    try:
        resolved = Path(path).expanduser().resolve()
        live = live_state_dir().resolve()
    except OSError:
        return False
    return resolved == live or live in resolved.parents


def snapshot(
    source: str | os.PathLike | None = None,
    dest: str | os.PathLike | None = None,
) -> Path:
    """Copy ``source`` (default: the live state DB) to ``dest`` (default:
    ``<repo>/_scratch/bench/executor-state.db``) and return ``dest``.

    The source handle is read-only and closed before this returns, even when
    the copy fails.
    """
    src_path = Path(source).expanduser() if source else live_db_path()
    if not src_path.is_file():
        raise FileNotFoundError(f"no state database at {src_path}")
    dst_path = Path(dest).expanduser() if dest else default_scratch_dir() / STATE_DB_NAME
    if is_live_path(dst_path):
        raise ValueError(f"refusing to write a copy into the live state directory: {dst_path}")
    dst_path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = dst_path.with_name(dst_path.name + ".partial")
    _drop_sidecars(tmp_path)
    _create_private(tmp_path)

    src = sqlite3.connect(
        f"file:{src_path}?mode=ro", uri=True, timeout=BUSY_TIMEOUT_S
    )
    try:
        dst = sqlite3.connect(str(tmp_path))
        try:
            src.backup(dst)
        finally:
            dst.close()
    finally:
        src.close()
    # The copy is a plain rollback-journal file: no -wal beside it to lose.
    conn = sqlite3.connect(str(tmp_path))
    try:
        conn.execute("PRAGMA journal_mode=DELETE")
    finally:
        conn.close()
    _drop_sidecars(dst_path)
    os.replace(tmp_path, dst_path)
    return dst_path


def _create_private(path: Path) -> None:
    """Create ``path`` as an empty file with mode 0600 before SQLite writes it.

    The copy holds the user's conversations in plain text. SQLite opens an
    existing (empty) file as it is and gives its journal the same mode, so
    no other user can read the copy at any time."""
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    try:
        os.fchmod(fd, 0o600)
    finally:
        os.close(fd)


def _drop_sidecars(path: Path) -> None:
    """Delete ``path`` and its ``-wal`` / ``-shm`` files. A stale ``-wal``
    beside a replaced database would be replayed into the new file."""
    for suffix in ("", "-wal", "-shm", "-journal"):
        candidate = Path(str(path) + suffix)
        if candidate.exists():
            candidate.unlink()


def ensure_copy(db: str | os.PathLike | None, *, fresh: bool = False) -> Path:
    """The database path a bench mode should read.

    - ``db`` is ``None``: use the default copy; take it (from the live DB) when
      it is missing or ``fresh`` is set.
    - ``db`` points into the live state directory: never read it in place,
      take a fresh copy of it instead.
    - any other ``db``: use it as it is.
    """
    if db is None:
        target = default_scratch_dir() / STATE_DB_NAME
        if fresh or not target.is_file():
            return snapshot(None, target)
        return target
    if is_live_path(db):
        return snapshot(db, default_scratch_dir() / STATE_DB_NAME)
    path = Path(db).expanduser()
    if not path.is_file():
        raise FileNotFoundError(f"no database at {path}")
    return path


def copy_file(source: str | os.PathLike, dest: str | os.PathLike) -> Path:
    """A working copy of a database COPY (not the live file), through the
    backup API so a half-written source is never copied byte for byte."""
    if is_live_path(source):
        raise ValueError("copy_file is for bench copies; use snapshot() for the live DB")
    dst_path = Path(dest)
    dst_path.parent.mkdir(parents=True, exist_ok=True)
    _drop_sidecars(dst_path)
    _create_private(dst_path)
    src = sqlite3.connect(f"file:{Path(source)}?mode=ro", uri=True, timeout=BUSY_TIMEOUT_S)
    try:
        dst = sqlite3.connect(str(dst_path))
        try:
            src.backup(dst)
        finally:
            dst.close()
    finally:
        src.close()
    return dst_path


def age_text(path: str | os.PathLike) -> str:
    """``taken 3m ago`` for a copy, so a report never hides that it is stale."""
    try:
        age = time.time() - Path(path).stat().st_mtime
    except OSError:
        return "age unknown"
    if age < 90:
        return f"taken {age:.0f}s ago"
    if age < 5400:
        return f"taken {age / 60:.0f}m ago"
    return f"taken {age / 3600:.1f}h ago"
