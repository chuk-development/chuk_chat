"""Read an old Mem0 Qdrant store without trusting it (§12 import).

The folder lives in an agent workspace, which the agent's sandbox can write.
Qdrant's local mode stores every point as a **pickle** — loading it with
``pickle.loads`` (what ``QdrantClient(path=…)`` does) would run code the agent
planted. So this file is never imported by the host. The host runs it as a
separate process (see :func:`chuk_agents_runtime.memory_hindsight.read_legacy_facts`):

* ``python -I -S -B`` — no site-packages, no ``.pth`` files, no environment
  variables, no bytecode writes; the script needs the standard library only;
* an empty environment (no token, no secrets), ``cwd=/`` and a timeout; the
  script sets its own resource limits (address space, CPU time, no file
  writes, no core dump) as the very first step of :func:`main`, before the
  store is opened. (Not ``preexec_fn`` in the host: forking a threaded host and
  running Python code before ``exec`` can deadlock.)
* the path is opened component by component with ``O_NOFOLLOW`` from the
  workspace root, so a symlink cannot point the reader at another agent's
  store or any other file;
* the points are unpickled with an allowlist: only Qdrant's ``PointStruct``
  and ``SparseVector`` names resolve, and both resolve to an inert stand-in
  class, never to the real code. Any other global (``os.system``,
  ``builtins.eval``, ...) aborts the whole read.

It prints one JSON object on stdout; the host parses nothing else.

    python -I -S -B mem0_legacy_reader.py <root> <part> [<part> ...]
"""

from __future__ import annotations

import io
import json
import os
import pickle
import re
import sqlite3
import stat
import sys

MAX_DB_BYTES = 256 * 1024 * 1024
LIMIT_MEM_BYTES = 768 * 1024 * 1024
LIMIT_CPU_SECONDS = 60
MAX_POINTS = 50_000
MAX_TEXT = 4_000
_PART = re.compile(r"^[A-Za-z0-9._-]{1,128}$")
#: The only globals a Qdrant point pickle may name (protocol 4+: STACK_GLOBAL).
_ALLOWED = {
    ("qdrant_client.http.models.models", "PointStruct"),
    ("qdrant_client.http.models.models", "SparseVector"),
}


class _Inert:
    """What an allowed Qdrant class resolves to: it keeps the pickled state
    and runs nothing."""

    def __new__(cls, *args, **kwargs):  # NEWOBJ calls cls.__new__(cls, *args)
        return object.__new__(cls)

    def __init__(self, *args, **kwargs) -> None:
        self.state = None

    def __setstate__(self, state) -> None:
        self.state = state


class _Point(_Inert):
    pass


class _Sparse(_Inert):
    pass


class RestrictedUnpickler(pickle.Unpickler):
    def find_class(self, module: str, name: str):
        if (module, name) in _ALLOWED:
            return _Point if name == "PointStruct" else _Sparse
        raise pickle.UnpicklingError(f"refused global {module}.{name}")

    def persistent_load(self, pid):  # noqa: ANN001
        raise pickle.UnpicklingError("persistent ids refused")


def safe_loads(blob: bytes):
    return RestrictedUnpickler(io.BytesIO(blob)).load()


def open_nofollow(root: str, parts: list[str]) -> int:
    """Open ``root/parts...`` refusing a symlink at every step."""
    for part in parts:
        if not _PART.match(part) or part in (".", ".."):
            raise ValueError(f"refused path part {part!r}")
    fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for i, part in enumerate(parts):
            last = i == len(parts) - 1
            flags = os.O_RDONLY | os.O_NOFOLLOW | (0 if last else os.O_DIRECTORY)
            nfd = os.open(part, flags, dir_fd=fd)
            os.close(fd)
            fd = nfd
    except BaseException:
        os.close(fd)
        raise
    return fd


def _payload(point: object) -> dict:
    state = getattr(point, "state", None)
    if isinstance(state, dict):
        fields = state.get("__dict__") if isinstance(state.get("__dict__"), dict) else state
        payload = fields.get("payload") if isinstance(fields, dict) else None
        point_id = fields.get("id") if isinstance(fields, dict) else None
        if isinstance(payload, dict):
            return {"payload": payload, "id": point_id}
    return {}


def read(root: str, parts: list[str]) -> dict:
    fd = open_nofollow(root, parts)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            return {"ok": False, "error": "not a regular file"}
        if info.st_size > MAX_DB_BYTES:
            return {"ok": False, "error": "store too large"}
        con = sqlite3.connect(f"file:/proc/self/fd/{fd}?mode=ro&immutable=1", uri=True)
        try:
            rows = con.execute("SELECT point FROM points LIMIT ?", (MAX_POINTS + 1,)).fetchall()
        finally:
            con.close()
    finally:
        os.close(fd)
    if len(rows) > MAX_POINTS:
        return {"ok": False, "error": "too many points"}
    facts = []
    for (blob,) in rows:
        if not isinstance(blob, (bytes, bytearray)):
            return {"ok": False, "error": "point is not a blob"}
        try:
            point = safe_loads(bytes(blob))
        except Exception as exc:  # noqa: BLE001 — one bad point refuses the store
            return {"ok": False, "error": f"refused point: {type(exc).__name__}: {str(exc)[:120]}"}
        entry = _payload(point)
        payload = entry.get("payload") or {}
        text = payload.get("data")
        if not isinstance(text, str) or not text.strip():
            continue
        created = payload.get("created_at")
        facts.append(
            {
                "id": str(entry.get("id"))[:64],
                "text": text.strip()[:MAX_TEXT],
                "created_at": created[:40] if isinstance(created, str) else "",
            }
        )
    return {"ok": True, "facts": facts}


def apply_limits() -> None:
    """Resource limits for this process; any failure aborts the read."""
    import resource

    resource.setrlimit(resource.RLIMIT_AS, (LIMIT_MEM_BYTES, LIMIT_MEM_BYTES))
    resource.setrlimit(resource.RLIMIT_CPU, (LIMIT_CPU_SECONDS, LIMIT_CPU_SECONDS))
    resource.setrlimit(resource.RLIMIT_FSIZE, (0, 0))
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))


def main(argv: list[str]) -> int:
    try:
        apply_limits()
    except Exception as exc:  # noqa: BLE001 — no limits, no read
        sys.stdout.write(json.dumps({"ok": False, "error": f"limits: {type(exc).__name__}"}))
        return 0
    if len(argv) < 3:
        print(json.dumps({"ok": False, "error": "usage"}))
        return 2
    try:
        result = read(argv[1], argv[2:])
    except FileNotFoundError:
        result = {"ok": True, "facts": [], "missing": True}
    except Exception as exc:  # noqa: BLE001 — the host only ever sees JSON
        result = {"ok": False, "error": f"{type(exc).__name__}: {str(exc)[:120]}"}
    sys.stdout.write(json.dumps(result, ensure_ascii=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
