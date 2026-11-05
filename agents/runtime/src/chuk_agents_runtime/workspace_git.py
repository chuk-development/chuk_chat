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
   and results are scrubbed with :func:`~chuk_agents_runtime.context.redact_secrets`
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

**Whose repo** (bead B14): a fresh workspace gets the agent's own ``.git``.
A workspace that already is the USER's repo is never committed into: the
agent keeps its checkpoints in a private git dir (``GIT_DIR`` +
``GIT_WORK_TREE``), so the user's index, refs and history stay as they were.
``.agents/`` is added to the user's ``info/exclude`` (a local, uncommitted
file) so their ``git add -A`` never sweeps the agent's journal.
A ``.git`` the agent made earlier (its identity is in the local config) keeps
working in place.

**Host state, not workspace** (security review of 3cb9aa01, H3): the private
git dir and the rewind ledger live in the HOST's state directory
(:func:`git_state_home`, one folder per workspace, keyed by the hash of the
resolved workspace path), never inside the workspace. The agent can write
every file in its workspace; a git config or a ledger it can write is a git
config it can make the host execute (``core.fsmonitor``, ``diff.external``,
filter drivers, textconv) and a ledger it can make lie. A private dir that an
older build left at ``.agents/git`` is moved into the host state once (copied,
verified, then deleted; a symlinked or symlink-holding one is not trusted and
is left alone). Every git call also runs with those hooks switched off
(``_HARDENING``, ``--no-ext-diff --no-textconv``, attributes from the empty
tree only), because the agent's OWN ``.git`` in a fresh workspace stays inside
the workspace.

**Rewind never writes through a symlink** (H2): a restored or deleted path is
walked one directory at a time from the workspace root with ``O_NOFOLLOW``;
a symlinked parent refuses the path, a symlink at the leaf is replaced, not
followed.

**Where git runs**: on the filesystem this process sees, in ``root``. That is
the same assumption :mod:`chuk_agents_runtime.memory` and :mod:`chuk_agents_runtime.skills`
already make about the workspace path; with a container sandbox the workspace is
a bind mount, so both sides see one directory.
"""

from __future__ import annotations

import hashlib
import json
import os
import stat
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

JOURNAL_DIRNAME = ".agents"
JOURNAL_FILENAME = "journal.jsonl"
JOURNAL_PATH = f"{JOURNAL_DIRNAME}/{JOURNAL_FILENAME}"

#: Where an older build kept the agent's private git directory: INSIDE the
#: workspace, writable by the agent. Only read to migrate it into the host
#: state (:func:`git_state_home`); nothing is ever created here again.
LEGACY_PRIVATE_GIT_DIR = f"{JOURNAL_DIRNAME}/git"
#: Kept as an alias for callers of the old name.
PRIVATE_GIT_DIR = LEGACY_PRIVATE_GIT_DIR

#: Moves the host state folder for workspace git (tests, a host with an
#: explicit state directory). Wins over :func:`set_git_state_home`.
GIT_STATE_ENV = "AGENTS_GIT_STATE_DIR"
#: Under the host state directory (``$AGENTS_HOME`` /
#: ``$XDG_DATA_HOME/chuk-agents``).
GIT_STATE_DIRNAME = "workspace-git"
#: Inside one workspace's state folder: the private git dir and the ledger.
STATE_GIT_DIRNAME = "git"
LEDGER_FILENAME = "agents-writes.json"
#: Subagent worktrees of a PRIVATE repo: inside the workspace, so a container
#: sandbox that mounts only the workspace still sees them; excluded from the
#: private repo so its ``git add -A`` never sweeps them.
PRIVATE_WORKTREE_DIR = f"{JOURNAL_DIRNAME}/worktrees"

#: The well-known empty tree. Attributes are read from it only
#: (``GIT_ATTR_SOURCE``), so a ``.gitattributes`` the agent writes into the
#: workspace can never select a filter, diff or merge driver.
EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

#: Per-invocation config that switches off every way a repo config or a
#: worktree file can make git run a program (security review H3).
_HARDENING: tuple[str, ...] = (
    "-c", "core.fsmonitor=false",
    "-c", "core.untrackedCache=false",
    "-c", "core.hooksPath=" + os.devnull,
    "-c", "diff.external=",
    "-c", "core.attributesFile=" + os.devnull,
    "-c", "core.sshCommand=",
    "-c", "core.askPass=",
    "-c", "credential.helper=",
)
#: Subcommands that can run an external diff or a textconv filter.
_DIFF_COMMANDS = frozenset({"diff", "log", "show", "diff-tree", "diff-index", "diff-files"})
#: Config keys of a named driver that run a program. Overridden with an empty
#: value for every driver name the repo config defines.
_DRIVER_KEY = re.compile(
    r"^(filter\.(.+)\.(clean|smudge|process)|diff\.(.+)\.(command|textconv)|merge\.(.+)\.driver)$"
)

_STATE_HOME_OVERRIDE: Path | None = None


def set_git_state_home(path: str | os.PathLike | None) -> None:
    """The host process says where its state is (``LocalHost`` passes
    ``<state>/workspace-git``). ``$AGENTS_GIT_STATE_DIR`` still wins."""
    global _STATE_HOME_OVERRIDE
    _STATE_HOME_OVERRIDE = Path(path) if path else None


def git_state_home() -> Path:
    """The host-side folder that holds every workspace's private git dir and
    ledger. Never inside a workspace."""
    explicit = os.environ.get(GIT_STATE_ENV, "").strip()
    if explicit:
        return Path(explicit).expanduser()
    if _STATE_HOME_OVERRIDE is not None:
        return _STATE_HOME_OVERRIDE
    for name in ("AGENTS_HOME", "COWORK_HOME"):
        value = os.environ.get(name, "").strip()
        if value:
            return Path(value).expanduser() / GIT_STATE_DIRNAME
    xdg = os.environ.get("XDG_DATA_HOME", "").strip()
    base = Path(xdg).expanduser() if xdg else Path.home() / ".local" / "share"
    return base / "chuk-agents" / GIT_STATE_DIRNAME


def workspace_state_dir(root: str | os.PathLike) -> Path:
    """The host state folder of one workspace (keyed by its resolved path)."""
    try:
        resolved = str(Path(root).resolve())
    except OSError:
        resolved = os.path.abspath(os.fspath(root))
    key = hashlib.sha256(resolved.encode("utf-8", "surrogateescape")).hexdigest()[:32]
    return git_state_home() / key

DEFAULT_AUTHOR_NAME = "Agents Agent"
DEFAULT_AUTHOR_EMAIL = "agent@cowork.local"

ROLLBACK_TOOL = "__rollback__"
#: Journal tools of the checkpoint feature (docs/WIRE_CONTRACT.md,
#: "Checkpoints, rewind and fork").
REWIND_TOOL = "__rewind__"
OUTSIDE_TOOL = "__outside__"
CHECKPOINT_REF_PREFIX = "refs/agents/checkpoints/"
REWIND_SAFE = "safe"
REWIND_KEEP = "keep_user_edits"
REWIND_MERGE = "merge"
REWIND_FORCE = "force"
REWIND_MODES = (REWIND_SAFE, REWIND_KEEP, REWIND_MERGE, REWIND_FORCE)
MERGE_TOOL = "__subagent_merge__"

#: Where a subagent's worktree is checked out (§7.6/§7.7). Inside the git
#: directory on purpose: git never scans its own directory, so the parent's
#: ``git add -A`` cannot swallow a child's whole checkout, and the worktrees
#: travel with the repo instead of littering the workspace's parent directory.
WORKTREE_DIRNAME = "agents-worktrees"

#: Branch prefix for a subagent branch.
SUBAGENT_BRANCH_PREFIX = "agents"

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
GITIGNORE_BODY = """# Agents workspace (§7.7): text is versioned, large media is not.
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


def _hardened_env(extra_env: dict[str, str] | None = None) -> dict[str, str]:
    """The environment of every host-side git call (H3)."""
    env = {
        k: v
        for k, v in os.environ.items()
        # Inherited git plumbing would point these calls at another repo or
        # make them run a program.
        if not k.startswith("GIT_") or k in ("GIT_EXEC_PATH",)
    }
    if extra_env:
        env.update(extra_env)
    env.update(
        {
            # Deterministic: the agent's repo must not depend on, or be
            # broken by, whatever config the host user carries.
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_OPTIONAL_LOCKS": "0",
            "GIT_PAGER": "cat",
            # Attributes come from the empty tree only: a .gitattributes the
            # agent writes can never select a filter, diff or merge driver.
            "GIT_ATTR_NOSYSTEM": "1",
            "GIT_ATTR_SOURCE": EMPTY_TREE,
        }
    )
    return env


def _config_signature(files: tuple[str, ...]) -> tuple:
    out = []
    for name in files:
        try:
            st = os.stat(name)
            out.append((name, st.st_mtime_ns, st.st_size, st.st_ino))
        except OSError:
            out.append((name, None))
    return tuple(out)


def _is_real_dir(path: Path) -> bool:
    """A directory that is not a symlink (nor reached through one at the
    leaf)."""
    try:
        return stat.S_ISDIR(os.lstat(path).st_mode)
    except OSError:
        return False


#: What survives of a migrated private repo's config: the format, the
#: identity. Everything else was agent-writable and is dropped.
_KEEP_CONFIG = re.compile(
    r"^(core\.(repositoryformatversion|filemode|bare|logallrefupdates)|"
    r"extensions\.[a-z0-9]+|user\.(name|email))$"
)


def _sanitise_private_config(config: Path, author: tuple[str, str]) -> None:
    """Rewrite a migrated private repo's config from an allowlist. Parsed with
    ``git config --file`` (no repo, no program run), written fresh."""
    proc = subprocess.run(
        ["git", "config", "--file", str(config), "--list", "-z"],
        capture_output=True, text=True, timeout=GIT_TIMEOUT_S,
        env=_hardened_env(), check=False,
    )
    kept: list[tuple[str, str]] = []
    if proc.returncode == 0:
        for item in proc.stdout.split("\0"):
            name, _, value = item.partition("\n")
            if _KEEP_CONFIG.match(name.lower()):
                kept.append((name.lower(), value))
    names = {name for name, _ in kept}
    if "core.repositoryformatversion" not in names:
        kept.append(("core.repositoryformatversion", "0"))
    kept = [(n, v) for n, v in kept if n != "core.bare"] + [("core.bare", "false")]
    if "user.name" not in names:
        kept.append(("user.name", author[0]))
    if "user.email" not in names:
        kept.append(("user.email", author[1]))
    fresh = config.with_name("config.fresh")
    fresh.unlink(missing_ok=True)
    fresh.touch()
    for name, value in kept:
        subprocess.run(
            ["git", "config", "--file", str(fresh), "--add", name, value],
            capture_output=True, timeout=GIT_TIMEOUT_S, env=_hardened_env(), check=False,
        )
    os.replace(fresh, config)


class UnsafePath(Exception):
    """A workspace path that leaves the root or passes a symlink (H2)."""


class _MissingParent(UnsafePath):
    """A parent directory of the path does not exist (and was not made)."""


def _split_rel(rel: str) -> list[str]:
    parts = [p for p in rel.replace("\\", "/").split("/") if p not in ("", ".")]
    if not parts or rel.startswith("/") or any(p == ".." for p in parts):
        raise UnsafePath(rel)
    return parts


@contextmanager
def _open_parent(root: Path, rel: str, *, create: bool) -> Iterator[tuple[int, str]]:
    """``(dir fd, leaf name)`` of ``rel`` under ``root``. Every parent
    component is opened with ``O_NOFOLLOW``: a symlinked (or non-directory)
    parent raises :class:`UnsafePath`, and nothing below it is touched.
    ``create`` makes missing directories (never through a symlink)."""
    parts = _split_rel(rel)
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
    try:
        fd = os.open(str(root), flags)
    except OSError as exc:
        raise UnsafePath(rel) from exc
    try:
        for part in parts[:-1]:
            try:
                nxt = os.open(part, flags, dir_fd=fd)
            except FileNotFoundError:
                if not create:
                    raise _MissingParent(rel)
                try:
                    os.mkdir(part, 0o777, dir_fd=fd)
                    nxt = os.open(part, flags, dir_fd=fd)
                except OSError as exc:
                    raise UnsafePath(rel) from exc
            except OSError as exc:  # ELOOP (symlink), ENOTDIR
                raise UnsafePath(rel) from exc
            os.close(fd)
            fd = nxt
        yield fd, parts[-1]
    finally:
        os.close(fd)


def _leaf_stat(dir_fd: int, name: str) -> os.stat_result | None:
    try:
        return os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
    except FileNotFoundError:
        return None


def _safe_write(root: Path, rel: str, data: bytes, *, mode: str = "100644") -> None:
    """Write ``rel`` under ``root``: a temp file in the real parent, then a
    rename over the leaf. A symlink at the leaf is replaced, never written
    through; a directory at the leaf is left alone."""
    with _open_parent(root, rel, create=True) as (dfd, leaf):
        st = _leaf_stat(dfd, leaf)
        if st is not None and stat.S_ISDIR(st.st_mode):
            raise UnsafePath(rel)
        tmp = f".{leaf}.agents-rewind-{os.getpid()}-{threading.get_ident()}"
        try:
            os.unlink(tmp, dir_fd=dfd)
        except FileNotFoundError:
            pass
        if mode == "120000":
            os.symlink(data.decode("utf-8", "surrogateescape"), tmp, dir_fd=dfd)
        else:
            perm = 0o755 if mode == "100755" else 0o644
            fd = os.open(
                tmp,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0),
                perm,
                dir_fd=dfd,
            )
            try:
                view = memoryview(data)
                while view:
                    view = view[os.write(fd, view):]
            finally:
                os.close(fd)
        os.replace(tmp, leaf, src_dir_fd=dfd, dst_dir_fd=dfd)


def _safe_unlink(root: Path, rel: str) -> None:
    """Delete ``rel`` (a file or a symlink itself, never its target). A
    symlinked parent raises :class:`UnsafePath`."""
    try:
        with _open_parent(root, rel, create=False) as (dfd, leaf):
            st = _leaf_stat(dfd, leaf)
            if st is None or stat.S_ISDIR(st.st_mode):
                return
            os.unlink(leaf, dir_fd=dfd)
    except _MissingParent:
        return  # nothing there to delete


def _safe_read(root: Path, rel: str) -> tuple[str, bytes] | None:
    """``(kind, bytes)`` of the leaf without following a symlink: ``file``
    content, or ``link`` target text. ``None`` when missing or a directory.
    A symlinked parent raises :class:`UnsafePath`."""
    try:
        with _open_parent(root, rel, create=False) as (dfd, leaf):
            return _read_leaf(dfd, leaf)
    except _MissingParent:
        return None


def _read_leaf(dfd: int, leaf: str) -> tuple[str, bytes] | None:
    st = _leaf_stat(dfd, leaf)
    if st is None or stat.S_ISDIR(st.st_mode):
        return None
    if stat.S_ISLNK(st.st_mode):
        return "link", os.fsencode(os.readlink(leaf, dir_fd=dfd))
    if not stat.S_ISREG(st.st_mode):
        return None
    fd = os.open(leaf, os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0), dir_fd=dfd)
    with os.fdopen(fd, "rb") as handle:
        return "file", handle.read()


_REPO_LOCKS: dict[str, threading.RLock] = {}
_REPO_LOCKS_GUARD = threading.Lock()


def _repo_lock(root: Path) -> threading.RLock:
    """One lock per repository directory, process-wide."""
    try:
        key = str(Path(root).resolve())
    except OSError:
        key = str(root)
    with _REPO_LOCKS_GUARD:
        return _REPO_LOCKS.setdefault(key, threading.RLock())


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
        state_dir: str | os.PathLike | None = None,
    ) -> None:
        self.root = Path(root)
        # Host-side, outside the workspace (H3): the private git dir and the
        # rewind ledger. Resolved in ``_bootstrap`` once ``root`` exists.
        self._state_dir: Path | None = Path(state_dir) if state_dir is not None else None
        # (config file signature) -> driver overrides; see ``_driver_overrides``.
        self._driver_cache: tuple[tuple, list[str]] | None = None
        self._ledger_file: Path | None = None
        self.max_blob_bytes = max_blob_bytes
        # One journal file per agent (§7.6): a subagent working in a worktree of
        # this repo writes its own, because two agents appending to one
        # ``journal.jsonl`` would conflict on every merge back.
        self.journal_path = journal_path or JOURNAL_PATH
        self._author = (author_name, author_email)
        self._enabled = False
        self._git_dir: Path | None = None
        self._common_dir: Path | None = None
        # Set when the agent keeps its checkpoints in a private git directory
        # because ``root`` is the user's own repo (bead B14).
        self._private_dir: Path | None = None
        # Coarse, reentrant, and shared by every instance on this repo in the
        # process: the parent's own journaling, a subagent thread merging its
        # branch back, and a tool thread a Stop abandoned in the previous task
        # (it still commits when it returns) all write this repo's index, and
        # git's index lock is not a queue — it is an error.
        self._lock = _repo_lock(self.root)
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
            # An agent commit must not fire the user's hooks (CI, formatters,
            # push triggers), nor anything the agent planted in a config it
            # can write (fsmonitor, external diff, ...): ``_HARDENING``.
            *_HARDENING,
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
        state_dir: str | os.PathLike | None = None,
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
            state_dir=state_dir,
        )
        ws._enabled = ws._bootstrap()
        return ws

    @property
    def enabled(self) -> bool:
        return self._enabled

    @property
    def private(self) -> bool:
        """True when the checkpoints live in a private git dir (host state)
        because the workspace is a repo of the user's own (bead B14)."""
        return self._private_dir is not None

    @property
    def state_dir(self) -> Path | None:
        """This workspace's host state folder (private git dir, ledger)."""
        return self._state_dir

    # -- git plumbing ------------------------------------------------------

    def _git(
        self,
        *args: str,
        timeout: int = GIT_TIMEOUT_S,
        text: bool = True,
        input: bytes | str | None = None,
    ) -> subprocess.CompletedProcess:
        # The work tree is always ``root``: a ``core.worktree`` the agent
        # writes into its own ``.git/config`` cannot point host git elsewhere.
        extra: dict[str, str] = {}
        if self._private_dir is not None or (args and args[0] != "init"):
            extra["GIT_WORK_TREE"] = str(self.root.resolve())
        if self._private_dir is not None:
            # The agent's own repo over the user's files: the user's ``.git``
            # is never read or written by these calls.
            extra["GIT_DIR"] = str(self._private_dir)
        return self._git_in(
            self.root, *args, timeout=timeout, extra_env=extra, text=text, input=input
        )

    def _git_in(
        self,
        cwd: str | os.PathLike,
        *args: str,
        timeout: int = GIT_TIMEOUT_S,
        extra_env: dict[str, str] | None = None,
        text: bool = True,
        input: bytes | str | None = None,
    ) -> subprocess.CompletedProcess:
        """The same git, run in another checkout of the same repo — a subagent's
        worktree. A worktree finds its git directory through its ``.git`` file,
        so it never gets ``GIT_DIR``."""
        env = _hardened_env(extra_env)
        if args and args[0] in _DIFF_COMMANDS:
            # No external diff, no textconv: both run a program the repo
            # config (agent-writable for an own ``.git``) names.
            args = (args[0], "--no-ext-diff", "--no-textconv", *args[1:])
        self._neutralise_attributes()
        overrides = self._driver_overrides(cwd, env)
        return subprocess.run(
            ["git", "-C", str(cwd), *self._config, *overrides, *args],
            capture_output=True,
            text=text,
            timeout=timeout,
            env=env,
            check=False,
            input=input,
        )

    def _neutralise_attributes(self) -> None:
        """``info/attributes`` is read even with ``GIT_ATTR_SOURCE``; in an own
        ``.git`` the agent can write it. Keep it empty (and never follow a
        symlink there)."""
        base = self._common_dir or self._git_dir
        if base is None:
            return
        path = base / "info" / "attributes"
        try:
            st = os.lstat(path)
        except OSError:
            return
        try:
            if stat.S_ISLNK(st.st_mode) or not stat.S_ISREG(st.st_mode):
                os.unlink(path)
            elif st.st_size:
                fd = os.open(path, os.O_WRONLY | os.O_TRUNC | os.O_NOFOLLOW)
                os.close(fd)
        except OSError:
            return

    def _driver_overrides(self, cwd: str | os.PathLike, env: dict[str, str]) -> list[str]:
        """``-c <key>=`` for every filter/diff/merge driver command the repo
        config defines: an empty command is no command. Defence in depth next
        to ``GIT_ATTR_SOURCE`` (no driver can be selected anyway). Cached on
        the stat of every config file git read."""
        cache_key = f"{cwd}\0{env.get('GIT_DIR', '')}"
        cached = self._driver_cache
        if cached is not None and cached[0][0] == cache_key and _config_signature(cached[0][1]) == cached[0][2]:
            return cached[1]
        try:
            proc = subprocess.run(
                ["git", "-C", str(cwd), *self._config, "config", "--list",
                 "--show-origin", "--name-only", "-z"],
                capture_output=True, text=True, timeout=GIT_TIMEOUT_S, env=env, check=False,
            )
        except (OSError, subprocess.SubprocessError):
            return []
        if proc.returncode != 0:
            return []
        overrides: list[str] = []
        origins: set[str] = set()
        fields = proc.stdout.split("\0")
        # -z with --show-origin: "<origin>\0<name>\0" pairs.
        for i in range(0, len(fields) - 1, 2):
            origin, name = fields[i], fields[i + 1]
            if origin.startswith("file:"):
                origins.add(origin[5:])
            match = _DRIVER_KEY.match(name.strip())
            if match:
                overrides += ["-c", f"{name.strip()}="]
                if name.startswith("filter."):
                    overrides += ["-c", f"filter.{match.group(2)}.required=false"]
        files = tuple(sorted(origins))
        self._driver_cache = ((cache_key, files, _config_signature(files)), overrides)
        return overrides

    def _bootstrap(self) -> bool:
        if shutil.which("git") is None:
            return False
        try:
            self.root.mkdir(parents=True, exist_ok=True)
        except OSError:
            return False

        try:
            # Three cases (bead B14):
            # 1. A private git dir exists in the host state (or an older
            #    build left one at ``.agents/git``, moved there now): the
            #    agent's private repo from an earlier start, over a repo of
            #    the user's.
            # 2. ``.git`` exists and is the agent's own (its identity is in the
            #    local config; also true for a subagent worktree of it): keep
            #    using it, exactly as before.
            # 3. ``.git`` exists and belongs to the user: never commit into it.
            #    The agent gets a private git dir over the same files.
            # No repo at all: the agent makes its own ``.git``, as before.
            created = False
            if self._state_dir is None:
                self._state_dir = workspace_state_dir(self.root)
            private = self._state_dir / STATE_GIT_DIRNAME
            legacy = self.root / LEGACY_PRIVATE_GIT_DIR
            if _is_real_dir(private):
                self._private_dir = private.resolve()
            elif _is_real_dir(legacy) and self._migrate_legacy_private(legacy, private):
                self._private_dir = private.resolve()
            elif (self.root / ".git").exists():
                if not self._is_own_repo():
                    if not self._init_private(private):
                        return False
                    created = True
            else:
                if self._git("init", "-q").returncode != 0:
                    return False
                # Written into our own repo so it works outside this process
                # too — the identity is never taken from a global config, which
                # `_git` switches off, so a host without one still commits.
                self._git("config", "--local", "user.name", self._author[0])
                self._git("config", "--local", "user.email", self._author[1])
                created = True

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
            self._ledger_file = self._resolve_ledger_file()

            if self._private_dir is not None:
                # The user's tree gets no .gitignore of ours: the patterns go
                # into the private repo's own exclude file instead.
                self._ensure_private_excludes()
            elif created:
                # Only a repo the agent just made gets a .gitignore. An adopted
                # checkout (a subagent worktree) already carries it, and a file
                # written here would end up in a merge back.
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
            self._commit("agents: workspace initialised", [])
        return True

    def _is_own_repo(self) -> bool:
        """True when ``root/.git`` is a repo the agent made: its local config
        carries the agent identity (written at ``init``). A subagent worktree
        of such a repo reads the same config. A user's repo does not."""
        probe = self._git("config", "--local", "--get", "user.email")
        if probe.returncode != 0:
            return False
        return probe.stdout.strip() in {self._author[1], DEFAULT_AUTHOR_EMAIL}

    def _init_private(self, private: Path) -> bool:
        """Create the private git dir (host state) for a workspace that is the
        user's repo."""
        try:
            private.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        except OSError:
            return False
        done = self._git_in(
            self.root,
            "--git-dir",
            str(private),
            "init",
            "-q",
            extra_env={"GIT_WORK_TREE": str(self.root.resolve())},
        )
        if done.returncode != 0:
            return False
        self._private_dir = private.resolve()
        self._git("config", "--local", "user.name", self._author[0])
        self._git("config", "--local", "user.email", self._author[1])
        self._hide_from_user_repo()
        return True

    def _migrate_legacy_private(self, legacy: Path, private: Path) -> bool:
        """Move a private git dir an older build kept at ``.agents/git`` into
        the host state: copy, sanitise the config, verify HEAD and every ref,
        and only then delete the old one. False (nothing moved, nothing
        deleted) when the old dir holds a symlink or does not verify: it is
        then not trusted, and a fresh private dir is made instead."""
        try:
            for dirpath, dirnames, filenames in os.walk(legacy, followlinks=False):
                for name in dirnames + filenames:
                    if os.path.islink(os.path.join(dirpath, name)):
                        return False
        except OSError:
            return False
        work_tree = str(self.root.resolve())

        def git_at(git_dir: Path, *args: str) -> subprocess.CompletedProcess:
            return self._git_in(
                self.root, *args,
                extra_env={"GIT_DIR": str(git_dir), "GIT_WORK_TREE": work_tree},
            )

        before = git_at(legacy, "rev-parse", "--verify", "-q", "HEAD")
        if before.returncode != 0 or not before.stdout.strip():
            return False
        head = before.stdout.strip()
        # A subagent checkout under the old dir goes away with it: commit what
        # it still holds onto its branch first, so no work is lost.
        listing = git_at(legacy, "worktree", "list", "--porcelain")
        for line in listing.stdout.splitlines() if listing.returncode == 0 else []:
            if not line.startswith("worktree "):
                continue
            path = Path(line[len("worktree "):])
            if path.is_dir() and path.resolve() != self.root.resolve():
                self._git_in(path, "add", "-A", "--", ".")
                self._git_in(path, "commit", "-q", "--no-verify", "-m",
                             "subagent: state before private repo move")
        refs_before = git_at(legacy, "for-each-ref", "--format=%(objectname) %(refname)")
        if refs_before.returncode != 0:
            return False
        tmp = private.with_name(private.name + ".migrating")
        try:
            private.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            if tmp.exists():
                shutil.rmtree(tmp)
            shutil.copytree(legacy, tmp, symlinks=True,
                            ignore=shutil.ignore_patterns(WORKTREE_DIRNAME))
            _sanitise_private_config(tmp / "config", self._author)
            # Agent-writable until now, so not carried over. Without a ledger
            # a rewind treats every changed file as the user's (safe refuses).
            for name in (LEDGER_FILENAME, "info/attributes"):
                if (tmp / name).exists():
                    (tmp / name).unlink()
            if (tmp / "hooks").is_dir():
                shutil.rmtree(tmp / "hooks")
        except OSError:
            shutil.rmtree(tmp, ignore_errors=True)
            return False
        after = git_at(tmp, "rev-parse", "--verify", "-q", "HEAD")
        refs_after = git_at(tmp, "for-each-ref", "--format=%(objectname) %(refname)")
        tree_ok = git_at(tmp, "cat-file", "-e", "HEAD^{tree}").returncode == 0
        if (
            after.returncode != 0
            or after.stdout.strip() != head
            or refs_after.stdout != refs_before.stdout
            or not tree_ok
        ):
            shutil.rmtree(tmp, ignore_errors=True)
            return False
        try:
            os.replace(tmp, private)
        except OSError:
            shutil.rmtree(tmp, ignore_errors=True)
            return False
        # The verified copy is in place: only now the old one goes.
        shutil.rmtree(legacy, ignore_errors=True)
        git_at(private, "worktree", "prune")
        return True

    def _ensure_private_excludes(self) -> None:
        """The private repo never commits the legacy dir or the subagent
        checkouts, and keeps the media patterns a fresh workspace has in its
        .gitignore."""
        if self._private_dir is None:
            return
        exclude = self._private_dir / "info" / "exclude"
        wanted = [f"/{LEGACY_PRIVATE_GIT_DIR}/", f"/{PRIVATE_WORKTREE_DIR}/"]
        try:
            existing = exclude.read_text(encoding="utf-8") if exclude.exists() else ""
            lines = existing.splitlines()
            missing = [line for line in wanted if line not in lines]
            if not missing:
                return
            exclude.parent.mkdir(parents=True, exist_ok=True)
            with exclude.open("a", encoding="utf-8") as handle:
                if existing and not existing.endswith("\n"):
                    handle.write("\n")
                handle.write("# Agents private checkpoints (bead B14)\n")
                for line in missing:
                    handle.write(f"{line}\n")
                if "*.mp4" not in lines:
                    handle.write(GITIGNORE_BODY)
        except OSError:
            return

    def _resolve_ledger_file(self) -> Path | None:
        """The ledger of this repo, in the host state. Shared by the
        workspace and its subagent worktrees (keyed by the common git dir)."""
        common = self._common_dir or self._git_dir
        if common is None:
            return None
        try:
            common = common.resolve()
            home = git_state_home().resolve()
        except OSError:
            return None
        if common.name == STATE_GIT_DIRNAME and common.parent.parent == home:
            return common.parent / LEDGER_FILENAME  # a private repo's folder
        # An own ``.git``: keyed by the workspace that holds it.
        return workspace_state_dir(common.parent) / LEDGER_FILENAME

    def _hide_from_user_repo(self) -> None:
        """Keep ``.agents/`` out of the user's ``git status`` and ``git add -A``.

        Written to the user's ``info/exclude``: a local file, never committed,
        not the index, refs or history. Without it a ``git add -A`` of the user
        would sweep the agent's whole object store into the user's repo."""
        try:
            # No ``--path-format=absolute``: it needs Git 2.31, and on an older
            # Git the probe failed and nothing was excluded. The plain answer
            # is relative to ``root`` (``-C``) or absolute; ``root / value``
            # handles both.
            probe = self._git_in(self.root, "rev-parse", "--git-common-dir")
            if probe.returncode != 0 or not probe.stdout.strip():
                return
            exclude = Path(self.root) / probe.stdout.strip() / "info" / "exclude"
            line = f"/{JOURNAL_DIRNAME}/"
            existing = exclude.read_text(encoding="utf-8") if exclude.exists() else ""
            if line in existing.splitlines():
                return
            exclude.parent.mkdir(parents=True, exist_ok=True)
            with exclude.open("a", encoding="utf-8") as handle:
                if existing and not existing.endswith("\n"):
                    handle.write("\n")
                handle.write(f"{line}\n")
        except (OSError, subprocess.SubprocessError):
            return

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

    # -- checkpoints, rewind (docs/WIRE_CONTRACT.md, "Checkpoints, rewind
    # and fork", Hermes H30/H31) ------------------------------------------

    def _ledger_path(self) -> Path | None:
        """The agent-write ledger: ``{path: blob sha | "-"}`` of the last
        version of each file the AGENT wrote ("-" = the agent deleted it).
        In the host state (H3), never in the workspace: the agent cannot
        make it lie about who wrote a file. Never committed, never rewound."""
        return self._ledger_file

    def agent_writes(self) -> dict[str, str]:
        path = self._ledger_path()
        if path is None:
            return {}
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            return {}
        return {str(k): str(v) for k, v in data.items()} if isinstance(data, dict) else {}

    def _save_agent_writes(self, ledger: dict[str, str]) -> None:
        path = self._ledger_path()
        if path is None:
            return
        try:
            path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
            tmp = path.with_suffix(".tmp")
            tmp.write_text(json.dumps(ledger, sort_keys=True), encoding="utf-8")
            os.replace(tmp, path)
        except OSError:
            return

    def _blob_of(self, rel: str) -> str:
        """The blob sha of a working-tree file, or ``"-"`` when it is gone,
        ``"?"`` when it cannot be read safely. Read without following a
        symlink (a symlink hashes as its target text, the way git stores it),
        so the hash never reveals a file outside the workspace."""
        try:
            found = _safe_read(self.root, rel)
        except (UnsafePath, OSError):
            return "?"
        if found is None:
            return "-"
        proc = self._git("hash-object", "--no-filters", "--stdin", text=False, input=found[1])
        return proc.stdout.decode("ascii", "replace").strip() if proc.returncode == 0 else "?"

    def note_agent_writes(self, paths: list[str]) -> None:
        """Record that the agent wrote ``paths`` (the files a tool call
        changed). The ledger is what lets a rewind tell the agent's work from
        the user's own later hand edits (Hermes H31)."""
        if not self._enabled or not paths:
            return
        with self._lock:
            ledger = self.agent_writes()
            for rel in paths:
                if rel == self.journal_path or rel.startswith(JOURNAL_DIRNAME + "/"):
                    continue
                ledger[rel] = self._blob_of(rel)
            self._save_agent_writes(ledger)

    def outside_changes(self) -> list[str]:
        """Paths changed since the last commit, journal excluded: before an
        agent call these are changes made OUTSIDE the agent."""
        if not self._enabled:
            return []
        return [p for _, p in self._pending() if p != self.journal_path]

    def commit_outside_changes(self) -> CommitInfo | None:
        """Commit what changed outside the agent as its own commit, so the
        next commit holds only the agent's changes and the ledger stays true.
        Inside :meth:`batch` nothing is committed: the pending changes are the
        batch's own (the agent's), and the batch is one commit by design."""
        if not self._enabled or self._batch is not None:
            return None
        with self._lock:
            pending = self._pending()
            changed = [p for _, p in pending if p != self.journal_path]
            if not changed:
                return None
            return self._commit(
                "outside: changes made outside the agent",
                [f"tool: {OUTSIDE_TOOL}", f"files-changed: {len(changed)}"],
                pending,
            )

    def create_checkpoint(self, checkpoint_id: str) -> CommitInfo | None:
        """The workspace as it is now, pinned under
        ``refs/agents/checkpoints/<id>``. Changes outside the agent are
        committed first, so the checkpoint is exactly what the user had."""
        if not self._enabled or not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", checkpoint_id or ""):
            return None
        with self._lock:
            self.commit_outside_changes()
            head = self._git("rev-parse", "HEAD")
            if head.returncode != 0:
                return None
            sha = head.stdout.strip()
            self._git("update-ref", f"{CHECKPOINT_REF_PREFIX}{checkpoint_id}", sha)
            return CommitInfo(commit=sha, short=sha[:8], time=_now(), subject=f"checkpoint {checkpoint_id}")

    def drop_checkpoint(self, checkpoint_id: str) -> None:
        if self._enabled and re.fullmatch(r"[A-Za-z0-9_-]{1,64}", checkpoint_id or ""):
            self._git("update-ref", "-d", f"{CHECKPOINT_REF_PREFIX}{checkpoint_id}")

    def rewind(self, commit: str, *, mode: str = REWIND_SAFE) -> dict:
        """Restore the files the agent changed since ``commit`` (a checkpoint).

        A file that differs from the checkpoint is the agent's when its
        current content is the version the agent last wrote (the ledger). Any
        other difference is a change made outside the agent (the user's hand
        edit). ``mode``:

        - ``safe`` (default): refuse the whole rewind when there is one such
          file; nothing changes; the answer lists them;
        - ``keep_user_edits``: restore the agent's files, leave the others;
        - ``merge``: like ``keep_user_edits``, but a text file the agent
          wrote and the user then edited gets a 3-way merge (base = the
          agent's version, ours = now, theirs = the checkpoint); a clean merge
          is written, a conflict leaves the file as it is;
        - ``force``: restore every file, also the user's edits.

        Like :meth:`rollback`, the restore is a new commit; history and the
        journal are kept."""
        if not self._enabled:
            return {"ok": False, "error": "workspace versioning is not enabled"}
        if mode not in REWIND_MODES:
            return {"ok": False, "error": f"mode must be one of {', '.join(REWIND_MODES)}"}
        with self._lock:
            resolved = self._git("rev-parse", "--verify", "-q", f"{commit}^{{commit}}")
            if resolved.returncode != 0 or not resolved.stdout.strip():
                return {"ok": False, "error": "no such checkpoint"}
            target = resolved.stdout.strip()
            self.commit_outside_changes()
            diff = self._git("diff", "--name-only", "-z", "--no-renames", target, "HEAD", "--")
            if diff.returncode != 0:
                return {"ok": False, "error": (diff.stderr or "diff failed").strip()[:400]}
            paths = [
                p for p in diff.stdout.split("\0")
                if p and p != self.journal_path and not p.startswith(JOURNAL_DIRNAME + "/")
            ]
            ledger = self.agent_writes()
            agent_owned: list[str] = []
            user_edited: list[str] = []
            for rel in paths:
                current = self._blob_of(rel)
                if ledger.get(rel) == current:
                    agent_owned.append(rel)
                else:
                    user_edited.append(rel)
            if user_edited and mode == REWIND_SAFE:
                return {
                    "ok": False,
                    "error": "files changed outside the agent since this checkpoint",
                    "conflicts": user_edited[:200],
                    "restorable": len(agent_owned),
                }
            restore = list(agent_owned) + (list(user_edited) if mode == REWIND_FORCE else [])
            merged: list[str] = []
            kept: list[str] = []
            if mode == REWIND_MERGE:
                for rel in user_edited:
                    if self._merge_back(rel, ledger.get(rel), target):
                        merged.append(rel)
                    else:
                        kept.append(rel)
            elif mode == REWIND_KEEP:
                kept = list(user_edited)
            # A path through a symlink is refused, not restored (H2).
            refused = [rel for rel in restore if not self._restore_path(rel, target)]
            restore = [rel for rel in restore if rel not in refused]
            entry = self._build_entry(
                REWIND_TOOL,
                {"target": target, "mode": mode},
                {"ok": True, "restored": len(restore), "merged": len(merged),
                 "kept": len(kept), "refused": len(refused)},
                None,
                restore + merged,
            )
            self._append_journal(entry)
            info = self._commit(
                f"rewind: restore workspace to checkpoint {target[:8]}",
                [f"tool: {REWIND_TOOL}", f"journal-seq: {entry['seq']}"],
            )
            # What the rewind wrote is now the agent's version.
            ledger = self.agent_writes()
            for rel in restore + merged:
                ledger[rel] = self._blob_of(rel)
            self._save_agent_writes(ledger)
            return {
                "ok": True,
                "restored": restore[:200],
                "merged": merged[:200],
                "kept": kept[:200],
                "refused": refused[:200],
                "commit": info.commit if info else None,
                "note": (
                    "Files are restored. Effects outside the workspace (sent mail, "
                    "API calls, installed packages) are NOT undone."
                ),
            }

    def _tree_entry(self, target: str, rel: str) -> tuple[str, str] | None:
        """``(mode, blob sha)`` of ``rel`` in commit ``target``, or ``None``."""
        proc = self._git("ls-tree", "-z", target, "--", rel)
        if proc.returncode != 0 or not proc.stdout:
            return None
        meta, _, name = proc.stdout.rstrip("\0").partition("\t")
        parts = meta.split()
        if name != rel or len(parts) != 3 or parts[1] != "blob":
            return None
        return parts[0], parts[2]

    def _blob_bytes(self, sha: str) -> bytes | None:
        """Raw blob bytes: ``cat-file blob`` runs no filter and no textconv."""
        proc = self._git("cat-file", "blob", sha, text=False)
        return proc.stdout if proc.returncode == 0 else None

    def _restore_path(self, rel: str, target: str) -> bool:
        """Put ``rel`` back to its version in ``target`` (or delete it). Never
        writes or deletes through a symlink (H2): a symlinked parent refuses
        the path; a symlink at the leaf is replaced, not followed."""
        entry = self._tree_entry(target, rel)
        try:
            if entry is None:
                _safe_unlink(self.root, rel)
                return True
            mode, sha = entry
            if mode not in ("100644", "100755", "120000"):
                return False  # a submodule entry: nothing to write
            data = self._blob_bytes(sha)
            if data is None:
                return False
            _safe_write(self.root, rel, data, mode=mode)
            return True
        except (UnsafePath, OSError):
            return False

    def _merge_back(self, rel: str, base_blob: str | None, target: str) -> bool:
        """3-way: undo the agent's change (base -> checkpoint) on top of the
        current file with the user's edit in it. True when the merge was
        clean and written. A symlink anywhere on the path refuses the merge."""
        if not base_blob or base_blob in ("-", "?"):
            return False
        try:
            current = _safe_read(self.root, rel)
        except (UnsafePath, OSError):
            return False
        if current is None or current[0] != "file":
            return False
        entry = self._tree_entry(target, rel)
        if entry is None or entry[0] not in ("100644", "100755"):
            return False
        import tempfile

        base = self._blob_bytes(base_blob)
        theirs = self._blob_bytes(entry[1])
        ours = current[1]
        if base is None or theirs is None or b"\0" in base or b"\0" in theirs or b"\0" in ours:
            return False
        # Scratch files in the host's temp dir, never in the workspace.
        with tempfile.TemporaryDirectory(prefix="agents-merge-") as tmp:
            files = []
            for name, data in (("ours", ours), ("base", base), ("theirs", theirs)):
                path = Path(tmp) / name
                path.write_bytes(data)
                files.append(str(path))
            proc = subprocess.run(
                ["git", "merge-file", "-p", *files],
                capture_output=True, timeout=GIT_TIMEOUT_S, env=_hardened_env(), check=False,
            )
        if proc.returncode != 0:
            return False
        try:
            _safe_write(self.root, rel, proc.stdout, mode=entry[0])
        except (UnsafePath, OSError):
            return False
        return True

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
            merge_message = message or f"subagent: merge {info.branch}"
            merged = self._git(
                "merge", "--no-ff", "--no-edit", "-m", merge_message, info.branch,
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
        if self._private_dir is not None:
            # The private git dir is host state, outside the workspace; the
            # child's checkout stays inside it (a container sandbox mounts
            # only the workspace) and is excluded from the private repo.
            return self.root / PRIVATE_WORKTREE_DIR / branch.replace("/", "_")
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
