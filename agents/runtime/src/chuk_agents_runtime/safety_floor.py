"""The safety floor (research docs/research/HERMES_AND_OTHER_AGENTS.md H23-H25,
and docs/WIRE_CONTRACT.md "Safety floor").

The agent runs on the user's real computer, so a small set of actions is
stopped before it runs, whatever the approval mode:

- **Hard deny** (never allowed): a recursive delete of ``/``, a top-level
  system directory, the home directory or anything that holds it (``~``,
  ``~/*``, ``/home``, ``/*/``, ``/{bin,etc}`` …), ``mkfs*``, writing a block
  device (``dd of=/dev/sda``, ``> /dev/sda``, ``cp x.iso /dev/sda``,
  ``wipefs``, ``blkdiscard`` …), a fork bomb, a recursive world-writable
  ``chmod`` of ``/``, and deleting or overwriting the agent's own install or
  state directory.
- **Soft stop** (needs the user's explicit approval): writing under
  ``~/.ssh``, ``~/.aws``, ``~/.gnupg``, ``~/.config/gh``, ``~/.netrc``; reading
  a private key or a credentials file there; touching any ``.env`` file;
  ``shutdown`` / ``reboot`` (unless the host allows them); a recursive delete
  of a target the floor cannot resolve (``rm -rf "$DIR"``); a shell that reads
  code the floor cannot see (``curl … | sh``).

The floor is defense in depth. The sandbox is the real boundary.

Matching is on shell tokens (quoting as the shell reads it), not raw
substrings, so a path inside a string literal or a comment does not trip it,
and a quoted or escaped operator (``';'``, ``\\;``) does not split a command.
Here-documents, here-strings, ``$(…)``, backticks, ``bash -c``, ``eval``,
``alias`` values, ``trap`` strings and launchers (``sudo``, ``env -S``,
``watch`` …) are followed.

The floor FAILS CLOSED: a command it cannot parse with certainty (an open
quote, nesting that is too deep, too much work) is never let through
silently. A catastrophic shape visible anywhere in the raw text is a hard
deny; anything else is a soft stop.
"""

from __future__ import annotations

import itertools
import os
import posixpath
import re
from dataclasses import dataclass, field
from fnmatch import fnmatchcase


@dataclass(frozen=True)
class FloorVerdict:
    """Why an action is stopped. ``hard`` is an unconditional deny; a soft
    verdict can be lifted by an explicit approval (an allowed command prefix)."""

    reason: str
    hard: bool = True

    def message(self) -> str:
        if self.hard:
            return (
                f"blocked by the safety floor: {self.reason}. This is never allowed. "
                "Do not retry it; tell the user what you were asked to do and why it was refused."
            )
        return (
            f"stopped by the safety floor: {self.reason}. It needs the user's explicit "
            "approval and did not happen. Ask the user to allow it, or do the task another way."
        )


#: Protected directories under $HOME (research H24). A write under one of
#: these, and any read or write of a ``.env`` file, asks first.
PROTECTED_REL = (".ssh", ".aws", ".gnupg", ".netrc", os.path.join(".config", "gh"))

#: Top-level system directories. A recursive delete of one is a hard deny.
_SYSTEM_TOP = (
    "bin", "boot", "etc", "home", "lib", "lib32", "lib64", "libx32", "opt", "root",
    "sbin", "srv", "usr", "var",
)

#: Commands that read a file's content (a secret file read asks).
_READ_VERBS = frozenset(
    {
        "cat", "tac", "less", "more", "head", "tail", "bat", "batcat", "nl", "xxd", "od", "hexdump",
        "strings", "grep", "egrep", "fgrep", "rg", "ag", "ack", "sed", "awk", "gawk", "mawk", "cut",
        "sort", "uniq", "wc", "diff", "cmp", "base64", "base32", "basenc", "uuencode", "source", ".",
        "tar", "zip", "gzip", "bzip2", "xz", "zstd", "7z", "openssl", "gpg", "jq", "yq", "column",
        "paste", "join", "comm", "fold", "fmt", "pr", "rev", "tr", "iconv", "vim", "vi", "nano",
        "emacs", "code", "view", "python", "python3", "node", "perl", "ruby", "php", "curl", "wget",
        "nc", "ncat", "socat", "scp", "sftp", "cp", "rsync", "install", "dd",
    }
)
#: Commands that change the files they name.
_WRITE_VERBS = frozenset(
    {
        "rm", "rmdir", "mv", "cp", "tee", "truncate", "dd", "chmod", "chown", "chgrp", "ln",
        "install", "shred", "unlink", "touch", "rsync", "scp", "sed", "perl",
    }
)
#: Commands that only list or name a path; touching a protected path with
#: them is fine (``ls ~/.ssh``, ``ssh -i ~/.ssh/key host``).
_PATH_ONLY_VERBS = frozenset(
    {
        "ls", "stat", "file", "test", "[", "[[", "realpath", "readlink", "basename", "dirname",
        "echo", "printf", "true", "false", ":", "cd", "pushd", "popd", "ssh", "ssh-add", "du",
        "which", "type", "mkdir", "export", "declare", "local", "readonly", "typeset", "unset",
    }
)
#: Commands that may take ``-r`` / ``-R`` on ``/`` or ``~`` without deleting
#: anything. Any other command with a recursive flag on such a target is
#: treated like ``rm -r``.
_RECURSIVE_SAFE = frozenset(
    {
        "grep", "egrep", "fgrep", "rg", "ag", "ack", "ls", "du", "tree", "diff", "cp", "scp", "rsync",
        "zip", "tar", "git", "wc", "cat", "sort", "file", "stat", "chmod", "chown", "chgrp",
        "getfacl", "find", "locate", "mkdir", "rmdir", "echo", "printf", "test", "less", "head",
        "tail", "code", "vim", "python", "python3", "pip", "pip3", "uv", "npm", "pnpm", "yarn",
        "sha256sum", "sha1sum", "md5sum", "b2sum", "cksum", "unzip", "7z", "aws", "gsutil",
        "rclone", "clamscan", "pytest", "make", "docker", "podman", "kubectl", "helm", "ln", "cd",
        "wget", "curl", "fd", "fdfind", "exa", "eza", "lsd", "ncdu", "dust", "rename", "sed",
    }
)
#: Launchers: the real command follows their options and values.
_LAUNCHERS = frozenset(
    {
        "sudo", "env", "nice", "nohup", "stdbuf", "setsid", "time", "command", "doas", "exec",
        "timeout", "xargs", "ionice", "watch", "taskset", "chroot", "flock", "busybox", "builtin",
        "pkexec", "runuser", "su", "systemd-run", "unshare", "script", "strace", "ltrace",
        "nsenter", "firejail", "chrt", "caffeinate", "catchsegv", "faketime", "torsocks",
        "proxychains", "proxychains4",
    }
)
#: Commands that end the machine.
_SHUTDOWN = frozenset({"shutdown", "reboot", "halt", "poweroff"})
#: Programs that make a filesystem; always a hard deny.
_MKFS = frozenset({"mke2fs", "mkdosfs", "mkntfs", "mkexfatfs", "mformat", "newfs"})
#: Disk tools that are a hard deny on a block device.
_DISK_TOOLS = frozenset(
    {"wipefs", "blkdiscard", "sgdisk", "mkswap", "shred", "cryptsetup", "badblocks", "sfdisk",
     "fdisk", "cfdisk", "parted", "gdisk", "zpool", "pvcreate", "vgcreate", "hdparm"}
)
#: Flags with which those disk tools only list.
_DISK_LIST_FLAGS = frozenset({"-l", "--list", "-p", "--print", "print", "-i", "--info", "-s", "-v"})
#: Device nodes that must not be written.
_BLOCK_DEV = re.compile(
    r"^/dev/(sd|hd|vd|xvd|nvme|mmcblk|dm-|md\d|md/|loop\d|disk|mapper/|sr\d|root$|nbd|zd|rbd|bcache)"
)
#: Shells whose ``-c`` string, here-document or piped input is a command.
_SHELLS = frozenset(
    {"sh", "bash", "zsh", "dash", "ksh", "mksh", "fish", "ash", "busybox-sh", "rbash", "yash", "tcsh", "csh"}
)
#: Programs that read commands from their input like a shell.
_STDIN_SHELLS = _SHELLS | {"at", "batch"}
#: Verbs that never read a file named in their arguments (a ``.env`` word
#: there is just a word).
_NO_FILE_VERBS = frozenset(
    {"echo", "printf", "true", "false", ":", "test", "[", "[[", "ls", "stat", "file", "realpath",
     "readlink", "basename", "dirname", "which", "type", "export", "mkdir", "cd"}
)
#: Shell reserved words that can stand before a command.
_RESERVED = frozenset(
    {"{", "}", "!", "if", "then", "else", "elif", "do", "while", "until", "fi", "done", "in", "esac"}
)
_ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*\+?=")
_VAR_REF = re.compile(r"\$(?:\{([A-Za-z_][A-Za-z0-9_]*)\}|([A-Za-z_][A-Za-z0-9_]*))")

#: Deepest nesting of ``bash -c`` / ``$(…)`` the floor follows.
_MAX_DEPTH = 8
#: Deepest nesting of quotes and ``$(`` inside one string the lexer reads.
_MAX_NEST = 50
#: Characters the floor lexes for one command in total (all nesting levels).
_WORK_LIMIT = 500_000
#: Longest command the floor parses; a longer one fails closed.
_MAX_COMMAND = 100_000
#: Most expansions of one word (braces, variables).
_MAX_EXPANSIONS = 64
#: Most later words a launcher's command may start at.
_MAX_LAUNCHER_POSITIONS = 12


class _Unparsable(ValueError):
    """The floor cannot read the command with certainty (it fails closed)."""


@dataclass
class _Chain:
    """What one command string sets up for its later parts: the working
    directory after a ``cd`` and the plain variable assignments."""

    cwd: str | None = None
    vars: dict[str, list[str]] = field(default_factory=dict)


#: Marker for a pipe input the floor cannot see.
_PIPE_UNKNOWN = object()


@dataclass
class SafetyFloor:
    """The floor for one run. ``home`` is the user's home; ``self_dirs`` are the
    agent's own install/state directories (never deleted). ``allow_shutdown``
    lets the host permit power commands. ``prefix_allowed`` is the per-agent
    'approve and remember' check (:mod:`chuk_agents_runtime.action_policy`):
    when it returns ``True`` for a command, a *soft* stop is lifted; a hard
    deny never is."""

    home: str = field(default_factory=lambda: os.path.expanduser("~"))
    self_dirs: tuple[str, ...] = ()
    allow_shutdown: bool = False
    prefix_allowed: "object | None" = None

    # -- paths ----------------------------------------------------------------

    def _expand(self, token: str) -> str:
        text = str(token)
        if text in ("~", "$HOME", "${HOME}"):
            return _norm(self.home)
        if text.startswith("~/"):
            text = self.home + text[1:]
        text = text.replace("${HOME}", self.home).replace("$HOME", self.home)
        return _norm(text) if text.startswith("/") else posixpath.normpath(text)

    def _protected_dirs(self) -> list[str]:
        return [posixpath.normpath(posixpath.join(self.home, rel)) for rel in PROTECTED_REL]

    def _under(self, path: str, base: str) -> bool:
        path = _norm(path)
        base = _norm(base)
        return path == base or base == "/" or path.startswith(base + "/")

    def protected_target(self, raw_path: str) -> str | None:
        """The protected location a path falls in, or ``None``. Used by the
        file tools before a write, a delete or a ``.env`` read."""
        path = self._expand(str(raw_path))
        if _env_name(posixpath.basename(path)):
            return ".env file"
        if not path.startswith("/"):
            path = _norm(posixpath.join(self.home, path))
        for base in self._protected_dirs():
            if self._under(path, base):
                return base
        return None

    def _self_dir_of(self, path: str) -> str | None:
        if not path.startswith("/"):
            return None
        for d in self.self_dirs:
            if self._under(path, d):
                return d
        return None

    def check_path_write(self, raw_path: str) -> FloorVerdict | None:
        """A write / delete of ``raw_path`` (file tools). The agent's own
        directories are a hard deny; a protected path is a soft stop."""
        path = self._expand(str(raw_path))
        d = self._self_dir_of(path)
        if d is not None:
            return FloorVerdict(f"this would change the agent's own files ({d})", hard=True)
        hit = self.protected_target(raw_path)
        if hit is None:
            return None
        return FloorVerdict(f"writing {hit} is protected", hard=False)

    def check_path_read(self, raw_path: str) -> FloorVerdict | None:
        """A read of ``raw_path`` (file tools): a ``.env`` file, a private key
        or a credentials file asks."""
        path = self._expand(str(raw_path))
        if _env_name(posixpath.basename(path)):
            return FloorVerdict("reading a .env file is protected", hard=False)
        hit = self._secret_hit(path if path.startswith("/") else _norm(posixpath.join(self.home, path)))
        if hit is not None:
            return FloorVerdict(f"reading {hit} is protected", hard=False)
        return None

    # -- path classification (globs allowed) ------------------------------------

    def _critical(self) -> list[tuple[str, str]]:
        """Directories whose recursive delete is a hard deny, with a label."""
        out = [("/" + name, f"/{name}") for name in _SYSTEM_TOP]
        out.append((_norm(self.home), "your home directory"))
        out.extend((_norm(d), f"the agent's own directory ({d})") for d in self.self_dirs)
        return out

    def _wipe_hit(self, path: str) -> str | None:
        """``path`` (absolute, globs allowed) is ``/``, a top-level system
        directory, or holds the home or an agent directory: deleting it
        recursively is catastrophic. A glob counts by what it can match; a
        glob that is only wildcards (``~/*``, ``/*/``) counts as its prefix."""
        if not path.startswith("/"):
            return None
        comps = _comps(path)
        if not comps:
            return "/"
        k = next((i for i, c in enumerate(comps) if _has_glob(c)), None)
        if k is not None and _pure_wildcard(comps[k]):
            prefix = comps[:k]
            if not prefix:
                return "/"
            for crit, label in self._critical():
                if _may_cover(prefix, _comps(crit), ancestor=True, inside=False):
                    return label
        for crit, label in self._critical():
            if _may_cover(comps, _comps(crit), ancestor=True, inside=False):
                return label
        return None

    def _protected_hit(self, path: str, *, ancestor: bool = False) -> str | None:
        """``path`` (absolute, globs allowed) may be or lie in a protected
        directory (or hold one, when ``ancestor``)."""
        comps = _comps(path)
        for base in self._protected_dirs():
            if _may_cover(comps, _comps(base), ancestor=ancestor, inside=True):
                return base
        return None

    def _secret_hit(self, path: str) -> str | None:
        """``path`` (absolute, globs allowed) may be a private key or a
        credentials file (a read of it asks)."""
        comps = _comps(path)
        for base in self._protected_dirs():
            bcomps = _comps(base)
            if not _may_cover(comps, bcomps, ancestor=False, inside=True):
                continue
            if posixpath.basename(base) == ".ssh" and len(comps) > len(bcomps):
                last = comps[-1]
                if not _has_glob(last) and (
                    last.endswith(".pub") or last.startswith("known_hosts") or last == "config"
                ):
                    continue
            return base
        return None

    # -- word resolution ----------------------------------------------------------

    def _resolve(self, word: str, chain: _Chain) -> list[str | None]:
        """Every path ``word`` can name: brace expansion, variables the chain
        knows, ``~`` / ``$HOME``, the ``cd`` directory, normalised. ``None``
        stands for a path the floor cannot resolve (``$X``, ``$(…)``,
        ``~user``). A relative path stays relative when the directory is
        unknown."""
        out: list[str | None] = []
        for w in _brace_expand(str(word)):
            for v in self._substitute(w, chain):
                out.append(None if v is None else self._finish_path(v, chain))
                if len(out) >= _MAX_EXPANSIONS:
                    return out
        return out

    def _substitute(self, w: str, chain: _Chain) -> list[str | None]:
        if "$(" in w or "`" in w or "<(" in w:
            return [None]
        if "$" not in w:
            return [w]
        refs = list(_VAR_REF.finditer(w))
        names = [m.group(1) or m.group(2) for m in refs]
        values: list[list[str]] = []
        for name in names:
            if name == "HOME":
                values.append([self.home])
            elif name in chain.vars:
                values.append(chain.vars[name])
            else:
                return [None]
        out: list[str | None] = []
        for combo in itertools.islice(itertools.product(*values), _MAX_EXPANSIONS):
            it = iter(combo)
            text = _VAR_REF.sub(lambda _m: next(it), w)
            out.append(None if "$" in text else text)
        return out or [None]

    def _finish_path(self, w: str, chain: _Chain) -> str | None:
        if w == "~" or w.startswith("~/"):
            w = self.home + w[1:]
        elif w == "~+" or w.startswith("~+/"):
            if chain.cwd is None:
                return None
            w = chain.cwd + w[2:]
        elif w.startswith("~"):
            return None  # ``~user``, ``~-``
        if w.startswith("/"):
            return _norm(w)
        if chain.cwd is not None:
            return _norm(posixpath.join(chain.cwd, w))
        return posixpath.normpath(w) if w else w

    def _as_home_relative(self, path: str) -> str:
        """A relative path with an unknown directory is checked as if the
        directory were the home (``.ssh`` is a hit)."""
        return path if path.startswith("/") else _norm(posixpath.join(self.home, path))

    # -- commands -------------------------------------------------------------

    def _is_prefix_allowed(self, command: str) -> bool:
        fn = self.prefix_allowed
        if fn is None:
            return False
        try:
            return bool(fn(command))  # type: ignore[operator]
        except Exception:  # noqa: BLE001 — an unreadable allowlist denies
            return False

    def check_command(self, command: str) -> FloorVerdict | None:
        """The floor for one ``run_command`` call. ``None`` lets it run."""
        if not isinstance(command, str) or not command.strip():
            return None
        scan = _Scan()
        try:
            if len(command) > _MAX_COMMAND:
                raise _Unparsable("the command is too long to check")
            self._scan_command(command, scan, depth=0)
        except (ValueError, RecursionError):
            return self._fail_closed(command, scan)
        if not scan.verdicts:
            return None
        hard = [v for v in scan.verdicts if v.hard]
        if hard:
            return hard[0]
        verdict = scan.verdicts[0]
        # A soft stop (a protected path, a shutdown the host left off) is lifted
        # when the user allowed this command prefix (research C2, item 9) — but
        # only for ONE simple command. A chain, a pipe, a substitution or a
        # nested shell is never covered by a remembered prefix.
        if scan.simple and self._is_prefix_allowed(command):
            return None
        return verdict

    def _fail_closed(self, command: str, scan: "_Scan") -> FloorVerdict:
        """The command could not be read with certainty: a catastrophic shape
        anywhere in the raw text is a hard deny, anything else asks."""
        hard = [v for v in scan.verdicts if v.hard]
        if hard:
            return hard[0]
        try:
            raw = self._raw_catastrophic(command)
        except (ValueError, RecursionError):
            raw = "a command the floor cannot read"
        if raw is not None:
            return FloorVerdict(f"{raw} (the command could not be fully parsed)")
        return FloorVerdict(
            "the floor could not parse this command with certainty "
            "(an open quote, deep nesting or a very long command)",
            hard=False,
        )

    def _raw_catastrophic(self, text: str) -> str | None:
        """The fallback scan of unparsable text: catastrophic shapes on the
        raw words, quotes dropped. Only used when the parser failed."""
        if _has_fork_bomb(text):
            return "fork bomb"
        flat = re.sub(r"[\"'`\\]", "", text[: _WORK_LIMIT])
        if re.search(r">\s*/dev/(sd|hd|vd|xvd|nvme|mmcblk|dm-|md\d|loop\d|disk|mapper/)", flat):
            return "a write to a block device"
        words = [w for w in re.split(r"[\s;|&(){}<>]+", flat) if w]
        chain = _Chain()
        for i, w in enumerate(words):
            base = posixpath.basename(w)
            window = words[i + 1 : i + 14]
            if base.startswith("mkfs") or base in _MKFS:
                return "mkfs formats a filesystem"
            if w.startswith("of=") and any(
                p is not None and _BLOCK_DEV.match(p) for p in self._resolve(w[3:], chain)
            ):
                return "dd writes to a block device"
            if base in _DISK_TOOLS and any(x.startswith("/dev/") and _BLOCK_DEV.match(x) for x in window):
                return f"{base} on a block device"
            if base in ("rm", "find", "chmod", "chown") or base.startswith("$"):
                verb = "rm" if base.startswith("$") else base
                rec = any(_recursive(x, verb) for x in window if x.startswith("-")) or (
                    base == "find" and any(x in ("-delete", "-exec", "-execdir") for x in window)
                )
                if not rec:
                    continue
                for x in window:
                    if x.startswith("-"):
                        continue
                    for p in self._resolve(x, chain):
                        if p is not None and self._wipe_hit(p) is not None:
                            return f"{base} of / or your home directory"
        return None

    def _scan_command(self, command: str, scan: "_Scan", depth: int, chain: _Chain | None = None) -> None:
        """Collect every verdict of ``command`` into ``scan``: each simple
        command between separators, each ``$(…)`` / backtick substitution,
        each here-document fed to a shell and each ``bash -c`` / ``eval``
        string is checked. Raises :class:`_Unparsable` (a ``ValueError``) when
        the command cannot be read with certainty."""
        if depth > _MAX_DEPTH:
            raise _Unparsable("the command nests shells too deeply to check")
        scan.work += len(command) + 1
        if scan.work > _WORK_LIMIT:
            raise _Unparsable("the command is too large to check")
        if _has_fork_bomb(command):
            scan.add(FloorVerdict("fork bomb"))
        subs: list[str] = []
        tokens = _lex(command, subs)
        for inner in subs:
            if inner.strip():
                scan.simple = False
                self._scan_command(inner, scan, depth + 1)
        if not tokens:
            return
        chain = chain if chain is not None else _Chain()
        segments = _split_segments_piped(tokens)
        if len(segments) > 1:
            scan.simple = False
        prev_out: object = None
        for segment, piped in segments:
            # Each simple command costs more than its characters: bound them too.
            scan.work += 64 + 8 * len(segment)
            if scan.work > _WORK_LIMIT:
                raise _Unparsable("the command is too large to check")
            stdin: object = None
            if piped:
                stdin = prev_out if prev_out is not None else _PIPE_UNKNOWN
            prev_out = self._scan_segment(segment, scan, depth, chain, stdin)

    def _scan_segment(
        self, segment: list[str], scan: "_Scan", depth: int, chain: _Chain, stdin: object
    ) -> str | None:
        """One simple command: its redirections, then its words. Returns the
        text it writes to its output when the floor knows it (``echo``,
        ``printf``, ``cat`` of a here-document), else ``None``."""
        words: list[str] = []
        i = 0
        while i < len(segment):
            word = segment[i]
            if _is_redirect(word):
                scan.simple = False  # a redirect is never covered by a prefix
                target = segment[i + 1] if i + 1 < len(segment) else ""
                if words and words[-1].isdigit():
                    words.pop()  # the fd number of ``2>``
                if word in ("<<", "<<-"):
                    body = getattr(target, "heredoc_body", None)
                    stdin = body if body is not None else ""
                elif word == "<<<":
                    stdin = str(target) + "\n"
                else:
                    self._check_redirect(str(word), str(target), scan, chain)
                    if word in ("<", "<>"):
                        stdin = None
                i += 2
                continue
            words.append(word)
            i += 1
        return self._scan_words(words, 0, scan, depth, chain, stdin, set())

    def _check_redirect(self, op: str, target: str, scan: "_Scan", chain: _Chain) -> None:
        if not target:
            return
        if ">" in op:
            if target.isdigit() or target == "-":
                return  # ``2>&1``, ``>&-``
            for p in self._resolve(target, chain):
                if p is None:
                    continue
                v = self._write_verdict(p, "a redirect")
                if v is not None:
                    scan.add(v)
        if op in ("<", "<>"):
            for p in self._resolve(target, chain):
                if p is None:
                    continue
                v = self._read_verdict(p)
                if v is not None:
                    scan.add(v)

    def _write_verdict(self, p: str, verb: str) -> FloorVerdict | None:
        """A write to ``p`` (resolved; globs allowed)."""
        if p.startswith("/dev/"):
            if _BLOCK_DEV.match(p):
                return FloorVerdict(f"{verb} writes to a block device ({p})")
            return None
        d = self._self_dir_of(p)
        if d is not None or (p.startswith("/") and _has_glob(p) and self._glob_touches_self(p)):
            return FloorVerdict(f"{verb} would change the agent's own files ({d or p})")
        if _env_name(posixpath.basename(p)):
            return FloorVerdict(f"{verb} on a .env file", hard=False)
        hit = self._protected_hit(self._as_home_relative(p))
        if hit is not None:
            return FloorVerdict(f"{verb} writes {hit}", hard=False)
        return None

    def _glob_touches_self(self, p: str) -> bool:
        comps = _comps(p)
        return any(_may_cover(comps, _comps(d), ancestor=False, inside=True) for d in self.self_dirs)

    def _read_verdict(self, p: str) -> FloorVerdict | None:
        if _env_name(posixpath.basename(p)):
            return FloorVerdict("reading a .env file is protected", hard=False)
        hit = self._secret_hit(self._as_home_relative(p))
        if hit is not None:
            return FloorVerdict(f"reading {hit} is protected", hard=False)
        return None

    def _scan_words(
        self,
        words: list[str],
        idx: int,
        scan: "_Scan",
        depth: int,
        chain: _Chain,
        stdin: object,
        seen: set[int],
    ) -> str | None:
        """The words of one simple command from ``idx``. ``seen`` stops a start
        index from being scanned twice (launchers try several)."""
        if idx in seen:
            return None
        seen.add(idx)
        assignments: list[str] = []
        while idx < len(words):
            word = words[idx]
            name = posixpath.basename(word)
            if _ASSIGNMENT.match(word):
                assignments.append(word)
                idx += 1  # ``VAR=value`` before the program
                continue
            if word in _RESERVED:
                scan.simple = False
                idx += 1  # ``{ rm …; }``, ``if rm …; then``, ``! rm``
                continue
            if word == "function":
                scan.simple = False
                idx += 2  # ``function f { … }``: the body is its own segment
                continue
            if word == "coproc":
                scan.simple = False
                idx += 1
                if idx + 1 < len(words) and words[idx + 1] == "{":
                    idx += 1  # ``coproc NAME { … }``
                continue
            if word == "for" and idx + 1 < len(words):
                # ``for f in a b``: remember the values of f for the body.
                var = words[idx + 1]
                values = [str(w) for w in words[idx + 3 :]] if idx + 2 < len(words) and words[idx + 2] == "in" else []
                if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", var) and values:
                    chain.vars[var] = values[:_MAX_EXPANSIONS]
                scan.simple = False
                return None
            if name in _LAUNCHERS:
                scan.simple = False
                self._scan_launcher(name, words, idx + 1, scan, depth, chain, stdin, seen)
                return None
            break
        if idx >= len(words):
            # Only assignments: remember them for the rest of the chain.
            for a in assignments:
                key, _, value = a.partition("=")
                key = key.rstrip("+")
                vals = [v for v in self._substitute(value, chain) if v is not None]
                if vals and len(vals) == len(self._substitute(value, chain)):
                    chain.vars[key] = vals
                else:
                    chain.vars.pop(key, None)
            return None
        verb_word = str(words[idx])
        rest = [str(w) for w in words[idx + 1 :]]
        if "$" in verb_word or "`" in verb_word:
            subs = self._substitute(verb_word, chain)
            if subs and all(s is not None for s in subs):
                for s in subs:
                    self._scan_words(str(s).split() + rest, 0, scan, depth, chain, stdin, set())
                return None
            scan.simple = False
            self._unknown_recursive(f"a command named by a variable ({verb_word})", rest, scan, chain)
            return None
        verb = posixpath.basename(verb_word)
        if verb in _SHELLS:
            self._scan_shell(rest, scan, depth, stdin, chain)
            return None
        if verb in _STDIN_SHELLS:
            if "-f" not in rest:
                self._scan_stdin_code(verb, stdin, scan, depth)
            return None
        if verb == "eval":
            scan.simple = False
            self._scan_command(" ".join(rest), scan, depth + 1)
            return None
        if verb == "trap":
            scan.simple = False
            args = [a for a in rest if a != "--"]
            if args and not args[0].startswith("-"):
                self._scan_command(args[0], scan, depth + 1)
            return None
        if verb == "alias":
            scan.simple = False
            for a in rest:
                if "=" in a and not a.startswith("-"):
                    self._scan_alias(a.partition("=")[2], scan, depth)
            return None
        if verb in ("export", "declare", "local", "readonly", "typeset"):
            for a in rest:
                if _ASSIGNMENT.match(a):
                    key, _, value = a.partition("=")
                    vals = self._substitute(value, chain)
                    if all(v is not None for v in vals):
                        chain.vars[key.rstrip("+")] = [str(v) for v in vals]
            return None
        if verb in ("cd", "pushd"):
            self._track_cd(rest, chain)
            return None
        if verb == "find":
            self._scan_find(rest, scan, depth, chain)
            return None
        self._verb_verdicts(verb, rest, scan, chain)
        return _literal_output(verb, rest, stdin)

    # -- launchers and nested shells ----------------------------------------------

    def _scan_launcher(
        self,
        name: str,
        words: list[str],
        idx: int,
        scan: "_Scan",
        depth: int,
        chain: _Chain,
        stdin: object,
        seen: set[int],
    ) -> None:
        """A launcher: skip its options, then check every later word that may
        start the real command (an unknown option value cannot hide it)."""
        spec = _LAUNCHER_SPECS.get(name, _LauncherSpec())
        start, found = _walk_options(words, idx, spec)
        if found is None and name in ("su", "runuser", "script", "flock"):
            # ``su - root -c "…"``: the command option may follow the user.
            found = _find_command_option([str(w) for w in words[idx:]], spec)
        if found is not None:
            # ``env -S "…"``, ``su -c "…"``, ``script -c "…"``: a command string.
            self._scan_command(found, scan, depth + 1)
            if name in ("su", "runuser", "script", "env"):
                return
        if name == "watch":
            if any(w in ("-x", "--exec") for w in words[idx:start]):
                self._scan_words(words, start, scan, depth, chain, stdin, seen)
            else:
                self._scan_command(" ".join(str(w) for w in words[start:]), scan, depth + 1)
            return
        if name == "xargs":
            extra = _xargs_input(stdin)
            positions = 0
            for k in range(start, len(words)):
                if str(words[k]).startswith("-") and k != start:
                    continue
                cmd = [str(w) for w in words[k:]] + extra
                self._scan_words(cmd, 0, scan, depth, chain, None, set())
                positions += 1
                if positions >= _MAX_LAUNCHER_POSITIONS:
                    break
            if start >= len(words) and extra:
                self._scan_words(["echo", *extra], 0, scan, depth, chain, None, set())
            return
        positions = 0
        for k in range(start, len(words)):
            if k != start and str(words[k]).startswith("-"):
                continue
            self._scan_words(words, k, scan, depth, chain, stdin, seen)
            positions += 1
            if positions >= _MAX_LAUNCHER_POSITIONS:
                break

    def _scan_shell(self, rest: list[str], scan: "_Scan", depth: int, stdin: object, chain: _Chain) -> None:
        inner, reads_stdin = _shell_command_string(rest)
        if inner is not None:
            scan.simple = False
            self._scan_command(inner, scan, depth + 1)
            return
        if reads_stdin:
            self._scan_stdin_code("a shell", stdin, scan, depth)

    def _scan_stdin_code(self, who: str, stdin: object, scan: "_Scan", depth: int) -> None:
        """A program that runs its input as commands."""
        if isinstance(stdin, str):
            scan.simple = False
            self._scan_command(stdin, scan, depth + 1)
        elif stdin is _PIPE_UNKNOWN:
            scan.simple = False
            scan.add(FloorVerdict(f"{who} runs commands from a pipe the floor cannot see", hard=False))

    def _scan_alias(self, value: str, scan: "_Scan", depth: int) -> None:
        """An alias value is a command that runs later (the persistent shell
        keeps aliases): check it now; an alias that starts a destructive
        program asks, because its arguments come later."""
        self._scan_command(value, scan, depth + 1)
        toks = [t for t in _lex(value, None) if not _is_op(t)]
        verb = posixpath.basename(str(toks[0])) if toks else ""
        if verb in ("rm", "dd", "shred", "chmod", "chown", "find", "xargs", "eval", "wipefs", "truncate") or (
            verb in _SHELLS or verb in _LAUNCHERS or verb.startswith("mkfs") or verb in _MKFS
        ):
            scan.add(FloorVerdict(f"an alias for {verb} hides its arguments from the floor", hard=False))

    def _track_cd(self, rest: list[str], chain: _Chain) -> None:
        args = [a for a in rest if not a.startswith("-") or a == "-"]
        if not args:
            chain.cwd = _norm(self.home)
            return
        if args[0] == "-":
            chain.cwd = None
            return
        paths = self._resolve(args[0], chain)
        p = paths[0] if len(paths) == 1 else None
        chain.cwd = p if p is not None and p.startswith("/") and not _has_glob(p) else None

    def _scan_find(self, rest: list[str], scan: "_Scan", depth: int, chain: _Chain) -> None:
        """``find PATH… -delete`` / ``-exec rm -rf {} +``: the start paths are
        the targets."""
        k = 0
        while k < len(rest) and (rest[k] in ("-H", "-L", "-P") or rest[k].startswith("-O")):
            k += 1
        starts: list[str] = []
        while k < len(rest) and not rest[k].startswith("-") and rest[k] not in ("(", "!", ")"):
            starts.append(rest[k])
            k += 1
        expr = rest[k:]
        starts = starts or ["."]
        if "-delete" in expr:
            self._rm_verdict(["-r", *starts], scan, chain, verb="find -delete")
        j = 0
        while j < len(expr):
            if expr[j] in ("-exec", "-execdir", "-ok", "-okdir"):
                cmd: list[str] = []
                j += 1
                while j < len(expr) and expr[j] not in (";", "+"):
                    cmd.append(expr[j])
                    j += 1
                if cmd:
                    for s in starts:
                        filled = [s if c == "{}" else c.replace("{}", s) for c in cmd]
                        self._scan_words(filled, 0, scan, depth, chain, None, set())
            j += 1

    # -- verbs ----------------------------------------------------------------

    def _verb_verdicts(self, verb: str, rest: list[str], scan: "_Scan", chain: _Chain) -> None:
        opts, pos = _split_args(rest)
        if verb.startswith("mkfs") or verb in _MKFS:
            scan.add(FloorVerdict("mkfs formats a filesystem"))
            return
        if verb in _SHUTDOWN or (verb == "systemctl" and any(a in ("poweroff", "reboot", "halt", "kexec") for a in rest)):
            if not self.allow_shutdown:
                scan.add(FloorVerdict(f"{verb} powers off or reboots the machine", hard=False))
            return
        if verb in ("init", "telinit") and any(a in ("0", "6") for a in rest):
            if not self.allow_shutdown:
                scan.add(FloorVerdict("init 0/6 powers off or reboots the machine", hard=False))
            return
        if verb in _DISK_TOOLS and not any(o in _DISK_LIST_FLAGS for o in rest):
            for a in pos:
                for p in self._resolve(a, chain):
                    if p is not None and _BLOCK_DEV.match(p):
                        scan.add(FloorVerdict(f"{verb} on a block device ({p})"))
                        return
        if verb == "dd":
            for a in rest:
                key, eq, value = a.partition("=")
                if not eq:
                    continue
                for p in self._resolve(value, chain):
                    if p is None:
                        continue
                    v = self._write_verdict(p, "dd") if key == "of" else (
                        self._read_verdict(p) if key == "if" else None
                    )
                    if v is not None:
                        scan.add(v)
            return
        if verb == "rm":
            self._rm_verdict(rest, scan, chain)
            return
        if verb in ("chmod", "chown", "chgrp"):
            self._chmod_verdict(verb, opts, pos, scan, chain)
        writes = verb in _WRITE_VERBS and (verb not in ("sed", "perl", "ruby") or self._in_place(verb, opts))
        if writes:
            self._write_targets(verb, opts, pos, scan, chain)
        elif verb in _READ_VERBS:
            for a in self._file_words(rest):
                for p in self._resolve(a, chain):
                    if p is not None:
                        v = self._read_verdict(p)
                        if v is not None:
                            scan.add(v)
        elif verb not in _PATH_ONLY_VERBS:
            # An unknown program: a protected path or a secret in its
            # arguments asks.
            for a in self._file_words(rest):
                for p in self._resolve(a, chain):
                    if p is None:
                        continue
                    hp = self._as_home_relative(p)
                    hit = self._protected_hit(hp) or self._secret_hit(hp)
                    if hit is not None:
                        scan.add(FloorVerdict(f"{verb} touches {hit}", hard=False))
        if verb not in _NO_FILE_VERBS:
            for a in self._file_words(rest):
                for p in self._resolve(a, chain):
                    if p is not None and _env_name(posixpath.basename(p)):
                        scan.add(FloorVerdict("reading a .env file is protected", hard=False))
                        break
        if verb not in _RECURSIVE_SAFE:
            self._unknown_recursive(verb, rest, scan, chain)

    @staticmethod
    def _file_words(rest: list[str]) -> list[str]:
        """Arguments that may name a file: positionals, the value of
        ``--opt=value`` and ``@file`` (``curl -d @.env``)."""
        out: list[str] = []
        for a in rest:
            if a.startswith("-"):
                if "=" in a:
                    out.append(a.partition("=")[2])
                continue
            out.append(a)
            if a.startswith("@") and len(a) > 1:
                out.append(a[1:])
            elif "=" in a and not a.startswith("/"):
                out.append(a.partition("=")[2])
        for v in list(out):
            if v.startswith("@") and len(v) > 1:
                out.append(v[1:])
        return out

    @staticmethod
    def _in_place(verb: str, opts: list[str]) -> bool:
        if verb not in ("sed", "perl", "ruby"):
            return False
        for o in opts:
            if o.startswith("--in-place"):
                return True
            if not o.startswith("--") and "i" in o[1:].split("e")[0]:
                return True
        return False

    def _write_targets(self, verb: str, opts: list[str], pos: list[str], scan: "_Scan", chain: _Chain) -> None:
        dests = list(pos)
        sources: list[str] = []
        if verb in ("cp", "install", "rsync", "scp", "ln"):
            target_dir = None
            for i, o in enumerate(opts):
                if o.startswith("--target-directory="):
                    target_dir = o.partition("=")[2]
                elif o == "-t" and i + 1 < len(opts):
                    target_dir = opts[i + 1]
            if target_dir is not None:
                dests, sources = [target_dir], list(pos)
            elif len(pos) >= 2:
                dests, sources = [pos[-1]], pos[:-1]
        for a in dests:
            for p in self._resolve(a, chain):
                if p is None:
                    continue
                v = self._write_verdict(p, verb)
                if v is not None:
                    scan.add(v)
                if verb == "mv" and p.startswith("/") and self._wipe_hit(p) is not None:
                    scan.add(FloorVerdict(f"mv moves {self._wipe_hit(p)}"))
        for a in sources:
            for p in self._resolve(a, chain):
                if p is not None:
                    v = self._read_verdict(p)
                    if v is not None:
                        scan.add(v)

    def _chmod_verdict(self, verb: str, opts: list[str], pos: list[str], scan: "_Scan", chain: _Chain) -> None:
        """``chmod -R`` that makes ``/``, a system directory or the home
        world-writable, and ``chown -R`` / ``chgrp -R`` of ``/`` or a system
        directory, are a hard deny."""
        if not any(_recursive(o, verb) for o in opts):
            return
        reference = any(o.startswith("--ref") for o in opts)
        if verb == "chmod":
            if reference or not pos or not _world_writable(pos[0]):
                return
            targets = pos[1:]
        else:
            targets = pos if reference else pos[1:]
        for a in targets:
            for p in self._resolve(a, chain):
                if p is None or not p.startswith("/"):
                    continue
                label = self._wipe_hit(p)
                if label is None or (verb != "chmod" and not label.startswith("/")):
                    continue
                scan.add(FloorVerdict(f"{verb} -R on {label}"))
                return

    def _rm_verdict(self, rest: list[str], scan: "_Scan", chain: _Chain, *, verb: str = "rm") -> None:
        opts, targets = _split_args(rest)
        recursive = any(_recursive(a, "rm") for a in opts)
        for t in targets:
            for p in self._resolve(t, chain):
                if p is None:
                    if recursive:
                        scan.add(FloorVerdict(f"{verb} -r of a path the floor cannot resolve ({t})", hard=False))
                    continue
                if recursive and p.startswith("/"):
                    label = self._wipe_hit(p)
                    if label is not None:
                        scan.add(FloorVerdict(f"{verb} -rf of {label}"))
                        return
                if p.startswith("/"):
                    d = self._self_dir_of(p)
                    if d is not None or (_has_glob(p) and self._glob_touches_self(p)):
                        scan.add(FloorVerdict(f"{verb} of the agent's own files ({d or p})"))
                        return
                if _env_name(posixpath.basename(p)):
                    scan.add(FloorVerdict("deleting a .env file", hard=False))
                    continue
                hit = self._protected_hit(self._as_home_relative(p), ancestor=recursive and p.startswith("/"))
                if hit is not None:
                    scan.add(FloorVerdict(f"deleting {hit}", hard=False))

    def _unknown_recursive(self, what: str, rest: list[str], scan: "_Scan", chain: _Chain) -> None:
        """A program the floor does not know, with a recursive flag on ``/`` or
        the home, is treated like ``rm -rf`` of it."""
        opts, pos = _split_args(rest)
        if not any(_recursive(o, "rm") for o in opts):
            return
        for a in pos:
            for p in self._resolve(a, chain):
                if p is not None and p.startswith("/"):
                    label = self._wipe_hit(p)
                    if label is not None:
                        scan.add(FloorVerdict(f"{what} with a recursive flag on {label}"))
                        return


# -- helpers --------------------------------------------------------------------


def _has_fork_bomb(text: str) -> bool:
    """A function that pipes itself into itself in the background, with any
    name: ``:(){ :|:& };:``, ``bomb(){ bomb|bomb& };bomb``,
    ``function b { b|b& }``. Linear in the length of ``text``."""
    sq = re.sub(r"\s+", "", text).replace("&amp;", "&")
    stops = "(){}|;&<>\"'"
    for m in re.finditer(r"\(\)\{|function", sq):
        if m.group() == "function":
            end = m.end()
            k = end
            while k < len(sq) and k - end < 256 and sq[k] not in stops:
                k += 1
            name = sq[end:k]
            body = sq[k + 2 :] if sq.startswith("()", k) else sq[k:]
            if name and body.startswith("{") and body[1:].startswith(f"{name}|{name}&"):
                return True
            continue
        j = m.start()
        while j > 0 and m.start() - j < 256 and sq[j - 1] not in stops:
            j -= 1
        name = sq[j : m.start()]
        if name.startswith("function"):
            name = name[len("function") :] or name
        if name and sq.startswith(f"{name}|{name}&", m.end()):
            return True
    return False


def _norm(path: str) -> str:
    """Normalise an absolute path: ``//*`` and ``/./*`` are ``/*``."""
    if path.startswith("/"):
        path = "/" + path.lstrip("/")
    return posixpath.normpath(path) if path else path


def _comps(path: str) -> list[str]:
    return [c for c in _norm(path).split("/") if c and c != "."]


def _has_glob(text: str) -> bool:
    return any(ch in text for ch in "*?[")


def _pure_wildcard(comp: str) -> bool:
    """A glob component that matches (almost) anything: ``*``, ``.*``, ``?*``."""
    return not re.sub(r"[*?.]", "", comp)


def _glob_match(name: str, pattern: str) -> bool:
    """``name`` matches the glob component ``pattern`` as bash would (a
    leading dot must be matched literally)."""
    if not _has_glob(pattern):
        return name == pattern
    if name.startswith(".") and not pattern.startswith("."):
        return False
    try:
        return fnmatchcase(name, pattern)
    except re.error:
        return True  # fail closed: an odd pattern may match


def _may_cover(pattern: list[str], target: list[str], *, ancestor: bool, inside: bool) -> bool:
    """The path ``pattern`` (components, globs allowed) can be ``target``,
    an ancestor of it (``ancestor``), or lie inside it (``inside``)."""
    if len(pattern) < len(target):
        if not ancestor:
            return False
        return all(_glob_match(t, p) for p, t in zip(pattern, target))
    if len(pattern) > len(target) and not inside:
        return False
    return all(_glob_match(t, p) for p, t in zip(pattern, target))


def _env_name(name: str) -> bool:
    """``name`` (a basename, globs allowed) can be a ``.env`` / ``.env.*`` file."""
    if not name:
        return False
    if not _has_glob(name):
        return name == ".env" or name.startswith(".env.")
    return any(_glob_match(c, name) for c in (".env", ".env.local", ".env.production"))


def _brace_expand(word: str) -> list[str]:
    """Bash brace expansion (``/{bin,etc}``), capped at ``_MAX_EXPANSIONS``."""
    todo = [word]
    done: list[str] = []
    while todo:
        w = todo.pop()
        parts = _brace_once(w)
        if parts is None:
            done.append(w)
        else:
            todo.extend(reversed(parts))
        if len(done) + len(todo) > _MAX_EXPANSIONS:
            return done + todo
    return done


def _brace_once(w: str) -> list[str] | None:
    i = 0
    n = len(w)
    while i < n:
        if w[i] == "{" and not (i > 0 and w[i - 1] == "$"):
            depth = 0
            commas: list[int] = []
            for j in range(i, n):
                c = w[j]
                if c == "{":
                    depth += 1
                elif c == "}":
                    depth -= 1
                    if depth == 0:
                        if commas:
                            bounds = [i, *commas, j]
                            return [w[:i] + w[a + 1 : b] + w[j + 1 :] for a, b in zip(bounds, bounds[1:])]
                        break
                elif c == "," and depth == 1:
                    commas.append(j)
        i += 1
    return None


def _recursive(flag: str, verb: str) -> bool:
    """``flag`` asks ``verb`` to recurse: ``-r``/``-R`` in a short cluster
    (``chmod`` / ``chown`` take only ``-R``), or any GNU abbreviation of
    ``--recursive`` (``--r``, ``--recur``)."""
    if flag.startswith("--"):
        name = flag.split("=", 1)[0]
        return len(name) >= 3 and "--recursive".startswith(name)
    if not flag.startswith("-") or len(flag) < 2:
        return False
    letters = flag[1:]
    if verb in ("chmod", "chown", "chgrp"):
        return "R" in letters
    return "r" in letters or "R" in letters


def _world_writable(mode: str) -> bool:
    """A ``chmod`` mode that makes files writable by others: octal with the
    other-write bit (``777``, ``0777``, ``1777``), or symbolic ``o+w``,
    ``a+rwx``, ``+w``, ``=rwx``."""
    if re.fullmatch(r"[0-7]{1,5}", mode):
        return bool(int(mode, 8) & 0o002)
    for clause in mode.split(","):
        m = re.fullmatch(r"([ugoa]*)([-+=])([rwxXst]*|[ugo])", clause)
        if m is None:
            continue
        who, op, perms = m.groups()
        if op in "+=" and "w" in perms and (not who or "a" in who or "o" in who):
            return True
    return False


def _split_args(rest: list[str]) -> tuple[list[str], list[str]]:
    """Options and positional arguments (everything after ``--`` is positional)."""
    opts: list[str] = []
    pos: list[str] = []
    ended = False
    for a in rest:
        if not ended and a == "--":
            ended = True
            continue
        if not ended and a.startswith("-") and len(a) > 1:
            opts.append(a)
        else:
            pos.append(a)
    return opts, pos


def _literal_output(verb: str, rest: list[str], stdin: object) -> str | None:
    """What ``echo`` / ``printf`` / ``cat`` (of a here-document) write."""
    if verb == "echo":
        args = list(rest)
        while args and re.fullmatch(r"-[neE]+", args[0]):
            args.pop(0)
        return " ".join(args).replace("\\n", "\n") + "\n"
    if verb == "printf":
        args = [a for a in rest if a != "--"]
        return " ".join(args).replace("\\n", "\n") if args else ""
    if verb == "cat" and isinstance(stdin, str) and not [a for a in rest if a != "-"]:
        return stdin
    return None


def _xargs_input(stdin: object) -> list[str]:
    if isinstance(stdin, str):
        return stdin.split()[:_MAX_EXPANSIONS]
    if stdin is _PIPE_UNKNOWN:
        return ["$__xargs_input"]  # an argument the floor cannot resolve
    return []


@dataclass(frozen=True)
class _LauncherSpec:
    #: Short option letters that take a value (attached or the next word).
    short_values: str = ""
    #: Long options that take a value (``--user root`` / ``--user=root``).
    long_values: frozenset[str] = frozenset()
    #: Positional arguments before the command (``timeout 5 rm``).
    positional: int = 0
    #: The short letter / long option whose value is a command string.
    command_short: str = ""
    command_long: frozenset[str] = frozenset()


_LAUNCHER_SPECS: dict[str, _LauncherSpec] = {
    "sudo": _LauncherSpec(
        "ughCpUrtTDR",
        frozenset({"--user", "--group", "--host", "--close-from", "--prompt", "--other-user",
                   "--role", "--type", "--command-timeout", "--chdir", "--chroot"}),
    ),
    "doas": _LauncherSpec("uC"),
    "env": _LauncherSpec(
        "uCS", frozenset({"--unset", "--chdir", "--split-string"}),
        command_short="S", command_long=frozenset({"--split-string"}),
    ),
    "nice": _LauncherSpec("n", frozenset({"--adjustment"})),
    "ionice": _LauncherSpec("cnpPu", frozenset({"--class", "--classdata", "--pid", "--pgid", "--uid"})),
    "stdbuf": _LauncherSpec("ioe", frozenset({"--input", "--output", "--error"})),
    "time": _LauncherSpec("fo", frozenset({"--format", "--output"})),
    "exec": _LauncherSpec("a"),
    "timeout": _LauncherSpec("sk", frozenset({"--signal", "--kill-after"}), positional=1),
    "xargs": _LauncherSpec(
        "InPLsdaE",
        frozenset({"--max-args", "--max-procs", "--max-lines", "--max-chars", "--delimiter",
                   "--arg-file", "--eof", "--process-slot-var"}),
    ),
    "watch": _LauncherSpec("nq", frozenset({"--interval", "--equexit", "--errexit"})),
    "taskset": _LauncherSpec("", positional=1),
    "chroot": _LauncherSpec("", frozenset({"--userspec", "--groups"}), positional=1),
    "flock": _LauncherSpec("wEc", frozenset({"--timeout", "--conflict-exit-code", "--command"}),
                           positional=1, command_short="c", command_long=frozenset({"--command"})),
    "pkexec": _LauncherSpec("", frozenset({"--user"})),
    "runuser": _LauncherSpec("ugGcsw", frozenset({"--user", "--group", "--supp-group", "--command",
                                                  "--shell", "--whitelist-environment"}),
                             command_short="c", command_long=frozenset({"--command", "--session-command"})),
    "su": _LauncherSpec("gGcsw", frozenset({"--group", "--supp-group", "--command", "--shell",
                                            "--session-command", "--whitelist-environment"}),
                        command_short="c", command_long=frozenset({"--command", "--session-command"})),
    "systemd-run": _LauncherSpec(
        "pEuMHS",
        frozenset({"--property", "--setenv", "--unit", "--machine", "--host", "--uid", "--gid",
                   "--nice", "--working-directory", "--slice", "--description", "--on-calendar",
                   "--on-active", "--on-boot", "--on-startup", "--on-unit-active",
                   "--on-unit-inactive", "--path-property", "--socket-property", "--timer-property",
                   "--service-type", "--expand-environment"}),
    ),
    "unshare": _LauncherSpec("SGwR", frozenset({"--map-user", "--map-group", "--setuid", "--setgid",
                                                "--wd", "--root", "--propagation"})),
    "setsid": _LauncherSpec(""),
    "script": _LauncherSpec("cEIOBTm", frozenset({"--command", "--echo", "--log-in", "--log-out",
                                                  "--log-io", "--log-timing", "--logging-format"}),
                            command_short="c", command_long=frozenset({"--command"})),
    "strace": _LauncherSpec("eoOpPsSuEIXbaA", frozenset({"--output", "--trace", "--signal"})),
    "ltrace": _LauncherSpec("eoOpsSuEaAlnLx"),
    "nsenter": _LauncherSpec("tSGwr", frozenset({"--target", "--setuid", "--setgid", "--wd", "--root"})),
    "chrt": _LauncherSpec("", positional=1),
    "faketime": _LauncherSpec("", positional=1),
}


def _long_match(key: str, names: frozenset[str]) -> bool:
    """``key`` names one of ``names``, exactly or as a GNU abbreviation."""
    if key in names:
        return True
    return len(key) >= 3 and any(n.startswith(key) for n in names)


def _walk_options(words: list[str], idx: int, spec: _LauncherSpec) -> tuple[int, str | None]:
    """Skip a launcher's options (and their values) and its positional
    arguments. Returns the index where the command starts and the value of
    its command-string option (``env -S``, ``su -c``), if any."""
    found: str | None = None
    positional = spec.positional
    n = len(words)
    while idx < n:
        word = str(words[idx])
        if word == "--":
            idx += 1
            break
        if _ASSIGNMENT.match(word):
            idx += 1  # ``env FOO=1 cmd``, ``sudo FOO=1 cmd``
            continue
        if word.startswith("--") and len(word) > 2:
            key, eq, value = word.partition("=")
            takes = _long_match(key, spec.long_values)
            if spec.command_long and _long_match(key, spec.command_long):
                found = value if eq else (str(words[idx + 1]) if idx + 1 < n else "")
            idx += 1 if eq or not takes else 2
            continue
        if word.startswith("-") and len(word) > 1:
            if word[1:].isdigit():
                idx += 1  # ``nice -5``
                continue
            step = 1
            letters = word[1:]
            for pos, char in enumerate(letters):
                if char in spec.short_values:
                    attached = letters[pos + 1 :]
                    value = attached if attached else (str(words[idx + 1]) if idx + 1 < n else "")
                    if char == spec.command_short:
                        found = value
                    step = 1 if attached else 2
                    break
            idx += step
            continue
        if positional > 0:
            positional -= 1  # ``timeout 5`` / ``chroot /srv``
            idx += 1
            continue
        break
    return idx, found


def _find_command_option(words: list[str], spec: _LauncherSpec) -> str | None:
    """The value of the command-string option anywhere in ``words``."""
    for i, word in enumerate(words):
        nxt = words[i + 1] if i + 1 < len(words) else ""
        if word.startswith("--"):
            key, eq, value = word.partition("=")
            if spec.command_long and _long_match(key, spec.command_long):
                return value if eq else nxt
        elif word.startswith("-") and spec.command_short and spec.command_short in word[1:]:
            attached = word[1:].split(spec.command_short, 1)[1]
            return attached or nxt
    return None


def _shell_command_string(args: list[str]) -> tuple[str | None, bool]:
    """The command string of ``bash -c "…"`` (also ``-lc``, ``-ec``,
    ``+x -c``, ``-o pipefail -c``), or ``None``; and whether the shell reads
    its commands from its input (no ``-c`` and no script file, or ``-s``)."""
    has_c = False
    has_s = False
    idx = 0
    while idx < len(args):
        word = args[idx]
        if word in ("--", "-"):
            idx += 1
            break
        if word in ("-o", "+o", "-O", "+O"):
            idx += 2
            continue
        if word.startswith("--"):
            if word in ("--rcfile", "--init-file"):
                idx += 2
                continue
            idx += 1
            continue
        if word[:1] in ("-", "+") and len(word) > 1:
            letters = word[1:]
            if word[0] == "-" and "c" in letters:
                has_c = True
            if word[0] == "-" and "s" in letters:
                has_s = True
            idx += 2 if ("o" in letters or "O" in letters) else 1
            continue
        break
    if has_c:
        return (args[idx] if idx < len(args) else ""), False
    return None, has_s or idx >= len(args)


# -- the lexer ----------------------------------------------------------------------


#: Redirection operators the lexer emits.
_REDIRECTS = frozenset({">", ">>", "<", ">|", "&>", "&>>", ">&", "<&", "<<", "<<<", "<>", "<<-"})
_PUNCT = frozenset("();<>|&")
#: Operators, longest first.
_OPERATORS = (
    "<<<", "<<-", ";;&", "&>>", "<<", ">>", "&&", "||", ";;", ";&", "|&", "&>", ">&", "<&", "<>",
    ">|", "<(", ">(", ";", "&", "|", "(", ")", "<", ">",
)


class ShellToken(str):
    """One shell word. ``op`` is ``True`` only for a control or redirection
    operator (``;`` ``&&`` ``|`` ``>`` ``(`` …) that the shell itself sees as
    an operator: unquoted and not escaped. A quoted or escaped ``';'`` /
    ``\\;`` is a plain word (``op`` is ``False``), as in the shell. The
    delimiter word of a here-document carries its body in ``heredoc_body``."""

    op: bool
    heredoc_body: str | None = None
    heredoc_quoted: bool = False

    def __new__(cls, text: str, op: bool = False) -> "ShellToken":
        obj = super().__new__(cls, text)
        obj.op = op
        return obj


def shell_tokens(command: str) -> list[str] | None:
    """``command`` as shell words, with the control operators (``;`` ``&&``
    ``|`` ``(`` ``>`` …) as words of their own even without spaces around
    them (``a;rm`` is three words). A newline separates commands like ``;``.

    Quoting follows the shell: single quotes, double quotes (``\\`` escapes
    only ``$``, a backtick, ``"``, ``\\`` and a newline), ``$'…'`` ANSI-C strings,
    ``$"…"``, a backslash outside quotes, and ``#`` at the start of a word
    begins a comment. A carriage return is part of a word, as in bash.
    Here-documents are read: their body is not a command. ``$(…)`` and
    backticks stay inside their word. Each token is a :class:`ShellToken`, so
    a caller can tell a real operator from a quoted one. ``None`` when the
    command cannot be parsed with certainty (an open quote, too deep)."""
    try:
        return _lex(command, None)
    except (ValueError, RecursionError):
        return None


def _is_op(token: str) -> bool:
    """``token`` is an operator the shell sees. A :class:`ShellToken` carries
    its provenance; a plain string (old callers) falls back to its characters."""
    op = getattr(token, "op", None)
    if op is not None:
        return bool(op)
    return bool(token) and set(token) <= _PUNCT


def is_separator(token: str) -> bool:
    """A control operator between two simple commands (``;`` ``&&`` ``|``
    ``(`` ``)`` ``<(`` …), not a redirection. A quoted or escaped operator
    character is an argument, not a separator."""
    return _is_op(token) and token not in _REDIRECTS


def _is_redirect(token: str) -> bool:
    return _is_op(token) and token in _REDIRECTS


_OPS_BY_CHAR = {c: tuple(op for op in _OPERATORS if op[0] == c) for c in _PUNCT}


def _match_operator(s: str, i: int) -> str:
    for op in _OPS_BY_CHAR.get(s[i], ()):
        if s.startswith(op, i):
            return op
    return s[i]


def _lex(s: str, subs: list[str] | None, nest: int = 0) -> list[ShellToken]:
    """Tokenize ``s``. The text of every ``$(…)`` and backtick substitution
    (also inside an unquoted here-document) is appended to ``subs``."""
    if nest > _MAX_NEST:
        raise _Unparsable("nesting too deep")
    tokens: list[ShellToken] = []
    buf: list[str] = []
    in_word = False
    word_start = 0
    expect_delim: str | None = None
    pending: list[tuple[ShellToken, bool]] = []
    n = len(s)
    i = 0

    def flush(end: int) -> None:
        nonlocal buf, in_word, expect_delim
        if in_word:
            tok = ShellToken("".join(buf))
            tokens.append(tok)
            if expect_delim is not None:
                raw = s[word_start:end]
                tok.heredoc_quoted = any(q in raw for q in "'\"\\")
                pending.append((tok, expect_delim == "<<-"))
                expect_delim = None
        buf = []
        in_word = False

    def start_word(at: int) -> None:
        nonlocal in_word, word_start
        if not in_word:
            in_word = True
            word_start = at

    while i < n:
        c = s[i]
        if c in " \t":
            flush(i)
            i += 1
            continue
        if c == "\n":
            flush(i)
            if expect_delim is not None:
                raise _Unparsable("here-document without a delimiter")
            tokens.append(ShellToken(";", op=True))
            i += 1
            if pending:
                i = _read_heredocs(s, i, pending, subs, nest)
                pending = []
            continue
        if c in _PUNCT:
            flush(i)
            if expect_delim is not None:
                raise _Unparsable("here-document without a delimiter")
            op = _match_operator(s, i)
            tokens.append(ShellToken(op, op=True))
            i += len(op)
            if op in ("<<", "<<-"):
                expect_delim = op
            continue
        if c == "#" and not in_word:
            j = s.find("\n", i)
            i = n if j == -1 else j
            continue
        if c == "\\":
            if i + 1 < n and s[i + 1] == "\n":
                i += 2  # line continuation
                continue
            start_word(i)
            if i + 1 >= n:
                buf.append("\\")
                i += 1
            else:
                buf.append(s[i + 1])
                i += 2
            continue
        start_word(i)
        if c == "'":
            j = s.find("'", i + 1)
            if j == -1:
                raise ValueError("open single quote")
            buf.append(s[i + 1 : j])
            i = j + 1
            continue
        if c == '"':
            i = _lex_double(s, i + 1, buf, subs, nest + 1)
            continue
        if c == "$" and i + 1 < n:
            nxt = s[i + 1]
            if nxt == "'":
                i = _lex_ansi_c(s, i + 2, buf)
                continue
            if nxt == '"':
                i = _lex_double(s, i + 2, buf, subs, nest + 1)
                continue
            if nxt == "(":
                j = _skip_paren(s, i + 1, nest + 1)
                buf.append(s[i:j])
                if subs is not None:
                    subs.append(s[i + 2 : j - 1])
                i = j
                continue
        if c == "`":
            j = _skip_backtick(s, i)
            buf.append(s[i:j])
            if subs is not None:
                subs.append(s[i + 1 : j - 1].replace("\\`", "`"))
            i = j
            continue
        buf.append(c)
        i += 1
    flush(n)
    if expect_delim is not None:
        raise _Unparsable("here-document without a delimiter")
    for tok, _strip in pending:
        tok.heredoc_body = ""  # a here-document at the very end has no body
    return tokens


def _read_heredocs(
    s: str, i: int, pending: list[tuple[ShellToken, bool]], subs: list[str] | None, nest: int
) -> int:
    """Read the bodies of the pending here-documents from ``i`` (the start of
    the line after their operator). Returns the index after the last one."""
    n = len(s)
    for tok, strip in pending:
        delim = str(tok)
        lines: list[str] = []
        while i < n:
            j = s.find("\n", i)
            line = s[i:] if j == -1 else s[i:j]
            i = n if j == -1 else j + 1
            check = line.lstrip("\t") if strip else line
            if check == delim:
                break
            lines.append(check)
        body = "\n".join(lines) + ("\n" if lines else "")
        tok.heredoc_body = body
        if not tok.heredoc_quoted and subs is not None:
            subs.extend(_body_substitutions(body, nest + 1))
    return i


def _body_substitutions(body: str, nest: int) -> list[str]:
    """The ``$(…)`` / backtick substitutions of an unquoted here-document
    (quotes are plain characters there)."""
    out: list[str] = []
    n = len(body)
    i = 0
    while i < n:
        c = body[i]
        if c == "\\":
            i += 2
            continue
        if c == "$" and i + 1 < n and body[i + 1] == "(":
            j = _skip_paren(body, i + 1, nest + 1)
            out.append(body[i + 2 : j - 1])
            i = j
            continue
        if c == "`":
            j = _skip_backtick(body, i)
            out.append(body[i + 1 : j - 1].replace("\\`", "`"))
            i = j
            continue
        i += 1
    return out


def _lex_double(s: str, i: int, buf: list[str], subs: list[str] | None = None, nest: int = 0) -> int:
    """Read a double-quoted string from ``i`` (after the quote) into ``buf``;
    returns the index after the closing quote."""
    if nest > _MAX_NEST:
        raise _Unparsable("nesting too deep")
    n = len(s)
    while i < n:
        c = s[i]
        if c == '"':
            return i + 1
        if c == "\\" and i + 1 < n:
            nxt = s[i + 1]
            if nxt == "\n":
                pass
            elif nxt in '$`"\\':
                buf.append(nxt)
            else:
                buf.append(c + nxt)
            i += 2
            continue
        if c == "$" and i + 1 < n and s[i + 1] == "(":
            j = _skip_paren(s, i + 1, nest + 1)
            buf.append(s[i:j])
            if subs is not None:
                subs.append(s[i + 2 : j - 1])
            i = j
            continue
        if c == "`":
            j = _skip_backtick(s, i)
            buf.append(s[i:j])
            if subs is not None:
                subs.append(s[i + 1 : j - 1].replace("\\`", "`"))
            i = j
            continue
        buf.append(c)
        i += 1
    raise ValueError("open double quote")


_ANSI_SIMPLE = {
    "a": "\a", "b": "\b", "e": "\x1b", "E": "\x1b", "f": "\f", "n": "\n",
    "r": "\r", "t": "\t", "v": "\v", "\\": "\\", "'": "'", '"': '"', "?": "?",
}


def _lex_ansi_c(s: str, i: int, buf: list[str]) -> int:
    """Read a ``$'…'`` string from ``i`` (after the quote) into ``buf`` with
    its escapes decoded (``$'\\x2f'`` is ``/``); returns the index after it."""
    n = len(s)
    while i < n:
        c = s[i]
        if c == "'":
            return i + 1
        if c != "\\" or i + 1 >= n:
            buf.append(c)
            i += 1
            continue
        e = s[i + 1]
        i += 2
        if e in _ANSI_SIMPLE:
            buf.append(_ANSI_SIMPLE[e])
        elif e in "01234567":
            j = i - 1
            while j < n and j < i + 2 and s[j] in "01234567":
                j += 1
            buf.append(chr(int(s[i - 1 : j], 8) & 0xFF))
            i = j
        elif e in "xuU":
            width = {"x": 2, "u": 4, "U": 8}[e]
            j = i
            while j < n and j < i + width and s[j] in "0123456789abcdefABCDEF":
                j += 1
            if j == i:
                buf.append("\\" + e)
            else:
                try:
                    buf.append(chr(int(s[i:j], 16)))
                except (ValueError, OverflowError):
                    buf.append("�")
                i = j
        elif e == "c" and i < n:
            buf.append(chr(ord(s[i]) & 0x1F))
            i += 1
        else:
            buf.append("\\" + e)
    raise ValueError("open $' quote")


def _heredoc_delim(s: str, j: int) -> tuple[str, int]:
    """The delimiter word of a here-document starting at ``j`` (after the
    operator and blanks), quotes removed; returns it and the index after it."""
    n = len(s)
    out: list[str] = []
    while j < n and s[j] not in " \t\n;&|()<>":
        c = s[j]
        if c in "'\"":
            k = s.find(c, j + 1)
            if k == -1:
                raise ValueError("open quote in a here-document delimiter")
            out.append(s[j + 1 : k])
            j = k + 1
        elif c == "\\" and j + 1 < n:
            out.append(s[j + 1])
            j += 2
        else:
            out.append(c)
            j += 1
    return "".join(out), j


def _skip_paren(s: str, i: int, nest: int = 0) -> int:
    """``s[i]`` is the ``(`` of ``$(``; returns the index after its ``)``,
    honouring quotes, nesting, comments and here-documents inside."""
    if nest > _MAX_NEST:
        raise _Unparsable("nesting too deep")
    n = len(s)
    depth = 1
    j = i + 1
    heredocs: list[tuple[str, bool]] = []
    while j < n:
        c = s[j]
        if c == "\\":
            j += 2
        elif c == "'":
            k = s.find("'", j + 1)
            if k == -1:
                raise ValueError("open single quote")
            j = k + 1
        elif c == '"':
            j = _lex_double(s, j + 1, [], None, nest + 1)
        elif c == "`":
            j = _skip_backtick(s, j)
        elif c == "$" and j + 1 < n and s[j + 1] == "(":
            j = _skip_paren(s, j + 1, nest + 1)
        elif c == "#" and (j == 0 or s[j - 1] in " \t\n;&|("):
            k = s.find("\n", j)
            if k == -1:
                raise ValueError("open $( after a comment")
            j = k
        elif c == "<" and s.startswith("<<", j) and not s.startswith("<<<", j):
            k = j + 2
            strip = k < n and s[k] == "-"
            if strip:
                k += 1
            while k < n and s[k] in " \t":
                k += 1
            delim, k = _heredoc_delim(s, k)
            if delim:
                heredocs.append((delim, strip))
            j = k
        elif c == "\n" and heredocs:
            j += 1
            for delim, strip in heredocs:
                while j < n:
                    k = s.find("\n", j)
                    line = s[j:] if k == -1 else s[j:k]
                    j = n if k == -1 else k + 1
                    if (line.lstrip("\t") if strip else line) == delim:
                        break
            heredocs = []
        elif c == "(":
            depth += 1
            j += 1
        elif c == ")":
            depth -= 1
            j += 1
            if depth == 0:
                return j
        else:
            j += 1
    raise ValueError("open $(")


def _skip_backtick(s: str, i: int) -> int:
    """``s[i]`` is an opening backtick; returns the index after its pair."""
    n = len(s)
    j = i + 1
    while j < n:
        if s[j] == "\\":
            j += 2
            continue
        if s[j] == "`":
            return j + 1
        j += 1
    raise ValueError("open backtick")


@dataclass
class _Scan:
    """What one :meth:`SafetyFloor.check_command` found."""

    verdicts: list[FloorVerdict] = field(default_factory=list)
    #: One simple command, no chain, pipe, substitution, launcher or nested
    #: shell. Only such a command may have a soft stop lifted by a prefix.
    simple: bool = True
    #: Characters lexed so far (all nesting levels), against ``_WORK_LIMIT``.
    work: int = 0

    def add(self, verdict: FloorVerdict, *, simple: bool = True) -> None:
        self.verdicts.append(verdict)
        if not simple:
            self.simple = False


def _split_segments(tokens: list[str]) -> list[list[str]]:
    """Split a token list on shell separators into simple commands."""
    return [seg for seg, _piped in _split_segments_piped(tokens)]


def _split_segments_piped(tokens: list[str]) -> list[tuple[list[str], bool]]:
    """Split a token list into simple commands; each comes with whether a
    pipe (``|`` / ``|&``) feeds it."""
    segments: list[tuple[list[str], bool]] = []
    current: list[str] = []
    between: list[str] = []
    piped = False
    for token in tokens:
        if is_separator(token):
            if current:
                segments.append((current, piped))
                current = []
                between = []
            between.append(str(token))
            continue
        if not current:
            piped = any(t in ("|", "|&") for t in between)
        current.append(token)
    if current:
        segments.append((current, piped))
    return segments


__all__ = ["FloorVerdict", "SafetyFloor", "PROTECTED_REL", "ShellToken", "is_separator", "shell_tokens"]
