"""BaseEnvironment: the 2-method sandbox abstraction (borrowed from Hermes, MIT).

Subclasses implement only two things:

* ``_run_bash(cmd, *, login, timeout, stdin) -> ProcessResult`` -- execute one
  exact command string in the target (a local shell, a ``docker exec``, ...),
  enforcing the timeout by killing the process, and return the raw result.
* ``cleanup()`` -- release the backend (temp dirs, container, ...).

Everything else lives here: bounded output, snapshot-file session persistence,
cwd recovery, and the ``run_bash`` protocol adapter.

Snapshot-file session persistence
---------------------------------
There is no long-lived shell to babysit. Every ``run`` wraps the user command
as::

    shopt -s expand_aliases
    source <snap>            # restore env/aliases/functions from last call
    cd <cwd>                 # restore working directory
    { <user cmd> } ; rc=$?
    { declare -px; declare -f; alias; } > <tmp>   # re-dump the session
    mv -f <tmp> <snap>       # atomic swap
    printf '<marker>%s' "$PWD"  # emit cwd so the base can recover it
    exit $rc

So exported variables, aliases, functions and the working directory survive
across calls even though each call is a fresh ``bash``. The snapshot is rewritten
atomically (mktemp + mv) so a crash mid-write never corrupts it.
"""

from __future__ import annotations

import secrets
import shlex
from abc import ABC, abstractmethod

from .result import ProcessResult

# Default cap on captured stdout/stderr, in characters. Long-running tools can
# emit unbounded output; the base trims it and flags the truncation so a single
# command cannot blow up the agent's context window.
DEFAULT_MAX_OUTPUT_CHARS = 100_000


class BaseEnvironment(ABC):
    """Abstract execution environment with snapshot-file session persistence."""

    def __init__(
        self,
        *,
        snapshot_path: str,
        initial_cwd: str,
        max_output_chars: int = DEFAULT_MAX_OUTPUT_CHARS,
    ) -> None:
        self._snapshot_path = snapshot_path
        self._cwd = initial_cwd
        self._max_output_chars = max_output_chars
        # A per-instance random marker keeps the cwd line from colliding with any
        # legitimate command output.
        self._cwd_marker = f"__COWORK_CWD_{secrets.token_hex(8)}__:"
        self._session_initialized = False

    # ------------------------------------------------------------------ #
    # Subclass surface
    # ------------------------------------------------------------------ #
    @abstractmethod
    def _run_bash(
        self,
        cmd: str,
        *,
        login: bool = False,
        timeout: int = 120,
        stdin: str | None = None,
    ) -> ProcessResult:
        """Execute one exact command string; enforce timeout by killing."""
        raise NotImplementedError

    @abstractmethod
    def cleanup(self) -> None:
        """Release backend resources. Safe to call more than once."""
        raise NotImplementedError

    def cancel(self) -> None:
        """Abort the command **currently in flight**, if there is one.

        This is the sandbox end of the §7.1 kill switch: the loop's Stop can only
        end a run *between* tool calls, so without this a ``run_command`` that
        runs for ten minutes would keep the user waiting for ten minutes. A
        backend implements it by killing the process it is blocked on; the killed
        command comes back like any other failure (a non-zero exit code), not as
        an exception, because the caller is a tool handler and not the stopper.

        Not sticky and not a mode: it cancels what is running now and nothing
        else. The next ``run`` works normally — the run is ended by the loop's
        kill switch, not by a poisoned environment, and the plumbing that follows
        a stop (a journal commit, a cleanup) still needs a working shell.

        The default does nothing, which is the honest behaviour for a backend
        that cannot interrupt itself; the run then ends at the next poll instead.

        Called from another thread than the one inside ``run`` — that is the whole
        point. One environment still serves **one** command thread: it tracks one
        cwd, one snapshot and one in-flight process, so two callers running
        commands on it would race regardless of this method.
        """
        return None

    # ------------------------------------------------------------------ #
    # Public API
    # ------------------------------------------------------------------ #
    @property
    def cwd(self) -> str:
        """The current working directory, recovered from the last command."""
        return self._cwd

    def init_session(self) -> None:
        """Seed the snapshot once from a login shell (PATH, profile env, ...)."""
        if self._session_initialized:
            return
        snap = shlex.quote(self._snapshot_path)
        # Dump a login shell's environment straight into the snapshot file.
        seed = f"{{ declare -px; declare -f; alias; }} > {snap} 2>/dev/null; true"
        self._run_bash(seed, login=True, timeout=60)
        self._session_initialized = True

    def run(
        self,
        cmd: str,
        *,
        login: bool = False,
        timeout: int = 120,
        stdin: str | None = None,
    ) -> ProcessResult:
        """Run ``cmd`` with session persistence and bounded output."""
        if not self._session_initialized:
            self.init_session()

        wrapped = self._wrap(cmd)
        raw = self._run_bash(wrapped, login=login, timeout=timeout, stdin=stdin)

        stdout, cwd = self._extract_cwd(raw.stdout)
        if cwd:
            self._cwd = cwd

        stdout, out_trunc = self._bound(stdout)
        stderr, err_trunc = self._bound(raw.stderr)
        return ProcessResult(
            stdout=stdout,
            stderr=stderr,
            exit_code=raw.exit_code,
            stdout_truncated=out_trunc,
            stderr_truncated=err_trunc,
            timed_out=raw.timed_out,
        )

    def run_bash(
        self, cmd: str, *, timeout: int = 120, internal: bool = False
    ) -> ProcessResult:
        """Adapter that satisfies the agent runtime's ``Environment`` protocol.

        ``internal`` marks plumbing the agent did not ask for (an availability
        probe, a journal commit). The sandbox runs it identically; only
        observers higher up use the flag to keep it out of the user's thread."""
        del internal
        return self.run(cmd, timeout=timeout)

    # Context-manager sugar so callers can ``with make_environment(...) as env``.
    def __enter__(self) -> "BaseEnvironment":
        return self

    def __exit__(self, *exc: object) -> None:
        self.cleanup()

    # ------------------------------------------------------------------ #
    # Internals
    # ------------------------------------------------------------------ #
    def _wrap(self, cmd: str) -> str:
        """Wrap a user command in the source/cd/redump/marker envelope."""
        snap = shlex.quote(self._snapshot_path)
        cwd = shlex.quote(self._cwd)
        marker = self._cwd_marker
        # ``mktemp`` is created next to the snapshot so the final ``mv`` is a
        # same-filesystem atomic rename.
        return (
            "shopt -s expand_aliases 2>/dev/null\n"
            f"source {snap} 2>/dev/null\n"
            f"cd {cwd} 2>/dev/null\n"
            "{\n"
            f"{cmd}\n"
            "}\n"
            "__cw_rc=$?\n"
            f'__cw_tmp="$(mktemp {snap}.XXXXXX)"\n'
            f'{{ declare -px; declare -f; alias; }} > "$__cw_tmp" 2>/dev/null\n'
            f'mv -f "$__cw_tmp" {snap} 2>/dev/null\n'
            f"printf '\\n%s%s\\n' '{marker}' \"$PWD\"\n"
            "exit $__cw_rc\n"
        )

    def _extract_cwd(self, stdout: str) -> tuple[str, str | None]:
        """Strip the cwd marker line and return (clean_stdout, cwd)."""
        marker = self._cwd_marker
        if marker not in stdout:
            return stdout, None
        cwd: str | None = None
        kept: list[str] = []
        for line in stdout.split("\n"):
            if line.startswith(marker):
                cwd = line[len(marker):]
            else:
                kept.append(line)
        # The wrapper always prints a leading '\n' before the marker, which adds
        # exactly one trailing empty element; drop it to restore the original.
        if kept and kept[-1] == "":
            kept.pop()
        return "\n".join(kept), cwd

    def _bound(self, text: str) -> tuple[str, bool]:
        """Cap output length, appending a note when truncation happens."""
        limit = self._max_output_chars
        if len(text) <= limit:
            return text, False
        omitted = len(text) - limit
        note = f"\n[... output truncated, {omitted} characters omitted ...]"
        return text[:limit] + note, True
