"""Built-in tools (§7.2 / §7.3).

Every tool runs through the injected
:class:`~cowork_agent.environment.Environment`, so the same tool set works
against the local stand-in and against the real sandbox. There is no second
filesystem path — a Docker sandbox stays a Docker sandbox.

- ``run_command`` — one shell command.
- ``write_file`` / ``read_file`` / ``list_dir`` — file work without shell
  quoting. The file content travels as base64 inside the command, so newlines,
  quotes, backticks and ``$`` in the content can never break the shell or be
  expanded by it. Models get shell heredocs wrong often enough that the file
  tools are what make "write me a script" actually land on disk.
- ``web_search`` (:mod:`cowork_agent.web_search`) — search through our own
  backend, so no provider key ever sits in the sandbox. Needs the account
  session; without one it is not registered and not documented to the model.
- ``web_fetch`` (:mod:`cowork_agent.web_fetch`) — read one page as Markdown,
  locally, with the SSRF/size/type hardening that module documents.
- ``read_document`` (:mod:`cowork_agent.documents`) — any document to Markdown,
  offline through anydoc, with a vision route for scans and images.
- ``send_file_to_user`` (:mod:`cowork_agent.files_out`) — push a produced file
  into the chat thread. Needs a sink; without one it is not registered.
- ``run_ffmpeg`` / ``run_ffprobe`` (:mod:`cowork_agent.media`) — the host's
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
from .files_out import FileSink, register_send_file
from .media import WorkspaceMount, register_media_tools
from .registry import ToolRegistry
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

RUN_COMMAND_SCHEMA = {
    "type": "object",
    "description": (
        "Run one shell command in the workspace and return its exit code, "
        "stdout and stderr. Use it to run scripts and tests, to inspect the "
        "system, and for git. For a long command (a build, a download, a "
        "training run) set background=true: it returns a job_id at once, the "
        "command keeps running, and you are woken with its output when it "
        "ends. For a program that asks questions use shell_start instead."
    ),
    "properties": {
        "command": {"type": "string", "description": "Shell command to run."},
        "timeout": {
            "type": "integer",
            "description": "Seconds before the command is killed (foreground only).",
            "default": 120,
        },
        "background": {
            "type": "boolean",
            "description": (
                "Start detached and return {job_id, log_path} immediately. "
                "No timeout (24 h cap). You are woken when it finishes."
            ),
            "default": False,
        },
        "cwd": {
            "type": "string",
            "description": "Directory to run in (background only).",
        },
    },
    "required": ["command"],
}

WRITE_FILE_SCHEMA = {
    "type": "object",
    "description": (
        "Write text to a file, creating parent directories as needed. This is "
        "how you create a file. Printing the content in your answer does not "
        "create anything."
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
    "description": "Read a text file back. The result is truncated at 60000 bytes.",
    "properties": {
        "path": {"type": "string", "description": "File path to read."},
        "max_bytes": {
            "type": "integer",
            "description": "Read at most this many bytes.",
            "default": READ_CAP,
        },
    },
    "required": ["path"],
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
        "Run a Python 3 script in the workspace and return its exit code, "
        "stdout and stderr. Prefer this over many small shell calls when a task "
        "needs several steps, loops, or intermediate values — write one script. "
        "The script runs to completion; print what you need to see."
    ),
    "properties": {
        "code": {"type": "string", "description": "The full Python source to run."},
        "timeout": {
            "type": "integer",
            "description": "Seconds before the script is killed.",
            "default": 120,
        },
    },
    "required": ["code"],
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
    env: Environment, secrets: SecretsAccess | None = None, jobs=None
):
    """``jobs`` is a :class:`cowork_agent.shell_tools.JobManager` (or None).
    With one, ``background=true`` starts the command detached and returns the
    job handle; without one the flag is refused with a message."""

    def run_command(
        command: str,
        timeout: int = 120,
        background: bool = False,
        cwd: str | None = None,
    ) -> dict:
        if background:
            if jobs is None:
                return {
                    "ok": False,
                    "error": "background jobs are not available in this runtime; run it in the foreground",
                }
            return jobs.start(command, cwd=cwd or None)
        result = env.run_bash(command, timeout=timeout, **_secret_env(secrets))
        return {
            "exit_code": result.exit_code,
            "stdout": result.stdout,
            "stderr": result.stderr,
            "timed_out": result.timed_out,
            "duration_s": round(result.duration_s, 4),
        }

    return run_command


def make_write_file_handler(env: Environment):
    def write_file(path: str, content: str, append: bool = False) -> dict:
        raw = content.encode("utf-8")
        payload = base64.b64encode(raw).decode("ascii")
        quoted = shlex.quote(path)
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
        return {
            "ok": True,
            "path": path,
            "bytes_written": len(raw),
            "appended": bool(append),
        }

    return write_file


def make_read_file_handler(env: Environment):
    def read_file(path: str, max_bytes: int = READ_CAP) -> dict:
        limit = max(1, min(int(max_bytes), READ_CAP))
        quoted = shlex.quote(path)
        # head -c reads at most `limit` bytes; +1 tells truncation from an exact fit.
        result = env.run_bash(f"head -c {limit + 1} -- {quoted}", timeout=60)
        if not result.ok:
            return {
                "ok": False,
                "path": path,
                "error": (result.stderr or "read failed").strip(),
            }
        content = result.stdout
        truncated = len(content.encode("utf-8", "replace")) > limit
        if truncated:
            content = content[:limit]
        return {"ok": True, "path": path, "content": content, "truncated": truncated}

    return read_file


def make_list_dir_handler(env: Environment):
    def list_dir(path: str = ".") -> dict:
        quoted = shlex.quote(path)
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


def make_run_python_handler(env: Environment, secrets: SecretsAccess | None = None):
    def run_python(code: str, timeout: int = 120) -> dict:
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
        result = env.run_bash(cmd, timeout=timeout, **_secret_env(secrets))
        stdout, out_trunc = _cap(result.stdout, PYTHON_OUTPUT_CAP)
        stderr, err_trunc = _cap(result.stderr, PYTHON_OUTPUT_CAP)
        return {
            "exit_code": result.exit_code,
            "stdout": stdout,
            "stderr": stderr,
            "timed_out": result.timed_out,
            "truncated": out_trunc or err_trunc,
            "duration_s": round(result.duration_s, 4),
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
) -> None:
    registry.register(
        "run_command",
        RUN_COMMAND_SCHEMA,
        make_run_command_handler(env, secrets, jobs),
    )


def register_file_tools(registry: ToolRegistry, env: Environment) -> None:
    registry.register("write_file", WRITE_FILE_SCHEMA, make_write_file_handler(env))
    registry.register("read_file", READ_FILE_SCHEMA, make_read_file_handler(env))
    registry.register("list_dir", LIST_DIR_SCHEMA, make_list_dir_handler(env))


def register_run_python(
    registry: ToolRegistry, env: Environment, secrets: SecretsAccess | None = None
) -> None:
    registry.register("python", RUN_PYTHON_SCHEMA, make_run_python_handler(env, secrets))


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
) -> None:
    """Register the whole built-in tool set against one environment.

    ``session`` is the account session (:class:`~cowork_agent.backend.SupabaseSession`).
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
    - ``vision`` — an explicit :class:`~cowork_agent.documents.VisionReader`.
      Left out, one is built from ``session`` when there is a session to bill.
    - ``secrets`` — the user's secret set (docs/WIRE_CONTRACT.md, "Secrets").
      With it, ``run_command`` and ``python`` get the values as child-process
      environment, ``request_secrets`` / ``list_secrets`` are registered, and
      the registry's result filter masks every value on the way back. Without
      it, none of that exists and the prompt never mentions secrets.
    - ``jobs`` — a :class:`cowork_agent.shell_tools.JobManager`. With it,
      ``run_command(background=true)`` starts a detached job (docs/
      WIRE_CONTRACT.md, "Interactive shell and background commands"); without
      it the flag is refused and the job tools are not registered.
    """
    register_run_command(registry, env, secrets, jobs)
    register_file_tools(registry, env)
    # Net-new built-ins: CodeAct `python` and the explicit `finish` terminator.
    # Both need only the environment/registry, so the extra channel params above
    # (session, sinks, mounts) do not apply to them.
    register_run_python(registry, env, secrets)
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
