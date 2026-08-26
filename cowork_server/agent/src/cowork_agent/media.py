"""``run_ffmpeg`` / ``run_ffprobe`` — the host's ffmpeg on the sandbox's files (§9).

**The mechanism, and why this one.** The plan leaves the choice open between
passing the GPU into the container (``--gpus``) and letting the host binary work
on a shared mount. This takes the second, for three reasons that are all about
blast radius rather than convenience:

1. ``--gpus`` means the NVIDIA container toolkit, a matching driver inside the
   image, and a device node exposed to a box the agent can ``apt install``
   anything into. Host-executes-on-shared-mount adds nothing to the container at
   all — the sandbox stays a plain Debian with no device access.
2. The host binary is the one the user already tuned (NVENC/VAAPI). Nothing has
   to be reinstalled or version-matched inside the image.
3. The dangerous surface shrinks to exactly one thing: the argument vector. That
   is a thing this module can enumerate and test, and it does.

**The hardening.** The agent never hands over a command line. It names inputs, an
output and options, and every one of them is checked before ``ffmpeg`` sees it:

- every path is resolved *inside* the workspace mount — a ``..`` segment, an
  absolute path outside the sandbox root, and a symlink that points out of the
  workspace are each rejected, the last because resolution follows symlinks and
  the result is re-checked against the root;
- options come from an allowlist, by name, with a fixed value/no-value shape.
  ``-i`` is not on it: extra inputs go through ``inputs``, so a second file can
  never be smuggled in as an option;
- option values must match a conservative character class and must not reference
  a file or a protocol. ffmpeg reads files from places that do not look like
  paths — ``-vf movie=/etc/shadow``, ``subtitles=``, ``fontfile=``,
  ``concat:``, ``http://`` — so those are blocked by token, not by shape;
- the command is executed as an **argv list, never through a shell**, with the
  host workspace as the working directory.

``run_ffprobe`` is a separate, purely reading tool: fixed arguments, one input,
no options at all, JSON out. Reading a file's metadata should not go through the
tool that can write one.

Without a configured mount — or without ffmpeg on the host — neither tool is
available, so ``check_fn`` keeps both out of the prompt entirely (§7.9). The
mount itself is wired by whoever creates the sandbox; nothing here assumes how.
"""

from __future__ import annotations

import json
import re
import shutil
import subprocess
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from pathlib import Path, PurePosixPath

from .registry import ToolRegistry

FFMPEG_BINARY = "ffmpeg"
FFPROBE_BINARY = "ffprobe"

DEFAULT_TIMEOUT = 600
MAX_TIMEOUT = 3600
MAX_INPUTS = 8
MAX_OPTION_TOKENS = 48
STDERR_CAP = 4000
PROBE_CAP = 20_000

# Options that take exactly one value.
ALLOWED_VALUE_OPTIONS = frozenset(
    {
        "-c", "-c:a", "-c:v", "-codec", "-acodec", "-vcodec",
        "-f", "-map", "-metadata:s",
        "-b:a", "-b:v", "-maxrate", "-bufsize", "-crf", "-preset", "-tune",
        "-profile:v", "-level", "-g", "-bf",
        "-q:a", "-q:v", "-qscale:a", "-qscale:v",
        "-r", "-ar", "-ac", "-sample_fmt", "-pix_fmt", "-s", "-aspect",
        "-vf", "-af", "-filter:a", "-filter:v",
        "-ss", "-t", "-to", "-frames:v", "-frames:a",
        "-loop", "-movflags", "-threads", "-fps_mode", "-vsync",
        "-max_muxing_queue_size", "-hwaccel", "-hwaccel_device",
        "-start_number", "-compression_level",
    }
)

# Options that stand alone.
ALLOWED_FLAG_OPTIONS = frozenset(
    {"-an", "-vn", "-sn", "-dn", "-shortest", "-autorotate", "-noautorotate"}
)

# A deliberately narrow class. No shell is involved, so this is not about
# quoting — it is about keeping values close to what a codec or filter argument
# actually looks like.
_VALUE_OK = re.compile(r"^[A-Za-z0-9_.,:=+\-*/%'\[\]()@|;#\s]{1,512}$")

# ffmpeg reads and writes files from arguments that do not look like paths.
# These are the ways it does that.
_FILE_REFERENCE_TOKENS = (
    "://",
    "file:",
    "pipe:",
    "concat:",
    "cache:",
    "crypto:",
    "subfile:",
    "data:",
    "movie=",
    "amovie=",
    "subtitles=",
    "ass=",
    "textfile=",
    "fontfile=",
    "filename=",
    "sendcmd",
    "asendcmd",
)


class MediaError(ValueError):
    """An argument was rejected before ffmpeg ran."""


@dataclass(frozen=True)
class WorkspaceMount:
    """The one shared directory: the same bytes under two names.

    ``sandbox_root`` is the path the agent and the container use (``/workspace``);
    ``host_root`` is where that directory really lives on the user's machine.
    Both are what makes host-side ffmpeg legitimate — and what bounds it.
    """

    sandbox_root: str
    host_root: str

    def host_base(self) -> Path:
        return Path(self.host_root).resolve()

    def usable(self) -> bool:
        try:
            return bool(self.sandbox_root) and self.host_base().is_dir()
        except OSError:
            return False


@dataclass(frozen=True)
class MediaResult:
    """What running one media command produced."""

    exit_code: int
    stdout: str
    stderr: str
    timed_out: bool


# argv + timeout -> outcome. The default shells out; tests inject a fake.
CommandRunner = Callable[[Sequence[str], int], MediaResult]


def subprocess_runner(argv: Sequence[str], timeout: int) -> MediaResult:
    """Run an argv list on the host. No shell, ever."""
    try:
        proc = subprocess.run(
            list(argv),
            capture_output=True,
            text=True,
            timeout=timeout,
            stdin=subprocess.DEVNULL,
        )
    except subprocess.TimeoutExpired as exc:
        return MediaResult(
            exit_code=124,
            stdout=exc.stdout if isinstance(exc.stdout, str) else "",
            stderr=exc.stderr if isinstance(exc.stderr, str) else "",
            timed_out=True,
        )
    except OSError as exc:
        return MediaResult(exit_code=127, stdout="", stderr=str(exc), timed_out=False)
    return MediaResult(
        exit_code=proc.returncode,
        stdout=proc.stdout or "",
        stderr=proc.stderr or "",
        timed_out=False,
    )


# -- path hardening -----------------------------------------------------------


def _relative_part(mount: WorkspaceMount, path: str) -> PurePosixPath:
    """The workspace-relative form of ``path``, or raise.

    Blocks, in order: an empty path, a ``..`` segment anywhere, and an absolute
    path that is not under the sandbox root. This runs on the *stated* path,
    before any filesystem call, so a rejection never touches the disk.
    """
    text = (path if isinstance(path, str) else str(path or "")).strip()
    if not text:
        raise MediaError("path is empty")
    if "\x00" in text:
        raise MediaError("path contains a null byte")

    pure = PurePosixPath(text)
    if ".." in pure.parts:
        raise MediaError(f"path escapes the workspace: {text}")

    if pure.is_absolute():
        root = PurePosixPath(mount.sandbox_root)
        if not pure.is_relative_to(root):
            raise MediaError(
                f"path is outside the workspace {mount.sandbox_root}: {text}"
            )
        pure = pure.relative_to(root)

    if not pure.parts:
        raise MediaError("path is the workspace itself, not a file")
    return pure


def resolve_in_workspace(
    mount: WorkspaceMount, path: str, *, must_exist: bool
) -> Path:
    """Map a workspace path to its real host path, or raise.

    The second check is the one that matters: ``Path.resolve()`` follows
    symlinks, so a link inside the workspace that points at ``/etc`` resolves to
    ``/etc`` and fails the containment test. For an output that does not exist
    yet the *parent* is resolved instead, which catches a symlinked directory
    just the same.
    """
    relative = _relative_part(mount, path)
    base = mount.host_base()
    candidate = base / Path(*relative.parts)

    if must_exist:
        try:
            real = candidate.resolve(strict=True)
        except (OSError, RuntimeError):
            raise MediaError(f"no such file in the workspace: {path}") from None
        if not real.is_relative_to(base):
            raise MediaError(f"path leaves the workspace through a link: {path}")
        if not real.is_file():
            raise MediaError(f"not a regular file: {path}")
        return real

    try:
        parent = candidate.parent.resolve(strict=False)
    except (OSError, RuntimeError):
        raise MediaError(f"cannot resolve the output directory for {path}") from None
    if not parent.is_relative_to(base):
        raise MediaError(f"output leaves the workspace through a link: {path}")
    if candidate.is_symlink():
        # Writing through a symlink would write wherever it points.
        raise MediaError(f"output is a symlink: {path}")
    return parent / candidate.name


# -- option hardening ---------------------------------------------------------


def _check_value(option: str, value: str) -> str:
    text = value if isinstance(value, str) else str(value)
    if not text:
        raise MediaError(f"option {option} has an empty value")
    if not _VALUE_OK.match(text):
        raise MediaError(f"option {option} has a value with forbidden characters")
    low = text.lower()
    for token in _FILE_REFERENCE_TOKENS:
        if token in low:
            raise MediaError(
                f"option {option} refers to a file or a protocol ({token!r}); "
                "inputs go through `inputs`"
            )
    return text


def validate_options(options: Sequence[str] | None) -> list[str]:
    """Check an option list token by token and return it unchanged.

    Names must be on the allowlist. A value option must be followed by exactly
    one value; a flag option must not be. ``-i`` is absent from both lists on
    purpose, so an extra input can never arrive disguised as an option.
    """
    if not options:
        return []
    if isinstance(options, (str, bytes)):
        raise MediaError("options must be a list of separate tokens, not one string")
    tokens = [t if isinstance(t, str) else str(t) for t in options]
    if len(tokens) > MAX_OPTION_TOKENS:
        raise MediaError(f"too many option tokens (max {MAX_OPTION_TOKENS})")

    checked: list[str] = []
    index = 0
    while index < len(tokens):
        name = tokens[index].strip()
        if name in ALLOWED_FLAG_OPTIONS:
            checked.append(name)
            index += 1
            continue
        if name in ALLOWED_VALUE_OPTIONS:
            if index + 1 >= len(tokens):
                raise MediaError(f"option {name} needs a value")
            checked.append(name)
            checked.append(_check_value(name, tokens[index + 1]))
            index += 2
            continue
        if name in {"-i", "-y", "-n"}:
            raise MediaError(
                f"{name} is set by the tool, not by you: use `inputs`, `output` "
                "and `overwrite`"
            )
        raise MediaError(f"option not allowed: {name}")
    return checked


# -- ffmpeg -------------------------------------------------------------------

RUN_FFMPEG_SCHEMA = {
    "type": "object",
    "description": (
        "Convert, cut, resize or re-encode media with ffmpeg. It runs on the "
        "machine's own (GPU-accelerated) ffmpeg and works on files in the "
        "workspace. Name the input files, the output file and the options as "
        "separate tokens — you do not write a command line."
    ),
    "properties": {
        "inputs": {
            "type": "array",
            "description": (
                "Input files in the workspace, in order. Usually one."
            ),
        },
        "output": {
            "type": "string",
            "description": (
                "Output file in the workspace. The extension picks the format."
            ),
        },
        "options": {
            "type": "array",
            "description": (
                "ffmpeg options as separate tokens, for example "
                "[\"-c:v\", \"h264_nvenc\", \"-crf\", \"23\", \"-vf\", "
                "\"scale=1280:720\"]. Only encoding options are allowed; you "
                "cannot add inputs or file paths here."
            ),
        },
        "overwrite": {
            "type": "boolean",
            "description": "Replace the output file if it already exists.",
            "default": False,
        },
        "timeout": {
            "type": "integer",
            "description": "Seconds before the job is killed.",
            "default": DEFAULT_TIMEOUT,
        },
    },
    "required": ["inputs", "output"],
}

RUN_FFPROBE_SCHEMA = {
    "type": "object",
    "description": (
        "Read a media file's technical details — duration, size, codecs, "
        "streams, bit rate — as JSON. Reads only; it never changes a file. Use "
        "it before `run_ffmpeg` to see what you are working with."
    ),
    "properties": {
        "path": {
            "type": "string",
            "description": "Media file in the workspace.",
        },
    },
    "required": ["path"],
}


def _clip(text: str, cap: int) -> str:
    text = text or ""
    return text if len(text) <= cap else text[-cap:]


def _as_list(value) -> list[str]:
    if value is None:
        return []
    if isinstance(value, str):
        return [value]
    if isinstance(value, (list, tuple)):
        return [v if isinstance(v, str) else str(v) for v in value]
    raise MediaError("expected a list of paths")


def make_run_ffmpeg_handler(
    mount: WorkspaceMount,
    *,
    runner: CommandRunner = subprocess_runner,
    binary: str = FFMPEG_BINARY,
):
    """Build the ``run_ffmpeg`` handler for one workspace mount."""

    def run_ffmpeg(
        inputs,
        output: str,
        options=None,
        overwrite: bool = False,
        timeout: int = DEFAULT_TIMEOUT,
    ) -> dict:
        try:
            raw_inputs = _as_list(inputs)
            if not raw_inputs:
                raise MediaError("no input file given")
            if len(raw_inputs) > MAX_INPUTS:
                raise MediaError(f"too many inputs (max {MAX_INPUTS})")
            host_inputs = [
                resolve_in_workspace(mount, item, must_exist=True)
                for item in raw_inputs
            ]
            checked_options = validate_options(options)
            host_output = resolve_in_workspace(mount, output, must_exist=False)
        except MediaError as exc:
            return {"ok": False, "error": str(exc)}

        if host_output in host_inputs:
            return {"ok": False, "error": "the output is also an input"}
        if host_output.exists():
            if host_output.is_dir():
                return {"ok": False, "error": f"the output is a directory: {output}"}
            if not overwrite:
                return {
                    "ok": False,
                    "error": (
                        f"{output} already exists; pass overwrite=true to replace it"
                    ),
                }
        try:
            host_output.parent.mkdir(parents=True, exist_ok=True)
        except OSError as exc:
            return {"ok": False, "error": f"cannot create the output directory: {exc}"}

        try:
            seconds = max(1, min(int(timeout), MAX_TIMEOUT))
        except (TypeError, ValueError):
            seconds = DEFAULT_TIMEOUT

        argv = [binary, "-nostdin", "-hide_banner", "-loglevel", "error"]
        argv.append("-y" if overwrite else "-n")
        for item in host_inputs:
            argv += ["-i", str(item)]
        argv += checked_options
        argv.append(str(host_output))

        result = runner(argv, seconds)
        if result.timed_out:
            return {
                "ok": False,
                "output": output,
                "timed_out": True,
                "error": f"ffmpeg was killed after {seconds}s",
            }
        if result.exit_code != 0:
            return {
                "ok": False,
                "output": output,
                "exit_code": result.exit_code,
                "error": _clip(result.stderr, STDERR_CAP) or "ffmpeg failed",
            }
        try:
            size = host_output.stat().st_size
        except OSError:
            size = 0
        return {
            "ok": True,
            "output": output,
            "bytes": size,
            "exit_code": 0,
            "stderr": _clip(result.stderr, 1000),
        }

    return run_ffmpeg


def make_run_ffprobe_handler(
    mount: WorkspaceMount,
    *,
    runner: CommandRunner = subprocess_runner,
    binary: str = FFPROBE_BINARY,
    timeout: int = 60,
):
    """Build the read-only ``run_ffprobe`` handler."""

    def run_ffprobe(path: str) -> dict:
        try:
            host_path = resolve_in_workspace(mount, path, must_exist=True)
        except MediaError as exc:
            return {"ok": False, "error": str(exc)}

        argv = [
            binary,
            "-v", "error",
            "-print_format", "json",
            "-show_format",
            "-show_streams",
            str(host_path),
        ]
        result = runner(argv, timeout)
        if result.timed_out:
            return {"ok": False, "path": path, "error": "ffprobe timed out"}
        if result.exit_code != 0:
            return {
                "ok": False,
                "path": path,
                "exit_code": result.exit_code,
                "error": _clip(result.stderr, STDERR_CAP) or "ffprobe failed",
            }
        body = result.stdout or ""
        if len(body) > PROBE_CAP:
            return {
                "ok": False,
                "path": path,
                "error": "ffprobe returned more than can be read back",
            }
        try:
            return {"ok": True, "path": path, "info": json.loads(body)}
        except ValueError:
            return {"ok": False, "path": path, "error": "ffprobe returned no JSON"}

    return run_ffprobe


def _binary_present(binary: str) -> bool:
    return shutil.which(binary) is not None


def register_media_tools(
    registry: ToolRegistry,
    mount: WorkspaceMount | None,
    *,
    runner: CommandRunner = subprocess_runner,
    ffmpeg_binary: str = FFMPEG_BINARY,
    ffprobe_binary: str = FFPROBE_BINARY,
    require_binaries: bool = True,
) -> None:
    """Register ``run_ffmpeg`` and ``run_ffprobe``.

    Without a mount there is no shared directory and nothing to run on, so
    neither tool is registered. With one, each ``check_fn`` still re-probes the
    mount and the binary every time the prompt is built, so a machine that lost
    its ffmpeg simply stops advertising the tool instead of failing a task
    halfway. ``require_binaries=False`` is for tests that inject a runner.
    """
    if mount is None:
        return

    def _available(binary: str) -> bool:
        if not mount.usable():
            return False
        return _binary_present(binary) if require_binaries else True

    registry.register(
        "run_ffmpeg",
        RUN_FFMPEG_SCHEMA,
        make_run_ffmpeg_handler(mount, runner=runner, binary=ffmpeg_binary),
        check_fn=lambda: _available(ffmpeg_binary),
    )
    registry.register(
        "run_ffprobe",
        RUN_FFPROBE_SCHEMA,
        make_run_ffprobe_handler(mount, runner=runner, binary=ffprobe_binary),
        check_fn=lambda: _available(ffprobe_binary),
    )


__all__ = [
    "ALLOWED_FLAG_OPTIONS",
    "ALLOWED_VALUE_OPTIONS",
    "DEFAULT_TIMEOUT",
    "MAX_INPUTS",
    "CommandRunner",
    "MediaError",
    "MediaResult",
    "WorkspaceMount",
    "make_run_ffmpeg_handler",
    "make_run_ffprobe_handler",
    "register_media_tools",
    "resolve_in_workspace",
    "subprocess_runner",
    "validate_options",
]
