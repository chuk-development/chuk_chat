"""Interactive shell and background jobs (docs/WIRE_CONTRACT.md, section
"Interactive shell and background commands").

Two things ``run_command`` cannot do, both inside the sandbox:

- **An interactive shell.** ``shell_start`` / ``shell_read`` / ``shell_send`` /
  ``shell_list`` / ``shell_kill`` are a thin layer over the tmux driver in
  :mod:`chuk_agents_runtime.terminal`: session names, key tokens, output caps. The
  model may also call ``tmux`` itself through ``run_command``; these tools
  only make the common path short.
- **Background jobs.** ``run_command(background=true)`` starts a command
  detached (``setsid``) and returns at once. :class:`JobManager` writes the
  job's files under ``<workspace>/.agents/jobs/`` and a wrapper appends ONE
  line to the automations' trigger file when the job ends. The host tails
  that file and wakes the agent (``chuk_agents_executor.shell``). The model never
  polls; ``job_status`` / ``job_output`` / ``job_cancel`` exist for the
  moments it wants to look anyway.

Every read returns the LAST part of the output by default (200 lines, 30 000
characters). The model asks for more when it needs more.

All of it goes through :meth:`Environment.run_bash`, so the same code drives
the local stand-in and the Docker sandbox.
"""

from __future__ import annotations

import base64
import json
import re
import secrets as _secrets
import shlex
from collections.abc import Callable, Mapping
from typing import Any

from .environment import Environment
from .registry import ToolRegistry
from .terminal import (
    DEFAULT_SETTLE_S,
    TerminalError,
    TerminalManager,
    tmux_key,
)

#: The default number of lines a read returns, and the ceiling.
DEFAULT_LINES = 200
MAX_LINES = 2000

#: Characters one result may carry back to the model (same as ``python``).
SHELL_OUTPUT_CAP = 30_000

#: Where a job's files live, relative to the sandbox-side workspace root.
JOBS_DIRNAME = ".agents/jobs"
#: The automations' self-wake file, relative to the workspace root. ONE tail
#: on the host, two consumers (``kind``).
TRIGGERS_RELPATH = ".agents/automations/triggers.jsonl"

#: The fallback cap on a background job (docs/WIRE_CONTRACT.md: 24 h).
JOB_TIMEOUT_S = 86_400

#: Environment variable the Docker image sets to the workspace mount. The
#: local sandbox has none; then the host path the runtime knows is used.
ENV_WORKSPACE = "AGENTS_WORKSPACE"

JOB_RUNNING = "running"
JOB_FINISHED = "finished"
JOB_FAILED = "failed"
JOB_CANCELLED = "cancelled"
JOB_TIMED_OUT = "timed_out"

_JOB_ID_RE = re.compile(r"^j[0-9a-f]{8}$")

#: Key tokens ``shell_send`` presses instead of typing. Case-sensitive on
#: purpose: ``Home`` is a key, ``home`` is a word. Modifier forms (``C-c``,
#: ``M-x``, ``^c``) and ``F1``..``F12`` are recognised by shape.
KEY_TOKENS = frozenset(
    {
        "Enter",
        "Tab",
        "BTab",
        "Escape",
        "Esc",
        "Space",
        "Up",
        "Down",
        "Left",
        "Right",
        "Home",
        "End",
        "PageUp",
        "PageDown",
        "BSpace",
        "Backspace",
        "Delete",
        "Insert",
    }
)
_TOKEN_SHAPE_RE = re.compile(r"^(?:F([1-9]|1[0-2])|(?:[CM]-)+[!-~]|\^[!-~])$")


def is_key_token(item: str) -> bool:
    """True when ``item`` is pressed as a key by ``shell_send`` (not typed)."""
    return item in KEY_TOKENS or bool(_TOKEN_SHAPE_RE.match(item))


def parse_send_items(keys: Any, *, literal: bool = False) -> list[tuple[str, str]]:
    """Turn the ``keys`` argument into ``("text" | "key", value)`` items.

    A string is one item. Every item that :func:`is_key_token` accepts is a
    key press; everything else is typed as text. ``literal=True`` types all.
    """
    if keys is None:
        return []
    if isinstance(keys, str):
        keys = [keys]
    if not isinstance(keys, list):
        raise TerminalError("`keys` must be a list of strings")
    items: list[tuple[str, str]] = []
    for raw in keys:
        text = str(raw)
        if not literal and is_key_token(text):
            items.append(("key", tmux_key(text)))
        elif text:
            items.append(("text", text))
    return items


def _cap_text(text: str, limit: int = SHELL_OUTPUT_CAP) -> tuple[str, bool]:
    if len(text) <= limit:
        return text, False
    return text[-limit:], True


def _clamp_lines(lines: Any) -> int:
    try:
        value = int(lines)
    except (TypeError, ValueError):
        value = DEFAULT_LINES
    return max(1, min(value, MAX_LINES))


# -- the interactive shell ----------------------------------------------------


class ShellTools:
    """The ``shell_*`` handlers over one :class:`TerminalManager`."""

    def __init__(self, manager: TerminalManager) -> None:
        self.manager = manager

    def _read(self, name: str, lines: int, **extra: Any) -> dict:
        tail = self.manager.capture_tail(name, lines)
        status = self.manager.pane_status(name)
        screen, truncated = _cap_text("\n".join(tail))
        out: dict[str, Any] = {
            "ok": True,
            "name": name,
            "running": status["running"],
            "foreground": status["foreground"],
            "cursor_line": status["cursor_line"],
            "lines": len(tail),
            "screen": screen,
        }
        if truncated:
            out["truncated"] = True
        if status.get("dead"):
            out["dead"] = True
        out.update(extra)
        return out

    def start(self, name: str = "main", command: str | None = None, cwd: str | None = None) -> dict:
        manager = self.manager
        if manager.adopt(name) is not None:
            # A live session of that name (this task or an earlier one of the
            # same sandbox): attach, never kill what the model may still need.
            if command:
                manager.send_sequence(name, [("text", command), ("key", "Enter")])
            return self._read(name, DEFAULT_LINES, attached=True)
        manager.open(name, cwd=cwd, command=command)
        return self._read(name, DEFAULT_LINES)

    def read(self, name: str = "main", lines: int = DEFAULT_LINES) -> dict:
        self._ensure(name)
        return self._read(name, _clamp_lines(lines))

    def send(self, name: str = "main", keys: Any = None, literal: bool = False) -> dict:
        self._ensure(name)
        items = parse_send_items(keys, literal=bool(literal))
        if not items:
            raise TerminalError("nothing to send: give `keys`, for example [\"y\", \"Enter\"]")
        self.manager.send_sequence(name, items, settle_s=DEFAULT_SETTLE_S)
        return self._read(name, DEFAULT_LINES)

    def list(self) -> dict:
        names = sorted(set(self.manager.list_sessions()) | set(self.manager.live_names()))
        sessions: list[dict] = []
        for name in names:
            if self.manager.adopt(name) is None:
                continue
            try:
                status = self.manager.pane_status(name)
            except TerminalError:
                continue
            sessions.append(
                {
                    "name": name,
                    "running": status["running"],
                    "foreground": status["foreground"],
                    "cursor_line": status["cursor_line"],
                }
            )
        return {"ok": True, "sessions": sessions}

    def kill(self, name: str = "main") -> dict:
        return self.manager.close(name)

    def _ensure(self, name: str) -> None:
        if self.manager.adopt(name) is None:
            raise TerminalError(
                f"no shell named {name!r}. Start one with shell_start first."
            )


# -- background jobs ----------------------------------------------------------


def _b64(text: str) -> str:
    return base64.b64encode(text.encode("utf-8")).decode("ascii")


class JobManager:
    """Start, inspect and cancel detached commands inside the sandbox.

    ``session_key`` is the conversation the wake-up belongs to; the wrapper
    writes it into the trigger line so the host can route the job's end
    without a lookup. ``None`` (a runtime without a host) still runs jobs;
    the trigger line then carries no session and nobody is woken.

    ``workspace`` is the host-side workspace path. In the Docker sandbox the
    image's ``AGENTS_WORKSPACE`` wins; locally the two are the same directory.
    """

    def __init__(
        self,
        env: Environment,
        *,
        session_key: str | None = None,
        workspace: str | None = None,
        secrets_env: Callable[[], Mapping[str, str]] | None = None,
        timeout_s: int = JOB_TIMEOUT_S,
        new_id: Callable[[], str] | None = None,
    ) -> None:
        self.env = env
        self.session_key = session_key
        self.workspace = workspace
        self._secrets_env = secrets_env
        self.timeout_s = int(timeout_s)
        self._new_id = new_id or (lambda: "j" + _secrets.token_hex(4))

    # -- shell fragments -----------------------------------------------------

    def _root_expr(self) -> str:
        """A shell expression for the sandbox-side workspace root."""
        hint = shlex.quote(self.workspace) if self.workspace else '"$PWD"'
        return f'"${{{ENV_WORKSPACE}:-{hint}}}"'

    def _prelude(self) -> str:
        return (
            f"__cw_ws={self._root_expr()}; "
            f'__cw_d="$__cw_ws/{JOBS_DIRNAME}"; '
            f'__cw_t="$__cw_ws/{TRIGGERS_RELPATH}"; '
            'mkdir -p "$__cw_d" "$(dirname "$__cw_t")" || exit 97; '
        )

    def _env_kw(self) -> dict:
        if self._secrets_env is None:
            return {}
        try:
            values = dict(self._secrets_env())
        except Exception:  # noqa: BLE001 — a vault hiccup runs the job without keys
            return {}
        return {"env": values} if values else {}

    def _wrapper(self, job_id: str, cwd: str | None) -> str:
        """The detached wrapper. It writes the pid, runs the command under the
        24 h cap with its output in the log, records the exit code, then
        appends the trigger line. Plain POSIX tools only."""
        session_json = json.dumps(self.session_key) if self.session_key else "null"
        cd_line = f"cd {shlex.quote(cwd)} 2>/dev/null\n" if cwd else ""
        return (
            "#!/bin/bash\n"
            f"D=$1; ID={job_id}; T=$2\n"
            'echo $$ > "$D/$ID.pid"\n'
            f"{cd_line}"
            f'timeout --signal=TERM -k 10 {self.timeout_s} bash "$D/$ID.cmd" > "$D/$ID.log" 2>&1\n'
            "rc=$?\n"
            'if [ -e "$D/$ID.cancelled" ]; then exit 0; fi\n'
            'echo $rc > "$D/$ID.exit"\n'
            "to=false; [ $rc -eq 124 ] && to=true\n"
            "printf '{\"kind\":\"job\",\"job_id\":\"%s\",\"session_key\":%s,"
            "\"exit_code\":%d,\"timed_out\":%s,\"ts\":%s}\\n' "
            f'"$ID" {shlex.quote(session_json)} "$rc" "$to" "$(date +%s)" >> "$T"\n'
        )

    # -- API -------------------------------------------------------------------

    def start(self, command: str, cwd: str | None = None) -> dict:
        if not isinstance(command, str) or not command.strip():
            return {"ok": False, "error": "command must not be empty"}
        job_id = self._new_id()
        meta = {
            "job_id": job_id,
            "command": command,
            "cwd": cwd,
            "session_key": self.session_key,
        }
        # Statements, not one ``&&`` chain: ``a && b && setsid ... &`` would
        # background the WHOLE list in a subshell that then waits for the
        # wrapper and holds the caller's stdout pipe until the job ends.
        cmd = (
            self._prelude()
            + f'printf %s {shlex.quote(_b64(command))} | base64 -d > "$__cw_d/{job_id}.cmd" || exit 98; '
            + f'printf %s {shlex.quote(_b64(self._wrapper(job_id, cwd)))} | base64 -d > "$__cw_d/{job_id}.sh" || exit 98; '
            # ``started_at`` comes from the sandbox clock: the meta JSON is
            # decoded, its closing brace replaced by the stamp.
            + f'__cw_m="$(printf %s {shlex.quote(_b64(json.dumps(meta)))} | base64 -d)"; '
            + '__cw_now=$(date +%s); '
            + 'printf \'%s,"started_at":%s}\' "${__cw_m%\\}}" "$__cw_now" > "$__cw_d/'
            + job_id
            + '.json" || exit 98; '
            # Detached: its own session, no tty, no inherited pipes, so the
            # ``docker exec`` / ``bash -c`` that started it returns at once.
            + f'setsid bash "$__cw_d/{job_id}.sh" "$__cw_d" "$__cw_t" </dev/null >/dev/null 2>&1 & '
            + 'echo "$!"; echo "$__cw_d"'
        )
        result = self.env.run_bash(cmd, timeout=60, **self._env_kw())
        if not result.ok:
            return {
                "ok": False,
                "error": (result.stderr or result.stdout or "could not start the job").strip()[:2000],
            }
        lines = [line for line in result.stdout.splitlines() if line.strip()]
        pid = lines[0].strip() if lines else ""
        jobs_dir = lines[1].strip() if len(lines) > 1 else JOBS_DIRNAME
        return {
            "ok": True,
            "job_id": job_id,
            "pid": int(pid) if pid.isdigit() else None,
            "log_path": f"{JOBS_DIRNAME}/{job_id}.log",
            "jobs_dir": jobs_dir,
            "state": JOB_RUNNING,
            "note": (
                "Running in the background. You are woken when it ends; "
                "job_status / job_output show it meanwhile."
            ),
        }

    def status(self, job_id: str | None = None) -> dict:
        if job_id is not None and not _JOB_ID_RE.match(str(job_id)):
            return {"ok": False, "error": f"unknown job id {job_id!r}"}
        select = f'"$__cw_d"/{job_id}.json' if job_id else '"$__cw_d"/*.json'
        script = (
            self._prelude()
            + f"for __f in {select}; do "
            + '[ -e "$__f" ] || continue; '
            + '__id=$(basename "$__f" .json); '
            + '__exit=-; [ -e "$__cw_d/$__id.exit" ] && __exit=$(cat "$__cw_d/$__id.exit"); '
            + '__can=0; [ -e "$__cw_d/$__id.cancelled" ] && __can=1; '
            + '__alive=0; if [ ! -e "$__cw_d/$__id.pid" ] || kill -0 "$(cat "$__cw_d/$__id.pid")" 2>/dev/null; then __alive=1; fi; '
            + '__lines=0; [ -e "$__cw_d/$__id.log" ] && __lines=$(wc -l < "$__cw_d/$__id.log"); '
            + '__fin=-; [ -e "$__cw_d/$__id.exit" ] && __fin=$(stat -c %Y "$__cw_d/$__id.exit" 2>/dev/null || echo -); '
            + "printf '%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n' "
            + '"$__id" "$__exit" "$__can" "$__alive" "$__lines" "$__fin" "$(base64 -w0 "$__f")"; '
            + "done"
        )
        result = self.env.run_bash(script, timeout=60)
        if not result.ok:
            return {"ok": False, "error": (result.stderr or "could not read the jobs").strip()[:2000]}
        jobs = [self._parse_status_line(line) for line in result.stdout.splitlines() if "\t" in line]
        jobs = [j for j in jobs if j is not None]
        if job_id is not None:
            if not jobs:
                return {"ok": False, "error": f"no job {job_id}"}
            return {"ok": True, **jobs[0]}
        return {"ok": True, "jobs": jobs}

    @staticmethod
    def _parse_status_line(line: str) -> dict | None:
        parts = line.split("\t")
        if len(parts) < 7:
            return None
        job_id, exit_text, cancelled, alive, log_lines, finished_at, meta_b64 = parts[:7]
        try:
            meta = json.loads(base64.b64decode(meta_b64).decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            meta = {}
        exit_code = int(exit_text) if exit_text.strip().lstrip("-").isdigit() and exit_text.strip() != "-" else None
        state = job_state(exit_code=exit_code, cancelled=cancelled.strip() == "1", alive=alive.strip() == "1")
        out = {
            "job_id": job_id,
            "command": meta.get("command"),
            "cwd": meta.get("cwd"),
            "state": state,
            "exit_code": exit_code,
            "started_at": meta.get("started_at"),
            "finished_at": int(finished_at) if finished_at.strip().isdigit() else None,
            "log_path": f"{JOBS_DIRNAME}/{job_id}.log",
            "log_lines": int(log_lines) if log_lines.strip().isdigit() else 0,
        }
        return out

    def output(self, job_id: str, lines: int = DEFAULT_LINES, offset: int = 0) -> dict:
        if not _JOB_ID_RE.match(str(job_id or "")):
            return {"ok": False, "error": f"unknown job id {job_id!r}"}
        count = _clamp_lines(lines)
        try:
            start = max(0, int(offset))
        except (TypeError, ValueError):
            start = 0
        if start > 0:
            select = f"sed -n '{start},{start + count - 1}p'"
        else:
            select = f"tail -n {count}"
        script = (
            self._prelude()
            + f'__log="$__cw_d/{job_id}.log"; [ -e "$__log" ] || {{ echo "no log for {job_id}" >&2; exit 2; }}; '
            + 'wc -l < "$__log"; '
            + f'{select} "$__log" | tail -c {SHELL_OUTPUT_CAP + 1}'
        )
        result = self.env.run_bash(script, timeout=60)
        if not result.ok:
            return {"ok": False, "error": (result.stderr or "could not read the log").strip()[:2000]}
        head, _, body = result.stdout.partition("\n")
        total = int(head.strip()) if head.strip().isdigit() else 0
        text, truncated = _cap_text(body.rstrip("\n"))
        out: dict[str, Any] = {
            "ok": True,
            "job_id": job_id,
            "total_lines": total,
            "offset": start,
            "output": text,
            "log_path": f"{JOBS_DIRNAME}/{job_id}.log",
        }
        if truncated:
            out["truncated"] = True
            out["note"] = f"cut to the last {SHELL_OUTPUT_CAP} characters; read the log file for all of it"
        return out

    def cancel(self, job_id: str) -> dict:
        if not _JOB_ID_RE.match(str(job_id or "")):
            return {"ok": False, "error": f"unknown job id {job_id!r}"}
        script = (
            self._prelude()
            + f'__pid_f="$__cw_d/{job_id}.pid"; [ -e "$__pid_f" ] || {{ echo "no job {job_id}" >&2; exit 2; }}; '
            + f'[ -e "$__cw_d/{job_id}.exit" ] && {{ echo already-finished; exit 0; }}; '
            + '__pid=$(cat "$__pid_f"); '
            + f'touch "$__cw_d/{job_id}.cancelled"; '
            + 'kill -TERM -- "-$__pid" 2>/dev/null || kill -TERM "$__pid" 2>/dev/null; '
            + "for __i in 1 2 3 4 5 6 7 8 9 10; do kill -0 \"$__pid\" 2>/dev/null || break; sleep 0.5; done; "
            + 'kill -KILL -- "-$__pid" 2>/dev/null; kill -KILL "$__pid" 2>/dev/null; '
            + f'echo 143 > "$__cw_d/{job_id}.exit"; echo cancelled'
        )
        result = self.env.run_bash(script, timeout=60)
        if not result.ok:
            return {"ok": False, "error": (result.stderr or "could not cancel").strip()[:2000]}
        if "already-finished" in result.stdout:
            return {"ok": True, "job_id": job_id, "state": "already finished"}
        return {"ok": True, "job_id": job_id, "state": JOB_CANCELLED}


def job_state(*, exit_code: int | None, cancelled: bool, alive: bool) -> str:
    """The state word for a job from what the files say."""
    if cancelled:
        return JOB_CANCELLED
    if exit_code is None:
        # No exit code yet: running while the wrapper lives; a wrapper that is
        # gone without one died (a host reboot, a kill -9 of the tree).
        return JOB_RUNNING if alive else JOB_FAILED
    if exit_code == 124:
        return JOB_TIMED_OUT
    return JOB_FINISHED if exit_code == 0 else JOB_FAILED


# -- tool schemas ----------------------------------------------------------------

_NAME_PROP = {
    "type": "string",
    "description": "Shell name, so you can keep two apart.",
    "default": "main",
}

SHELL_START_SCHEMA = {
    "type": "object",
    "description": (
        "Start an interactive shell (a tmux session in your sandbox) for a "
        "program that asks questions, shows a menu or a TUI, or must keep "
        "running while you do other things. Attaches if a shell of that name "
        "is already running. Returns the screen. For a normal command use "
        "run_command."
    ),
    "properties": {
        "name": _NAME_PROP,
        "command": {
            "type": "string",
            "description": "Command to type into the new shell and run, for example 'sudo apt-get install foo'.",
        },
        "cwd": {"type": "string", "description": "Start directory."},
    },
    "required": [],
}

SHELL_READ_SCHEMA = {
    "type": "object",
    "description": (
        "Read a shell: the last lines of its output including scrollback, "
        "whether a program is running in the foreground, and the line the "
        "cursor is on (the prompt or the question being asked). Ask for more "
        "lines when you need more."
    ),
    "properties": {
        "name": _NAME_PROP,
        "lines": {
            "type": "integer",
            "description": f"How many lines from the end (max {MAX_LINES}).",
            "default": DEFAULT_LINES,
        },
    },
    "required": [],
}

SHELL_SEND_SCHEMA = {
    "type": "object",
    "description": (
        "Type into a shell and return the screen after it reacted. `keys` is a "
        "list: a key token is pressed, anything else is typed as text. Tokens: "
        "Enter, Tab, Escape, Space, Up, Down, Left, Right, Home, End, PageUp, "
        "PageDown, BSpace, Delete, F1-F12, C-c (Ctrl-C), C-d, M-x (Alt). "
        "Examples: [\"y\", \"Enter\"] answers a prompt; [\"C-c\"] interrupts; "
        "[\"make -j4\", \"Enter\"] runs a command."
    ),
    "properties": {
        "name": _NAME_PROP,
        "keys": {
            "type": "array",
            "items": {"type": "string"},
            "description": "Text items and key tokens, in order.",
        },
        "literal": {
            "type": "boolean",
            "description": "Type every item as text, even one that looks like a key token.",
            "default": False,
        },
    },
    "required": ["keys"],
}

SHELL_LIST_SCHEMA = {
    "type": "object",
    "description": "List your interactive shells with what runs in each.",
    "properties": {},
    "required": [],
}

SHELL_KILL_SCHEMA = {
    "type": "object",
    "description": "Kill a shell and the program running in it. Do this when the interactive part is done.",
    "properties": {"name": _NAME_PROP},
    "required": [],
}

JOB_STATUS_SCHEMA = {
    "type": "object",
    "description": (
        "State of a background job (running, finished, failed, cancelled, "
        "timed_out) with exit code, clocks and log size. Without job_id: every "
        "job of this workspace. You are woken when a job ends, so you rarely "
        "need to poll."
    ),
    "properties": {"job_id": {"type": "string", "description": "The job id from run_command(background=true)."}},
    "required": [],
}

JOB_OUTPUT_SCHEMA = {
    "type": "object",
    "description": (
        "Output of a background job: by default the last `lines` lines of its "
        "log. With `offset` (1-based line number) you read a window from there. "
        "total_lines says how much exists; the whole log is a file you can read_file."
    ),
    "properties": {
        "job_id": {"type": "string", "description": "The job id."},
        "lines": {"type": "integer", "description": f"How many lines (max {MAX_LINES}).", "default": DEFAULT_LINES},
        "offset": {"type": "integer", "description": "Start line (1-based). 0 = the last lines.", "default": 0},
    },
    "required": ["job_id"],
}

JOB_CANCEL_SCHEMA = {
    "type": "object",
    "description": "Stop a background job (SIGTERM to its process group, SIGKILL after 5 s).",
    "properties": {"job_id": {"type": "string", "description": "The job id."}},
    "required": ["job_id"],
}


def _guard(manager: TerminalManager, call: Callable[[], dict]) -> dict:
    """Every shell handler: reap abandoned terminals, run, report a rejection
    as a message instead of an exception."""
    try:
        manager.reap()
        return call()
    except TerminalError as exc:
        return {"ok": False, "error": str(exc)}


def make_shell_handlers(tools: ShellTools) -> dict[str, Callable[..., dict]]:
    manager = tools.manager

    def shell_start(name: str = "main", command: str | None = None, cwd: str | None = None) -> dict:
        return _guard(manager, lambda: tools.start(name, command=command, cwd=cwd))

    def shell_read(name: str = "main", lines: int = DEFAULT_LINES) -> dict:
        return _guard(manager, lambda: tools.read(name, lines=lines))

    def shell_send(name: str = "main", keys: Any = None, literal: bool = False) -> dict:
        return _guard(manager, lambda: tools.send(name, keys=keys, literal=literal))

    def shell_list() -> dict:
        return _guard(manager, tools.list)

    def shell_kill(name: str = "main") -> dict:
        return _guard(manager, lambda: tools.kill(name))

    return {
        "shell_start": shell_start,
        "shell_read": shell_read,
        "shell_send": shell_send,
        "shell_list": shell_list,
        "shell_kill": shell_kill,
    }


_SHELL_SCHEMAS = {
    "shell_start": SHELL_START_SCHEMA,
    "shell_read": SHELL_READ_SCHEMA,
    "shell_send": SHELL_SEND_SCHEMA,
    "shell_list": SHELL_LIST_SCHEMA,
    "shell_kill": SHELL_KILL_SCHEMA,
}

SHELL_TOOL_NAMES = tuple(_SHELL_SCHEMAS)
JOB_TOOL_NAMES = ("job_status", "job_output", "job_cancel")


def register_shell_tools(registry: ToolRegistry, manager: TerminalManager) -> ShellTools:
    """Register ``shell_start`` / ``shell_read`` / ``shell_send`` /
    ``shell_list`` / ``shell_kill``. All five share the manager's tmux probe
    as ``check_fn``: without tmux in the sandbox they are registered but never
    offered or dispatched."""
    tools = ShellTools(manager)
    for name, handler in make_shell_handlers(tools).items():
        registry.register(name, _SHELL_SCHEMAS[name], handler, check_fn=manager.tmux_available)
    return tools


def register_job_tools(registry: ToolRegistry, jobs: JobManager | None) -> None:
    """Register ``job_status`` / ``job_output`` / ``job_cancel``. ``None``
    registers nothing (a runtime with no job manager offers no background)."""
    if jobs is None:
        return

    def job_status(job_id: str | None = None) -> dict:
        return jobs.status(job_id or None)

    def job_output(job_id: str, lines: int = DEFAULT_LINES, offset: int = 0) -> dict:
        return jobs.output(job_id, lines=lines, offset=offset)

    def job_cancel(job_id: str) -> dict:
        return jobs.cancel(job_id)

    registry.register("job_status", JOB_STATUS_SCHEMA, job_status)
    registry.register("job_output", JOB_OUTPUT_SCHEMA, job_output)
    registry.register("job_cancel", JOB_CANCEL_SCHEMA, job_cancel)
