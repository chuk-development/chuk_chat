"""Live proof of the automatic memory (bead cowork-2tq.3): a fact stated in
task 1 is recalled — without any tool call by the model — at the start of
task 2, through the real Mem0 store (embedded Qdrant + the configured
embedder; local fastembed when no proxy key is set).

    cd agent && MEMGUARD_ALLOW_MB=8192 uv run python tests/live_memory_recall.py

Two AgentLoop runs on one workspace, wired exactly like ``build_runtime`` wires
memory: ``recall_provider=store.recall_messages`` and a turn observer that runs
``observe_turn(..., wait=True)`` (inline, so the probe can assert right after).
The driving model is a scripted mock; the memory WRITER is a stub that answers
Mem0's extraction prompts with the fact (no model credits). The embedder is
real — that is what the probe is for: recall by meaning, through the store, on
a second task. Not pytest-collected: it loads the embedding model.
"""

from __future__ import annotations

import json
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from live_memory_two_tasks import _StubWriter  # noqa: E402

from chuk_agents_runtime import AgentLoop, MockModelClient, StateStore, ToolRegistry  # noqa: E402
from chuk_agents_runtime.memory import MemoryStore  # noqa: E402

FACT_PROMPT = "For this project: the codename is BLUEFALCON. Remember it."
RECALL_PROMPT = "What is the codename of this project? Answer from memory."


def main() -> int:
    tmp = Path(tempfile.mkdtemp(prefix="agents_mem_recall_"))
    root = tmp / "memory"
    writer = _StubWriter()
    store = MemoryStore(str(root), llm_client=writer)
    state = StateStore(str(tmp / "state.db"))

    def loop(answer: str) -> AgentLoop:
        return AgentLoop(
            MockModelClient([answer]),
            ToolRegistry(),
            state,
            recall_provider=store.recall_messages,
            turn_observer=lambda record: store.observe_turn(
                record.user_message, record.final_answer,
                tool_names=record.tool_names, wait=True,
            ),
        )

    # -- task 1: the fact is stated; the turn observer extracts it ---------
    r1 = loop("Noted: the codename is BLUEFALCON.").run("probe", FACT_PROMPT)
    rows1 = state.get_conversation(r1.session_id)
    recall_rows_1 = [m for m in rows1 if m.role == "memory"]
    print(f"[task1] finished={r1.reason.name} recall rows={len(recall_rows_1)} (store was empty)")
    listing = store.list()
    print(f"[task1] memory after the turn: {json.dumps(listing)[:300]}")

    # -- task 2: a NEW thread; the recall must carry the fact -------------
    r2 = loop("The codename is BLUEFALCON.").run("probe-2", RECALL_PROMPT)
    rows2 = state.get_conversation(r2.session_id)
    recall_rows_2 = [m for m in rows2 if m.role == "memory"]
    recalled = "\n".join(m.content.get("content", "") for m in recall_rows_2)
    print(f"[task2] recall rows={len(recall_rows_2)}")
    print(f"[task2] recall block: {recalled[:400]!r}")
    order = [m.role for m in rows2]
    print(f"[task2] row order: {order}")

    checks = {
        "store built (not a no-op)": store._memory() is not None,
        "task 1 extracted the fact": any("BLUEFALCON" in s for s in listing.get("results", [])),
        "task 2 injected exactly one recall row after the prompt": (
            len(recall_rows_2) == 1 and order[:2] == ["user", "memory"]
        ),
        "the recall carries the fact": "BLUEFALCON" in recalled,
        "task 1 had no recall (empty store)": recall_rows_1 == [],
        "replay hides the recall row": all(
            e["type"] != "user" or "memory recall" not in e["text"]
            for e in state.replay_events(r2.session_id)
        ),
    }
    print("\n--- checks ---")
    for label, ok in checks.items():
        print(("PASS " if ok else "FAIL ") + label)
    verdict = all(checks.values())
    print("\nVERDICT:", "AUTOMATIC MEMORY WORKS ACROSS TASKS" if verdict else "see FAIL lines")
    return 0 if verdict else 1


if __name__ == "__main__":
    raise SystemExit(main())
