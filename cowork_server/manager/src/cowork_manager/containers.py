"""ContainerSupervisor — the real per-agent container lifecycle (§5, §6).

The Manager's job here is narrow and stated in the plan: *start/stop/supervise
the per-agent sandbox containers*. This is the concrete
:class:`~cowork_manager.supervisor.AgentSupervisor` that does it, on top of
``cowork_sandbox``'s label-keyed container lifecycle.

What it adds over the raw sandbox backend:

* **Roster-driven.** The workspace bind mount comes from the agent's roster row,
  so the container always sees the same directory the rest of the Manager
  believes the agent owns.
* **One environment per agent.** ``environment(agent_id)`` hands back the live
  :class:`~cowork_sandbox.BaseEnvironment` for that agent, creating it on first
  use, so the executor keeps talking to the same box across turns.
* **Stop keeps the box, destroy removes it.** :meth:`stop` stops the container;
  the agent's installed packages survive and the next :meth:`start` resumes it.
  :meth:`destroy` is the explicit "throw this Debian away".
* **Orphan reaping.** :meth:`reap_orphans` removes managed containers that no
  live session owns — call it at startup to clear what a killed run left behind.

Task-scoped children (subagents, §7.6) get their own container via
:meth:`task_environment`; those are torn down by ``cleanup()`` because their task
id is not ``default``.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import datetime, timezone

from cowork_sandbox import (
    DEFAULT_TASK_ID,
    BaseEnvironment,
    DockerCli,
    DockerEnvironment,
    DockerUnavailableError,
    reap_orphans,
    resolve_image,
)

from cowork_manager.roster import RosterStore
from cowork_manager.supervisor import AgentSupervisor, RuntimeState, RuntimeStatus

#: Resolves an agent id to the host directory to bind-mount, or ``None``.
WorkspaceResolver = Callable[[str], str | None]


def roster_workspace_resolver(roster: RosterStore) -> WorkspaceResolver:
    """Workspace resolver reading ``workspace_dir`` off the roster row."""

    def resolve(agent_id: str) -> str | None:
        agent = roster.get(agent_id)
        if agent is None:
            return None
        return agent.workspace_dir or None

    return resolve


@dataclass
class ContainerSupervisor(AgentSupervisor):
    """Per-agent Debian containers, one per roster agent.

    ``workspace_resolver`` decides what gets mounted; pass
    :func:`roster_workspace_resolver` for the normal case, or a lambda in tests.
    ``env_factory`` exists purely as a seam: production leaves it alone,
    tests substitute a fake environment and assert the lifecycle without docker.
    """

    workspace_resolver: WorkspaceResolver = lambda _agent_id: None
    image: str | None = None
    cli: DockerCli | None = None
    env_factory: Callable[..., BaseEnvironment] | None = None
    _envs: dict[str, BaseEnvironment] = field(default_factory=dict, init=False)
    _states: dict[str, RuntimeState] = field(default_factory=dict, init=False)

    def __post_init__(self) -> None:
        if self.cli is None:
            self.cli = DockerCli()
        self.image = resolve_image(self.image)

    # ------------------------------------------------------------------ #
    # Environment access
    # ------------------------------------------------------------------ #
    def _new_env(self, agent_id: str, task_id: str) -> BaseEnvironment:
        factory = self.env_factory or DockerEnvironment
        return factory(
            agent_id=agent_id,
            task_id=task_id,
            image=self.image,
            workdir=self.workspace_resolver(agent_id),
            cli=self.cli,
        )

    def environment(self, agent_id: str) -> BaseEnvironment:
        """The agent's session environment, created (but not started) on demand."""
        env = self._envs.get(agent_id)
        if env is None:
            env = self._new_env(agent_id, DEFAULT_TASK_ID)
            self._envs[agent_id] = env
        return env

    def task_environment(self, agent_id: str, task_id: str) -> BaseEnvironment:
        """A **task-scoped** environment for a subagent or one-off job.

        Not cached and not tracked: its ``cleanup()`` removes the container, so
        the caller owns it (``with`` it, or call ``cleanup()`` in a ``finally``).
        """
        if task_id == DEFAULT_TASK_ID:
            raise ValueError(
                f"task_id {DEFAULT_TASK_ID!r} is the agent's own session container; "
                "use environment() for that"
            )
        return self._new_env(agent_id, task_id)

    # ------------------------------------------------------------------ #
    # AgentSupervisor surface
    # ------------------------------------------------------------------ #
    def start(self, agent_id: str) -> RuntimeState:
        """Bring the agent's container up. Idempotent when already running."""
        current = self._states.get(agent_id)
        if current is not None and current.status is RuntimeStatus.RUNNING:
            return current
        self._states[agent_id] = RuntimeState(
            agent_id=agent_id, status=RuntimeStatus.STARTING
        )
        env = self.environment(agent_id)
        try:
            # One trivial command is what forces creation: the sandbox creates or
            # reuses the container lazily on first exec, and the exit code proves
            # the box actually answers.
            result = env.run_bash("true", timeout=120, internal=True)
        except DockerUnavailableError as exc:
            state = RuntimeState(
                agent_id=agent_id, status=RuntimeStatus.ERROR, detail=str(exc)
            )
            self._states[agent_id] = state
            return state
        if not result.ok:
            state = RuntimeState(
                agent_id=agent_id,
                status=RuntimeStatus.ERROR,
                detail=(result.stderr or "probe command failed").strip(),
            )
            self._states[agent_id] = state
            return state
        state = RuntimeState(
            agent_id=agent_id,
            status=RuntimeStatus.RUNNING,
            container_id=getattr(env, "container_id", None),
            started_at=datetime.now(timezone.utc),
        )
        self._states[agent_id] = state
        return state

    def stop(self, agent_id: str) -> RuntimeState:
        """Stop the container but keep it, so the next start resumes the same box."""
        env = self._envs.get(agent_id)
        container = getattr(env, "container_id", None) if env is not None else None
        if container is not None and self.cli is not None:
            self.cli.run("stop", container, timeout=60)
        if env is not None:
            # Releases the in-process handle; a default-task container is left in
            # place on purpose (that is the sandbox's cleanup contract).
            env.cleanup()
        self._envs.pop(agent_id, None)
        state = RuntimeState(agent_id=agent_id, status=RuntimeStatus.STOPPED)
        self._states[agent_id] = state
        return state

    def status(self, agent_id: str) -> RuntimeState:
        return self._states.get(
            agent_id, RuntimeState(agent_id=agent_id, status=RuntimeStatus.STOPPED)
        )

    def running(self) -> list[str]:
        """Agent ids whose container this supervisor believes is up."""
        return [
            aid
            for aid, st in self._states.items()
            if st.status is RuntimeStatus.RUNNING
        ]

    # ------------------------------------------------------------------ #
    # Destruction + reaping
    # ------------------------------------------------------------------ #
    def destroy(self, agent_id: str) -> RuntimeState:
        """Throw the agent's Debian away (container removed, workspace untouched)."""
        env = self._envs.pop(agent_id, None)
        if env is None:
            env = self._new_env(agent_id, DEFAULT_TASK_ID)
        remove = getattr(env, "remove", None)
        if callable(remove):
            remove()
        else:  # pragma: no cover - non-docker backends
            env.cleanup()
        state = RuntimeState(agent_id=agent_id, status=RuntimeStatus.STOPPED)
        self._states[agent_id] = state
        return state

    def live_session_ids(self) -> set[str]:
        """Session ids this supervisor is currently responsible for."""
        ids: set[str] = set()
        for env in self._envs.values():
            session = getattr(env, "session_id", None)
            if session:
                ids.add(session)
        return ids

    def reap_orphans(self) -> list[str]:
        """Remove managed containers no live session of ours owns.

        At startup (nothing tracked yet) this clears every container a killed
        previous Manager left behind — the case the plan calls out explicitly.
        """
        return reap_orphans(active_session_ids=self.live_session_ids(), cli=self.cli)

    def shutdown(self) -> None:
        """Release every handle. Default-task containers survive by design."""
        for agent_id in list(self._envs):
            self.stop(agent_id)
