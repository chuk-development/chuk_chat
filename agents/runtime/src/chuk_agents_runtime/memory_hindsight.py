"""The Hindsight memory store (§12, ``memory.backend = hindsight``).

:class:`HindsightMemoryStore` has the same surface as the Mem0
:class:`~chuk_agents_runtime.memory.MemoryStore` — the loop, the tools and the
context ladder cannot tell them apart — and keeps its static persona files
(``soul.md``, ``agents.md``) exactly as they are. Only the semantic layer
changes. How each seam maps onto Hindsight:

=========================  =====================================================
``memory`` / ``memory_add``  ``retain`` (sync, so it is recallable at once),
                             ``context="note the agent chose to keep"``
``memory_search``            ``recall`` (``budget="mid"``)
``memory`` ``list``          ``memories/list``
task-start recall            ``recall`` (``budget="low"``, about 800 tokens),
                             only if ready inside the recall budget
``observe_turn``             async ``retain``, one document per turn
                             (``turn:<uuid>``), tagged ``session:<key>``,
                             ``observation_scopes="shared"``
ladder ``on_summary``        async ``retain`` (``summary:<digest>``: idempotent)
=========================  =====================================================

One bank per agent. The bank id is explicit (``memory_bank_id`` in
``build_runtime``) and falls back to a stable id derived from the workspace.
Subagents inherit the parent's bank.

Everything is best-effort, like the Mem0 store: a sidecar that is not up yet,
a dead proxy or an embedding-space mismatch turns every call into a logged
no-op (``status: memory_unavailable``) and never takes a run down.
"""

from __future__ import annotations

import datetime as _dt
import hashlib
import json
import logging
import os
import queue
import re
import stat
import subprocess
import sys
import threading
import time
import uuid
from collections.abc import Callable
from pathlib import Path
from typing import Any

from .memory import (
    AUTO_RECALL_TIMEOUT,
    MAX_ENTRY_CHARS,
    MAX_FILE_CHARS,
    RECALL_LIMIT,
    TURN_EXTRACT_CHARS,
    MemoryStore,
    MemoryToolError,
    _clip,
    _clip_tail,
)

logger = logging.getLogger(__name__)

BANK_MISSION = (
    "Long-term memory of an AI coworker that works for one person on that "
    "person's own machine. Keep what stays true after a task: the person's "
    "preferences and how they want things done, project facts, decisions, "
    "names, and open commitments. Skip small talk."
)
#: How long the explicit tools wait for a cold sidecar before answering
#: ``memory_unavailable``.
TOOL_READY_WAIT = 30.0
#: A sync retain runs the extraction LLM; give it room.
SYNC_RETAIN_TIMEOUT = 120.0
#: Background retains waiting for the sidecar. Beyond this the oldest is dropped.
RETAIN_QUEUE_MAX = 256
IMPORT_BATCH = 25
IMPORT_POLL_SECONDS = 2.0
IMPORT_TIMEOUT = 45 * 60.0

_BANK_SAFE = re.compile(r"[^a-z0-9_-]+")


def bank_id_for_workspace(workspace: str | Path | None) -> str | None:
    """The bank of the agent that works in ``workspace``: its directory name
    (already unique per agent: ``<name>-<digest>``) plus a short digest of the
    resolved path, so two installs that reuse a name never share a bank."""
    if not workspace:
        return None
    path = Path(workspace).expanduser().resolve()
    slug = _BANK_SAFE.sub("-", path.name.lower()).strip("-")[:40] or "agent"
    digest = hashlib.sha256(str(path).encode()).hexdigest()[:10]
    return f"{slug}-{digest}"


def bank_id_for_root(root: str | Path) -> str:
    """Fallback bank id for a memory root (``<workspace>/memory``)."""
    return bank_id_for_workspace(Path(root).expanduser().resolve().parent) or "agent"


def _now_iso() -> str:
    return _dt.datetime.now(_dt.timezone.utc).isoformat(timespec="seconds")


# -- the background retain worker (one per process) --------------------------------


class _RetainWorker:
    """One daemon thread that feeds async retains to the sidecar in order.

    ``observe_turn`` must never hold up an answer, and a cold sidecar may take
    a while to come up; the queue absorbs that. It is bounded: when it is full
    the oldest job is dropped (and counted), because a memory of a turn is
    worth less than a host that does not grow without limit.
    """

    def __init__(self) -> None:
        self._queue: queue.Queue[tuple[Callable[[], None], str]] = queue.Queue()
        self._thread: threading.Thread | None = None
        self._lock = threading.Lock()
        self.dropped = 0
        self.failed = 0
        self.done = 0

    def submit(self, job: Callable[[], None], label: str) -> None:
        with self._lock:
            while self._queue.qsize() >= RETAIN_QUEUE_MAX:
                try:
                    self._queue.get_nowait()
                    self._queue.task_done()
                    self.dropped += 1
                except queue.Empty:
                    break
            self._queue.put((job, label))
            if self._thread is None or not self._thread.is_alive():
                self._thread = threading.Thread(
                    target=self._run, name="hindsight-retain", daemon=True
                )
                self._thread.start()

    def _run(self) -> None:
        while True:
            job, label = self._queue.get()
            try:
                job()
                self.done += 1
            except Exception:  # noqa: BLE001 — a background job never raises
                self.failed += 1
                logger.warning("memory %s failed", label, exc_info=True)
            finally:
                self._queue.task_done()

    def drain(self, timeout: float) -> bool:
        """Wait until every queued job ran, at most ``timeout`` seconds."""
        deadline = time.monotonic() + max(0.0, timeout)
        while self._queue.unfinished_tasks:
            if time.monotonic() >= deadline:
                return False
            time.sleep(0.05)
        return True


_WORKER = _RetainWorker()
#: bank id -> (checked at, pending operations); see ``_backlog_full``.
_BACKLOG: dict[str, tuple[float, int]] = {}
BACKLOG_CACHE_SECONDS = 10.0


def drain_retains(timeout: float = 20.0) -> bool:
    """Let queued background retains reach the sidecar (executor teardown)."""
    return _WORKER.drain(timeout)


def retain_worker_stats() -> dict:
    return {"done": _WORKER.done, "failed": _WORKER.failed, "dropped": _WORKER.dropped}


# -- the store ---------------------------------------------------------------------


class HindsightMemoryStore(MemoryStore):
    """See the module docstring. ``service`` is the host's
    :class:`~chuk_agents_runtime.hindsight_service.HindsightService`; without
    one the store keeps the static files and the tools answer
    ``memory_unavailable``, and :attr:`automatic` is ``False``."""

    backend = "hindsight"

    def __init__(
        self,
        root: str | Path,
        *,
        bank_id: str | None = None,
        service: Any = None,
        seed_defaults: bool = True,
        max_entry_chars: int = MAX_ENTRY_CHARS,
        max_file_chars: int = MAX_FILE_CHARS,
        bank_name: str | None = None,
        llm_client: Any = None,
        auto_import: bool | None = None,
    ) -> None:
        super().__init__(
            root,
            llm_client=llm_client,
            seed_defaults=seed_defaults,
            max_entry_chars=max_entry_chars,
            max_file_chars=max_file_chars,
        )
        self.bank_id = bank_id or bank_id_for_root(root)
        self._service = service
        self._bank_name = bank_name or Path(root).expanduser().resolve().parent.name
        settings = getattr(service, "settings", None)
        self._recall_timeout = float(getattr(settings, "recall_timeout", AUTO_RECALL_TIMEOUT))
        self._recall_budget = str(getattr(settings, "recall_budget", "low"))
        self._recall_max_tokens = int(getattr(settings, "recall_max_tokens", 800))
        self._stamp = str(getattr(settings, "stamp_label", ""))
        # The one-shot Mem0 import on first use: ``None`` follows the service
        # settings (``memory.import_mem0``); tests turn it off to drive
        # :func:`migrate_mem0` themselves.
        self._auto_import = auto_import
        self._import_checked = False

    # -- availability --------------------------------------------------------

    @property
    def automatic(self) -> bool:
        """Automatic recall and turn capture: only with a service and a real
        backend model (one that can ``cheap_clone`` itself). A scripted mock —
        every unit test — gets the explicit tools only, exactly like the Mem0
        store, so no test ever starts a sidecar by accident."""
        service = self._service
        if service is None or getattr(service, "terminal", False):
            return False
        return callable(getattr(self._llm_client, "cheap_clone", None))

    def _memory(self):  # noqa: D401 — the Mem0 handle does not exist here
        return None

    def _api(self, wait: float, *, timeout: float | None = None):
        """The sidecar client with this agent's bank in place, or ``None``.
        ``timeout`` bounds the bank call too (the automatic recall path)."""
        service = self._service
        if service is None:
            return None
        try:
            if not service.wait_ready(wait):
                return None
            api = service.api()
            if api is None:
                return None
            api.ensure_bank(
                self.bank_id, name=self._bank_name, mission=BANK_MISSION, timeout=timeout
            )
        except Exception:  # noqa: BLE001 — best-effort: an unreachable sidecar is a no-op
            logger.warning("hindsight unavailable for bank %s", self.bank_id, exc_info=True)
            return None
        self._maybe_import(service)
        return api

    def _maybe_import(self, service: Any) -> None:
        if self._import_checked:
            return
        self._import_checked = True
        settings = getattr(service, "settings", None)
        enabled = (
            self._auto_import
            if self._auto_import is not None
            else bool(getattr(settings, "import_mem0", False))
        )
        if not enabled:
            return
        # The host's record first: once a bank had its one attempt, its
        # workspace folder is never looked at again.
        if import_recorded(_imports_dir(self), self.bank_id):
            return
        qdrant = self.root / getattr(settings, "qdrant_dirname", "qdrant")
        if mem0_import_pending(qdrant):
            start_mem0_import(
                self, qdrant, collection=getattr(settings, "mem0_collection", "cowork_memory")
            )

    def _item(self, content: str, *, context: str, source: str, document_id: str, **extra: Any) -> dict:
        metadata = {"source": source}
        if self._stamp:
            metadata["embed"] = self._stamp
        item: dict[str, Any] = {
            "content": content,
            "context": context,
            "document_id": document_id,
            "timestamp": _now_iso(),
            "metadata": metadata,
        }
        item.update({k: v for k, v in extra.items() if v is not None})
        return item

    # -- the explicit tools -------------------------------------------------

    def add(self, text: str) -> dict:
        entry = (text or "").strip()
        if not entry:
            raise MemoryToolError("nothing to add: text is empty")
        api = self._api(TOOL_READY_WAIT)
        if api is None:
            return {"ok": True, "action": "add", "status": "memory_unavailable"}
        item = self._item(
            _clip_tail(entry, TURN_EXTRACT_CHARS),
            context="note the agent chose to keep",
            source="tool",
            document_id=f"note:{uuid.uuid4().hex}",
        )
        try:
            api.retain(self.bank_id, [item], async_=False, timeout=SYNC_RETAIN_TIMEOUT)
        except Exception:  # noqa: BLE001 — best-effort
            logger.warning("memory add failed", exc_info=True)
            return {"ok": True, "action": "add", "status": "write_failed"}
        return {"ok": True, "action": "add", "stored": _clip(entry, 120)}

    def search(self, query: str, *, limit: int = 5, _wait: float = TOOL_READY_WAIT,
               _budget: str = "mid", _max_tokens: int = 2048,
               _timeout: float | None = None) -> dict:
        needle = (query or "").strip()
        if not needle:
            raise MemoryToolError("nothing to search: query is empty")
        api = self._api(_wait, timeout=_timeout)
        if api is None:
            return {"ok": True, "action": "search", "results": [], "status": "memory_unavailable"}
        # A foreground recall: the one-time ticket gives its query embedding
        # the reserved slots of the memory rate limit (the gateway strips it).
        ticket = ""
        issue = getattr(self._service, "recall_ticket", None)
        if callable(issue):
            try:
                ticket = issue() or ""
            except Exception:  # noqa: BLE001 — no ticket just means no priority
                ticket = ""
        try:
            rows = api.recall(
                self.bank_id, ticket + needle[:2_000], budget=_budget,
                max_tokens=_max_tokens, timeout=_timeout,
            )
        except Exception as exc:  # noqa: BLE001 — recall never breaks
            from .hindsight_service import HindsightError

            if isinstance(exc, HindsightError):
                # Method, path and error type only (a timeout is routine for
                # the bounded automatic recall); no traceback noise.
                logger.info("memory search failed: %s", exc)
            else:
                logger.warning("memory search failed", exc_info=True)
            return {"ok": True, "action": "search", "results": [], "status": "search_failed"}
        texts = [str(r.get("text") or "").strip() for r in rows]
        return {"ok": True, "action": "search", "results": [t for t in texts if t][: max(1, int(limit))]}

    def list(self, *, limit: int = 20) -> dict:
        api = self._api(TOOL_READY_WAIT)
        if api is None:
            return {"ok": True, "action": "list", "results": [], "status": "memory_unavailable"}
        try:
            rows = api.list_memories(self.bank_id, limit=limit)
        except Exception:  # noqa: BLE001
            logger.warning("memory list failed", exc_info=True)
            return {"ok": True, "action": "list", "results": [], "status": "list_failed"}
        texts = [str(r.get("text") or "").strip() for r in rows]
        return {"ok": True, "action": "list", "results": [t for t in texts if t][: max(1, int(limit))]}

    # -- automatic memory -------------------------------------------------------

    def recall_messages(self, query: str, *, limit: int = RECALL_LIMIT) -> list[dict]:
        needle = " ".join((query or "").split())
        if not needle:
            return []
        # Never wait for a cold sidecar here: the answer does not wait for
        # memory. The lookup itself kicks the start.
        # Bounded like the whole automatic recall: a slow sidecar must not
        # hold the process-wide recall slot for other agents.
        result = self.search(
            needle, limit=limit, _wait=0.0,
            _budget=self._recall_budget, _max_tokens=self._recall_max_tokens,
            _timeout=self._recall_timeout,
        )
        from .memory import RECALL_PREFIX, neutralize

        clean = [neutralize(str(n)).strip() for n in result.get("results") or []]
        clean = [n for n in clean if n]
        if not clean:
            return []
        body = "\n".join(f"- {_clip(n, 500)}" for n in clean)
        return [{"role_tag": "memory", "role": "user", "content": RECALL_PREFIX + body}]

    def recall_messages_bounded(
        self, query: str, *, limit: int = RECALL_LIMIT, timeout: float | None = None
    ) -> list[dict]:
        # A recall now costs one proxy embedding round trip, so the budget is
        # the configured one (1.5 s by default), not the Mem0 store's 250 ms.
        return super().recall_messages_bounded(
            query, limit=limit, timeout=self._recall_timeout if timeout is None else timeout
        )

    def _retain_async(self, item: dict, label: str, *, automatic: bool = True) -> None:
        service = self._service
        if service is None:
            return
        wait = float(getattr(getattr(service, "settings", None), "start_timeout", 180.0))

        def job() -> None:
            api = self._api(wait)
            if api is None:
                logger.info("memory %s skipped: hindsight unavailable", label)
                return
            if automatic and self._backlog_full(api):
                logger.debug("memory %s dropped: the retain backlog is full", label)
                _WORKER.dropped += 1
                return
            api.retain(self.bank_id, [item], async_=True)

        _WORKER.submit(job, label)

    def _backlog_full(self, api: Any) -> bool:
        """``True`` when the bank already has ``RETAIN_BACKLOG_CAP`` pending
        operations. The count is cached for a few seconds per bank."""
        from .hindsight_service import RETAIN_BACKLOG_CAP

        now = time.monotonic()
        cached = _BACKLOG.get(self.bank_id)
        if cached is None or now - cached[0] > BACKLOG_CACHE_SECONDS:
            counter = getattr(api, "pending_operations", None)
            try:
                count = int(counter(self.bank_id)) if callable(counter) else 0
            except Exception:  # noqa: BLE001 — unknown backlog: let the write through
                count = 0
            cached = _BACKLOG[self.bank_id] = (now, count)
        return cached[1] >= RETAIN_BACKLOG_CAP

    def _turn_item(self, user_message: str, final_answer: str | None, tool_names, session_key):
        prompt = (user_message or "").strip()
        answer = (final_answer or "").strip()
        if not prompt and not answer:
            return None
        lines: list[str] = []
        if prompt:
            lines.append("User: " + _clip_tail(prompt, TURN_EXTRACT_CHARS))
        if answer:
            text = _clip_tail(answer, TURN_EXTRACT_CHARS)
            if tool_names:
                text += "\n(tools used: " + ", ".join(dict.fromkeys(tool_names)) + ")"
            lines.append("Assistant: " + text)
        return self._item(
            "\n\n".join(lines),
            context="one finished task between the user and their AI coworker",
            source="turn",
            document_id=f"turn:{uuid.uuid4().hex}",
            tags=[f"session:{session_key}"] if session_key else None,
            observation_scopes="shared",
        )

    def remember_turn(self, user_message, final_answer, *, tool_names=(), session_key=None) -> dict:
        item = self._turn_item(user_message, final_answer, tool_names, session_key)
        if item is None:
            return {"ok": True, "action": "remember_turn", "status": "nothing_to_remember"}
        api = self._api(TOOL_READY_WAIT)
        if api is None:
            return {"ok": True, "action": "remember_turn", "status": "memory_unavailable"}
        try:
            api.retain(self.bank_id, [item], async_=False, timeout=SYNC_RETAIN_TIMEOUT)
        except Exception:  # noqa: BLE001
            logger.warning("memory remember_turn failed", exc_info=True)
            return {"ok": True, "action": "remember_turn", "status": "write_failed"}
        return {"ok": True, "action": "remember_turn", "stored": _clip(user_message or final_answer or "", 120)}

    def remember_summary(self, summary: str) -> dict:
        text = (summary or "").strip()
        if not text:
            return {"ok": True, "action": "remember_summary", "status": "nothing_to_remember"}
        digest = hashlib.sha256(text.encode()).hexdigest()[:16]
        item = self._item(
            "Summary of earlier work in this workspace (facts, decisions, files, "
            "blockers):\n" + _clip_tail(text, TURN_EXTRACT_CHARS * 2),
            context="compaction summary of an agent's earlier work",
            source="compaction",
            document_id=f"summary:{digest}",
            observation_scopes="shared",
        )
        self._retain_async(item, "remember_summary")
        return {"ok": True, "action": "remember_summary", "status": "queued"}

    def observe_turn(
        self,
        user_message: str,
        final_answer: str | None,
        *,
        tool_names: tuple[str, ...] | list[str] = (),
        wait: bool = False,
        session_key: str | None = None,
    ) -> threading.Thread | None:
        """Hand the turn to Hindsight without holding up the answer: an async
        retain on the process-wide worker. ``wait`` runs a sync retain inline
        (probes). Returns ``None`` either way (no per-turn thread)."""
        if wait:
            self.remember_turn(user_message, final_answer, tool_names=tool_names, session_key=session_key)
            return None
        item = self._turn_item(user_message, final_answer, tool_names, session_key)
        if item is not None:
            self._retain_async(item, "remember_turn")
        return None


# -- one-shot import of the Mem0 facts -----------------------------------------------
#
# The old store sits in ``<workspace>/memory/qdrant``, inside the folder the
# agent's sandbox can write. Everything about the import assumes the agent may
# have tampered with it:
#
# * the host never unpickles it — :func:`read_legacy_facts` runs
#   ``mem0_legacy_reader.py`` in a locked-down subprocess and parses only its
#   JSON;
# * the import runs at most ONCE per bank. The record lives in the host's own
#   state (``<state_home>/hindsight/imports.json``), written before the folder
#   is read; once a bank has a record, its workspace folder is never looked at
#   again, whatever appears there later;
# * nothing the workspace contains (claims, markers) is trusted: the lock is a
#   host file (``imports.lock``) and an in-process lock.

_IMPORTS_LOCK = threading.Lock()
_IMPORTS_RUNNING: set[str] = set()
_MARKER_LOCK = threading.Lock()
IMPORTS_FILE = "imports.json"
IMPORTS_LOCK_FILE = "imports.lock"
READER_SCRIPT = Path(__file__).with_name("mem0_legacy_reader.py")
READER_TIMEOUT = 120.0
READER_MAX_OUTPUT = 64 * 1024 * 1024
MAX_IMPORT_FACTS = 50_000
_COLLECTION_SAFE = re.compile(r"^[A-Za-z0-9_-]{1,128}$")


def _imports_dir(store: HindsightMemoryStore) -> Path | None:
    settings = getattr(store._service, "settings", None)  # noqa: SLF001
    data_dir = getattr(settings, "data_dir", None)
    return Path(data_dir) if data_dir else None


def load_import_records(data_dir: Path) -> dict:
    try:
        records = json.loads((Path(data_dir) / IMPORTS_FILE).read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {}
    except (OSError, ValueError):
        # An unreadable record must not turn into "never imported": the safe
        # reading is that every bank already had its one attempt.
        return {"*": {"status": "unreadable"}}
    return records if isinstance(records, dict) else {"*": {"status": "unreadable"}}


def import_recorded(data_dir: Path | None, bank_id: str) -> bool:
    if data_dir is None:
        return True  # no host state to record in: never import
    records = load_import_records(data_dir)
    return bank_id in records or "*" in records


def _write_record(data_dir: Path, bank_id: str, record: dict) -> None:
    """Merge one record into ``imports.json`` (atomic replace)."""
    path = Path(data_dir) / IMPORTS_FILE
    path.parent.mkdir(parents=True, exist_ok=True)
    records = load_import_records(data_dir)
    records[bank_id] = dict(record, at=_now_iso())
    tmp = path.with_suffix(".tmp")
    tmp.write_text(json.dumps(records, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(tmp, path)


class _HostLock:
    """The in-process lock plus an ``flock`` on a host file, so two host
    processes on one state directory never import the same bank twice."""

    def __init__(self, data_dir: Path) -> None:
        self._path = Path(data_dir) / IMPORTS_LOCK_FILE
        self._fd: int | None = None

    def __enter__(self) -> "_HostLock":
        import fcntl

        _MARKER_LOCK.acquire()
        try:
            self._path.parent.mkdir(parents=True, exist_ok=True)
            self._fd = os.open(self._path, os.O_RDWR | os.O_CREAT, 0o600)
            fcntl.flock(self._fd, fcntl.LOCK_EX)
        except BaseException:
            _MARKER_LOCK.release()
            raise
        return self

    def __exit__(self, *exc: object) -> None:
        try:
            if self._fd is not None:
                os.close(self._fd)  # closing drops the flock
        finally:
            self._fd = None
            _MARKER_LOCK.release()


def read_legacy_facts(
    workspace: Path, parts: list[str], *, python: str | None = None
) -> tuple[list[dict] | None, str]:
    """Run the untrusted-store reader in a subprocess. Returns ``(facts,
    "ok")``, ``([], "missing")`` or ``(None, <why it was refused>)``."""
    try:
        completed = subprocess.run(
            [python or sys.executable, "-I", "-S", "-B", str(READER_SCRIPT), str(workspace), *parts],
            env={},
            cwd="/",
            stdin=subprocess.DEVNULL,
            capture_output=True,
            timeout=READER_TIMEOUT,
            # No preexec_fn (unsafe in a threaded host): the reader sets its
            # own resource limits before it opens the store.
            start_new_session=True,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return None, "reader timed out"
    except OSError as exc:
        return None, f"reader did not start: {type(exc).__name__}"
    out = completed.stdout or b""
    if completed.returncode != 0:
        return None, f"reader exited {completed.returncode}"
    if len(out) > READER_MAX_OUTPUT:
        return None, "reader output too large"
    try:
        result = json.loads(out.decode("ascii"))
    except (UnicodeDecodeError, ValueError):
        return None, "reader output is not JSON"
    if not isinstance(result, dict) or result.get("ok") is not True:
        why = result.get("error") if isinstance(result, dict) else None
        return None, str(why or "reader refused the store")[:200]
    if result.get("missing"):
        return [], "missing"
    facts: list[dict] = []
    raw = result.get("facts")
    if not isinstance(raw, list) or len(raw) > MAX_IMPORT_FACTS:
        return None, "reader returned no usable facts"
    for fact in raw:
        if not isinstance(fact, dict):
            return None, "reader returned a malformed fact"
        text, created, fid = fact.get("text"), fact.get("created_at", ""), fact.get("id", "")
        if not isinstance(text, str) or not isinstance(created, str) or not isinstance(fid, str):
            return None, "reader returned a malformed fact"
        if text.strip():
            facts.append({"id": fid[:64], "text": text.strip()[:4_000], "created_at": created[:40]})
    facts.sort(key=lambda f: (f["created_at"], f["id"]))
    return facts, "ok"


def read_mem0_facts(qdrant_dir: Path, collection: str) -> list[dict]:
    """Every fact of a Mem0 Qdrant store, oldest first — through the sandboxed
    reader. Raises ``ValueError`` when the store is refused."""
    if not _COLLECTION_SAFE.match(collection):
        raise ValueError("refused collection name")
    qdrant_dir = Path(qdrant_dir)
    facts, why = read_legacy_facts(
        qdrant_dir.parent, [qdrant_dir.name, "collection", collection, "storage.sqlite"]
    )
    if facts is None:
        raise ValueError(why)
    return facts


def mem0_import_pending(qdrant_dir: Path) -> bool:
    """A real folder (not a symlink) waits at ``qdrant_dir``. Claims or other
    markers inside the workspace are never looked at."""
    try:
        info = os.lstat(qdrant_dir)
    except OSError:
        return False
    return stat.S_ISDIR(info.st_mode)


def import_items(facts: list[dict], *, batch: int = IMPORT_BATCH, stamp: str = "") -> list[dict]:
    """The retain items for an import: ``batch`` facts per item, with stable
    ``document_id`` values so a re-run replaces instead of duplicating."""
    items: list[dict] = []
    for n, start in enumerate(range(0, len(facts), batch)):
        chunk = facts[start : start + batch]
        lines = []
        for fact in chunk:
            day = fact["created_at"][:10]
            lines.append(f"- {fact['text']}" + (f" (noted {day})" if day else ""))
        newest = max((f["created_at"] for f in chunk if f["created_at"]), default="")
        metadata = {"source": "mem0-import"}
        if stamp:
            metadata["embed"] = stamp
        item: dict[str, Any] = {
            "content": "Facts remembered earlier about the user and their work, one per line:\n"
            + "\n".join(lines),
            "context": "facts imported from the agent's earlier memory store",
            "document_id": f"mem0-import:{n:04d}",
            "metadata": metadata,
            "observation_scopes": "shared",
        }
        if newest:
            item["timestamp"] = newest
        items.append(item)
    return items


def migrate_mem0(
    store: HindsightMemoryStore,
    qdrant_dir: Path,
    *,
    collection: str = "cowork_memory",
    reader: Callable[[Path, str], list[dict]] = read_mem0_facts,
    poll: float = IMPORT_POLL_SECONDS,
    timeout: float = IMPORT_TIMEOUT,
    today: Callable[[], str] | None = None,
) -> dict:
    """Import the old Mem0 facts of ``store``'s bank — at most once.

    The attempt is recorded in ``<state_home>/hindsight/imports.json`` BEFORE
    the folder is read, so a crash, a refusal or a failure never leads to a
    second read. The owner can delete the bank's entry to allow one more try.
    On success the folder is renamed to ``qdrant.migrated-<date>`` (the
    backup; the rename touches the directory entry only)."""
    qdrant_dir = Path(qdrant_dir)
    data_dir = _imports_dir(store)
    if data_dir is None:
        return {"status": "memory_unavailable"}
    # The lock covers only the claim: the checks and the "started" record.
    # Reading, importing and the folder move run without it; it is taken
    # again for the final record.
    with _HostLock(data_dir):
        if import_recorded(data_dir, store.bank_id):
            return {"status": "already_recorded"}
        if not mem0_import_pending(qdrant_dir):
            return {"status": "nothing_to_import"}
        api = store._api(TOOL_READY_WAIT)  # noqa: SLF001 — same module family
        if api is None:
            return {"status": "memory_unavailable"}
        _write_record(data_dir, store.bank_id, {"status": "started", "path": str(qdrant_dir)})
    try:
        facts = reader(qdrant_dir, collection)
    except Exception as exc:  # noqa: BLE001 — a refused store is recorded, never retried
        why = str(exc)[:200] or type(exc).__name__
        with _HostLock(data_dir):
            _write_record(data_dir, store.bank_id, {"status": "refused", "reason": why})
        logger.warning("mem0 import refused for bank %s: %s", store.bank_id, why)
        return {"status": "refused", "reason": why}
    report = _import_facts(store, api, facts, poll=poll, timeout=timeout)
    if report["status"] == "imported":
        stamp_day = (today or (lambda: _dt.date.today().strftime("%Y%m%d")))()
        target = qdrant_dir.with_name(f"{qdrant_dir.name}.migrated-{stamp_day}")
        suffix = 1
        while os.path.lexists(target):
            suffix += 1
            target = qdrant_dir.with_name(f"{qdrant_dir.name}.migrated-{stamp_day}-{suffix}")
        try:
            if mem0_import_pending(qdrant_dir):
                qdrant_dir.rename(target)
                report = dict(report, moved_to=str(target))
        except OSError:
            logger.warning("could not rename %s after the import", qdrant_dir, exc_info=True)
        logger.info("imported %d mem0 facts into bank %s", report["facts"], store.bank_id)
    with _HostLock(data_dir):
        _write_record(
            data_dir, store.bank_id, {k: v for k, v in report.items() if k != "operation"}
        )
    return report


def _import_facts(
    store: HindsightMemoryStore, api: Any, facts: list[dict], *, poll: float, timeout: float
) -> dict:
    items = import_items(facts, stamp=store._stamp)  # noqa: SLF001
    operations: list[str] = []
    for start in range(0, len(items), 4):
        response = api.retain(store.bank_id, items[start : start + 4], async_=True)
        ids = response.get("operation_ids") or (
            [response["operation_id"]] if response.get("operation_id") else []
        )
        operations.extend(str(i) for i in ids)
    deadline = time.monotonic() + timeout
    pending = list(operations)
    while pending:
        if time.monotonic() > deadline:
            return {"status": "timeout", "facts": len(facts), "pending": len(pending)}
        still: list[str] = []
        for op in pending:
            status = str(api.operation(store.bank_id, op).get("status") or "").lower()
            if status in ("failed", "error", "cancelled"):
                return {"status": "failed", "facts": len(facts), "operation": op}
            if status not in ("completed", "done", "succeeded", "success"):
                still.append(op)
        pending = still
        if pending:
            time.sleep(poll)
    return {"status": "imported", "facts": len(facts), "items": len(items)}


def start_mem0_import(store: HindsightMemoryStore, qdrant_dir: Path, *, collection: str) -> threading.Thread | None:
    """Run :func:`migrate_mem0` in the background, once per bank per process."""
    key = store.bank_id
    with _IMPORTS_LOCK:
        if key in _IMPORTS_RUNNING:
            return None
        _IMPORTS_RUNNING.add(key)

    def run() -> None:
        try:
            report = migrate_mem0(store, Path(qdrant_dir), collection=collection)
            logger.info("mem0 import for bank %s: %s", store.bank_id, report.get("status"))
        except Exception:  # noqa: BLE001 — an import failure is logged, not retried
            logger.warning("mem0 import failed for bank %s", store.bank_id, exc_info=True)
        finally:
            with _IMPORTS_LOCK:
                _IMPORTS_RUNNING.discard(key)

    thread = threading.Thread(target=run, name="mem0-import", daemon=True)
    thread.start()
    return thread


__all__ = [
    "BANK_MISSION",
    "HindsightMemoryStore",
    "bank_id_for_root",
    "bank_id_for_workspace",
    "drain_retains",
    "import_items",
    "import_recorded",
    "load_import_records",
    "mem0_import_pending",
    "migrate_mem0",
    "read_legacy_facts",
    "read_mem0_facts",
    "retain_worker_stats",
    "start_mem0_import",
]
