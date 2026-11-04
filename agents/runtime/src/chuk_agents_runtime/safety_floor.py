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

Matching is on tokens (``shlex``), not raw substrings, so a path inside a
string literal or a comment does not trip it. A command the shell cannot parse
is NOT blocked here (the sandbox switches are the control for the exotic case);
the clear, catastrophic shapes are caught token by token.
"""

from __future__ import annotations

import os
import posixpath
import re
import shlex
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
#: Launchers that are stripped so the real command underneath is seen.
_LAUNCHERS = frozenset({"sudo", "env", "nice", "nohup", "stdbuf", "setsid", "time", "command", "doas", "exec"})
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
        try:
            return shlex.split(command, comments=False, posix=True)
        except ValueError:
            return None

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
        # The fork bomb survives any tokenizer; match it on the squeezed text.
        squeezed = re.sub(r"\s+", "", command)
        if ":(){:|:&};:" in squeezed or ":(){:|:&amp;};:" in squeezed:
            return FloorVerdict("fork bomb")
        tokens = self._tokenize(command)
        if not tokens:
            return None
        verdict = self._scan_tokens(tokens)
        if verdict is None or verdict.hard:
            return verdict
        # A soft stop (a protected path, a shutdown the host left off) is lifted
        # when the user allowed this command prefix (research C2, item 9).
        if self._is_prefix_allowed(command):
            return None
        return verdict

    def _scan_tokens(self, tokens: list[str]) -> FloorVerdict | None:
        # Walk each simple command between separators, stripping launchers.
        for segment in _split_segments(tokens):
            verdict = self._scan_segment(segment)
            if verdict is not None:
                return verdict
        return None

    def _scan_segment(self, segment: list[str]) -> FloorVerdict | None:
        words = list(segment)
        # Redirection into a protected path (``> ~/.ssh/authorized_keys``).
        for i, word in enumerate(words):
            if word in (">", ">>") and i + 1 < len(words):
                hit = self.protected_target(words[i + 1])
                if hit is not None:
                    return FloorVerdict(f"writing {hit}", hard=False)
            elif word.startswith(">") and len(word) > 1 and word not in (">", ">>"):
                hit = self.protected_target(word.lstrip(">"))
                if hit is not None:
                    return FloorVerdict(f"writing {hit}", hard=False)
        # Strip launchers (sudo, env VAR=…, nice, …) to reach the real verb.
        idx = 0
        while idx < len(words) and (words[idx] in _LAUNCHERS or "=" in words[idx]):
            if words[idx] in ("env",) or "=" in words[idx]:
                idx += 1
                while idx < len(words) and "=" in words[idx]:
                    idx += 1
                continue
            idx += 1
        if idx >= len(words):
            return None
        verb = posixpath.basename(words[idx])
        rest = words[idx + 1:]
        return self._verb_verdict(verb, rest, words[idx:])

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


def _split_segments(tokens: list[str]) -> list[list[str]]:
    """Split a token list on shell separators into simple commands."""
    separators = {"&&", "||", "|", ";", "&", "|&"}
    segments: list[list[str]] = []
    current: list[str] = []
    for token in tokens:
        if token in separators:
            if current:
                segments.append(current)
            current = []
        else:
            current.append(token)
    if current:
        segments.append(current)
    return segments


__all__ = ["FloorVerdict", "SafetyFloor", "PROTECTED_REL"]
