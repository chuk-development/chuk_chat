"""One place that sets up a connection to the host's shared SQLite state file.

The host opens a short-lived connection per operation (a task frame, a
document read, a skill toggle). Two SQLite defaults make that expensive on a
busy disk, and they cost on the serve thread before a task becomes a run:

* ``synchronous=FULL`` fsyncs the WAL on every commit. In WAL mode ``NORMAL``
  is the documented choice: a commit is durable against a crash of the
  process, and only a power cut can drop the last commits; the file is never
  corrupted. The fsync moves to the checkpoint.
* Closing the last connection checkpoints the WAL into the file and fsyncs it.
  With one connection per operation almost every close is the last one. The
  WAL is checkpointed by the automatic checkpoint (about every 1000 pages)
  instead.
"""

from __future__ import annotations

import contextlib
import sqlite3

__all__ = ["tune_connection"]


def tune_connection(conn: sqlite3.Connection) -> sqlite3.Connection:
    """Apply the settings above to ``conn`` and return it.

    Call it right after :func:`sqlite3.connect`, before any statement. Safe on
    a file that is not in WAL mode: ``synchronous=NORMAL`` then only means
    fewer fsyncs of the rollback journal, which is still crash-safe.
    """
    with contextlib.suppress(AttributeError, sqlite3.Error):
        conn.setconfig(sqlite3.SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE, True)
    conn.execute("PRAGMA synchronous=NORMAL;")
    return conn
