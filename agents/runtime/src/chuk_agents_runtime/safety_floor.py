"""The safety floor (research docs/research/HERMES_AND_OTHER_AGENTS.md H23-H25,
and docs/WIRE_CONTRACT.md "Safety floor").

The agent runs on the user's real computer, so a small set of actions is
stopped before it runs, whatever the approval mode:

- **Hard deny** (never allowed): ``rm -rf /`` / ``~`` / ``$HOME``, ``mkfs*``,
  ``dd`` to a block device, the classic fork bomb, ``chmod -R 777 /``,
  ``shutdown`` / ``reboot`` (unless the host allows it), and deleting the
  agent's own install or state directory.
- **Protected paths** (not touched without an explicit approval): ``~/.ssh``,
  ``~/.aws``, ``~/.gnupg``, ``~/.config/gh``, ``~/.netrc`` and any ``.env``
  file. Writing to them, and reading a ``.env``, must ask first.

Matching is on shell tokens (quoting as the shell reads it), not raw
substrings, so a path inside a string literal or a comment does not trip it,
and a quoted or escaped operator (``';'``, ``\\;``) does not split a command.
A command the shell cannot parse is NOT blocked here (the sandbox switches
are the control for the exotic case);
the clear, catastrophic shapes are caught token by token.
"""

from __future__ import annotations

import os
import posixpath
import re
from dataclasses import dataclass, field


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

#: Commands that read a file's content (so reading a ``.env`` asks).
_READ_VERBS = frozenset({"cat", "less", "more", "head", "tail", "bat", "nl", "xxd", "od", "strings"})
#: Commands that change the filesystem (so a protected target asks).
_WRITE_VERBS = frozenset(
    {"rm", "rmdir", "mv", "cp", "tee", "truncate", "dd", "chmod", "chown", "ln", "install", "shred", "unlink"}
)
#: Launchers that are stripped so the real command underneath is seen (their
#: options and values too, see ``_LAUNCHER_SPECS``).
_LAUNCHERS = frozenset(
    {
        "sudo", "env", "nice", "nohup", "stdbuf", "setsid", "time", "command", "doas", "exec",
        "timeout", "xargs", "ionice", "watch", "taskset", "chroot", "flock", "busybox", "builtin",
    }
)
#: Commands that end the machine.
_SHUTDOWN = frozenset({"shutdown", "reboot", "halt", "poweroff"})
#: Device nodes a raw ``dd`` must not write.
_BLOCK_DEV = re.compile(r"^/dev/(sd[a-z]|nvme\d+n\d+|mmcblk\d+|vd[a-z]|disk\d+|hd[a-z])")


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
        text = token
        if text in ("~", "$HOME", "${HOME}"):
            return self.home
        if text.startswith("~/"):
            text = self.home + text[1:]
        text = text.replace("$HOME", self.home).replace("${HOME}", self.home)
        return posixpath.normpath(text)

    def _protected_dirs(self) -> list[str]:
        return [posixpath.normpath(posixpath.join(self.home, rel)) for rel in PROTECTED_REL]

    def _under(self, path: str, base: str) -> bool:
        path = posixpath.normpath(path)
        base = posixpath.normpath(base)
        return path == base or path.startswith(base + "/")

    def protected_target(self, raw_path: str) -> str | None:
        """The protected location a path falls in, or ``None``. Used by the
        file tools before a write, a delete or a ``.env`` read."""
        path = self._expand(str(raw_path))
        name = posixpath.basename(path)
        if name == ".env" or name.startswith(".env."):
            return ".env file"
        for base in self._protected_dirs():
            if self._under(path, base):
                return base
        if posixpath.basename(path) == ".netrc":
            return ".netrc"
        return None

    def check_path_write(self, raw_path: str) -> FloorVerdict | None:
        """A write / delete of ``raw_path`` (file tools). Soft when protected."""
        hit = self.protected_target(raw_path)
        if hit is None:
            return None
        for d in self.self_dirs:
            if self._under(self._expand(str(raw_path)), d):
                return FloorVerdict(f"this would change the agent's own files ({d})", hard=True)
        return FloorVerdict(f"writing {hit} is protected", hard=False)

    def check_path_read(self, raw_path: str) -> FloorVerdict | None:
        """A read of ``raw_path`` (file tools): only a ``.env`` asks."""
        path = self._expand(str(raw_path))
        name = posixpath.basename(path)
        if name == ".env" or name.startswith(".env."):
            return FloorVerdict("reading a .env file is protected", hard=False)
        return None

    # -- commands -------------------------------------------------------------

    def _tokenize(self, command: str) -> list[str] | None:
        return shell_tokens(command)

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
        self._scan_command(command, scan, depth=0)
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

    def _scan_command(self, command: str, scan: "_Scan", depth: int) -> None:
        """Collect every verdict of ``command`` into ``scan``: each simple
        command between separators, each ``$(…)`` / backtick / ``<(…)``
        substitution and each ``bash -c`` / ``eval`` string is checked."""
        if depth > _MAX_DEPTH:
            # Nesting this deep is not a normal command; refuse to guess.
            scan.add(FloorVerdict("the command nests shells too deeply to check"), simple=False)
            return
        # The fork bomb survives any tokenizer; match it on the squeezed text.
        squeezed = re.sub(r"\s+", "", command)
        if ":(){:|:&};:" in squeezed or ":(){:|:&amp;};:" in squeezed:
            scan.add(FloorVerdict("fork bomb"))
        for inner in _substitutions(command):
            scan.simple = False
            self._scan_command(inner, scan, depth + 1)
        tokens = self._tokenize(command)
        if not tokens:
            return
        segments = _split_segments(tokens)
        if len(segments) > 1:
            scan.simple = False
        for segment in segments:
            self._scan_segment(segment, scan, depth)

    def _scan_tokens(self, tokens: list[str]) -> FloorVerdict | None:
        """Kept for callers that scan already split tokens."""
        scan = _Scan()
        for segment in _split_segments(tokens):
            self._scan_segment(segment, scan, 0)
        hard = [v for v in scan.verdicts if v.hard]
        return hard[0] if hard else (scan.verdicts[0] if scan.verdicts else None)

    def _scan_segment(self, segment: list[str], scan: "_Scan", depth: int) -> None:
        words: list[str] = []
        # Redirections: a protected target asks; the operator and its target
        # are dropped so they are not taken for the verb.
        i = 0
        while i < len(segment):
            word = segment[i]
            if _is_redirect(word):
                scan.simple = False  # a redirect is never covered by a prefix
                target = segment[i + 1] if i + 1 < len(segment) else ""
                if ">" in word and target and not target.isdigit():
                    hit = self.protected_target(target)
                    if hit is not None:
                        scan.add(FloorVerdict(f"writing {hit}", hard=False))
                elif word == "<" and target:
                    read = self.check_path_read(target)
                    if read is not None:
                        scan.add(read)
                if words and words[-1].isdigit():
                    words.pop()  # the fd number of ``2>``
                i += 2
                continue
            words.append(word)
            i += 1
        self._scan_words(words, scan, depth)

    def _scan_words(self, words: list[str], scan: "_Scan", depth: int) -> None:
        idx = 0
        while idx < len(words):
            word = words[idx]
            name = posixpath.basename(word)
            if "=" in word and not word.startswith("-") and _ASSIGNMENT.match(word):
                idx += 1  # ``VAR=value`` before the program
                continue
            if word in _RESERVED:
                scan.simple = False
                idx += 1  # ``{ rm …; }``, ``if rm …; then``, ``! rm``
                continue
            if name in _LAUNCHERS:
                scan.simple = False
                idx = self._skip_launcher(name, words, idx + 1, scan, depth)
                continue
            break
        if idx >= len(words):
            return
        verb = posixpath.basename(words[idx])
        rest = words[idx + 1:]
        if verb in _SHELLS:
            inner = _shell_command_string(rest)
            if inner is not None:
                scan.simple = False
                self._scan_command(inner, scan, depth + 1)
            return
        if verb == "eval":
            scan.simple = False
            self._scan_command(" ".join(rest), scan, depth + 1)
            return
        if verb == "su":
            inner = _option_value(rest, ("-c", "--command"))
            if inner is not None:
                scan.simple = False
                self._scan_command(inner, scan, depth + 1)
            return
        verdict = self._verb_verdict(verb, rest, words[idx:])
        if verdict is not None:
            scan.add(verdict)

    def _skip_launcher(
        self, name: str, words: list[str], idx: int, scan: "_Scan", depth: int
    ) -> int:
        """Skip a launcher's options (and their values) and its positional
        arguments, so ``sudo -u root rm`` reaches ``rm``. Returns the index of
        the next word. ``env -S "…"`` splits a string into a command: it is
        checked like ``bash -c``."""
        spec = _LAUNCHER_SPECS.get(name, _LauncherSpec())
        positional = spec.positional
        while idx < len(words):
            word = words[idx]
            if word == "--":
                idx += 1
                break
            if name == "env" and _ASSIGNMENT.match(word):
                idx += 1
                continue
            if word.startswith("-") and len(word) > 1:
                if name == "nice" and word[1:].isdigit():
                    idx += 1  # ``nice -5``
                    continue
                key, eq, value = word.partition("=")
                if name == "env" and key in ("-S", "--split-string"):
                    text = value if eq else (words[idx + 1] if idx + 1 < len(words) else "")
                    scan.simple = False
                    self._scan_command(text, scan, depth + 1)
                    return len(words)
                if name == "taskset" and key in ("-c", "--cpu-list"):
                    positional = 0
                if name == "taskset" and key in ("-p", "--pid"):
                    return len(words)  # changes a running pid; no command
                if word.startswith("--"):
                    # ``--user=root`` carries its value; ``--user root`` does not.
                    idx += 1 if eq or key not in spec.value_opts else 2
                    continue
                # A short cluster: ``-E``, ``-uroot`` (value attached), ``-Hu root``.
                step = 1
                for pos, char in enumerate(word[1:], start=1):
                    if f"-{char}" in spec.value_opts:
                        step = 1 if pos < len(word) - 1 else 2
                        break
                idx += step
                continue
            if positional > 0:
                positional -= 1  # ``timeout 5`` / ``taskset 0x1``
                idx += 1
                continue
            break
        return idx

    def _verb_verdict(self, verb: str, rest: list[str], whole: list[str]) -> FloorVerdict | None:
        if verb.startswith("mkfs"):
            return FloorVerdict("mkfs formats a filesystem")
        if verb in _SHUTDOWN or (verb == "systemctl" and any(a in ("poweroff", "reboot", "halt") for a in rest)):
            if self.allow_shutdown:
                return None
            return FloorVerdict(f"{verb} powers off or reboots the machine", hard=False)
        if verb == "init" and any(a in ("0", "6") for a in rest):
            return FloorVerdict("init 0/6 powers off or reboots the machine", hard=not self.allow_shutdown)
        if verb == "dd":
            for a in rest:
                if a.startswith("of=") and _BLOCK_DEV.match(self._expand(a[3:])):
                    return FloorVerdict("dd writes to a block device")
        if verb == "chmod":
            if any(_recursive(a) for a in rest) and "777" in rest and any(self._is_root(p) for p in rest):
                return FloorVerdict("chmod -R 777 on /")
        if verb in ("rm",):
            return self._rm_verdict(rest)
        if verb in _WRITE_VERBS:
            for a in rest:
                if a.startswith("-"):
                    continue
                hit = self.protected_target(a)
                if hit is not None:
                    return FloorVerdict(f"{verb} on {hit}", hard=False)
        if verb in _READ_VERBS:
            for a in rest:
                if a.startswith("-"):
                    continue
                v = self.check_path_read(a)
                if v is not None:
                    return v
        return None

    def _rm_verdict(self, rest: list[str]) -> FloorVerdict | None:
        recursive = any(_recursive(a) for a in rest)
        targets = [a for a in rest if not a.startswith("-")]
        for t in targets:
            expanded = self._expand(t)
            if recursive and (self._is_root(t) or expanded == self.home or t in ("~", "$HOME", "${HOME}")):
                return FloorVerdict("rm -rf of / or your home directory")
            for d in self.self_dirs:
                if recursive and self._under(expanded, d):
                    return FloorVerdict(f"rm -rf of the agent's own directory ({d})")
            hit = self.protected_target(t)
            if hit is not None:
                return FloorVerdict(f"deleting {hit}", hard=False)
        return None

    @staticmethod
    def _is_root(token: str) -> bool:
        return token in ("/", "/*") or re.fullmatch(r"/\*?", token) is not None


def _recursive(flag: str) -> bool:
    if not flag.startswith("-") or flag.startswith("--"):
        return flag in ("--recursive",)
    return "r" in flag or "R" in flag


#: Deepest nesting of ``bash -c`` / ``$(…)`` the floor follows.
_MAX_DEPTH = 6
#: Redirection operators the punctuation-aware tokenizer emits.
_REDIRECTS = frozenset({">", ">>", "<", ">|", "&>", "&>>", ">&", "<&", "<<", "<<<", "<>", "<<-"})
_PUNCT = frozenset("();<>|&")
#: Shell reserved words that can stand before a command.
_RESERVED = frozenset({"{", "}", "!", "if", "then", "else", "elif", "do", "while", "until", "fi", "done"})
_ASSIGNMENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
#: Shells whose ``-c`` string is a command of its own.
_SHELLS = frozenset({"sh", "bash", "zsh", "dash", "ksh", "mksh", "fish", "ash", "busybox-sh"})


@dataclass(frozen=True)
class _LauncherSpec:
    #: Options that take a value as the next word (``sudo -u root``).
    value_opts: frozenset[str] = frozenset()
    #: Positional arguments before the command (``timeout 5 rm``).
    positional: int = 0


_LAUNCHER_SPECS: dict[str, _LauncherSpec] = {
    "sudo": _LauncherSpec(
        frozenset(
            {"-u", "-g", "-h", "-C", "-p", "-U", "-r", "-t", "-T", "-D", "-R",
             "--user", "--group", "--host", "--close-from", "--prompt", "--other-user",
             "--role", "--type", "--command-timeout", "--chdir", "--chroot"}
        )
    ),
    "doas": _LauncherSpec(frozenset({"-u", "-C"})),
    "env": _LauncherSpec(frozenset({"-u", "--unset", "-C", "--chdir"})),
    "nice": _LauncherSpec(frozenset({"-n", "--adjustment"})),
    "ionice": _LauncherSpec(frozenset({"-c", "-n", "--class", "--classdata"})),
    "stdbuf": _LauncherSpec(frozenset({"-i", "-o", "-e", "--input", "--output", "--error"})),
    "time": _LauncherSpec(frozenset({"-f", "-o", "--format", "--output"})),
    "exec": _LauncherSpec(frozenset({"-a"})),
    "timeout": _LauncherSpec(frozenset({"-s", "-k", "--signal", "--kill-after"}), positional=1),
    "xargs": _LauncherSpec(
        frozenset({"-I", "-n", "-P", "-L", "-s", "-d", "-a", "-E", "--max-args", "--max-procs",
                   "--max-lines", "--max-chars", "--delimiter", "--arg-file", "--eof", "--replace"})
    ),
    "watch": _LauncherSpec(frozenset({"-n", "--interval", "--equexit"})),
    "taskset": _LauncherSpec(frozenset(), positional=1),
    "chroot": _LauncherSpec(frozenset({"--userspec", "--groups"}), positional=1),
    "flock": _LauncherSpec(frozenset({"-w", "--timeout", "-E", "--conflict-exit-code"}), positional=1),
}


class ShellToken(str):
    """One shell word. ``op`` is ``True`` only for a run of control or
    redirection characters (``;`` ``&&`` ``|`` ``>`` ``(`` …) that the shell
    itself sees as an operator: unquoted and not escaped. A quoted or escaped
    ``';'`` / ``\\;`` is a plain word (``op`` is ``False``), as in the shell."""

    op: bool

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
    begins a comment. ``$(…)`` and backticks stay inside their word (their
    text is checked on its own, see :func:`_substitutions`). Each token is a
    :class:`ShellToken`, so a caller can tell a real operator from a quoted
    one. ``None`` when the shell could not parse it either (an open quote)."""
    try:
        return _lex(command)
    except ValueError:
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


def _lex(s: str) -> list[str]:
    tokens: list[str] = []
    buf: list[str] = []
    in_word = False
    n = len(s)
    i = 0

    def flush() -> None:
        nonlocal buf, in_word
        if in_word:
            tokens.append(ShellToken("".join(buf)))
        buf = []
        in_word = False

    while i < n:
        c = s[i]
        if c in " \t\r":
            flush()
            i += 1
            continue
        if c == "\n":
            flush()
            tokens.append(ShellToken(";", op=True))
            i += 1
            continue
        if c in _PUNCT:
            flush()
            j = i
            while j < n and s[j] in _PUNCT:
                j += 1
            tokens.append(ShellToken(s[i:j], op=True))
            i = j
            continue
        if c == "#" and not in_word:
            j = s.find("\n", i)
            i = n if j == -1 else j
            continue
        if c == "\\":
            if i + 1 < n and s[i + 1] == "\n":
                i += 2  # line continuation
                continue
            in_word = True
            if i + 1 >= n:
                buf.append("\\")
                i += 1
            else:
                buf.append(s[i + 1])
                i += 2
            continue
        in_word = True
        if c == "'":
            j = s.find("'", i + 1)
            if j == -1:
                raise ValueError("open single quote")
            buf.append(s[i + 1 : j])
            i = j + 1
            continue
        if c == '"':
            i = _lex_double(s, i + 1, buf)
            continue
        if c == "$" and i + 1 < n:
            nxt = s[i + 1]
            if nxt == "'":
                i = _lex_ansi_c(s, i + 2, buf)
                continue
            if nxt == '"':
                i = _lex_double(s, i + 2, buf)
                continue
            if nxt == "(":
                j = _skip_paren(s, i + 1)
                buf.append(s[i:j])
                i = j
                continue
        if c == "`":
            j = _skip_backtick(s, i)
            buf.append(s[i:j])
            i = j
            continue
        buf.append(c)
        i += 1
    flush()
    return tokens


def _lex_double(s: str, i: int, buf: list[str]) -> int:
    """Read a double-quoted string from ``i`` (after the quote) into ``buf``;
    returns the index after the closing quote."""
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
            j = _skip_paren(s, i + 1)
            buf.append(s[i:j])
            i = j
            continue
        if c == "`":
            j = _skip_backtick(s, i)
            buf.append(s[i:j])
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
                    buf.append("\ufffd")
                i = j
        elif e == "c" and i < n:
            buf.append(chr(ord(s[i]) & 0x1F))
            i += 1
        else:
            buf.append("\\" + e)
    raise ValueError("open $' quote")


def _skip_paren(s: str, i: int) -> int:
    """``s[i]`` is the ``(`` of ``$(``; returns the index after its ``)``,
    honouring quotes and nesting inside."""
    n = len(s)
    depth = 1
    j = i + 1
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
            j = _lex_double(s, j + 1, [])
        elif c == "`":
            j = _skip_backtick(s, j)
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


def _substitutions(command: str) -> list[str]:
    """The text inside every ``$(…)``, ``<(…)``, ``>(…)`` and backtick pair.
    Quoting is ignored on purpose: a substitution inside double quotes runs,
    and a false match in a single-quoted literal only means one more check."""
    found: list[str] = []
    i = 0
    n = len(command)
    while i < n:
        ch = command[i]
        if ch in "$<>" and i + 1 < n and command[i + 1] == "(":
            depth = 1
            j = i + 2
            while j < n and depth:
                if command[j] == "(":
                    depth += 1
                elif command[j] == ")":
                    depth -= 1
                j += 1
            found.append(command[i + 2 : j - 1 if depth == 0 else j])
            i = i + 2
            continue
        if ch == "`":
            j = command.find("`", i + 1)
            if j == -1:
                found.append(command[i + 1 :])
                break
            found.append(command[i + 1 : j])
            i = j + 1
            continue
        i += 1
    return [f for f in found if f.strip()]


def _shell_command_string(args: list[str]) -> str | None:
    """The command string of ``bash -c "…"`` (also ``-lc``, ``-ec``,
    ``-o pipefail -c``), or ``None`` when there is no ``-c``."""
    has_c = False
    idx = 0
    while idx < len(args):
        word = args[idx]
        if word == "--":
            idx += 1
            break
        if word in ("-o", "+o", "-O", "+O"):
            idx += 2
            continue
        if word.startswith("--"):
            if word == "--command":
                has_c = True
            idx += 1
            continue
        if word.startswith("-") and len(word) > 1:
            if "c" in word[1:]:
                has_c = True
            idx += 1
            continue
        break
    if has_c and idx < len(args):
        return args[idx]
    return None


def _option_value(args: list[str], names: tuple[str, ...]) -> str | None:
    for idx, word in enumerate(args):
        for name in names:
            if word == name and idx + 1 < len(args):
                return args[idx + 1]
            if word.startswith(name + "="):
                return word[len(name) + 1 :]
    return None


@dataclass
class _Scan:
    """What one :meth:`SafetyFloor.check_command` found."""

    verdicts: list[FloorVerdict] = field(default_factory=list)
    #: One simple command, no chain, pipe, substitution, launcher or nested
    #: shell. Only such a command may have a soft stop lifted by a prefix.
    simple: bool = True

    def add(self, verdict: FloorVerdict, *, simple: bool = True) -> None:
        self.verdicts.append(verdict)
        if not simple:
            self.simple = False


def _split_segments(tokens: list[str]) -> list[list[str]]:
    """Split a token list on shell separators into simple commands."""
    segments: list[list[str]] = []
    current: list[str] = []
    for token in tokens:
        if is_separator(token):
            if current:
                segments.append(current)
            current = []
        else:
            current.append(token)
    if current:
        segments.append(current)
    return segments


__all__ = ["FloorVerdict", "SafetyFloor", "PROTECTED_REL", "ShellToken", "is_separator", "shell_tokens"]
