"""Execution environment protocol (§7.3 run_command tool).

The agent runtime never talks to a shell directly. It talks to an
``Environment``. The real sandbox (``../sandbox``) implements this protocol and
is wired at integration time. The runtime depends only on the protocol, so it
stays testable and sandbox-agnostic.

``LocalEnvironment`` is a trivial subprocess stand-in for tests and local runs.
"""

from __future__ import annotations

import os
import subprocess
import time
from collections.abc import Mapping
from dataclasses import dataclass
from typing import Protocol, runtime_checkable

from .child_env import child_env


@dataclass
class ProcessResult:
    """The outcome of one shell command."""

    exit_code: int
    stdout: str
    stderr: str
    duration_s: float = 0.0
    timed_out: bool = False

    @property
    def ok(self) -> bool:
        return self.exit_code == 0 and not self.timed_out


@runtime_checkable
class Environment(Protocol):
    """Where a command runs. The one seam between runtime and sandbox."""

    def run_bash(
        self,
        cmd: str,
        *,
        timeout: int = 120,
        internal: bool = False,
        env: Mapping[str, str] | None = None,
    ) -> ProcessResult:
        """Run one shell command and return its result. Never raises for a
        non-zero exit or a timeout — those are reported in the result.

        ``internal=True`` marks plumbing the *agent* did not ask for — an
        availability probe, a git commit for the action journal. It is the same
        shell, but it is not agent activity, so observers must not report it to
        the user as a tool call. Without this flag a `command -v tmux` probe
        shows up in the chat thread as work the agent did.

        ``env`` (docs/WIRE_CONTRACT.md, "Secrets") is extra environment for
        THIS command's child process only — the user's secrets, passed by
        ``run_command`` / ``python`` and by nothing else. It must never be
        written to the shell session, a snapshot or a file. Callers pass it
        only when they have something to pass, so an environment that does not
        know the keyword keeps working."""
        ...


class LocalEnvironment:
    """A subprocess-backed ``Environment``. Stand-in for the real sandbox.

    Runs commands on the local host with ``bash -c``. No isolation — this is a
    development stand-in only. The production sandbox replaces it.
    """

    def run_bash(
        self,
        cmd: str,
        *,
        timeout: int = 120,
        internal: bool = False,
        env: Mapping[str, str] | None = None,
    ) -> ProcessResult:
        del internal  # nothing observes a local run
        start = time.monotonic()
        try:
            proc = subprocess.Popen(
                ["bash", "-c", cmd],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                # Own process group, so a timeout reaches the whole tree.
                start_new_session=True,
                # An allowlist of the host environment plus the granted secrets
                # (bead B9); nothing here keeps a shell alive, so nothing
                # outlives this call.
                env=child_env(env),
            )
            out, err = proc.communicate(timeout=timeout)
        except subprocess.TimeoutExpired:
            terminate_group(proc)
            out, err = proc.communicate()
            return ProcessResult(
                exit_code=124,
                stdout=out or "",
                stderr=err or "",
                duration_s=time.monotonic() - start,
                timed_out=True,
            )
        return ProcessResult(
            exit_code=proc.returncode,
            stdout=out,
            stderr=err,
            duration_s=time.monotonic() - start,
            timed_out=False,
        )


#: SIGTERM first, then SIGKILL after this many seconds (research item 36).
KILL_GRACE_S = 3.0


def terminate_group(proc: subprocess.Popen, grace: float = KILL_GRACE_S) -> None:
    """SIGTERM the process group of ``proc`` (started with
    ``start_new_session``), SIGKILL what is left after ``grace`` seconds."""
    import signal

    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except (ProcessLookupError, PermissionError):
        proc.kill()
        return
    try:
        proc.wait(timeout=grace)
    except subprocess.TimeoutExpired:
        pass
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except (ProcessLookupError, PermissionError):
        pass
    if proc.poll() is None:
        proc.kill()
