"""agents_hooks — the self-wake hook a watcher script imports.

The host copies this ONE file into ``<workspace>/.agents/automations/`` and
puts that directory on the watcher's ``PYTHONPATH``. It has no imports from
the agent package on purpose: it must run inside the sandbox, where the agent
package is not installed.

Usage in a watcher script::

    from agents_hooks import trigger

    if changed:
        trigger("new video", payload={"url": url, "title": title})

``trigger`` appends one JSON line to the trigger file. It does not talk to a
network or a socket. The host tails the file and starts a task in the
conversation that owns this watcher. The host folds triggers to at most one
task per 30 s per watcher and cuts a payload at 16 KB.
"""

from __future__ import annotations

import json
import os
import sys
import time

#: Set by the host on the watcher process. Without it there is no watcher to
#: wake, and ``trigger`` is a no-op that says so.
ENV_AUTOMATION_ID = "AGENTS_AUTOMATION_ID"
#: Where to append. Relative paths are resolved against the current directory,
#: which the host sets to the workspace.
ENV_TRIGGERS_PATH = "AGENTS_TRIGGERS_PATH"
DEFAULT_TRIGGERS_PATH = ".agents/automations/triggers.jsonl"

MAX_PAYLOAD_BYTES = 16 * 1024


def automation_id() -> str | None:
    """The id of the watcher this process runs as, or None outside one."""
    value = os.environ.get(ENV_AUTOMATION_ID, "").strip()
    return value or None


def triggers_path() -> str:
    return os.environ.get(ENV_TRIGGERS_PATH, "").strip() or DEFAULT_TRIGGERS_PATH


def trigger(reason: str, payload=None, *, kind: str = "automation") -> bool:
    """Wake the agent: start a task in this watcher's conversation.

    ``reason`` is a short text ("price under 100"). ``payload`` is any JSON
    value the task should see (a dict is best). Returns True when the line was
    written, False when this process is not a watcher or the write failed.

    ``kind`` names the consumer on the host: ``automation`` (default, a
    watcher wakes its conversation) or ``job`` (a background job of the
    terminal work reports back). The host routes the line by it.
    """
    aid = automation_id()
    if aid is None:
        sys.stderr.write(
            "agents_hooks.trigger: not running as a watcher "
            f"({ENV_AUTOMATION_ID} is not set); nothing sent\n"
        )
        return False
    record = {
        "automation_id": aid,
        "reason": str(reason)[:500],
        "payload": _cap(payload),
        "ts": time.time(),
        "kind": str(kind or "automation"),
    }
    line = json.dumps(record, ensure_ascii=False) + "\n"
    path = triggers_path()
    try:
        directory = os.path.dirname(path)
        if directory:
            os.makedirs(directory, exist_ok=True)
        # O_APPEND + one write: lines from several processes never interleave.
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
        try:
            data = line.encode("utf-8")
            if os.write(fd, data) != len(data):
                raise OSError("incomplete trigger write")
            os.fsync(fd)
        finally:
            os.close(fd)
    except OSError as exc:
        sys.stderr.write(f"agents_hooks.trigger: cannot write {path}: {exc}\n")
        return False
    return True


def _cap(payload, limit: int = MAX_PAYLOAD_BYTES):
    """Keep the line under the host's cap, so a huge payload cannot make the
    host skip the whole line."""
    try:
        encoded = json.dumps(payload, ensure_ascii=False)
    except (TypeError, ValueError):
        encoded = json.dumps(str(payload), ensure_ascii=False)
    raw = encoded.encode("utf-8")
    if len(raw) <= limit:
        return payload
    return {"truncated": True, "text": raw[: limit - 64].decode("utf-8", "ignore")}


__all__ = ["trigger", "automation_id", "triggers_path"]
