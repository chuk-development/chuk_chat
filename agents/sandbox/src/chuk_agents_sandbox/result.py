"""Process result value object and the Environment protocol.

``ProcessResult`` is the single shape every backend returns. It is kept
deliberately small and stable so the sibling ``../agent`` runtime can depend on
it: that runtime declares an ``Environment`` protocol whose sole method is
``run_bash(cmd, *, timeout=120) -> ProcessResult``. ``BaseEnvironment`` (and thus
every concrete backend) satisfies that protocol.
"""

from __future__ import annotations

from dataclasses import dataclass
from typing import Protocol, runtime_checkable


@dataclass(frozen=True, slots=True)
class ProcessResult:
    """The outcome of one command run inside an environment.

    Attributes:
        stdout: Captured standard output (already bounded, marker removed).
        stderr: Captured standard error (already bounded).
        exit_code: Shell exit status. ``-9`` marks a killed (timed-out) process.
        stdout_truncated: True if stdout was capped by the output limit.
        stderr_truncated: True if stderr was capped by the output limit.
        timed_out: True if the command was killed for exceeding its timeout.
    """

    stdout: str
    stderr: str
    exit_code: int
    stdout_truncated: bool = False
    stderr_truncated: bool = False
    timed_out: bool = False

    @property
    def ok(self) -> bool:
        """True when the command exited cleanly (status 0, no timeout)."""
        return self.exit_code == 0 and not self.timed_out


@runtime_checkable
class Environment(Protocol):
    """The minimal surface the agent runtime consumes.

    Any object with a matching ``run_bash`` is a valid environment. Concrete
    backends add ``run``, ``cleanup`` and more, but this is the contract seam.
    """

    def run_bash(
        self, cmd: str, *, timeout: int = 120, internal: bool = False
    ) -> ProcessResult: ...
