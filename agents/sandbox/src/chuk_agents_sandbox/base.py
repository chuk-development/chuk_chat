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
from collections.abc import Mapping

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
        self._cwd_marker = f"__AGENTS_CWD_{secrets.token_hex(8)}__:"
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
        env: Mapping[str, str] | None = None,
    ) -> ProcessResult:
        """Execute one exact command string; enforce timeout by killing.

        ``env`` is extra environment for THIS process only (the user's secrets,
        docs/WIRE_CONTRACT.md "Secrets"). A backend passes it to the child
        process — never on a command line, never into the image, never into a
        file. ``None`` / empty: run exactly as before."""
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
        env: Mapping[str, str] | None = None,
    ) -> ProcessResult:
        """Run ``cmd`` with session persistence and bounded output.

        ``env`` rides into the child process only. The wrapper unsets those
        names before it re-dumps the session, so a secret never lands in the
        snapshot file and never reaches the next command through it."""
        if not self._session_initialized:
            self.init_session()

        extra = {k: v for k, v in (env or {}).items() if _is_env_name(k)}
        wrapped = self._wrap(cmd, unset=list(extra))
        raw = self._run_bash(
            wrapped, login=login, timeout=timeout, stdin=stdin, env=extra or None
        )

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
        self,
        cmd: str,
        *,
        timeout: int = 120,
        internal: bool = False,
        env: Mapping[str, str] | None = None,
    ) -> ProcessResult:
        """Adapter that satisfies the agent runtime's ``Environment`` protocol.

        ``internal`` marks plumbing the agent did not ask for (an availability
        probe, a journal commit). The sandbox runs it identically; only
        observers higher up use the flag to keep it out of the user's thread.
        ``env`` is the per-command extra environment (secrets); see :meth:`run`."""
        del internal
        return self.run(cmd, timeout=timeout, env=env)

    # Context-manager sugar so callers can ``with make_environment(...) as env``.
    def __enter__(self) -> "BaseEnvironment":
        return self

    def __exit__(self, *exc: object) -> None:
        self.cleanup()

    # ------------------------------------------------------------------ #
    # Internals
    # ------------------------------------------------------------------ #
    def _wrap(self, cmd: str, *, unset: list[str] | None = None) -> str:
        """Wrap a user command in the source/cd/redump/marker envelope.

        ``unset`` names the per-command environment (secrets) that must NOT be
        dumped into the session snapshot: they are unset after the user block
        and before ``declare -px`` runs, so the values live exactly as long as
        this one process."""
        snap = shlex.quote(self._snapshot_path)
        cwd = shlex.quote(self._cwd)
        marker = self._cwd_marker
        # Names only, validated in ``run``: nothing here can carry a value.
        forget = f"unset -v {' '.join(unset)} 2>/dev/null\n" if unset else ""
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
            f"{forget}"
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


def _is_env_name(name: object) -> bool:
    """True for a valid environment variable name. The only shape ``run``
    passes through, so an ``unset`` line can never carry anything else."""
    if not isinstance(name, str) or not name or len(name) > 128:
        return False
    head, tail = name[0], name[1:]
    return (head.isalpha() or head == "_") and all(c.isalnum() or c == "_" for c in tail)
