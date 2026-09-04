"""Two tasks, one workspace: does mem0 still work on the SECOND task?

    cd agent && uv run python tests/live_memory_two_tasks.py

The executor builds a fresh runtime — and with it a fresh :class:`MemoryStore`
and a fresh ``Memory.from_config`` — for every task, all on the same workspace,
so the embedded local-path Qdrant under ``<workspace>/memory/qdrant`` is opened
again per task. If that second open fails (a storage lock still held by the
first, not-yet-collected store), ``MemoryStore._memory()`` swallows the error
into a permanent no-op and memory silently dies after task 1 — the risk the
review flagged. This script reproduces the shape as harshly as possible: the
first store is kept ALIVE (a reference is held, as a lingering loop object
would) while the second one is built on the same root.

The writer LLM is a stub that returns mem0's expected JSON, so no model credits
are spent; the embedder is whatever ``memory.py`` picks (local fastembed when no
proxy key is configured). Not pytest-collected: it loads the embedding model,
which is far too heavy for the unit suite.
"""

from __future__ import annotations

import json
import tempfile
from pathlib import Path

from cowork_agent.memory import MemoryStore
from cowork_agent.model import ModelResponse


class _StubWriter:
    """A mem0-compatible fact extractor: always returns one fact as the JSON
    shape mem0's add() parses (``{"facts": [...]}``) and, for the update step,
    an ADD event. Deterministic and offline."""

    def complete(self, messages: list[dict]) -> ModelResponse:
        text = " ".join(str(m.get("content", "")) for m in messages)
        if '"memory"' in text or "old_memory" in text or "retrieved" in text.lower():
            # Update-phase prompt: keep it simple, add the new fact.
            return ModelResponse(
                text=json.dumps(
                    {"memory": [{"id": "0", "text": "codename BLUEFALCON", "event": "ADD"}]}
                )
            )
        return ModelResponse(text=json.dumps({"facts": ["The codename is BLUEFALCON"]}))


def main() -> int:
    root = Path(tempfile.mkdtemp(prefix="cowork_mem_twotask_")) / "memory"
    writer = _StubWriter()

    # -- task 1 -----------------------------------------------------------
    first = MemoryStore(str(root), llm_client=writer)
    m1 = first._memory()
    print(f"[task1] memory handle: {'OK' if m1 is not None else 'NONE (no-op!)'}")
    r1 = first.add("The codename is BLUEFALCON")
    print(f"[task1] add -> {r1}")

    # -- task 2: same root, first store still alive -----------------------
    second = MemoryStore(str(root), llm_client=writer)
    m2 = second._memory()
    print(f"[task2] memory handle (first still alive): {'OK' if m2 is not None else 'NONE (no-op!)'}")
    r2 = second.search("what is the codename")
    print(f"[task2] search -> {r2}")

    ok_handles = m1 is not None and m2 is not None
    ok_recall = bool(r2.get("results")) and r2.get("status") != "memory_unavailable"
    print(f"[live] second-task memory usable: {ok_handles}")
    print(f"[live] second-task recall of task-1 fact: {ok_recall}")
    print("[live] RESULT:", "PASS" if (ok_handles and ok_recall) else "FAIL")
    # Keep `first` referenced to the very end on purpose.
    del first
    return 0 if (ok_handles and ok_recall) else 1


if __name__ == "__main__":
    raise SystemExit(main())
