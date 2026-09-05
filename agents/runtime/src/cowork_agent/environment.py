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
            proc = subprocess.run(
                ["bash", "-c", cmd],
                capture_output=True,
                text=True,
                timeout=timeout,
                # The secrets ride the child's environment only: nothing here
                # keeps a shell alive, so nothing outlives this call.
                env={**os.environ, **env} if env else None,
            )
        except subprocess.TimeoutExpired as exc:
            return ProcessResult(
                exit_code=124,
                stdout=exc.stdout or "" if isinstance(exc.stdout, str) else "",
                stderr=exc.stderr or "" if isinstance(exc.stderr, str) else "",
                duration_s=time.monotonic() - start,
                timed_out=True,
            )
        return ProcessResult(
            exit_code=proc.returncode,
            stdout=proc.stdout,
            stderr=proc.stderr,
            duration_s=time.monotonic() - start,
            timed_out=False,
        )
