"""Built-in tools (§7.2 / §7.3).

Every tool runs through the injected
:class:`~chuk_agents_runtime.environment.Environment`, so the same tool set works
against the local stand-in and against the real sandbox. There is no second
filesystem path — a Docker sandbox stays a Docker sandbox.

- ``run_command`` — one shell command.
- ``write_file`` / ``read_file`` / ``list_dir`` — file work without shell
  quoting. The file content travels as base64 inside the command, so newlines,
  quotes, backticks and ``$`` in the content can never break the shell or be
  expanded by it. Models get shell heredocs wrong often enough that the file
  tools are what make "write me a script" actually land on disk.
- ``web_search`` (:mod:`chuk_agents_runtime.web_search`) — search through our own
  backend, so no provider key ever sits in the sandbox. Needs the account
  session; without one it is not registered and not documented to the model.
- ``web_fetch`` (:mod:`chuk_agents_runtime.web_fetch`) — read one page as Markdown,
  locally, with the SSRF/size/type hardening that module documents.
- ``read_document`` (:mod:`chuk_agents_runtime.documents`) — any document to Markdown,
  offline through anydoc, with a vision route for scans and images.
- ``send_file_to_user`` (:mod:`chuk_agents_runtime.files_out`) — push a produced file
  into the chat thread. Needs a sink; without one it is not registered.
- ``run_ffmpeg`` / ``run_ffprobe`` (:mod:`chuk_agents_runtime.media`) — the host's
  ffmpeg on the workspace's files. Needs a workspace mount; without one neither
  is registered.

The web tools follow §8: an API call first, a browser only as a fallback.
"""

from __future__ import annotations

import base64
import shlex

import httpx

from .documents import VisionReader, build_backend_vision, register_read_document
from .environment import Environment
from . import escalation as _esc
from .file_edit import EditGuard, FileObservations
from .file_edit import edit_file as _edit_file
from .file_edit import read_window
from .file_patch import apply_patch as _apply_patch
from .safety_floor import FloorVerdict, SafetyFloor
from .files_out import FileSink, register_send_file
from .media import WorkspaceMount, register_media_tools
from .registry import ToolRegistry
from .sandbox_io import workspace_path
from .secrets import SecretsAccess, register_secrets_tools
from .web_fetch import Resolver, register_web_fetch
from .web_search import DEFAULT_BASE_URL, TokenSession, register_web_search

# The read cap. A tool result travels back into the prompt, so an unbounded read
# would blow the context on one call.
READ_CAP = 60_000

# stdout/stderr cap for the python tool — a tool result travels back into the
# prompt, so an unbounded capture would blow the context on one call.
PYTHON_OUTPUT_CAP = 30_000

# The tool name the loop recognises as terminal. Kept here so tool and loop
# agree on one string.
FINISH_TOOL = "finish"

#: The required one-line label (research item 40). 5-10 active-voice words the
#: app shows while the call streams, before the output is known.
_DESCRIPTION_PROP = {
    "type": "string",
    "description": "A 5-10 word active-voice label for this call (e.g. 'Run the unit tests'). First.",
}

RUN_COMMAND_SCHEMA = {
    "type": "object",
    "description": (
        "Run one shell command in the workspace; returns exit code, stdout, "
        "stderr. The working directory persists: after `cd x` the next command "
        "starts in x (file tools resolve relative paths from the workspace "
        "root). For a long command (build, download, training) set "
        "background=true: you get a job_id at once and are woken with the "
        "output when it ends. For a program that asks questions use shell_start."
    ),
    "properties": {
        "command": {"type": "string", "description": "Shell command to run."},
        "timeout": {
            "type": "integer",
            "description": "Seconds until killed (foreground).",
            "default": 120,
        },
        "background": {
            "type": "boolean",
            "description": "Detach; returns {job_id, log_path} at once (24 h cap).",
            "default": False,
        },
        "cwd": {
            "type": "string",
            "description": "Directory to run in (background only).",
        },
        **_esc.SCHEMA_PROPERTIES,
    },
    "required": ["description", "command"],
}

WRITE_FILE_SCHEMA = {
    "type": "object",
    "description": (
        "Write text to a file, creating parent directories as needed."
    ),
    "properties": {
        "path": {
            "type": "string",
            "description": "File path, relative to the workspace or absolute.",
        },
        "content": {"type": "string", "description": "The full text to write."},
        "append": {
            "type": "boolean",
            "description": "Append instead of replacing the file.",
            "default": False,
        },
    },
    "required": ["path", "content"],
}

READ_FILE_SCHEMA = {
    "type": "object",
    "description": (
        "Read a text file as numbered lines. By default it returns the first "
        "2000 lines; use `offset` (1-based) and `limit` to read a "
        "later window; the footer names the offset to continue. "
        "edit_file and apply_patch need a prior read."
    ),
    "properties": {
        "path": {"type": "string", "description": "File path to read."},
        "offset": {
            "type": "integer",
            "description": "First line to return (1-based). Default 1.",
            "default": 1,
        },
        "limit": {
            "type": "integer",
            "description": "How many lines to return. Default 2000.",
            "default": 2000,
        },
        "max_bytes": {
            "type": "integer",
            "description": "Cap on the bytes returned for this window.",
            "default": READ_CAP,
        },
    },
    "required": ["path"],
}

EDIT_FILE_SCHEMA = {
    "type": "object",
    "description": (
        "Edit an existing text file by replacing literal text. Read the file "
        "first. `old_string` must be present; with replace_all=false it must "
        "appear exactly once, so include enough surrounding text to make it "
        "unique. Use an empty new_string to delete the match. For several edits "
        "in different places, or to add/delete/move whole files, use apply_patch."
    ),
    "properties": {
        "path": {"type": "string", "description": "File to edit."},
        "old_string": {"type": "string", "description": "Literal text to replace (must be non-empty)."},
        "new_string": {"type": "string", "description": "Replacement text (empty to delete the match)."},
        "replace_all": {
            "type": "boolean",
            "description": "Replace every match. Default false (old_string must be unique).",
            "default": False,
        },
    },
    "required": ["path", "old_string", "new_string"],
}

APPLY_PATCH_SCHEMA = {
    "type": "object",
    "description": (
        "Apply a Codex-format patch: one envelope between '*** Begin Patch' and "
        "'*** End Patch' with '*** Add File:', '*** Update File:' (with @@ "
        "context and +/- lines), '*** Delete File:' and '*** Move to:' sections. "
        "Update and Delete need a prior read of the file. All operations are "
        "checked first and applied together, or none is applied."
    ),
    "properties": {
        "patch": {"type": "string", "description": "The whole patch text."},
    },
    "required": ["patch"],
}

LIST_DIR_SCHEMA = {
    "type": "object",
    "description": "List the entries of a directory, with size and mtime.",
    "properties": {
        "path": {
            "type": "string",
            "description": "Directory to list.",
            "default": ".",
        },
    },
    "required": [],
}

# Code-as-action (CodeAct, §7.1). One `python` tool whose argument is a code
# string run in the sandbox. A single action can carry a whole multi-step plan —
# loops, branches, intermediate variables, composition of several operations —
# instead of one JSON tool call per step. Measured ~20% higher task success and
# ~30% fewer turns vs one-tool-per-turn. A plain tool call stays for simple
# things; the model drops into `python` for anything multi-step.
RUN_PYTHON_SCHEMA = {
    "type": "object",
    "description": (
        "Run a Python 3 script in the workspace; returns exit code, stdout, "
        "stderr. Prefer one script over many shell calls for multi-step work; "
        "print what you need."
    ),
    "properties": {
        "description": _DESCRIPTION_PROP,
        "code": {"type": "string", "description": "The full Python source to run."},
        "timeout": {
            "type": "integer",
            "description": "Seconds until killed.",
            "default": 120,
        },
        **_esc.SCHEMA_PROPERTIES,
    },
    "required": ["description", "code"],
}

# Explicit terminal action (§7.1). None of the strong agent loops rely on
# "bare-text turn = done" alone — a mid-task reasoning turn with no tool call
# would be misread as the final answer. `finish` lets the model signal
# completion deliberately; the loop treats it as the terminator. The structural
# bare-text rule stays as a fallback.
FINISH_SCHEMA = {
    "type": "object",
    "description": (
        "Call this when the task is fully done to deliver the final answer and "
        "stop. Put the answer to the user in `summary`. Do not call it to report "
        "mid-task progress — only to finish."
    ),
    "properties": {
        "summary": {
            "type": "string",
            "description": "The final answer / result for the user.",
        },
    },
    "required": ["summary"],
}


def _join_streams(stdout: str, stderr: str) -> str:
    parts = [stdout or ""]
    if stderr:
        if parts[0] and not parts[0].endswith("\n"):
            parts[0] += "\n"
        parts.append(f"[stderr]\n{stderr}")
    return "".join(parts)


def _shell_result(result, timeout: int) -> dict:
    """The shell result dict (research items 5 / 27). ``stopped`` names why the
    run ended early (``timeout``; ``user_stop`` is added by the loop on a Stop).
    ``exit_code`` is the LAST key so a reader can anchor on it. A non-zero exit
    is a normal result, not a tool error."""
    return {
        "stdout": result.stdout,
        "stderr": result.stderr,
        "timed_out": result.timed_out,
        "stopped": "timeout" if result.timed_out else None,
        "timeout_ms": int(timeout) * 1000,
        "duration_s": round(result.duration_s, 4),
        "exit_code": result.exit_code,
    }


def _exit_last(result: dict) -> dict:
    """Keep ``exit_code`` the LAST key after extra fields were added."""
    if "exit_code" not in result:
        return result
    out = {k: v for k, v in result.items() if k != "exit_code"}
    out["exit_code"] = result["exit_code"]
    return out


def _secret_env(secrets: SecretsAccess | None) -> dict:
    """The ``env=`` keyword for a child process, or nothing.

    The keyword is passed ONLY when there is a value to pass, so an
    environment (a test fake, an older sandbox) that does not know ``env``
    keeps working unchanged. Only ``run_command`` and ``python`` call this:
    the file tools, the terminal and every probe run without the secrets."""
    if secrets is None:
        return {}
    try:
        values = secrets.env()
    except Exception:  # noqa: BLE001 — a vault hiccup runs the command without keys
        return {}
    return {"env": values} if values else {}


def make_run_command_handler(
    env: Environment,
    secrets: SecretsAccess | None = None,
    jobs=None,
    floor: "SafetyFloor | None" = None,
    escalation_ask=None,
):
    """``jobs`` is a :class:`chuk_agents_runtime.shell_tools.JobManager` (or None).
    With one, ``background=true`` starts the command detached and returns the
    job handle; without one the flag is refused with a message. ``floor`` is the
    safety floor (research H23-H25): a catastrophic command is refused before it
    runs, whatever the approval mode."""

    def run_command(
        command: str,
        description: str | None = None,
        timeout: int = 120,
        background: bool = False,
        cwd: str | None = None,
        sandbox_permissions=None,
        justification: str | None = None,
    ) -> dict:
        # The schema requires `description` so a model supplies the 5-10 word
        # label the app shows while the call streams (research item 40). A
        # present-but-blank value is rejected; an absent one still runs (an
        # older client, a scripted call), it just carries no label.
        if description is not None and not str(description).strip():
            return {
                "ok": False,
                "error": "description must not be blank: give a short 5-10 word label for this command",
            }
        if floor is not None:
            try:
                verdict = floor.check_command(command)
            except Exception:  # noqa: BLE001 — RecursionError and friends: fail closed
                verdict = FloorVerdict("the safety floor could not check this command", hard=False)
            if verdict is not None:
                return {"ok": False, "blocked": True, "error": verdict.message()}
        # Sandbox escalation (research item 28): checked and approved BEFORE
        # anything runs; a grant covers this one call only.
        asked = _esc.parse_escalation(sandbox_permissions, justification)
        if asked.requested and background and not asked.error:
            return {"ok": False, "error": "a call with sandbox_permissions runs in the foreground only"}
        resolution = _esc.resolve_escalation(
            asked, env=env, ask=escalation_ask, tool="run_command", command=command
        )
        if resolution.refusal is not None:
            return resolution.refusal
        if resolution.grant:
            result = env.run_escalated(
                command, grant=resolution.grant, timeout=timeout, **_secret_env(secrets)
            )
            return _exit_last({**_shell_result(result, timeout), "escalated": list(resolution.grant)})
        out = _run_command_plain(command, timeout, background, cwd)
        if resolution.note and isinstance(out, dict):
            out = {**out, "note": resolution.note}
        if isinstance(out, dict) and "exit_code" in out:
            extra = _esc.denial_fields(env, escalation_ask, out.get("exit_code"), "command")
            if extra:
                out = {**out, **extra}
            out = _exit_last(out)
        return out

    def _run_command_plain(command: str, timeout: int, background: bool, cwd: str | None) -> dict:
        if background:
            if jobs is None:
                return {
                    "ok": False,
                    "error": "background jobs are not available in this runtime; run it in the foreground",
                }
            return jobs.start(command, cwd=cwd or None)
        secret_kw = _secret_env(secrets)
        if (
            jobs is not None
            and callable(getattr(jobs, "run_foreground", None))
            and getattr(jobs, "env", env) is env
        ):
            # Research item 38: a foreground command runs as an adoptable job.
            # Past its timeout the SAME process becomes a background job; it is
            # never stopped and started a second time (a second ``git push`` /
            # ``curl -X POST`` / ``>>`` append would apply its effects twice).
            outcome = jobs.run_foreground(command, timeout=timeout, env=secret_kw.get("env"))
            if outcome is not None and outcome.get("moved"):
                return {
                    "moved_to_background": True,
                    "job_id": outcome.get("job_id"),
                    "log_path": outcome.get("log_path"),
                    "stderr_path": outcome.get("stderr_path"),
                    "output_so_far": _join_streams(outcome.get("stdout", ""), outcome.get("stderr", "")),
                    "timeout_ms": int(timeout) * 1000,
                    "note": (
                        "The command ran past its timeout and keeps running as a background job "
                        "(the same process, not started again). You are woken when it ends; "
                        "job_status / job_output show it meanwhile (stderr is in stderr_path)."
                    ),
                }
            if outcome is not None:
                return _shell_result(outcome["result"], timeout)
            # The job could not be set up, so the command never ran: run it plainly.
        result = env.run_bash(command, timeout=timeout, **secret_kw)
        return _shell_result(result, timeout)

    return run_command


def make_write_file_handler(
    env: Environment, guard: "EditGuard | None" = None, floor: "SafetyFloor | None" = None
):
    def write_file(path: str, content: str, append: bool = False) -> dict:
        if floor is not None:
            verdict = floor.check_path_write(path)
            if verdict is not None:
                return {"ok": False, "path": path, "blocked": True, "error": verdict.message()}
        # An existing file the agent has not read is protected (research item
        # 34): only a new path is a free create. Append is exempt — it adds, it
        # does not overwrite. A guardless runtime (a test, an older build) keeps
        # the old free behaviour.
        if guard is not None and not append:
            refused = guard.check_write(path)
            if refused:
                return {"ok": False, "path": path, "error": refused}
        raw = content.encode("utf-8")
        payload = base64.b64encode(raw).decode("ascii")
        quoted = shlex.quote(workspace_path(env, path))
        redirect = ">>" if append else ">"
        cmd = (
            f"mkdir -p -- \"$(dirname -- {quoted})\" && "
            f"printf %s {shlex.quote(payload)} | base64 -d {redirect} {quoted}"
        )
        result = env.run_bash(cmd, timeout=60)
        if not result.ok:
            return {
                "ok": False,
                "path": path,
                "error": (result.stderr or result.stdout or "write failed").strip(),
            }
        if guard is not None:
            guard.observe(path)
        return {
            "ok": True,
            "path": path,
            "bytes_written": len(raw),
            "appended": bool(append),
        }

    return write_file


def make_read_file_handler(
    env: Environment, guard: "EditGuard | None" = None, floor: "SafetyFloor | None" = None
):
    def read_file(
        path: str, offset: int = 1, limit: int = 2000, max_bytes: int = READ_CAP
    ) -> dict:
        if floor is not None:
            verdict = floor.check_path_read(path)
            if verdict is not None:
                return {"ok": False, "path": path, "blocked": True, "error": verdict.message()}
        return read_window(
            env, path, offset=offset, limit=limit, max_bytes=max_bytes, guard=guard
        )

    return read_file


def make_edit_file_handler(env: Environment, guard: "EditGuard", floor: "SafetyFloor | None" = None):
    def edit_file(path: str, old_string: str, new_string: str, replace_all: bool = False) -> dict:
        if floor is not None:
            verdict = floor.check_path_write(path)
            if verdict is not None:
                return {"ok": False, "path": path, "blocked": True, "error": verdict.message()}
        return _edit_file(env, guard, path, old_string, new_string, bool(replace_all))

    return edit_file


def make_apply_patch_handler(env: Environment, guard: "EditGuard", floor: "SafetyFloor | None" = None):
    def apply_patch(patch: str) -> dict:
        return _apply_patch(env, guard, patch, floor=floor)

    return apply_patch


def make_list_dir_handler(env: Environment):
    def list_dir(path: str = ".") -> dict:
        quoted = shlex.quote(workspace_path(env, path))
        result = env.run_bash(
            f"ls -la --time-style=long-iso -- {quoted}", timeout=30
        )
        if not result.ok:
            return {
                "ok": False,
                "path": path,
                "error": (result.stderr or "list failed").strip(),
            }
        return {"ok": True, "path": path, "listing": result.stdout}

    return list_dir


def _cap(text: str, limit: int) -> tuple[str, bool]:
    """Truncate ``text`` to ``limit`` bytes; report whether it was cut."""
    raw = text.encode("utf-8", "replace")
    if len(raw) <= limit:
        return text, False
    return raw[:limit].decode("utf-8", "ignore"), True


def make_run_python_handler(
    env: Environment, secrets: SecretsAccess | None = None, escalation_ask=None
):
    def run_python(
        code: str,
        description: str | None = None,
        timeout: int = 120,
        sandbox_permissions=None,
        justification: str | None = None,
    ) -> dict:
        if description is not None and not str(description).strip():
            return {
                "ok": False,
                "error": "description must not be blank: give a short 5-10 word label for this script",
            }
        # The source travels as base64 inside the command, so nothing in the
        # code (quotes, backticks, ``$``, newlines) can break the shell or be
        # expanded by it — the same trick the file tools use.
        payload = base64.b64encode(code.encode("utf-8")).decode("ascii")
        script = "$(mktemp --suffix=.py)"
        cmd = (
            f"__f={script}; "
            f"printf %s {shlex.quote(payload)} | base64 -d > \"$__f\" && "
            f"python3 \"$__f\"; __rc=$?; rm -f \"$__f\"; exit $__rc"
        )
        asked = _esc.parse_escalation(sandbox_permissions, justification)
        resolution = _esc.resolve_escalation(
            asked, env=env, ask=escalation_ask, tool="python", command=code, subject="script"
        )
        if resolution.refusal is not None:
            return resolution.refusal
        if resolution.grant:
            result = env.run_escalated(
                cmd, grant=resolution.grant, timeout=timeout, **_secret_env(secrets)
            )
        else:
            result = env.run_bash(cmd, timeout=timeout, **_secret_env(secrets))
        stdout, out_trunc = _cap(result.stdout, PYTHON_OUTPUT_CAP)
        stderr, err_trunc = _cap(result.stderr, PYTHON_OUTPUT_CAP)
        return {
            "stdout": stdout,
            "stderr": stderr,
            "timed_out": result.timed_out,
            "stopped": "timeout" if result.timed_out else None,
            "timeout_ms": int(timeout) * 1000,
            "truncated": out_trunc or err_trunc,
            "duration_s": round(result.duration_s, 4),
            **({"escalated": list(resolution.grant)} if resolution.grant else {}),
            **({"note": resolution.note} if resolution.note else {}),
            **(
                {}
                if resolution.grant
                else _esc.denial_fields(env, escalation_ask, result.exit_code, "script")
            ),
            "exit_code": result.exit_code,
        }

    return run_python


def make_finish_handler():
    def finish(summary: str) -> dict:
        # The loop intercepts a `finish` tool call and stops with this summary as
        # the final answer; the handler just echoes it so the tool is a real,
        # dispatchable tool and gets documented to the model like any other.
        return {"ok": True, "final": summary}

    return finish


def register_run_command(
    registry: ToolRegistry,
    env: Environment,
    secrets: SecretsAccess | None = None,
    jobs=None,
    floor: "SafetyFloor | None" = None,
    escalation_ask=None,
) -> None:
    registry.register(
        "run_command",
        RUN_COMMAND_SCHEMA,
        make_run_command_handler(env, secrets, jobs, floor, escalation_ask),
    )


def register_file_tools(
    registry: ToolRegistry,
    env: Environment,
    guard: "EditGuard | None" = None,
    floor: "SafetyFloor | None" = None,
) -> None:
    registry.register("write_file", WRITE_FILE_SCHEMA, make_write_file_handler(env, guard, floor))
    registry.register("read_file", READ_FILE_SCHEMA, make_read_file_handler(env, guard, floor))
    registry.register("list_dir", LIST_DIR_SCHEMA, make_list_dir_handler(env))
    # The literal edit and the Codex patch need the read-before-edit guard, so
    # they are only registered with one (research items 32-34). Without a guard
    # the runtime keeps only the plain write/read tools, as before.
    # Deferrable: they stay out of the per-round prompt (found with
    # search_tools) to keep the tool budget, but the loop still runs one when a
    # model calls it by name without searching first.
    if guard is not None:
        registry.register(
            "edit_file", EDIT_FILE_SCHEMA, make_edit_file_handler(env, guard, floor), deferrable=True
        )
        registry.register(
            "apply_patch", APPLY_PATCH_SCHEMA, make_apply_patch_handler(env, guard, floor), deferrable=True
        )


def register_run_python(
    registry: ToolRegistry, env: Environment, secrets: SecretsAccess | None = None, escalation_ask=None
) -> None:
    registry.register("python", RUN_PYTHON_SCHEMA, make_run_python_handler(env, secrets, escalation_ask))


def register_finish(registry: ToolRegistry) -> None:
    registry.register(FINISH_TOOL, FINISH_SCHEMA, make_finish_handler())


def register_builtin_tools(
    registry: ToolRegistry,
    env: Environment,
    *,
    session: TokenSession | None = None,
    base_url: str = DEFAULT_BASE_URL,
    search_http_client: httpx.Client | None = None,
    fetch_http_client: httpx.Client | None = None,
    resolve: Resolver | None = None,
    file_sink: FileSink | None = None,
    media_mount: WorkspaceMount | None = None,
    vision: VisionReader | None = None,
    vision_http_client: httpx.Client | None = None,
    secrets: SecretsAccess | None = None,
    jobs=None,
    guard: "EditGuard | None" = None,
    floor: "SafetyFloor | None" = None,
    escalation_ask=None,
) -> None:
    """Register the whole built-in tool set against one environment.

    ``session`` is the account session (:class:`~chuk_agents_runtime.backend.SupabaseSession`).
    It is what pays for ``web_search`` and for the vision route of
    ``read_document``; leave it out and only the local tools are registered. The
    clients stay separate on purpose — one talks to our backend, the other to
    whatever host the model picked. ``*_http_client`` and ``resolve`` are the
    test injection points.

    Three tools are wired only when their channel exists, which is what keeps
    them out of the prompt in a run that cannot use them (§7.9):

    - ``file_sink`` — where a sent file goes. The executor binds it to a sealed
      ``file`` event; without it ``send_file_to_user`` is not registered.
    - ``media_mount`` — the shared workspace directory the host's ffmpeg works
      on; without it neither media tool is registered.
    - ``vision`` — an explicit :class:`~chuk_agents_runtime.documents.VisionReader`.
      Left out, one is built from ``session`` when there is a session to bill.
    - ``secrets`` — the user's secret set (docs/WIRE_CONTRACT.md, "Secrets").
      With it, ``run_command`` and ``python`` get the values as child-process
      environment, ``request_secrets`` / ``list_secrets`` are registered, and
      the registry's result filter masks every value on the way back. Without
      it, none of that exists and the prompt never mentions secrets.
    - ``jobs`` — a :class:`chuk_agents_runtime.shell_tools.JobManager`. With it,
      ``run_command(background=true)`` starts a detached job (docs/
      WIRE_CONTRACT.md, "Interactive shell and background commands"); without
      it the flag is refused and the job tools are not registered.
    """
    register_run_command(registry, env, secrets, jobs, floor, escalation_ask)
    register_file_tools(registry, env, guard, floor)
    # Net-new built-ins: CodeAct `python` and the explicit `finish` terminator.
    # Both need only the environment/registry, so the extra channel params above
    # (session, sinks, mounts) do not apply to them.
    register_run_python(registry, env, secrets, escalation_ask)
    register_finish(registry)
    register_secrets_tools(registry, secrets)
    register_web_search(
        registry, session, base_url=base_url, http_client=search_http_client
    )
    register_web_fetch(registry, http_client=fetch_http_client, resolve=resolve)
    register_read_document(
        registry,
        env,
        vision=vision
        or build_backend_vision(
            session, base_url=base_url, http_client=vision_http_client
        ),
    )
    register_send_file(registry, env, file_sink)
    register_media_tools(registry, media_mount)
