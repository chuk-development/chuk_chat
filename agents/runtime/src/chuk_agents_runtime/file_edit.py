"""Paginated read, literal edit and the read-before-edit guard (research
docs/research/DEEPSEEK_HARNESS_IDEAS.md items 32, 34, 35).

- ``read_file`` returns a window of lines (``offset`` 1-based, ``limit``
  default 2000), each line capped, with a footer that says how to go on.
- ``edit_file`` replaces one literal ``old_string`` (or every match with
  ``replace_all``). CRLF files are matched in LF form and written back in CRLF.
- The guard keeps, per session, the version (mtime, size, sha256) of every
  file the agent read or wrote. An edit, or a write over an existing file,
  needs such a version and the file must still have it. A write to a path the
  agent never saw only creates; it never overwrites.

All file I/O goes through :meth:`Environment.run_bash`, like the other file
tools, so the same code runs in the local stand-in and in the sandbox.
"""

from __future__ import annotations

import base64
import difflib
import hashlib
import shlex
import threading
from collections import OrderedDict
from dataclasses import dataclass

from .environment import Environment
from .sandbox_io import TransferError, fetch_bytes, workspace_path

#: Default and ceiling of lines one read returns.
DEFAULT_READ_LINES = 2000
MAX_READ_LINES = 5000
#: Characters one line may carry back; a longer line is cut with a note.
MAX_LINE_CHARS = 2000
#: Byte cap of one read window (the old ``read_file`` cap).
READ_WINDOW_BYTES = 60_000
#: Largest file the edit tools load whole.
MAX_EDIT_BYTES = 8 * 1024 * 1024
#: Base64 characters per write command (keeps one argument well under the
#: kernel's 128 KiB single-argument limit).
WRITE_CHUNK_CHARS = 64_000
#: Sessions the guard keeps observations for, oldest dropped first.
MAX_SESSIONS = 256


@dataclass(frozen=True)
class FileVersion:
    mtime: str
    size: int
    sha256: str


class FileObservations:
    """The versions one session has seen. Thread-safe."""

    def __init__(self) -> None:
        self._seen: dict[str, FileVersion] = {}
        self._lock = threading.Lock()

    def get(self, path: str) -> FileVersion | None:
        with self._lock:
            return self._seen.get(path)

    def put(self, path: str, version: FileVersion | None) -> None:
        with self._lock:
            if version is None:
                self._seen.pop(path, None)
            else:
                self._seen[path] = version


_SESSIONS: "OrderedDict[str, FileObservations]" = OrderedDict()
_SESSIONS_LOCK = threading.Lock()


def observations_for(session_key: str | None) -> FileObservations:
    """The observation set of one session. ``None`` gets a fresh private set
    (a runtime without a session remembers only within itself)."""
    if not session_key:
        return FileObservations()
    with _SESSIONS_LOCK:
        found = _SESSIONS.get(session_key)
        if found is None:
            found = FileObservations()
            _SESSIONS[session_key] = found
            while len(_SESSIONS) > MAX_SESSIONS:
                _SESSIONS.popitem(last=False)
        else:
            _SESSIONS.move_to_end(session_key)
        return found


# -- shell helpers -------------------------------------------------------------


def _quoted(env: Environment, path: str) -> str:
    return shlex.quote(workspace_path(env, path))


def stat_version(env: Environment, path: str) -> FileVersion | None:
    """The version of a regular file, or ``None`` when it does not exist."""
    q = _quoted(env, path)
    result = env.run_bash(
        f"test -f {q} || exit 3; stat -c '%y|%s' -- {q} && sha256sum -- {q}",
        timeout=60,
        internal=True,
    )
    if result.exit_code == 3 or not result.ok:
        return None
    lines = [line for line in (result.stdout or "").splitlines() if line.strip()]
    if len(lines) < 2 or "|" not in lines[0]:
        return None
    mtime, _, size = lines[0].rpartition("|")
    digest = lines[1].split()[0] if lines[1].split() else ""
    try:
        return FileVersion(mtime=mtime, size=int(size), sha256=digest)
    except ValueError:
        return None


def path_exists(env: Environment, path: str) -> bool:
    result = env.run_bash(f"test -e {_quoted(env, path)}", timeout=30, internal=True)
    return result.ok


def load_text(env: Environment, path: str) -> str:
    """The whole file as text. Raises :class:`TransferError`."""
    size_probe = env.run_bash(
        f"test -f {_quoted(env, path)} && wc -c < {_quoted(env, path)}", timeout=30, internal=True
    )
    if not size_probe.ok:
        raise TransferError(f"not a readable file: {path}")
    if (size_probe.stdout or "").strip() == "0":
        return ""
    data = fetch_bytes(env, path, max_bytes=MAX_EDIT_BYTES).data
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        raise TransferError(f"{path} is not UTF-8 text") from None


def store_text(env: Environment, path: str, text: str) -> str | None:
    """Write ``text`` to ``path`` through a temp file and an atomic rename.
    Returns an error text, or ``None`` on success."""
    payload = base64.b64encode(text.encode("utf-8")).decode("ascii")
    target = _quoted(env, path)
    tmp = shlex.quote(workspace_path(env, path) + ".agents-tmp")
    chunks = [payload[i : i + WRITE_CHUNK_CHARS] for i in range(0, len(payload), WRITE_CHUNK_CHARS)] or [""]
    first = (
        f'mkdir -p -- "$(dirname -- {target})" && '
        f"printf %s {shlex.quote(chunks[0])} > {tmp}.b64"
    )
    result = env.run_bash(first, timeout=60, internal=True)
    for chunk in chunks[1:]:
        if not result.ok:
            break
        result = env.run_bash(f"printf %s {shlex.quote(chunk)} >> {tmp}.b64", timeout=60, internal=True)
    if result.ok:
        result = env.run_bash(
            f"base64 -d {tmp}.b64 > {tmp} && rm -f {tmp}.b64 && "
            f"{{ chmod --reference={target} {tmp} 2>/dev/null; true; }} && mv -f {tmp} {target}",
            timeout=60,
            internal=True,
        )
    if not result.ok:
        env.run_bash(f"rm -f {tmp} {tmp}.b64", timeout=30, internal=True)
        return (result.stderr or result.stdout or "write failed").strip()[:2000]
    return None


# -- the guard -----------------------------------------------------------------


def _not_read(path: str) -> str:
    return f"cannot modify {path}: file has not been read — read the file, then retry"


def _changed(path: str) -> str:
    return f"cannot modify {path}: file changed since it was read — re-read the file, then retry"


class EditGuard:
    """Compare-and-swap on observed versions for one session."""

    def __init__(self, env: Environment, observations: FileObservations | None = None) -> None:
        self.env = env
        self.seen = observations or FileObservations()

    def key(self, path: str) -> str:
        return workspace_path(self.env, path)

    def observe(self, path: str) -> FileVersion | None:
        version = stat_version(self.env, path)
        self.seen.put(self.key(path), version)
        return version

    def check_modify(self, path: str) -> str | None:
        """An error text when ``path`` may not be changed now."""
        prior = self.seen.get(self.key(path))
        if prior is None:
            return _not_read(path)
        current = stat_version(self.env, path)
        if current is None or current.sha256 != prior.sha256 or current.size != prior.size:
            return _changed(path)
        return None

    def check_write(self, path: str) -> str | None:
        """``write_file``: an existing file needs a prior read and an
        unchanged version; a path never seen only creates."""
        prior = self.seen.get(self.key(path))
        if prior is None:
            if path_exists(self.env, path):
                return (
                    f"cannot modify {path}: file has not been read — read the file, then retry "
                    "(write_file only creates a file you have not read)"
                )
            return None
        return self.check_modify(path)


# -- read_file -----------------------------------------------------------------


def _cut_line(line: str) -> str:
    if len(line) > MAX_LINE_CHARS:
        return f"{line[:MAX_LINE_CHARS]}... (line truncated to {MAX_LINE_CHARS} chars)"
    return line


def read_window(
    env: Environment,
    path: str,
    *,
    offset: int = 1,
    limit: int = DEFAULT_READ_LINES,
    max_bytes: int = READ_WINDOW_BYTES,
    guard: EditGuard | None = None,
) -> dict:
    try:
        start = max(1, int(offset))
    except (TypeError, ValueError):
        start = 1
    try:
        count = max(1, min(int(limit), MAX_READ_LINES))
    except (TypeError, ValueError):
        count = DEFAULT_READ_LINES
    try:
        cap = max(1, min(int(max_bytes), READ_WINDOW_BYTES))
    except (TypeError, ValueError):
        cap = READ_WINDOW_BYTES
    q = _quoted(env, path)
    end = start + count - 1
    # Line count first (one line), then the window, cut to the byte cap + 1.
    script = (
        f"test -f {q} || {{ ls -- {q} >/dev/null || true; echo 'not a readable file' >&2; exit 2; }}; "
        f"awk 'END {{ print NR }}' {q} && "
        f"sed -n '{start},{end}p' {q} | head -c {cap + 1}"
    )
    result = env.run_bash(script, timeout=60)
    if not result.ok:
        return {"ok": False, "path": path, "error": (result.stderr or "read failed").strip()[:2000]}
    head, _, body = (result.stdout or "").partition("\n")
    try:
        total = int(head.strip())
    except ValueError:
        total = 0
    if total == 0 and start == 1:
        if guard is not None:
            guard.observe(path)
        return {
            "ok": True,
            "path": path,
            "content": "",
            "truncated": False,
            "total_lines": 0,
            "footer": "(End of file - total 0 lines)",
        }
    if start > total:
        return {
            "ok": False,
            "path": path,
            "error": f"offset {start} is past the end of {path} ({total} lines)",
            "total_lines": total,
        }
    raw = body.encode("utf-8", "replace")
    cut = len(raw) > cap
    if cut:
        body = raw[:cap].decode("utf-8", "ignore")
    lines = body.split("\n")
    if body.endswith("\n"):
        lines = lines[:-1]
    shown_lines = [_cut_line(line) for line in lines]
    long_lines = any(len(line) > MAX_LINE_CHARS for line in lines)
    content = "\n".join(shown_lines)
    if body.endswith("\n") or (not cut and start + len(lines) - 1 < total):
        content += "\n"
    last = start + max(len(lines), 1) - 1
    if cut and lines:
        # The last line may be partial: continue from it.
        footer = (
            f"(Output cut at {cap} bytes. Showing lines {start}-{last} of {total}. "
            f"Use offset={last} to continue.)"
        )
    elif last < total:
        footer = f"(Showing lines {start}-{last} of {total}. Use offset={last + 1} to continue.)"
    else:
        footer = f"(End of file - total {total} lines)"
    if guard is not None:
        guard.observe(path)
    out = {
        "ok": True,
        "path": path,
        "content": content,
        "truncated": bool(cut or last < total or long_lines),
        "start_line": start,
        "end_line": last,
        "total_lines": total,
        "footer": footer,
    }
    return out


# -- edit_file -----------------------------------------------------------------


def unified_diff(path: str, before: str, after: str, *, limit: int = 20_000) -> str:
    text = "".join(
        difflib.unified_diff(
            before.splitlines(keepends=True),
            after.splitlines(keepends=True),
            fromfile=f"a/{path}",
            tofile=f"b/{path}",
            n=3,
        )
    )
    return text if len(text) <= limit else text[:limit] + "\n... (diff cut)\n"


def edit_text(text: str, old: str, new: str, replace_all: bool, path: str) -> tuple[str | None, str | None, int]:
    """``(new_text, error, count)``. CRLF text is matched in LF form."""
    crlf = "\r\n" in text
    work = text.replace("\r\n", "\n") if crlf else text
    old_n = old.replace("\r\n", "\n") if crlf else old
    new_n = new.replace("\r\n", "\n") if crlf else new
    count = work.count(old_n)
    if count == 0:
        return None, f"old_string was not found in {path}", 0
    if count > 1 and not replace_all:
        return (
            None,
            f"old_string matched {count} times in {path}; provide a more specific "
            "old_string or set replace_all to true",
            count,
        )
    result = work.replace(old_n, new_n) if replace_all else work.replace(old_n, new_n, 1)
    if crlf:
        result = result.replace("\n", "\r\n")
    return result, None, count if replace_all else 1


def edit_file(
    env: Environment,
    guard: EditGuard,
    path: str,
    old_string: str,
    new_string: str,
    replace_all: bool = False,
) -> dict:
    if not isinstance(path, str) or not path.strip():
        return {"ok": False, "error": "path must not be empty"}
    if not isinstance(old_string, str) or old_string == "":
        return {"ok": False, "path": path, "error": "old_string must not be empty"}
    if not isinstance(new_string, str):
        return {"ok": False, "path": path, "error": "new_string must be a string"}
    if old_string == new_string:
        return {"ok": False, "path": path, "error": "old_string and new_string must differ"}
    refused = guard.check_modify(path)
    if refused:
        return {"ok": False, "path": path, "error": refused}
    try:
        before = load_text(env, path)
    except TransferError as exc:
        return {"ok": False, "path": path, "error": str(exc)}
    after, error, count = edit_text(before, old_string, new_string, bool(replace_all), path)
    if error:
        return {"ok": False, "path": path, "error": error}
    failed = store_text(env, path, after)
    if failed:
        return {"ok": False, "path": path, "error": failed}
    guard.observe(path)
    return {
        "ok": True,
        "path": path,
        "replacements": count,
        "message": (
            f"The file {path} has been updated. All occurrences were replaced."
            if replace_all
            else f"The file {path} has been updated."
        ),
        # For the app's diff card; the model does not need it to go on.
        "_ui": {"diff": unified_diff(path, before, after)},
    }
