"""Git-versioned workspace + action journal (§7.7).

The agent's workspace is a git repo, and **every tool call** — mutating or not,
local or external — is written into an append-only journal that is committed
along with whatever files changed. The git log is therefore a forensic record of
*what the agent did*, not only *which files changed*, and any point in that
history can be restored.

Four properties, each enforced here rather than asked for:

1. **Never fatal.** No git binary, an unwritable directory, a broken repo — the
   feature turns itself off (``enabled is False``) and the loop runs on. Git
   history is an audit surface, not a dependency of doing the work.
2. **The journal is redacted before it is written.** A commit is permanent, so a
   token that reaches ``journal.jsonl`` stays in the history forever. Arguments
   and results are scrubbed with :func:`~cowork_agent.context.redact_secrets`
   plus a key-name rule, and capped, before they touch the disk.
3. **Text is versioned, large media is not.** A size threshold plus the usual
   media/archive patterns keep the repo from turning into a blob store. A file
   over the threshold is added to ``.git/info/exclude`` (local, uncommitted) and
   named in the commit message, so the *fact* is recorded even though the bytes
   are not.
4. **Undo is a commit, never a rewrite.** :meth:`GitWorkspace.rollback` restores
   the file tree of an earlier commit as a *new* commit and keeps the journal at
   its newest state, with the undo itself appended. Undoing an action does not
   erase the record that it happened.

**Granularity: one commit per action** (the open question in §7.7). The product
feature is "undo the last three actions", and a per-round commit cannot express
that. Measured cost is ~15 ms per action on a small workspace and ~38 ms on one
with 5000 files (``tests/bench_workspace_git.py``) — under 2% of a model round,
and it is the *round*, not the commit, that a user waits for. Rounds that fire
many cheap calls can still collapse into one commit with :meth:`GitWorkspace.batch`.

One workspace belongs to one agent and records one action at a time. The git
index is not concurrent, so every mutating method here takes one coarse
reentrant lock — enough for the one real case of contention (§7.6: a subagent
thread merging its branch back while the parent journals its own round), and not
a substitute for the fact that a *second process* on the same repo is still on
its own.

**Honest boundary** (§7.7): git undoes the *workspace*, not the *outside world*.
A sent email, a POST to an API, a package installed on the host are recorded in
the journal but are not reverted by a rollback. Anything surfacing this in a UI
must say so.

**Where git runs**: on the filesystem this process sees, in ``root``. That is
the same assumption :mod:`cowork_agent.memory` and :mod:`cowork_agent.skills`
already make about the workspace path; with a container sandbox the workspace is
a bind mount, so both sides see one directory.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import threading
import time
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Iterator

from .context import REDACTED, redact_secrets

# -- limits ----------------------------------------------------------------

#: Files bigger than this are excluded from the repo instead of committed.
DEFAULT_MAX_BLOB_BYTES = 5 * 1024 * 1024

#: One argument value in the journal, in characters.
ARG_VALUE_CAP = 500
#: One result summary in the journal, in characters.
RESULT_CAP = 800
#: Redaction runs over at most this many characters — everything past it is
#: dropped by the cap anyway, and an unbounded scan is a DoS on a big result.
REDACT_SCAN_CAP = 20_000
#: Changed paths listed per journal entry.
CHANGED_FILES_CAP = 20

GIT_TIMEOUT_S = 60

JOURNAL_DIRNAME = ".cowork"
JOURNAL_FILENAME = "journal.jsonl"
JOURNAL_PATH = f"{JOURNAL_DIRNAME}/{JOURNAL_FILENAME}"

DEFAULT_AUTHOR_NAME = "CoWork Agent"
DEFAULT_AUTHOR_EMAIL = "agent@cowork.local"

ROLLBACK_TOOL = "__rollback__"
MERGE_TOOL = "__subagent_merge__"

#: Where a subagent's worktree is checked out (§7.6/§7.7). Inside the git
#: directory on purpose: git never scans its own directory, so the parent's
#: ``git add -A`` cannot swallow a child's whole checkout, and the worktrees
#: travel with the repo instead of littering the workspace's parent directory.
WORKTREE_DIRNAME = "cowork-worktrees"

#: Branch prefix for a subagent branch.
SUBAGENT_BRANCH_PREFIX = "cowork"

_BRANCH_UNSAFE = re.compile(r"[^A-Za-z0-9._/-]+")

# Glob metacharacters that must be escaped when a literal path becomes a
# gitignore line.
_GLOB_CHARS = re.compile(r"([\\\[\]*?])")

# Argument/field names whose value is dropped whole. A key called `token` is a
# secret regardless of what the value looks like, and shape-based redaction only
# catches the shapes it knows.
_SECRET_KEY = re.compile(
    r"(?i)(pass(word|wd)?|secret|token|api[_\-]?key|apikey|credential|"
    r"auth|bearer|cookie|session[_\-]?id|private[_\-]?key)"
)

# Media and archives: committed as bytes they buy nothing and cost everything.
GITIGNORE_BODY = """# CoWork workspace (§7.7): text is versioned, large media is not.
# Anything over the size threshold is excluded per file in .git/info/exclude.
*.mp4
*.mov
*.mkv
*.avi
*.webm
*.mp3
*.wav
*.flac
*.ogg
*.m4a
*.png
*.jpg
*.jpeg
*.gif
*.bmp
*.tiff
*.webp
*.ico
*.psd
*.zip
*.tar
*.tgz
*.gz
*.bz2
*.xz
*.7z
*.rar
*.iso
*.img
*.dmg
*.exe
*.dll
*.so
*.dylib
*.o
*.a
*.class
*.jar
*.pyc
*.pyo
*.wasm
*.sqlite
*.db-wal
*.db-shm
__pycache__/
node_modules/
.venv/
venv/
"""


@dataclass(frozen=True)
class WorktreeInfo:
    """One subagent's private checkout of the workspace repo (§7.6, §7.7)."""

    branch: str
    path: str
    base: str

    def as_dict(self) -> dict:
        return {"branch": self.branch, "path": self.path, "base": self.base}


@dataclass(frozen=True)
class CommitInfo:
    """One entry of the workspace history."""

    commit: str
    short: str
    time: str
    subject: str
    seq: int | None = None

    def as_dict(self) -> dict:
        return {
            "commit": self.commit,
            "short": self.short,
            "time": self.time,
            "subject": self.subject,
            "seq": self.seq,
        }


class GitWorkspace:
    """A git repo around the agent's workspace, plus the action journal.

    Build it with :meth:`open`, which never raises: a workspace it cannot
    version comes back disabled.
    """

    def __init__(
        self,
        root: str | os.PathLike,
        *,
        max_blob_bytes: int = DEFAULT_MAX_BLOB_BYTES,
        author_name: str = DEFAULT_AUTHOR_NAME,
        author_email: str = DEFAULT_AUTHOR_EMAIL,
        journal_path: str = JOURNAL_PATH,
    ) -> None:
        self.root = Path(root)
        self.max_blob_bytes = max_blob_bytes
        # One journal file per agent (§7.6): a subagent working in a worktree of
        # this repo writes its own, because two agents appending to one
        # ``journal.jsonl`` would conflict on every merge back.
        self.journal_path = journal_path or JOURNAL_PATH
        self._author = (author_name, author_email)
        self._enabled = False
        self._git_dir: Path | None = None
        self._common_dir: Path | None = None
        # Coarse, reentrant: the parent's own journaling and a subagent thread
        # merging its branch back both write this repo's index, and git's index
        # lock is not a queue — it is an error.
        self._lock = threading.RLock()
        self._seq = 0
        self._batch: list[str] | None = None
        self._batch_summary: str | None = None
        # Per-invocation overrides, not writes to the repo config: an *adopted*
        # repo belongs to the user, and permanently disabling their signing,
        # hooks or gc is not ours to do.
        self._config: list[str] = [
            "-c",
            "commit.gpgsign=false",  # never block on a GPG passphrase prompt
            "-c",
            "gc.auto=0",  # no surprise repack in the middle of a round
            "-c",
            # An agent commit must not fire the user's hooks (CI, formatters,
            # push triggers). A path that cannot exist disables all of them,
            # including post-commit, which `--no-verify` does not cover.
            "core.hooksPath=" + os.path.join(os.sep, "nonexistent", "cowork-no-hooks"),
            # Every commit the agent makes says the agent made it, even in a
            # repo the user already had an identity in.
            "-c",
            f"user.name={author_name}",
            "-c",
            f"user.email={author_email}",
        ]

    # -- construction ------------------------------------------------------

    @classmethod
    def open(
        cls,
        root: str | os.PathLike | None,
        *,
        max_blob_bytes: int = DEFAULT_MAX_BLOB_BYTES,
        author_name: str = DEFAULT_AUTHOR_NAME,
        author_email: str = DEFAULT_AUTHOR_EMAIL,
        journal_path: str = JOURNAL_PATH,
    ) -> "GitWorkspace | None":
        """Initialise (or adopt) the repo at ``root``.

        Returns ``None`` for no workspace at all, and a *disabled* workspace when
        git is missing or the directory cannot hold a repo. Callers check
        :attr:`enabled`; nothing here raises.
        """
        if root is None:
            return None
        ws = cls(
            root,
            max_blob_bytes=max_blob_bytes,
            author_name=author_name,
            author_email=author_email,
            journal_path=journal_path,
        )
        ws._enabled = ws._bootstrap()
        return ws

    @property
    def enabled(self) -> bool:
        return self._enabled

    # -- git plumbing ------------------------------------------------------

    def _git(
        self, *args: str, timeout: int = GIT_TIMEOUT_S
    ) -> subprocess.CompletedProcess:
        return self._git_in(self.root, *args, timeout=timeout)

    def _git_in(
        self, cwd: str | os.PathLike, *args: str, timeout: int = GIT_TIMEOUT_S
    ) -> subprocess.CompletedProcess:
        """The same git, run in another checkout of the same repo — a subagent's
        worktree."""
        env = dict(os.environ)
        env.update(
            {
                # Deterministic: the agent's repo must not depend on, or be
                # broken by, whatever config the host user carries.
                "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_CONFIG_GLOBAL": os.devnull,
                "GIT_TERMINAL_PROMPT": "0",
                "GIT_OPTIONAL_LOCKS": "0",
                "GIT_PAGER": "cat",
            }
        )
        return subprocess.run(
            ["git", "-C", str(cwd), *self._config, *args],
            capture_output=True,
            text=True,
            timeout=timeout,
            env=env,
            check=False,
        )

    def _bootstrap(self) -> bool:
        if shutil.which("git") is None:
            return False
        try:
            self.root.mkdir(parents=True, exist_ok=True)
        except OSError:
            return False

        try:
            # "Already a repo" is the normal case from the second start on, and
            # adopting a repo the user already had is legitimate too.
            if not (self.root / ".git").exists():
                if self._git("init", "-q").returncode != 0:
                    return False
                # Written into our own repo so it works outside this process
                # too — the identity is never taken from a global config, which
                # `_git` switches off, so a host without one still commits.
                self._git("config", "--local", "user.name", self._author[0])
                self._git("config", "--local", "user.email", self._author[1])

            git_dir = self._git("rev-parse", "--absolute-git-dir")
            if git_dir.returncode != 0:
                return False
            self._git_dir = Path(git_dir.stdout.strip())
            # In a worktree the git dir is per-worktree but ``info/exclude`` is
            # read from the *common* dir, so the size guard must write there or
            # a subagent would quietly commit the blobs the parent excludes.
            common = self._git("rev-parse", "--path-format=absolute", "--git-common-dir")
            self._common_dir = (
                Path(common.stdout.strip())
                if common.returncode == 0 and common.stdout.strip()
                else self._git_dir
            )

            gitignore = self.root / ".gitignore"
            if not gitignore.exists():
                gitignore.write_text(GITIGNORE_BODY, encoding="utf-8")

            journal = self.root / self.journal_path
            journal.parent.mkdir(parents=True, exist_ok=True)
            journal.touch(exist_ok=True)
        except (OSError, subprocess.SubprocessError):
            return False

        self._seq = self._last_seq()
        # A repo with no HEAD has nothing to roll back to; give it a root commit.
        if self._git("rev-parse", "--verify", "-q", "HEAD").returncode != 0:
            self._commit("cowork: workspace initialised", [])
        return True

    def _last_seq(self) -> int:
        """Resume numbering across process restarts: the journal is the record,
        so the next sequence number comes from it, not from a counter in RAM."""
        try:
            lines = (
                (self.root / self.journal_path).read_text(encoding="utf-8").splitlines()
            )
        except OSError:
            return 0
        for line in reversed(lines):
            line = line.strip()
            if not line:
                continue
            try:
                seq = json.loads(line).get("seq")
            except (ValueError, AttributeError):
                continue
            if isinstance(seq, int):
                return seq
        return 0

    # -- the size boundary -------------------------------------------------

    def _pending(self) -> list[tuple[str, str]]:
        """``[(status, path)]`` for everything git would commit right now."""
        proc = self._git("status", "--porcelain=v1", "-z", "--untracked-files=all")
        if proc.returncode != 0:
            return []
        return _parse_status_z(proc.stdout)

    def _enforce_size_limit(self, pending: list[tuple[str, str]]) -> list[str]:
        """Keep files over the threshold out of the repo. Returns what was
        skipped, for the commit message — the fact is recorded, the bytes are
        not."""
        skipped: list[str] = []
        for status, path in pending:
            if path == self.journal_path:
                continue  # the record itself is never dropped for being long
            target = self.root / path
            try:
                if not target.is_file():
                    continue
                size = target.stat().st_size
            except OSError:
                continue
            if size <= self.max_blob_bytes:
                continue
            skipped.append(f"{path} ({size} bytes)")
            self._exclude(path)
            if not status.startswith("?"):
                # Previously committed and since grown past the limit.
                self._git("rm", "--cached", "-q", "--", path)
        return skipped

    def _exclude(self, path: str) -> None:
        """Exclude one path locally. ``.git/info/exclude`` is deliberate: it is
        not committed, so the ignore list stays a local disk-cost decision and
        never shows up as a diff."""
        base = self._common_dir or self._git_dir
        if base is None:
            return
        exclude_file = base / "info" / "exclude"
        # A path is a literal here, a gitignore line is a glob — escape the
        # difference or `report[1].txt` silently keeps being committed.
        line = "/" + _GLOB_CHARS.sub(r"\\\1", path.rstrip("/"))
        try:
            exclude_file.parent.mkdir(parents=True, exist_ok=True)
            existing = (
                exclude_file.read_text(encoding="utf-8")
                if exclude_file.exists()
                else ""
            )
            if line in existing.splitlines():
                return
            with exclude_file.open("a", encoding="utf-8") as handle:
                if existing and not existing.endswith("\n"):
                    handle.write("\n")
                handle.write(line + "\n")
        except OSError:
            return

    # -- commit ------------------------------------------------------------

    def _commit(
        self,
        subject: str,
        body: list[str],
        pending: list[tuple[str, str]] | None = None,
    ) -> CommitInfo | None:
        """``pending`` is the ``git status`` the caller already paid for — every
        spawned git process is ~6 ms charged to the round."""
        if pending is None:
            pending = self._pending()
        skipped = self._enforce_size_limit(pending)
        self._git("add", "-A", "--", ".")
        lines = list(body)
        lines.extend(f"skipped-large: {item}" for item in skipped)
        message = subject if not lines else subject + "\n\n" + "\n".join(lines)
        commit = self._git("commit", "-q", "--no-verify", "-m", message)
        if commit.returncode != 0:
            return None  # nothing staged, or git refused — either way, no commit
        head = self._git("rev-parse", "HEAD")
        if head.returncode != 0:
            return None
        sha = head.stdout.strip()
        seq_match = re.search(r"^journal-seq: (\d+)$", "\n".join(lines), re.MULTILINE)
        return CommitInfo(
            commit=sha,
            short=sha[:8],
            time=_now(),
            subject=subject,
            seq=int(seq_match.group(1)) if seq_match else None,
        )

    # -- the public surface ------------------------------------------------

    def record(
        self,
        tool: str,
        args: dict | None,
        result: Any,
        *,
        duration_ms: float | None = None,
        summary: str | None = None,
    ) -> CommitInfo | None:
        """Journal one tool call and commit it together with whatever it changed.

        Called for **every** dispatch, including read-only and purely external
        tools: a call that touched no file still produces a journal-only commit,
        which is what makes the log a record of actions rather than of diffs.
        Returns the commit, or ``None`` when disabled, batching, or nothing was
        staged.
        """
        if not self._enabled:
            return None

        with self._lock:
            pending = self._pending()
            changed = [p for _, p in pending if p != self.journal_path]
            entry = self._build_entry(tool, args, result, duration_ms, changed)
            self._append_journal(entry)

            body = [
                f"tool: {tool}",
                f"journal-seq: {entry['seq']}",
                f"files-changed: {len(changed)}",
            ]
            subject = summary or _default_subject(tool, entry["args"], changed)
            if self._batch is not None:
                self._batch.extend(body)
                return None
            return self._commit(subject, body, pending)

    @contextmanager
    def batch(self, summary: str | None = None) -> Iterator[None]:
        """Collect every action inside the block into ONE commit.

        Off by default: per-action commits are what make "undo the last three
        actions" mean anything. Use this for a round of many cheap calls where
        the round, not the call, is the unit a user would undo.
        """
        if not self._enabled or self._batch is not None:
            yield
            return
        self._batch = []
        self._batch_summary = summary
        try:
            yield
        finally:
            body, self._batch = self._batch, None
            subject, self._batch_summary = self._batch_summary, None
            if body:
                with self._lock:
                    self._commit(subject or "round: batched actions", body)

    def history(self, limit: int = 20) -> list[CommitInfo]:
        """Newest first. This is what an undo UI lists."""
        if not self._enabled:
            return []
        proc = self._git(
            "log",
            f"-n{max(1, int(limit))}",
            "--pretty=format:%H%x1f%h%x1f%aI%x1f%s%x1f%b%x1e",
        )
        if proc.returncode != 0:
            return []
        out: list[CommitInfo] = []
        for record in proc.stdout.split("\x1e"):
            record = record.strip("\n")
            if not record:
                continue
            parts = record.split("\x1f")
            if len(parts) < 4:
                continue
            body = parts[4] if len(parts) > 4 else ""
            match = re.search(r"^journal-seq: (\d+)$", body, re.MULTILINE)
            out.append(
                CommitInfo(
                    commit=parts[0],
                    short=parts[1],
                    time=parts[2],
                    subject=parts[3],
                    seq=int(match.group(1)) if match else None,
                )
            )
        return out

    def journal_entries(self, limit: int | None = None) -> list[dict]:
        """The journal as parsed entries, oldest first."""
        try:
            raw = (self.root / self.journal_path).read_text(encoding="utf-8")
        except OSError:
            return []
        entries: list[dict] = []
        for line in raw.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                entries.append(json.loads(line))
            except ValueError:
                continue
        if limit is not None:
            return entries[-limit:]
        return entries

    def rollback(
        self, *, commit: str | None = None, actions: int | None = None
    ) -> dict:
        """Restore the workspace file tree of an earlier commit.

        The restore is itself a commit: history is never rewritten, and the
        journal is kept at its newest state with the rollback appended, so the
        record of the undone actions survives the undo.

        Pass ``commit`` (any ref) or ``actions`` (``HEAD~n``).
        """
        if not self._enabled:
            return {"ok": False, "error": "workspace versioning is not enabled"}
        if commit is None and actions is None:
            return {"ok": False, "error": "pass either commit or actions"}
        with self._lock:
            return self._rollback_locked(commit, actions)

    def _rollback_locked(self, commit: str | None, actions: int | None) -> dict:
        ref = commit if commit is not None else f"HEAD~{int(actions)}"
        resolved = self._git("rev-parse", "--verify", "-q", f"{ref}^{{commit}}")
        if resolved.returncode != 0 or not resolved.stdout.strip():
            return {"ok": False, "error": f"no such commit: {ref}"}
        target = resolved.stdout.strip()

        # Commit anything still pending first, so nothing is silently discarded
        # and HEAD really is the state we are leaving behind.
        self._commit("checkpoint: state before undo", ["tool: __checkpoint__"])
        head = self._git("rev-parse", "HEAD")
        previous = head.stdout.strip() if head.returncode == 0 else None
        if previous == target:
            return {"ok": True, "restored": target[:8], "note": "already at target"}

        reset = self._git("read-tree", "-u", "--reset", target)
        if reset.returncode != 0:
            return {
                "ok": False,
                "error": (reset.stderr or "read-tree failed").strip()[:400],
            }
        # The journal is the forensic record — it does not travel back in time.
        if previous:
            self._git("checkout", previous, "--", JOURNAL_DIRNAME)

        pending = self._pending()
        restored = [path for _, path in pending if path != self.journal_path]
        entry = self._build_entry(
            ROLLBACK_TOOL,
            {"target": target, "from": previous or "", "actions": actions},
            {"ok": True, "restored_files": len(restored)},
            None,
            restored,
        )
        self._append_journal(entry)
        info = self._commit(
            f"undo: restore workspace to {target[:8]}",
            [
                f"tool: {ROLLBACK_TOOL}",
                f"journal-seq: {entry['seq']}",
                f"restored-from: {previous or ''}",
            ],
            pending,
        )
        return {
            "ok": True,
            "restored": target[:8],
            "files": len(restored),
            "commit": info.commit if info else None,
            "note": (
                "The workspace is restored. Effects outside the workspace "
                "(sent mail, API calls, host changes) are NOT undone."
            ),
        }

    # -- subagent branches / worktrees (§7.6, §7.7) ------------------------

    def create_worktree(self, name: str) -> "WorktreeInfo | None":
        """Check the workspace out a second time, on a fresh branch.

        This is what makes a parallel batch of subagents safe: each child edits
        its own checkout and its own index, so two children can touch the same
        file without racing, and the collision is resolved once, on merge, by
        git — not silently, at write time, by whoever ran last.

        Never raises. ``None`` means the caller runs unversioned (the child then
        works in the parent's workspace), which is the documented fallback.
        """
        if not self._enabled:
            return None
        with self._lock:
            head = self._git("rev-parse", "HEAD")
            if head.returncode != 0:
                return None
            base = head.stdout.strip()
            branch = self._free_branch(_branch_slug(name))
            path = self._worktree_path(branch)
            try:
                path.parent.mkdir(parents=True, exist_ok=True)
            except OSError:
                return None
            added = self._git("worktree", "add", "--quiet", "-b", branch, str(path), base)
            if added.returncode != 0:
                return None
            return WorktreeInfo(branch=branch, path=str(path), base=base)

    def merge_worktree(
        self, info: "WorktreeInfo", *, message: str | None = None
    ) -> dict:
        """Merge a subagent's branch back and clean its checkout up.

        Anything the child left uncommitted is committed on its own branch first,
        so nothing is thrown away by the cleanup. A conflict aborts the merge and
        keeps the branch **and** the worktree: the parent is told which files
        collided and can look at both sides, which is the whole reason the child
        got a branch in the first place.
        """
        if not self._enabled:
            return {"ok": False, "error": "workspace versioning is not enabled"}
        with self._lock:
            self._commit_in(info, "subagent: final state")
            # The parent's own tree must be clean, or git refuses the merge for
            # reasons that have nothing to do with the child.
            self._commit("checkpoint: state before subagent merge", [f"tool: {MERGE_TOOL}"])
            merged = self._git(
                "merge", "--no-ff", "--no-edit", "-m",
                message or f"subagent: merge {info.branch}", info.branch,
            )
            if merged.returncode != 0:
                conflicts = self._conflicts()
                self._git("merge", "--abort")
                return {
                    "ok": False,
                    "error": _cap(
                        (merged.stderr or merged.stdout or "merge failed").strip(), 400
                    ),
                    "conflicts": conflicts,
                    "branch": info.branch,
                    "worktree": info.path,
                }
            head = self._git("rev-parse", "HEAD")
            self.release_worktree(info, keep_branch=False)
            return {
                "ok": True,
                "branch": info.branch,
                "commit": head.stdout.strip() if head.returncode == 0 else None,
            }

    def release_worktree(self, info: "WorktreeInfo", *, keep_branch: bool = True) -> dict:
        """Drop a child's checkout. ``keep_branch`` keeps the commits reachable —
        that is where an unmerged child's work lives, and losing it silently would
        be the opposite of an audit trail."""
        if not self._enabled:
            return {"ok": False, "error": "workspace versioning is not enabled"}
        with self._lock:
            self._commit_in(info, "subagent: final state")
            self._git("worktree", "remove", "--force", info.path)
            self._git("worktree", "prune")
            if not keep_branch:
                self._git("branch", "-D", info.branch)
            return {"ok": True, "branch": info.branch, "kept_branch": keep_branch}

    def worktree_branches(self) -> list[str]:
        """Every subagent branch this repo still carries."""
        if not self._enabled:
            return []
        proc = self._git(
            "for-each-ref", "--format=%(refname:short)",
            f"refs/heads/{SUBAGENT_BRANCH_PREFIX}/",
        )
        if proc.returncode != 0:
            return []
        return [line.strip() for line in proc.stdout.splitlines() if line.strip()]

    # -- worktree internals -----------------------------------------------

    def _worktree_path(self, branch: str) -> Path:
        base = self._common_dir or self._git_dir or (self.root / ".git")
        return base / WORKTREE_DIRNAME / branch.replace("/", "_")

    def _free_branch(self, slug: str) -> str:
        """A branch name that does not exist yet. A retried task must not fail on
        the name of the attempt before it."""
        name = f"{SUBAGENT_BRANCH_PREFIX}/{slug}" if "/" not in slug else slug
        candidate = name
        suffix = 1
        while self._git("rev-parse", "--verify", "-q", f"refs/heads/{candidate}").returncode == 0:
            suffix += 1
            candidate = f"{name}-{suffix}"
        return candidate

    def _commit_in(self, info: "WorktreeInfo", subject: str) -> None:
        """Commit whatever is pending inside the child's checkout, on its branch."""
        if not Path(info.path).is_dir():
            return
        self._git_in(info.path, "add", "-A", "--", ".")
        self._git_in(info.path, "commit", "-q", "--no-verify", "-m", subject)

    def _conflicts(self) -> list[str]:
        proc = self._git("diff", "--name-only", "--diff-filter=U")
        if proc.returncode != 0:
            return []
        return [line.strip() for line in proc.stdout.splitlines() if line.strip()]

    # -- journal writing ---------------------------------------------------

    def _build_entry(
        self,
        tool: str,
        args: dict | None,
        result: Any,
        duration_ms: float | None,
        changed: list[str],
    ) -> dict:
        self._seq += 1
        entry: dict[str, Any] = {
            "seq": self._seq,
            "ts": _now(),
            "tool": tool,
            "args": redact_args(args or {}),
            "result": summarize_result(result),
            "ok": not (isinstance(result, dict) and "error" in result),
            "changed_files": changed[:CHANGED_FILES_CAP],
        }
        if len(changed) > CHANGED_FILES_CAP:
            entry["changed_files_total"] = len(changed)
        if duration_ms is not None:
            entry["duration_ms"] = round(duration_ms, 2)
        return entry

    def _append_journal(self, entry: dict) -> None:
        path = self.root / self.journal_path
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            with path.open("a", encoding="utf-8") as handle:
                handle.write(json.dumps(entry, ensure_ascii=False, default=str) + "\n")
        except OSError:
            return


# -- redaction and summarising --------------------------------------------


def redact_args(args: dict) -> dict:
    """Journal-safe arguments.

    Two rules, because either alone leaks: a value whose *key* names a
    credential is dropped whole, and every remaining string is scrubbed for
    credential *shapes* and capped. The journal is committed, so a leak here is
    permanent.
    """
    return {str(k): _redact_arg(k, v) for k, v in args.items()}


def _redact_arg(key: Any, value: Any) -> Any:
    if isinstance(key, str) and _SECRET_KEY.search(key):
        return REDACTED
    return _scrub(value)


def _scrub(value: Any) -> Any:
    if isinstance(value, str):
        return _cap(redact_secrets(value[:REDACT_SCAN_CAP]), ARG_VALUE_CAP)
    if isinstance(value, dict):
        return {str(k): _redact_arg(k, v) for k, v in value.items()}
    if isinstance(value, list):
        return [_scrub(item) for item in value[:20]]
    return value


def summarize_result(result: Any) -> str:
    """A capped, redacted one-field summary of what a tool returned. Results run
    to megabytes; the journal must stay a log, not a copy of the output."""
    if isinstance(result, str):
        text = result
    else:
        try:
            text = json.dumps(result, ensure_ascii=False, default=str)
        except (TypeError, ValueError):
            text = str(result)
    return _cap(redact_secrets(text[:REDACT_SCAN_CAP]), RESULT_CAP)


def _cap(text: str, limit: int) -> str:
    if len(text) <= limit:
        return text
    return text[:limit] + f"…[+{len(text) - limit} chars]"


def _default_subject(tool: str, args: dict, changed: list[str]) -> str:
    """The commit subject when the caller passes no round summary."""
    hint = ""
    for key in ("path", "command", "url", "query", "name"):
        value = args.get(key)
        if isinstance(value, str) and value.strip():
            hint = ": " + _cap(value.strip().splitlines()[0], 60)
            break
    if not changed:
        return f"{tool}{hint} (journal only)"
    return f"{tool}{hint}"


def _branch_slug(name: str) -> str:
    """A git-legal branch component. Git rejects a surprising amount (``..``, a
    trailing ``.lock``, control characters); this keeps to the safe alphabet."""
    slug = _BRANCH_UNSAFE.sub("-", name).strip("-./")
    slug = re.sub(r"\.\.+", ".", slug).strip("-./")
    if slug.endswith(".lock"):
        slug = slug[: -len(".lock")]
    return slug or "subagent"


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def _parse_status_z(raw: str) -> list[tuple[str, str]]:
    """Parse ``git status --porcelain=v1 -z``. A rename/copy carries its source
    path as the next NUL field, which must be consumed, not read as a record."""
    fields = raw.split("\0")
    out: list[tuple[str, str]] = []
    index = 0
    while index < len(fields):
        record = fields[index]
        index += 1
        if len(record) < 4:
            continue
        status, path = record[:2], record[3:]
        if "R" in status or "C" in status:
            index += 1
        out.append((status, path))
    return out


def timed_record(
    workspace: GitWorkspace | None,
    tool: str,
    args: dict | None,
    result: Any,
    started: float,
    *,
    summary: str | None = None,
) -> None:
    """Record one call, swallowing every failure.

    The journal must never be able to break the loop: a full disk or a broken
    repo costs the audit trail for that call, not the user's work.
    """
    if workspace is None or not workspace.enabled:
        return
    try:
        workspace.record(
            tool,
            args,
            result,
            duration_ms=(time.perf_counter() - started) * 1000.0,
            summary=summary,
        )
    except Exception:  # noqa: BLE001 — auditing must not take the run down
        return
