"""Agent supervisor — per-agent sandbox lifecycle (§5, §6).

The Manager starts/stops/supervises one container per agent. The real lifecycle
(a ``BaseEnvironment`` subclass driving a Debian container, §6) wires to
``../sandbox`` later. This module fixes the *interface* the rest of the Manager
codes against, plus a working in-memory stub so the scheduler and relay can be
exercised now without a container runtime.
"""

from __future__ import annotations

import abc
from dataclasses import dataclass, field, replace
from datetime import datetime, timezone
from enum import Enum


class RuntimeStatus(str, Enum):
    """Lifecycle state of an agent's sandbox."""

    STOPPED = "stopped"
    STARTING = "starting"
    RUNNING = "running"
    STOPPING = "stopping"
    ERROR = "error"


@dataclass(frozen=True, slots=True)
class RuntimeState:
    """A snapshot of one agent's runtime.

    ``container_id`` is the sandbox handle a real backend fills in; the stub
    leaves it ``None``. ``detail`` carries an error message when
    ``status`` is :attr:`RuntimeStatus.ERROR`.
    """

    agent_id: str
    status: RuntimeStatus = RuntimeStatus.STOPPED
    container_id: str | None = None
    started_at: datetime | None = None
    detail: str | None = None


class AgentSupervisor(abc.ABC):
    """Control-plane surface for per-agent sandbox lifecycle.

    A real subclass drives a container runtime; the two-method sandbox surface
    (§6) sits *below* this in ``../sandbox``. This interface is what the Manager
    (scheduler, relay bridge, roster wiring) depends on.
    """

    @abc.abstractmethod
    def start(self, agent_id: str) -> RuntimeState:
        """Bring an agent's sandbox up. Idempotent when already running."""

    @abc.abstractmethod
    def stop(self, agent_id: str) -> RuntimeState:
        """Tear an agent's sandbox down. Idempotent when already stopped."""

    @abc.abstractmethod
    def status(self, agent_id: str) -> RuntimeState:
        """Return the current runtime snapshot (STOPPED if never started)."""


@dataclass
class StubSupervisor(AgentSupervisor):
    """In-memory supervisor that tracks state without touching a runtime.

    Every transition is recorded so tests and the scheduler can assert the
    lifecycle without a container. Swapping in the real backend changes nothing
    the caller sees.
    """

    _states: dict[str, RuntimeState] = field(default_factory=dict)

    def _now(self) -> datetime:
        return datetime.now(timezone.utc)

    def start(self, agent_id: str) -> RuntimeState:
        current = self._states.get(agent_id)
        if current is not None and current.status is RuntimeStatus.RUNNING:
            return current
        state = RuntimeState(
            agent_id=agent_id,
            status=RuntimeStatus.RUNNING,
            container_id=f"stub-{agent_id}",
            started_at=self._now(),
        )
        self._states[agent_id] = state
        return state

    def stop(self, agent_id: str) -> RuntimeState:
        current = self._states.get(agent_id)
        if current is None or current.status is RuntimeStatus.STOPPED:
            state = RuntimeState(agent_id=agent_id, status=RuntimeStatus.STOPPED)
            self._states[agent_id] = state
            return state
        state = replace(
            current,
            status=RuntimeStatus.STOPPED,
            container_id=None,
            started_at=None,
        )
        self._states[agent_id] = state
        return state

    def status(self, agent_id: str) -> RuntimeState:
        return self._states.get(
            agent_id, RuntimeState(agent_id=agent_id, status=RuntimeStatus.STOPPED)
        )

    def running(self) -> list[str]:
        """Agent ids currently running — a convenience for the scheduler."""
        return [
            aid
            for aid, st in self._states.items()
            if st.status is RuntimeStatus.RUNNING
        ]
