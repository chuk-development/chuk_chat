"""Agent<->sandbox adapter (task 1).

``cowork_agent`` runs shell through an ``Environment`` whose sole method is
``run_bash(cmd, *, timeout=120) -> ProcessResult``. ``cowork_sandbox``'s
``BaseEnvironment`` already exposes exactly that method (``base.py:132``), so the
two protocols were designed compatible.

They differ in **one field of the result**. The agent's ``run_command`` tool
handler reads ``result.duration_s`` (``cowork_agent/tools.py:34``), but the
sandbox ``ProcessResult`` has no ``duration_s`` — it carries
``stdout_truncated`` / ``stderr_truncated`` instead. Passing a raw sandbox
environment to the agent would raise ``AttributeError`` on the first command.

``SandboxEnvironment`` is the thin shim that closes that gap: it wraps a sandbox
``BaseEnvironment``, times each call, and returns the agent's own
``ProcessResult`` (with ``duration_s`` filled in). No sibling package is
modified — the adaptation lives entirely here.

It also carries an optional ``on_run`` callback so the executor can stream a
"tool" event the instant a command finishes, without the agent loop knowing
anything about frames. Leave ``on_run`` ``None`` and it is a pure adapter.
"""

from __future__ import annotations

import time
from collections.abc import Callable

from cowork_agent import ProcessResult as AgentProcessResult
from cowork_sandbox import BaseEnvironment

# (command, agent-shaped result) -> None
RunObserver = Callable[[str, AgentProcessResult], None]


class SandboxEnvironment:
    """Adapts a sandbox ``BaseEnvironment`` to the agent runtime's ``Environment``
    protocol, adding the ``duration_s`` field the agent tool handler expects."""

    def __init__(
        self,
        inner: BaseEnvironment,
        *,
        on_run: RunObserver | None = None,
    ) -> None:
        self._inner = inner
        # Settable so the executor can rebind it per task and clear it after.
        self.on_run = on_run

    @property
    def inner(self) -> BaseEnvironment:
        return self._inner

    def cancel(self) -> None:
        """Abort the command in flight (§7.1). Forwards to the sandbox backend.

        The executor hangs this on the task's ``KillSwitch``, so a Stop pressed
        during a ten-minute ``run_command`` kills the command instead of waiting
        for it. Backends that cannot interrupt themselves inherit a no-op and the
        run ends at the loop's next poll instead.
        """
        self._inner.cancel()

    def run_bash(
        self, cmd: str, *, timeout: int = 120, internal: bool = False
    ) -> AgentProcessResult:
        start = time.monotonic()
        raw = self._inner.run_bash(cmd, timeout=timeout)
        result = AgentProcessResult(
            exit_code=raw.exit_code,
            stdout=raw.stdout,
            stderr=raw.stderr,
            duration_s=time.monotonic() - start,
            timed_out=raw.timed_out,
        )
        # Internal plumbing (availability probes, journal commits) runs on the
        # same shell but is not agent activity — reporting it would put
        # `command -v tmux` in the user's thread as a tool call.
        observer = self.on_run
        if observer is not None and not internal:
            observer(cmd, result)
        return result
