"""What one commit per action costs (§7.7).

Not a test — run it directly:

    uv run python tests/bench_workspace_git.py

It measures :meth:`GitWorkspace.record` against workspaces of growing size,
because the cost is dominated by ``git status``/``git add`` walking the tree, not
by the commit itself. Compare the numbers against a model round (seconds) before
deciding that per-action granularity is too expensive.
"""

from __future__ import annotations

import statistics
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))

from cowork_agent.workspace_git import GitWorkspace  # noqa: E402

ACTIONS = 25


def _populate(root: Path, files: int) -> None:
    for index in range(files):
        directory = root / f"pkg{index // 50}"
        directory.mkdir(parents=True, exist_ok=True)
        (directory / f"mod{index}.py").write_text(f"VALUE = {index}\n")


def _bench(files: int) -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp) / "workspace"
        root.mkdir()
        _populate(root, files)
        workspace = GitWorkspace.open(root)
        assert workspace is not None and workspace.enabled

        read_only: list[float] = []
        mutating: list[float] = []
        for index in range(ACTIONS):
            start = time.perf_counter()
            workspace.record("list_dir", {"path": "."}, {"ok": True})
            read_only.append((time.perf_counter() - start) * 1000)

            (root / f"edit{index}.txt").write_text("x" * 200)
            start = time.perf_counter()
            workspace.record("write_file", {"path": f"edit{index}.txt"}, {"ok": True})
            mutating.append((time.perf_counter() - start) * 1000)

        start = time.perf_counter()
        with workspace.batch("round"):
            for index in range(5):
                (root / f"batched{index}.txt").write_text("y")
                workspace.record("write_file", {"path": "batched"}, {"ok": True})
        batched = (time.perf_counter() - start) * 1000

        print(
            f"{files:>6} files | journal-only {statistics.median(read_only):6.1f} ms"
            f" | mutating {statistics.median(mutating):6.1f} ms"
            f" | 5 actions batched {batched:6.1f} ms"
        )


if __name__ == "__main__":
    print(f"median of {ACTIONS} actions per row\n")
    for count in (10, 500, 5_000):
        _bench(count)
