"""Persistent interactive terminal (§7.8).

The one-shot ``run_command`` tool (§6) cannot drive an interactive program. A
menu, a password prompt, an ncurses TUI, ``git rebase -i``, a REPL — each needs
a TTY that survives between tool calls, keystrokes sent into it, and the
*rendered screen* read back. This module adds exactly that, next to the
one-shot tool, and leaves the one-shot tool the default.

**Backing mechanism: tmux, not a raw PTY + `pyte`.** The plan left the choice
open (§20). tmux wins here for one structural reason: the runtime's only seam
to the machine is ``Environment.run_bash`` (one shell command in, a result
out). tmux keeps the terminal state in its own server process, so every
operation is a plain, stateless shell command — ``new-session``, ``send-keys``,
``capture-pane`` — and works unchanged against the local stand-in and against
the real sandbox, over whatever transport the sandbox uses. A PTY + ``pyte``
would need a long-lived file descriptor and a screen emulator living *inside*
the runtime process, i.e. a second seam that the sandbox would have to grow and
that could not be exercised the same way in tests. tmux also already does the
hard part correctly: VT100/xterm emulation, resize, wrapping, alternate screen.
The cost is one dependency in the image; the tool hides itself from the prompt
when it is absent.

**Token cost is the design constraint** (§7.8 "Token cost & lifecycle", §7.9):

- *Bounded viewport.* Reads capture the visible pane only, never the
  scrollback, clamped to ``rows x cols`` and trimmed of trailing blank lines.
- *Diff reads.* A read returns only the lines that changed since the previous
  capture, or ``"no change"`` when the screen is identical. Redraw-heavy TUIs
  repaint the same screen every round; that repaint costs nothing here.
  Measured on an 18-entry menu at 80x24 (the shape of a package-manager
  picker): ten cursor moves cost 4550 characters (~1137 tokens) as full
  captures and 575 characters (~143 tokens) as diffs — 88% less, and the gap
  grows with the size of the screen. A full capture stays available on demand,
  and is used automatically when most of the screen changed (a scrolled
  shell), where a line-numbered diff would be *bigger* than the screen.
- *One call per interaction.* ``terminal_send_keys`` settles briefly and
  returns the diff itself, so navigating a menu is one tool round, not two.

**Lifecycle: named, task-scoped, closed on done.** A manager is built per task
and prefixes its tmux session names with the task id, so a new task always gets
a fresh terminal — no leftover process, no stuck TUI, no stale cwd. The agent
closes a terminal when finished (``terminal_close``); an idle reaper kills
whatever it abandoned. Reuse of a previous session is possible but explicit
(``reuse=true``), because silent reuse is how an agent inherits somebody else's
half-finished ``vim``.

**The keystroke trap.** ``tmux send-keys`` interprets its argument as a *key
name* unless ``-l`` is given, so a literal ``"Enter the password"`` typed into a
prompt would press the Enter key. Literal text and named keys are therefore
separate arguments here (``text`` vs ``keys``) and literal text is always sent
with ``-l``. One further tmux quirk, verified against tmux 3.4 rather than
assumed: tmux strips a **trailing** semicolon from an argument (its command
separator), so ``echo A;`` would arrive as ``echo A``. Trailing semicolons are
split off and sent by hex code instead.
"""

from __future__ import annotations

import re
import shlex
import time
from dataclasses import dataclass, field
from typing import Callable

from .environment import Environment
from .registry import ToolRegistry

# -- bounds (characters and lines, deliberately not tokens) ----------------

DEFAULT_ROWS = 24
DEFAULT_COLS = 100
MAX_ROWS = 60
MAX_COLS = 200

#: Cap on the text one read may return. A screen is small; this only guards
#: against a pathological pane size.
CAPTURE_CHAR_CAP = 8_000

#: Above this share of changed lines a diff is no cheaper than the screen
#: itself (a scrolled shell shifts every line), so the full screen is sent.
DIFF_FULL_THRESHOLD = 0.6

#: Seconds an untouched terminal may live before the reaper kills it.
IDLE_TIMEOUT_S = 900

#: Live terminals per task. A model that opens one per thought is a bug.
MAX_SESSIONS = 8

#: Seconds waited after a keystroke before the screen is captured.
DEFAULT_SETTLE_S = 0.3
MAX_SETTLE_S = 5.0

MAX_WAIT_S = 120.0

_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$")


class TerminalError(ValueError):
    """A rejected terminal operation. The message is meant for the model."""


# -- key names -------------------------------------------------------------

# Friendly name -> tmux key name. Models write "escape" or "backspace"; tmux
# wants "Escape" and "BSpace". Anything not in here (or not a modifier form)
# is refused with the list, never guessed — a guessed keystroke is an unwanted
# keystroke, and this is a real keyboard on the user's machine.
KEY_ALIASES: dict[str, str] = {
    "enter": "Enter",
    "return": "Enter",
    "cr": "Enter",
    "newline": "Enter",
    "tab": "Tab",
    "backtab": "BTab",
    "shift-tab": "BTab",
    "escape": "Escape",
    "esc": "Escape",
    "space": "Space",
    "up": "Up",
    "down": "Down",
    "left": "Left",
    "right": "Right",
    "home": "Home",
    "end": "End",
    "pageup": "PageUp",
    "page-up": "PageUp",
    "pgup": "PageUp",
    "pagedown": "PageDown",
    "page-down": "PageDown",
    "pgdn": "PageDown",
    "insert": "IC",
    "delete": "DC",
    "del": "DC",
    "bspace": "BSpace",
    "backspace": "BSpace",
}

_FUNCTION_RE = re.compile(r"^f([1-9]|1[0-2])$")
# C-c / ctrl-c / ^c / M-x / alt-x / C-M-a, single printable target key only.
_MODIFIER_RE = re.compile(
    r"^(?P<mods>(?:(?:c|ctrl|control|m|alt|meta)-)+)(?P<key>[!-~])$"
)
_MOD_CANON = {"c": "C", "ctrl": "C", "control": "C", "m": "M", "alt": "M", "meta": "M"}


def tmux_key(name: str) -> str:
    """Map a friendly key name to a tmux key name.

    Raises :class:`TerminalError` for anything unknown, so a typo can never be
    sent as literal text by accident.
    """
    raw = (name or "").strip()
    if not raw:
        raise TerminalError("empty key name")
    low = raw.lower()
    if low in KEY_ALIASES:
        return KEY_ALIASES[low]
    fn = _FUNCTION_RE.match(low)
    if fn:
        return f"F{fn.group(1)}"
    if low.startswith("^") and len(raw) == 2:
        return f"C-{raw[1].lower()}"
    mod = _MODIFIER_RE.match(low)
    if mod:
        parts = [p for p in mod.group("mods").split("-") if p]
        seen: list[str] = []
        for part in parts:
            canon = _MOD_CANON[part]
            if canon not in seen:
                seen.append(canon)
        # tmux writes the control modifier first: C-M-a, never M-C-a.
        seen.sort(key=lambda m: 0 if m == "C" else 1)
        return "-".join(seen) + "-" + mod.group("key")
    raise TerminalError(
        f"unknown key name: {raw!r}. Known keys: "
        + ", ".join(sorted(set(KEY_ALIASES.values())))
        + ", F1-F12, C-<char>, M-<char>. "
        "Literal text belongs in `text`, not in `keys`."
    )


# -- screen normalisation and diffing -------------------------------------


def normalize_screen(raw: str, rows: int, cols: int) -> list[str]:
    """Clamp a raw capture to the viewport and drop trailing blank lines.

    A tmux pane is padded to its full height, so an idle shell captures as two
    lines of text and twenty-two blank ones. Those blanks are pure cost.
    """
    lines = raw.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    lines = [line.rstrip()[:cols] for line in lines[:rows]]
    while lines and not lines[-1]:
        lines.pop()
    return lines


def diff_screens(old: list[str], new: list[str]) -> list[tuple[int, str]]:
    """Positional line diff, 1-based.

    Positional, not sequence-based: this is a *screen*, not a stream. When a
    menu highlights the next entry, exactly two rows change and their row
    numbers are the information the agent needs. A line that went blank is
    reported with empty text.
    """
    changes: list[tuple[int, str]] = []
    for index in range(max(len(old), len(new))):
        before = old[index] if index < len(old) else ""
        after = new[index] if index < len(new) else ""
        if before != after:
            changes.append((index + 1, after))
    return changes


def _cap(text: str) -> tuple[str, bool]:
    if len(text) <= CAPTURE_CHAR_CAP:
        return text, False
    return text[:CAPTURE_CHAR_CAP] + "\n…[truncated]", True


# -- session bookkeeping ---------------------------------------------------


@dataclass
class TerminalSession:
    """One live tmux session and the baseline its diffs are taken against."""

    name: str
    tmux_name: str
    rows: int
    cols: int
    opened_at: float
    last_used: float
    last_screen: list[str] = field(default_factory=list)


# -- the manager -----------------------------------------------------------


class TerminalManager:
    """Owns the interactive terminals of one task.

    Every tmux call goes through :meth:`Environment.run_bash`, so the same code
    drives the local stand-in and the real sandbox.
    """

    def __init__(
        self,
        env: Environment,
        *,
        task_id: str = "task",
        rows: int = DEFAULT_ROWS,
        cols: int = DEFAULT_COLS,
        idle_timeout_s: float = IDLE_TIMEOUT_S,
        max_sessions: int = MAX_SESSIONS,
        clock: Callable[[], float] = time.monotonic,
        sleep: Callable[[float], None] = time.sleep,
        shell: str = "bash",
    ) -> None:
        self.env = env
        self.task_id = _sanitize_task_id(task_id)
        self.rows = max(4, min(int(rows), MAX_ROWS))
        self.cols = max(20, min(int(cols), MAX_COLS))
        self.idle_timeout_s = float(idle_timeout_s)
        self.max_sessions = int(max_sessions)
        self.shell = shell
        self._clock = clock
        self._sleep = sleep
        self._sessions: dict[str, TerminalSession] = {}
        self._tmux_ok: bool | None = None

    # -- availability ------------------------------------------------------

    def tmux_available(self) -> bool:
        """Probe for tmux once and cache it. Used as the tool ``check_fn``, so
        it runs on every prompt render — it must not shell out every time."""
        if self._tmux_ok is None:
            result = self.env.run_bash(
                "command -v tmux >/dev/null 2>&1", timeout=15, internal=True
            )
            self._tmux_ok = bool(result.ok)
        return self._tmux_ok

    # -- tmux plumbing -----------------------------------------------------

    def _run(self, argv_list: list[list[str]], *, timeout: int = 30):
        """Run one or more tmux commands as a single shell command."""
        cmd = " && ".join(
            " ".join(shlex.quote(part) for part in argv) for argv in argv_list
        )
        return self.env.run_bash(cmd, timeout=timeout)

    def _tmux_name(self, name: str) -> str:
        return f"cw-{self.task_id}-{name}"

    def _require(self, name: str) -> TerminalSession:
        session = self._sessions.get(name)
        if session is None:
            raise TerminalError(
                f"no terminal named {name!r}. Open one with terminal_open first."
            )
        return session

    @staticmethod
    def _pane(tmux_name: str) -> str:
        """The pane target of a session's only pane.

        Both parts matter, verified against tmux 3.4: the leading ``=`` forces
        an exact session-name match (without it tmux prefix-matches and can
        pick a stranger's session), and the trailing ``:`` is what makes tmux
        read the string as a *pane* target — ``-t =name`` alone fails with
        "can't find pane".
        """
        return f"={tmux_name}:"

    def _exists(self, tmux_name: str) -> bool:
        result = self._run([["tmux", "has-session", "-t", f"={tmux_name}"]])
        return bool(result.ok)

    # -- lifecycle ---------------------------------------------------------

    def open(
        self,
        name: str = "main",
        cwd: str | None = None,
        command: str | None = None,
        reuse: bool = False,
    ) -> dict:
        name = _check_name(name)
        existing = self._sessions.get(name)
        if reuse and existing is not None and self._exists(existing.tmux_name):
            existing.last_used = self._clock()
            return self._read_session(existing, full=True, reused=True)

        tmux_name = self._tmux_name(name)
        # A leftover session with this name is killed, not adopted: "fresh per
        # task" is the whole point of the lifecycle rule.
        self._run([["tmux", "kill-session", "-t", f"={tmux_name}"]])
        self._sessions.pop(name, None)

        if len(self._sessions) >= self.max_sessions:
            raise TerminalError(
                f"too many open terminals ({self.max_sessions}). "
                "Close one with terminal_close."
            )

        argv = [
            "tmux",
            "new-session",
            "-d",
            "-s",
            tmux_name,
            "-x",
            str(self.cols),
            "-y",
            str(self.rows),
        ]
        if cwd:
            argv += ["-c", cwd]
        argv.append(self.shell)
        result = self._run([argv])
        if not result.ok:
            raise TerminalError(
                "could not start the terminal: "
                + ((result.stderr or result.stdout).strip() or "tmux failed")
            )

        now = self._clock()
        session = TerminalSession(
            name=name,
            tmux_name=tmux_name,
            rows=self.rows,
            cols=self.cols,
            opened_at=now,
            last_used=now,
        )
        self._sessions[name] = session

        if command:
            self._send(session, text=command, keys=["Enter"])
        self._sleep(DEFAULT_SETTLE_S)
        return self._read_session(session, full=True)

    def close(self, name: str) -> dict:
        name = _check_name(name)
        session = self._sessions.pop(name, None)
        target = session.tmux_name if session else self._tmux_name(name)
        self._run([["tmux", "kill-session", "-t", f"={target}"]])
        return {"ok": True, "name": name, "closed": True}

    def close_all(self) -> list[str]:
        """Task teardown. Kills every terminal this manager opened."""
        names = list(self._sessions)
        for name in names:
            self.close(name)
        return names

    def reap(self) -> list[str]:
        """Kill terminals nobody touched for ``idle_timeout_s``."""
        now = self._clock()
        dead = [
            name
            for name, session in self._sessions.items()
            if now - session.last_used > self.idle_timeout_s
        ]
        for name in dead:
            self.close(name)
        return dead

    def list_sessions(self) -> list[str]:
        return list(self._sessions)

    # -- keys --------------------------------------------------------------

    def send_keys(
        self,
        name: str = "main",
        text: str | None = None,
        keys: list[str] | str | None = None,
        enter: bool = False,
        read: bool = True,
        settle_s: float = DEFAULT_SETTLE_S,
    ) -> dict:
        name = _check_name(name)
        session = self._require(name)
        key_names = _normalize_keys(keys)
        if enter:
            key_names = key_names + ["Enter"]
        if not text and not key_names:
            raise TerminalError("nothing to send: give `text`, `keys`, or enter=true")

        self._send(session, text=text, keys=key_names)
        session.last_used = self._clock()
        if not read:
            return {"ok": True, "name": name, "sent": True}
        self._sleep(max(0.0, min(float(settle_s), MAX_SETTLE_S)))
        return self._read_session(session, full=False)

    def _send(
        self, session: TerminalSession, *, text: str | None, keys: list[str]
    ) -> None:
        """Push literal text and named keys into the pane, in that order."""
        argv_list: list[list[str]] = []
        if text:
            for index, line in enumerate(text.split("\n")):
                if index:
                    # A newline inside literal text is an Enter press, sent as
                    # a key — never as a literal character, which some programs
                    # would swallow or paste-bracket differently.
                    argv_list.append(
                        [
                            "tmux",
                            "send-keys",
                            "-t",
                            self._pane(session.tmux_name),
                            "Enter",
                        ]
                    )
                argv_list.extend(self._literal_argv(session, line))
        for key in keys:
            argv_list.append(
                ["tmux", "send-keys", "-t", self._pane(session.tmux_name), key]
            )
        if not argv_list:
            return
        result = self._run(argv_list)
        if not result.ok:
            raise TerminalError(
                "could not send keys: "
                + ((result.stderr or result.stdout).strip() or "tmux failed")
            )

    def _literal_argv(self, session: TerminalSession, line: str) -> list[list[str]]:
        """``send-keys -l`` for one line, working around the trailing-semicolon
        quirk: tmux eats a ``;`` at the end of an argument, so the trailing
        semicolons are sent by hex code (``0x3b``) instead."""
        if not line:
            return []
        target = self._pane(session.tmux_name)
        body = line.rstrip(";")
        trailing = len(line) - len(body)
        argv_list: list[list[str]] = []
        if body:
            argv_list.append(["tmux", "send-keys", "-t", target, "-l", "--", body])
        if trailing:
            argv_list.append(
                ["tmux", "send-keys", "-t", target, "-H"] + ["3b"] * trailing
            )
        return argv_list

    # -- reads -------------------------------------------------------------

    def read(self, name: str = "main", full: bool = False) -> dict:
        name = _check_name(name)
        session = self._require(name)
        session.last_used = self._clock()
        return self._read_session(session, full=bool(full))

    def _capture(self, session: TerminalSession) -> list[str]:
        """The visible viewport only. No ``-S``/``-E``: the scrollback is
        exactly what must never reach the prompt."""
        result = self._run(
            [["tmux", "capture-pane", "-p", "-t", self._pane(session.tmux_name)]]
        )
        if not result.ok:
            self._sessions.pop(session.name, None)
            raise TerminalError(
                f"terminal {session.name!r} is not running any more "
                "(the program may have exited). Open a new one."
            )
        return normalize_screen(result.stdout, session.rows, session.cols)

    def _read_session(
        self, session: TerminalSession, *, full: bool, reused: bool = False
    ) -> dict:
        lines = self._capture(session)
        previous = session.last_screen
        session.last_screen = lines
        session.last_used = self._clock()

        base: dict = {"ok": True, "name": session.name}
        if reused:
            base["reused"] = True

        if full or not previous:
            screen, truncated = _cap("\n".join(lines))
            base.update(
                {"mode": "full", "changed": True, "rows": len(lines), "screen": screen}
            )
            if truncated:
                base["truncated"] = True
            return base

        changes = diff_screens(previous, lines)
        if not changes:
            base.update({"mode": "diff", "changed": False, "screen": "no change"})
            return base

        denominator = max(len(lines), len(previous), 1)
        if len(changes) / denominator > DIFF_FULL_THRESHOLD:
            screen, truncated = _cap("\n".join(lines))
            base.update(
                {
                    "mode": "full",
                    "changed": True,
                    "rows": len(lines),
                    "screen": screen,
                    "reason": "most of the screen changed",
                }
            )
            if truncated:
                base["truncated"] = True
            return base

        body, truncated = _cap(
            "\n".join(f"{number}| {content}" for number, content in changes)
        )
        base.update(
            {
                "mode": "diff",
                "changed": True,
                "changed_lines": len(changes),
                "screen": body,
            }
        )
        if truncated:
            base["truncated"] = True
        return base

    # -- waiting -----------------------------------------------------------

    def wait(
        self,
        name: str = "main",
        pattern: str | None = None,
        idle_ms: int = 500,
        timeout_s: float = 15.0,
        poll_ms: int = 250,
    ) -> dict:
        """Wait for a pattern on screen, or for the screen to stop changing.

        Guards against reading a half-drawn TUI. The returned screen is a diff
        against the state before the wait, so a slow redraw costs one read.
        """
        name = _check_name(name)
        session = self._require(name)
        regex = None
        if pattern:
            try:
                # MULTILINE: the capture is a screen, so `^`/`$` must anchor a
                # row. Anchored against the whole blob they would never match.
                regex = re.compile(pattern, re.MULTILINE)
            except re.error as exc:
                raise TerminalError(f"invalid pattern: {exc}") from exc

        timeout = max(0.0, min(float(timeout_s), MAX_WAIT_S))
        poll_s = max(0.02, float(poll_ms) / 1000.0)
        idle_s = max(0.0, float(idle_ms) / 1000.0)
        deadline = self._clock() + timeout

        previous: list[str] | None = None
        stable_since: float | None = None
        outcome = "timeout"
        while True:
            lines = self._capture(session)
            now = self._clock()
            if regex is not None and regex.search("\n".join(lines)):
                outcome = "matched"
                break
            if regex is None:
                if previous is not None and lines == previous:
                    if stable_since is None:
                        stable_since = now
                    if (now - stable_since) >= idle_s:
                        outcome = "idle"
                        break
                else:
                    stable_since = None
            previous = lines
            if now >= deadline:
                break
            self._sleep(poll_s)

        session.last_used = self._clock()
        result = self._read_session(session, full=False)
        result["outcome"] = outcome
        return result


def _sanitize_task_id(task_id: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9_-]", "-", str(task_id or "task")).strip("-")
    return (cleaned or "task")[:40]


def _check_name(name: str) -> str:
    name = (name or "main").strip()
    if not _NAME_RE.match(name):
        raise TerminalError(
            f"invalid terminal name {name!r}: letters, digits, '-' and '_', "
            "max 32 characters."
        )
    return name


def _normalize_keys(keys: list[str] | str | None) -> list[str]:
    if keys is None:
        return []
    if isinstance(keys, str):
        keys = [part for part in re.split(r"[,\s]+", keys) if part]
    if not isinstance(keys, list):
        raise TerminalError("`keys` must be a list of key names")
    return [tmux_key(str(key)) for key in keys]


# -- tools -----------------------------------------------------------------

TERMINAL_OPEN_SCHEMA = {
    "type": "object",
    "description": (
        "Open a persistent interactive terminal for a program that needs a "
        "keyboard: an installer, a password prompt, a menu or TUI, "
        "`git rebase -i`, vim, a REPL, ssh. For a normal command use "
        "run_command instead. Returns the first screen. Close it with "
        "terminal_close when the task is done."
    ),
    "properties": {
        "name": {
            "type": "string",
            "description": "Terminal name, so you can keep two apart.",
            "default": "main",
        },
        "cwd": {"type": "string", "description": "Start directory."},
        "command": {
            "type": "string",
            "description": "Command to start in the terminal, for example 'python3 -i'.",
        },
        "reuse": {
            "type": "boolean",
            "description": (
                "Continue an earlier terminal with this name instead of "
                "starting a clean one."
            ),
            "default": False,
        },
    },
    "required": [],
}

TERMINAL_SEND_KEYS_SCHEMA = {
    "type": "object",
    "description": (
        "Type into an interactive terminal and return what changed on screen. "
        "`text` is typed literally, `keys` are key presses. Never put a key "
        "name in `text`: the word Enter in `text` is typed as five letters, "
        "which is what you want when a prompt asks for text."
    ),
    "properties": {
        "name": {"type": "string", "description": "Terminal name.", "default": "main"},
        "text": {"type": "string", "description": "Literal text to type."},
        "keys": {
            "type": "array",
            "description": (
                "Key presses, in order: Enter, Tab, Escape, Up, Down, Left, "
                "Right, Home, End, PageUp, PageDown, BSpace, Delete, F1-F12, "
                "C-c, C-d, M-x."
            ),
            "items": {"type": "string"},
        },
        "enter": {
            "type": "boolean",
            "description": "Press Enter after the text.",
            "default": False,
        },
        "read": {
            "type": "boolean",
            "description": "Return the changed screen lines.",
            "default": True,
        },
    },
    "required": [],
}

TERMINAL_READ_SCHEMA = {
    "type": "object",
    "description": (
        "Read the terminal screen. By default only the lines that changed "
        "since the last read are returned, as 'line| text', or 'no change'. "
        "Set full=true for the whole screen."
    ),
    "properties": {
        "name": {"type": "string", "description": "Terminal name.", "default": "main"},
        "full": {
            "type": "boolean",
            "description": "Return the whole visible screen.",
            "default": False,
        },
    },
    "required": [],
}

TERMINAL_WAIT_SCHEMA = {
    "type": "object",
    "description": (
        "Wait until text appears on screen, or until the screen stops "
        "changing, then return what changed. Use it when a program is slow to "
        "draw or slow to finish."
    ),
    "properties": {
        "name": {"type": "string", "description": "Terminal name.", "default": "main"},
        "pattern": {
            "type": "string",
            "description": (
                "Regular expression to wait for on screen. '^' and '$' anchor "
                "a screen row."
            ),
        },
        "timeout_s": {
            "type": "number",
            "description": "Give up after this many seconds.",
            "default": 15,
        },
        "idle_ms": {
            "type": "integer",
            "description": "With no pattern: how long the screen must stay unchanged.",
            "default": 500,
        },
    },
    "required": [],
}

TERMINAL_CLOSE_SCHEMA = {
    "type": "object",
    "description": (
        "Close a terminal and kill what runs in it. Do this when the "
        "interactive part of the task is done."
    ),
    "properties": {
        "name": {"type": "string", "description": "Terminal name.", "default": "main"},
    },
    "required": [],
}


def _guard(manager: TerminalManager, call: Callable[[], dict]) -> dict:
    """Every handler: reap the abandoned, then run, then report a rejection as
    a message instead of an exception."""
    try:
        manager.reap()
        return call()
    except TerminalError as exc:
        return {"ok": False, "error": str(exc)}


def make_terminal_handlers(manager: TerminalManager) -> dict[str, Callable[..., dict]]:
    def terminal_open(
        name: str = "main",
        cwd: str | None = None,
        command: str | None = None,
        reuse: bool = False,
    ) -> dict:
        return _guard(
            manager, lambda: manager.open(name, cwd=cwd, command=command, reuse=reuse)
        )

    def terminal_send_keys(
        name: str = "main",
        text: str | None = None,
        keys: list[str] | str | None = None,
        enter: bool = False,
        read: bool = True,
    ) -> dict:
        return _guard(
            manager,
            lambda: manager.send_keys(
                name, text=text, keys=keys, enter=enter, read=read
            ),
        )

    def terminal_read(name: str = "main", full: bool = False) -> dict:
        return _guard(manager, lambda: manager.read(name, full=full))

    def terminal_wait(
        name: str = "main",
        pattern: str | None = None,
        timeout_s: float = 15.0,
        idle_ms: int = 500,
    ) -> dict:
        return _guard(
            manager,
            lambda: manager.wait(
                name, pattern=pattern, timeout_s=timeout_s, idle_ms=idle_ms
            ),
        )

    def terminal_close(name: str = "main") -> dict:
        return _guard(manager, lambda: manager.close(name))

    return {
        "terminal_open": terminal_open,
        "terminal_send_keys": terminal_send_keys,
        "terminal_read": terminal_read,
        "terminal_wait": terminal_wait,
        "terminal_close": terminal_close,
    }


_SCHEMAS = {
    "terminal_open": TERMINAL_OPEN_SCHEMA,
    "terminal_send_keys": TERMINAL_SEND_KEYS_SCHEMA,
    "terminal_read": TERMINAL_READ_SCHEMA,
    "terminal_wait": TERMINAL_WAIT_SCHEMA,
    "terminal_close": TERMINAL_CLOSE_SCHEMA,
}


def register_terminal_tools(
    registry: ToolRegistry, manager: TerminalManager
) -> TerminalManager:
    """Register the interactive terminal tool set.

    All five share one ``check_fn``: without tmux in the environment they are
    registered but never rendered into the prompt and never dispatched, so the
    model is not told about a keyboard it does not have.
    """
    handlers = make_terminal_handlers(manager)
    for name, handler in handlers.items():
        registry.register(
            name,
            _SCHEMAS[name],
            handler,
            check_fn=manager.tmux_available,
        )
    return manager
