"""A real ``AgentSupervisor`` (task 4).

``cowork_manager`` ships the :class:`~cowork_manager.AgentSupervisor` ABC and an
in-memory ``StubSupervisor``. :class:`ExecutorSupervisor` is the real thing: it
starts an :class:`~cowork_executor.executor.Executor` for a roster agent as an
in-process background task and can stop it, reporting the same
:class:`~cowork_manager.RuntimeState` the stub does.

Building an executor needs per-agent crypto material and a transport endpoint,
which the Manager wires at pairing time. That wiring is injected as an
``executor_factory`` so this class owns only the lifecycle — start, track, stop —
which is the supervisor's real job. The factory receives the roster
:class:`~cowork_manager.Agent` (its ``workspace_dir`` becomes the sandbox
workdir).
"""

from __future__ import annotations

from collections.abc import Callable
from datetime import datetime, timezone

from cowork_manager import (
    Agent,
    AgentSupervisor,
    RosterStore,
    RuntimeState,
    RuntimeStatus,
)

from .executor import Executor

# Given a roster agent, build a ready (not-yet-started) Executor for it.
ExecutorFactory = Callable[[Agent], Executor]


class ExecutorSupervisor(AgentSupervisor):
    """Starts/stops one :class:`Executor` per roster agent, in-process."""

    def __init__(self, roster: RosterStore, executor_factory: ExecutorFactory) -> None:
        self._roster = roster
        self._factory = executor_factory
        self._executors: dict[str, Executor] = {}
        self._states: dict[str, RuntimeState] = {}

    @staticmethod
    def _now() -> datetime:
        return datetime.now(timezone.utc)

    def start(self, agent_id: str) -> RuntimeState:
        current = self._states.get(agent_id)
        if current is not None and current.status is RuntimeStatus.RUNNING:
            return current

        agent = self._roster.get(agent_id)
        if agent is None:
            state = RuntimeState(
                agent_id=agent_id,
                status=RuntimeStatus.ERROR,
                detail="unknown agent",
            )
            self._states[agent_id] = state
            return state

        try:
            executor = self._factory(agent)
            executor.start()
        except Exception as exc:  # a broken factory is an ERROR state, not a crash
            state = RuntimeState(
                agent_id=agent_id,
                status=RuntimeStatus.ERROR,
                detail=f"{type(exc).__name__}: {exc}",
            )
            self._states[agent_id] = state
            return state

        self._executors[agent_id] = executor
        state = RuntimeState(
            agent_id=agent_id,
            status=RuntimeStatus.RUNNING,
            container_id=executor.name,
            started_at=self._now(),
        )
        self._states[agent_id] = state
        return state

    def stop(self, agent_id: str) -> RuntimeState:
        executor = self._executors.pop(agent_id, None)
        if executor is not None:
            executor.stop()
        state = RuntimeState(agent_id=agent_id, status=RuntimeStatus.STOPPED)
        self._states[agent_id] = state
        return state

    def status(self, agent_id: str) -> RuntimeState:
        return self._states.get(
            agent_id, RuntimeState(agent_id=agent_id, status=RuntimeStatus.STOPPED)
        )

    def executor(self, agent_id: str) -> Executor | None:
        """The live executor for an agent, if running (for direct wiring/tests)."""
        return self._executors.get(agent_id)

    def running(self) -> list[str]:
        return [
            aid
            for aid, st in self._states.items()
            if st.status is RuntimeStatus.RUNNING
        ]
