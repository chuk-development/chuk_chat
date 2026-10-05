"""What did one run change, and undo it (docs/WIRE_CONTRACT.md, "What did it do:
run changes and undo", bead chuk_chat-4qry).

The workspace is a git repo and every commit a run makes carries the trailer
``run-id: <run id>`` (:meth:`GitWorkspace.begin_run`). This module reads that
history and answers two questions for the app:

* :func:`run_changes`: which files did the run add, change or delete, by how
  many lines, in which commits, and can each change still be undone?
* :func:`undo_run`: revert the run's changes (all, or some paths) as ONE new
  commit. History is never rewritten.

Rules, each enforced here:

1. **Only the run's own commits count.** The run's commits are found on the
   first-parent line by their trailer. A subagent's work enters through a
   merge commit that carries the trailer, so it counts too. Changes the user
   made by hand are committed by an untagged checkpoint before a run starts
   (and before an undo), so they never belong to a run.
2. **Content decides a conflict, not the commit log.** A file can be undone
   when its content now is exactly what the run left behind and nothing is
   pending on it. When a later run or the user changed it, the undo is refused
   with the list of conflicts, unless ``force`` is given. A later change that
   was itself undone does not block.
3. **Nothing outside the workspace.** Paths come from git's own tree diffs
   (relative, no ``..``); a path whose real location leaves the workspace (a
   symlinked parent) is skipped. The agent's own state directories
   (:data:`SYSTEM_PREFIXES`) are never listed and never reverted.
4. **No git, no problem.** A workspace without a repo (or without the run's
   commits) answers "nothing to undo"; nothing here creates a repo.
"""

from __future__ import annotations

import os
import re
import subprocess
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

from .workspace_git import (
    GIT_TIMEOUT_S,
    JOURNAL_DIRNAME,
    RUN_ID_TRAILER,
    UNDO_OF_TRAILER,
    GitWorkspace,
    run_tag,
)

#: Workspace paths that are the agent's own state, not the user's files: the
#: journal and host state (``.agents/``), memory and the exported transcript.
#: They are never listed as a change and never reverted.
SYSTEM_PREFIXES: tuple[str, ...] = (f"{JOURNAL_DIRNAME}/", "memory/", "transcript/")

#: At most this many files / commits in one ``run_changes`` frame.
FILES_CAP = 500
COMMITS_CAP = 200

# ``reason`` / ``code`` values (docs/WIRE_CONTRACT.md).
REASON_NO_HISTORY = "no_history"
REASON_NOT_FOUND = "not_found"
REASON_NO_CHANGES = "no_changes"
REASON_ALREADY_UNDONE = "already_undone"
REASON_CONFLICTS = "conflicts"
REASON_RUN_ACTIVE = "run_active"
REASON_FAILED = "failed"

CONFLICT_CHANGED_LATER = "changed_later"
CONFLICT_UNCOMMITTED = "uncommitted"

SKIP_NOT_IN_RUN = "not_in_run"
SKIP_ALREADY_UNDONE = "already_undone"
SKIP_OUTSIDE = "outside_workspace"

_EMPTY = "\0empty"  # marker for "before the repo's first commit"


@dataclass
class _Commit:
    sha: str
    parent: str | None
    time: str
    subject: str
    run_id: str | None
    undo_of: str | None
    seq: int | None
    paths: list[str] = field(default_factory=list)


@dataclass
class _FileChange:
    path: str
    base: str  # tree-ish before the run touched it (or _EMPTY)
    after: str  # the run's last commit that touched it
    first_index: int
    last_index: int
    change: str = "modified"
    additions: int = 0
    deletions: int = 0
    binary: bool = False
    undone: bool = False
    conflict: str | None = None
    later_runs: list[str] = field(default_factory=list)
    later_outside: bool = False


@dataclass
class _Scan:
    commits: list[_Commit]  # oldest first, from the run's first commit to HEAD
    run_commits: list[_Commit]
    files: list[_FileChange]
    empty_tree: str


# -- git -----------------------------------------------------------------------


def _git(root: Path, *args: str, input: str | None = None) -> subprocess.CompletedProcess:
    """Read-mostly git with the same isolation as :class:`GitWorkspace`: no
    user config, no prompts, no pager, and literal pathspecs."""
    env = dict(os.environ)
    env.update(
        {
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_OPTIONAL_LOCKS": "0",
            "GIT_PAGER": "cat",
            "GIT_LITERAL_PATHSPECS": "1",
        }
    )
    return subprocess.run(
        ["git", "-C", str(root), "-c", "core.quotePath=false", *args],
        capture_output=True,
        text=True,
        timeout=GIT_TIMEOUT_S,
        env=env,
        check=False,
        input=input,
    )


def has_history(root: str | os.PathLike | None) -> bool:
    """True when ``root`` is the top of a git repo with at least one commit.
    Never creates anything."""
    if not root:
        return False
    path = Path(root)
    if not (path / ".git").exists():
        return False
    try:
        top = _git(path, "rev-parse", "--show-toplevel")
        if top.returncode != 0:
            return False
        if Path(top.stdout.strip()).resolve() != path.resolve():
            return False  # a subdirectory of some other repo is not ours
        return _git(path, "rev-parse", "--verify", "-q", "HEAD").returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False


def is_system_path(path: str) -> bool:
    return any(path.startswith(prefix) for prefix in SYSTEM_PREFIXES)


_TRAILER = re.compile(r"^([A-Za-z-]+): ?(.*)$")


def _trailers(body: str) -> dict[str, str]:
    out: dict[str, str] = {}
    for line in body.splitlines():
        match = _TRAILER.match(line.strip())
        if match and match.group(1) not in out:
            out[match.group(1)] = match.group(2).strip()
    return out


def _run_commit_shas(root: Path, run_id: str) -> list[str]:
    """The run's commits on the first-parent line, newest first."""
    run_id = run_tag(run_id)
    if not run_id:
        return []
    proc = _git(
        root,
        "log",
        "--first-parent",
        "-F",
        f"--grep={RUN_ID_TRAILER}: {run_id}",
        "--format=%H%x1f%B%x1e",
    )
    if proc.returncode != 0:
        return []
    shas: list[str] = []
    for record in proc.stdout.split("\x1e"):
        record = record.strip("\n")
        if not record or "\x1f" not in record:
            continue
        sha, body = record.split("\x1f", 1)
        # ``--grep`` matches a substring; the trailer must match exactly.
        if _trailers(body).get(RUN_ID_TRAILER) == run_id:
            shas.append(sha.strip())
    return shas


def _commits_since(root: Path, oldest: str) -> list[_Commit]:
    """Every first-parent commit from ``oldest`` to HEAD, oldest first."""
    has_parent = _git(root, "rev-parse", "--verify", "-q", f"{oldest}^").returncode == 0
    span = f"{oldest}^..HEAD" if has_parent else "HEAD"
    proc = _git(
        root,
        "log",
        "--first-parent",
        "--reverse",
        "--format=%H%x1f%P%x1f%aI%x1f%s%x1f%b%x1e",
        span,
    )
    if proc.returncode != 0:
        return []
    out: list[_Commit] = []
    for record in proc.stdout.split("\x1e"):
        record = record.strip("\n")
        if not record:
            continue
        parts = record.split("\x1f")
        if len(parts) < 4:
            continue
        trailers = _trailers(parts[4] if len(parts) > 4 else "")
        seq = trailers.get("journal-seq")
        parents = parts[1].split()
        out.append(
            _Commit(
                sha=parts[0],
                parent=parents[0] if parents else None,
                time=parts[2],
                subject=parts[3],
                run_id=trailers.get(RUN_ID_TRAILER) or None,
                undo_of=trailers.get(UNDO_OF_TRAILER) or None,
                seq=int(seq) if seq and seq.isdigit() else None,
            )
        )
    return out


def _fill_paths(root: Path, commits: list[_Commit]) -> None:
    """Each commit's changed paths against its first parent, in one git call."""
    if not commits:
        return
    lines = [f"{c.sha} {c.parent}" if c.parent else c.sha for c in commits]
    proc = _git(
        root,
        "diff-tree",
        "--stdin",
        "--root",
        "-r",
        "--no-renames",
        "--name-only",
        "-z",
        input="\n".join(lines) + "\n",
    )
    if proc.returncode != 0:
        return
    by_sha = {c.sha: c for c in commits}
    current: _Commit | None = None
    for token in proc.stdout.split("\0"):
        if not token:
            continue
        if token in by_sha:
            current = by_sha[token]
            continue
        if current is not None and not is_system_path(token):
            current.paths.append(token)


def _empty_tree(root: Path) -> str:
    proc = _git(root, "hash-object", "-t", "tree", "--stdin", input="")
    return proc.stdout.strip() if proc.returncode == 0 else "4b825dc642cb6eb9a060e54bf8d69288fbee4904"


def _diff_names(root: Path, a: str, b: str) -> set[str]:
    proc = _git(root, "diff", "--no-renames", "--name-only", "-z", a, b)
    if proc.returncode != 0:
        return set()
    return set(filter(None, proc.stdout.split("\0")))


def _name_status(root: Path, a: str, b: str) -> dict[str, str]:
    proc = _git(root, "diff", "--no-renames", "--name-status", "-z", a, b)
    if proc.returncode != 0:
        return {}
    tokens = proc.stdout.split("\0")
    out: dict[str, str] = {}
    index = 0
    while index + 1 < len(tokens):
        status, path = tokens[index], tokens[index + 1]
        index += 2
        if status:
            out[path] = status[0]
    return out


def _numstat(root: Path, a: str, b: str) -> dict[str, tuple[int, int, bool]]:
    proc = _git(root, "diff", "--no-renames", "--numstat", "-z", a, b)
    if proc.returncode != 0:
        return {}
    out: dict[str, tuple[int, int, bool]] = {}
    for record in proc.stdout.split("\0"):
        parts = record.split("\t", 2)
        if len(parts) != 3:
            continue
        add, delete, path = parts
        if add == "-" or delete == "-":
            out[path] = (0, 0, True)
        else:
            try:
                out[path] = (int(add), int(delete), False)
            except ValueError:
                continue
    return out


def _pending_paths(root: Path) -> set[str]:
    proc = _git(root, "status", "--porcelain=v1", "-z", "--untracked-files=all")
    if proc.returncode != 0:
        return set()
    fields = proc.stdout.split("\0")
    out: set[str] = set()
    index = 0
    while index < len(fields):
        record = fields[index]
        index += 1
        if len(record) < 4:
            continue
        status, path = record[:2], record[3:]
        out.add(path)
        if "R" in status or "C" in status:
            if index < len(fields) and fields[index]:
                out.add(fields[index])
            index += 1
    return out


# -- analysis ------------------------------------------------------------------


def _scan(root: Path, run_id: str) -> _Scan | None:
    """The run's changes, or ``None`` when the run left no commit."""
    shas = _run_commit_shas(root, run_id)
    if not shas:
        return None
    run_id = run_tag(run_id)
    commits = _commits_since(root, shas[-1])
    _fill_paths(root, commits)
    empty = _empty_tree(root)
    run_commits = [c for c in commits if c.run_id == run_id]

    files: dict[str, _FileChange] = {}
    for index, commit in enumerate(commits):
        if commit.run_id != run_id:
            continue
        for path in commit.paths:
            change = files.get(path)
            if change is None:
                files[path] = _FileChange(
                    path=path,
                    base=commit.parent or _EMPTY,
                    after=commit.sha,
                    first_index=index,
                    last_index=index,
                )
            else:
                change.after = commit.sha
                change.last_index = index

    # Net effect per path: from the state before the run first touched it to
    # the run's last commit on it. A file the run created and deleted again (or
    # changed and changed back) is no change at all.
    pairs: dict[tuple[str, str], list[_FileChange]] = {}
    for change in files.values():
        pairs.setdefault((change.base, change.after), []).append(change)
    net: list[_FileChange] = []
    for (base, after), group in pairs.items():
        base_ref = empty if base == _EMPTY else base
        statuses = _name_status(root, base_ref, after)
        stats = _numstat(root, base_ref, after)
        for change in group:
            status = statuses.get(change.path)
            if status is None:
                continue
            change.change = {"A": "added", "D": "deleted"}.get(status, "modified")
            add, delete, binary = stats.get(change.path, (0, 0, False))
            change.additions, change.deletions, change.binary = add, delete, binary
            net.append(change)

    # Where does each file stand now?
    pending = _pending_paths(root)
    since_after: dict[str, set[str]] = {}
    since_base: dict[str, set[str]] = {}
    for change in net:
        if change.after not in since_after:
            since_after[change.after] = _diff_names(root, change.after, "HEAD")
        base_ref = empty if change.base == _EMPTY else change.base
        if base_ref not in since_base:
            since_base[base_ref] = _diff_names(root, base_ref, "HEAD")
        if change.path not in since_base[base_ref]:
            # The file is back to what it was before the run: an earlier
            # undo, or someone reverted it by hand.
            change.undone = True
            continue
        if change.path in since_after[change.after]:
            change.conflict = CONFLICT_CHANGED_LATER
            for later in commits[change.last_index + 1:]:
                if change.path not in later.paths or later.run_id == run_id:
                    continue
                if later.run_id:
                    if later.run_id not in change.later_runs:
                        change.later_runs.append(later.run_id)
                else:
                    change.later_outside = True
        elif change.path in pending:
            change.conflict = CONFLICT_UNCOMMITTED

    net.sort(key=lambda c: c.path)
    return _Scan(commits=commits, run_commits=run_commits, files=net, empty_tree=empty)


def _file_dict(change: _FileChange) -> dict[str, Any]:
    entry: dict[str, Any] = {
        "path": change.path,
        "change": change.change,
        "additions": change.additions,
        "deletions": change.deletions,
        "undoable": not change.undone and change.conflict is None,
    }
    if change.binary:
        entry["binary"] = True
    if change.undone:
        entry["undone"] = True
    if change.conflict is not None:
        entry["conflict"] = _conflict_dict(change)
    return entry


def _conflict_dict(change: _FileChange) -> dict[str, Any]:
    out: dict[str, Any] = {"path": change.path, "reason": change.conflict}
    if change.later_runs:
        out["runs"] = list(change.later_runs)
    if change.later_outside:
        out["outside"] = True
    return out


def _summary(files: list[_FileChange]) -> dict[str, Any]:
    return {
        "files": len(files),
        "additions": sum(c.additions for c in files),
        "deletions": sum(c.deletions for c in files),
        "undone": sum(1 for c in files if c.undone),
    }


def run_changes(
    root: str | os.PathLike | None, run_id: str, *, busy: bool = False
) -> dict[str, Any]:
    """The body of a ``run_changes`` frame (without ``type``).

    ``busy``: a run is in progress in this workspace right now; the list is
    still answered, but nothing is undoable until it ends.
    """
    body: dict[str, Any] = {
        "run_id": run_id,
        "files": [],
        "commits": [],
        "undoable": False,
    }
    if not has_history(root):
        body["reason"] = REASON_NO_HISTORY
        return body
    try:
        scan = _scan(Path(root), run_id)  # type: ignore[arg-type]
    except (OSError, subprocess.SubprocessError):
        body["reason"] = REASON_FAILED
        return body
    if scan is None or not scan.files:
        body["reason"] = REASON_NO_CHANGES
        return body

    files = scan.files
    body["files"] = [_file_dict(c) for c in files[:FILES_CAP]]
    if len(files) > FILES_CAP:
        body["files_total"] = len(files)
    with_files = [c for c in scan.run_commits if c.paths]
    body["commits"] = [
        {
            "commit": c.sha,
            "short": c.sha[:8],
            "time": c.time,
            "subject": c.subject,
            "seq": c.seq,
            "files": len(c.paths),
        }
        for c in with_files[-COMMITS_CAP:]
    ]
    if len(with_files) > COMMITS_CAP:
        body["commits_total"] = len(with_files)
    body["actions"] = len(scan.run_commits)
    body["summary"] = _summary(files)

    open_files = [c for c in files if not c.undone]
    if busy:
        body["reason"] = REASON_RUN_ACTIVE
    elif not open_files:
        body["reason"] = REASON_ALREADY_UNDONE
    elif any(c.conflict is None for c in open_files):
        body["undoable"] = True
        conflicts = [c for c in open_files if c.conflict is not None]
        if conflicts:
            body["conflicts"] = [_conflict_dict(c) for c in conflicts]
    else:
        body["reason"] = REASON_CONFLICTS
        body["conflicts"] = [_conflict_dict(c) for c in open_files]
    return body


def run_change_summary(root: str | os.PathLike | None, run_id: str) -> dict[str, Any] | None:
    """The compact block a ``done`` carries: ``{"files", "additions",
    "deletions", "undone"}``. ``None`` when there is no history or the run
    changed no file. Never raises."""
    try:
        if not run_id or not has_history(root):
            return None
        scan = _scan(Path(root), run_id)  # type: ignore[arg-type]
    except Exception:  # noqa: BLE001 — a summary must never fail a run
        return None
    if scan is None or not scan.files:
        return None
    return _summary(scan.files)


# -- undo ----------------------------------------------------------------------


def _normalize(path: Any) -> str | None:
    if not isinstance(path, str):
        return None
    text = path.strip().replace("\\", "/")
    while text.startswith("./"):
        text = text[2:]
    if not text or text.startswith("/") or any(part == ".." for part in text.split("/")):
        return None
    return text


def _inside(root: Path, path: str) -> bool:
    """The path's real parent directory is inside the workspace. A symlinked
    directory that leads elsewhere must not make git write outside it."""
    try:
        real_root = root.resolve()
        parent = (root / path).parent.resolve()
    except OSError:
        return False
    return parent == real_root or real_root in parent.parents


def undo_run(
    root: str | os.PathLike | None,
    run_id: str,
    *,
    paths: list[str] | None = None,
    force: bool = False,
    busy: bool = False,
) -> dict[str, Any]:
    """The body of a ``run_undo_result`` frame (without ``type``)."""
    result: dict[str, Any] = {
        "run_id": run_id,
        "ok": False,
        "reverted": [],
        "conflicts": [],
    }

    def refuse(code: str, message: str) -> dict[str, Any]:
        result["code"] = code
        result["error"] = message
        return result

    if not has_history(root):
        return refuse(REASON_NO_HISTORY, "Nothing to undo: this workspace has no history.")
    if busy:
        return refuse(
            REASON_RUN_ACTIVE,
            "A run is working in this workspace right now. Undo after it ends.",
        )
    workspace = Path(root)  # type: ignore[arg-type]
    try:
        scan = _scan(workspace, run_id)
    except (OSError, subprocess.SubprocessError) as exc:
        return refuse(REASON_FAILED, f"Could not read the history: {type(exc).__name__}")
    if scan is None or not scan.files:
        return refuse(REASON_NO_CHANGES, "Nothing to undo: this run changed no file.")

    by_path = {c.path: c for c in scan.files}
    skipped: list[dict[str, str]] = []
    if paths is None:
        selected = list(scan.files)
    else:
        selected = []
        seen: set[str] = set()
        for raw in paths:
            norm = _normalize(raw)
            if norm is None:
                skipped.append({"path": str(raw), "reason": SKIP_OUTSIDE})
                continue
            if norm in seen:
                continue
            seen.add(norm)
            change = by_path.get(norm)
            if change is None:
                skipped.append({"path": norm, "reason": SKIP_NOT_IN_RUN})
            else:
                selected.append(change)

    candidates: list[_FileChange] = []
    for change in selected:
        if change.undone:
            skipped.append({"path": change.path, "reason": SKIP_ALREADY_UNDONE})
        elif not _inside(workspace, change.path):
            skipped.append({"path": change.path, "reason": SKIP_OUTSIDE})
        else:
            candidates.append(change)
    if skipped:
        result["skipped"] = skipped

    conflicts = [c for c in candidates if c.conflict is not None]
    result["conflicts"] = [_conflict_dict(c) for c in conflicts]
    if conflicts and not force:
        names = ", ".join(c.path for c in conflicts[:5])
        more = f" and {len(conflicts) - 5} more" if len(conflicts) > 5 else ""
        return refuse(
            REASON_CONFLICTS,
            f"{len(conflicts)} file(s) changed after this run: {names}{more}. "
            "Undo them anyway with force, or pick other files.",
        )
    if not candidates:
        reason = REASON_ALREADY_UNDONE if any(
            s["reason"] == SKIP_ALREADY_UNDONE for s in skipped
        ) else REASON_NO_CHANGES
        return refuse(reason, "Nothing to undo for the files asked for.")

    ws = GitWorkspace.open(workspace)
    if ws is None or not ws.enabled:
        return refuse(REASON_FAILED, "The workspace history cannot be written.")
    groups: dict[str, list[str]] = {}
    for change in candidates:
        base = scan.empty_tree if change.base == _EMPTY else change.base
        groups.setdefault(base, []).append(change.path)
    try:
        written = ws.revert_paths(list(groups.items()), undo_of=run_id)
    except (OSError, subprocess.SubprocessError) as exc:
        return refuse(REASON_FAILED, f"Undo failed: {type(exc).__name__}")
    if not written.get("ok"):
        return refuse(REASON_FAILED, str(written.get("error") or "undo failed"))
    result["ok"] = True
    result["reverted"] = sorted(written.get("reverted") or [])
    if written.get("commit"):
        result["commit"] = written["commit"]
    if conflicts:
        result["forced"] = True
    result["note"] = (
        "Files in the workspace are restored. Effects outside the workspace "
        "(sent mail, API calls, host changes) are NOT undone."
    )
    return result
