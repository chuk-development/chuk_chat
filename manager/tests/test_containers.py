"""ContainerSupervisor tests — the Manager's per-agent container lifecycle (§6).

The supervisor is exercised through an injected fake environment, so the
*control plane* (start is idempotent, stop keeps the box, destroy removes it,
which sessions count as live) is proven without a container runtime. A
docker-gated test at the end runs the same supervisor against a real daemon.
"""

from __future__ import annotations

import os
import uuid

import pytest

from cowork_manager import ContainerSupervisor, RosterStore, RuntimeStatus
from cowork_manager.containers import roster_workspace_resolver
from cowork_sandbox import DEFAULT_TASK_ID, DockerUnavailableError, ProcessResult


class FakeEnv:
    """Minimal stand-in for a ``DockerEnvironment``."""

    instances: list["FakeEnv"] = []

    def __init__(self, *, agent_id, task_id, image, workdir, cli, fail=False):
        self.agent_id = agent_id
        self.task_id = task_id
        self.image = image
        self.workdir = workdir
        self.cli = cli
        self.session_id = uuid.uuid4().hex[:8]
        self.container_id = f"fake-{agent_id}-{task_id}"
        self.commands: list[str] = []
        self.cleaned = 0
        self.removed = 0
        self.fail = fail
        FakeEnv.instances.append(self)

    def run_bash(self, cmd, *, timeout=120, internal=False):
        self.commands.append(cmd)
        if self.fail:
            return ProcessResult("", "boom", 1)
        return ProcessResult("", "", 0)

    def cleanup(self):
        self.cleaned += 1

    def remove(self):
        self.removed += 1
        return True


@pytest.fixture(autouse=True)
def _clear_instances():
    FakeEnv.instances.clear()
    yield
    FakeEnv.instances.clear()


class FakeCli:
    binary = "docker"

    def __init__(self):
        self.calls: list[tuple[str, ...]] = []

    def available(self) -> bool:
        return True

    def run(self, *args, timeout=None):
        self.calls.append(args)
        from cowork_sandbox import CliResult

        return CliResult("", "", 0)


def make_supervisor(**kwargs) -> ContainerSupervisor:
    return ContainerSupervisor(
        workspace_resolver=kwargs.pop("workspace_resolver", lambda _a: "/tmp/ws"),
        image=kwargs.pop("image", "cowork-base:test"),
        cli=kwargs.pop("cli", FakeCli()),
        env_factory=kwargs.pop("env_factory", FakeEnv),
        **kwargs,
    )


# ------------------------------------------------------------------ start


def test_start_creates_one_container_and_reports_it_running():
    sup = make_supervisor()
    state = sup.start("agent-1")
    assert state.status is RuntimeStatus.RUNNING
    assert state.container_id == "fake-agent-1-default"
    assert len(FakeEnv.instances) == 1
    # The probe command is what forces the container into existence.
    assert FakeEnv.instances[0].commands == ["true"]


def test_start_is_idempotent():
    sup = make_supervisor()
    first = sup.start("agent-1")
    second = sup.start("agent-1")
    assert second == first
    assert len(FakeEnv.instances) == 1


def test_start_uses_the_agents_workspace_as_the_mount():
    sup = make_supervisor(workspace_resolver=lambda aid: f"/home/user/.cowork/{aid}")
    sup.start("agent-7")
    assert FakeEnv.instances[0].workdir == "/home/user/.cowork/agent-7"


def test_start_reports_error_when_the_runtime_is_missing():
    class Missing(FakeEnv):
        def run_bash(self, cmd, *, timeout=120, internal=False):
            raise DockerUnavailableError("no daemon")

    sup = make_supervisor(env_factory=Missing)
    state = sup.start("agent-1")
    assert state.status is RuntimeStatus.ERROR
    assert "no daemon" in (state.detail or "")


def test_start_reports_error_when_the_probe_command_fails():
    def factory(**kwargs):
        return FakeEnv(**kwargs, fail=True)

    sup = make_supervisor(env_factory=factory)
    state = sup.start("agent-1")
    assert state.status is RuntimeStatus.ERROR
    assert "boom" in (state.detail or "")


# ------------------------------------------------------------ stop/destroy


def test_stop_stops_the_container_but_does_not_remove_it():
    cli = FakeCli()
    sup = make_supervisor(cli=cli)
    sup.start("agent-1")
    state = sup.stop("agent-1")
    assert state.status is RuntimeStatus.STOPPED
    assert ("stop", "fake-agent-1-default") in cli.calls
    assert FakeEnv.instances[0].removed == 0
    assert FakeEnv.instances[0].cleaned == 1


def test_start_after_stop_builds_a_fresh_handle_for_the_same_agent():
    sup = make_supervisor()
    sup.start("agent-1")
    sup.stop("agent-1")
    sup.start("agent-1")
    assert len(FakeEnv.instances) == 2
    assert sup.status("agent-1").status is RuntimeStatus.RUNNING


def test_destroy_removes_the_container():
    sup = make_supervisor()
    sup.start("agent-1")
    state = sup.destroy("agent-1")
    assert state.status is RuntimeStatus.STOPPED
    assert FakeEnv.instances[0].removed == 1


def test_destroy_works_for_an_agent_this_process_never_started():
    sup = make_supervisor()
    sup.destroy("never-started")
    assert FakeEnv.instances[0].removed == 1


def test_status_of_an_unknown_agent_is_stopped():
    sup = make_supervisor()
    assert sup.status("nobody").status is RuntimeStatus.STOPPED


def test_running_lists_only_started_agents():
    sup = make_supervisor()
    sup.start("a")
    sup.start("b")
    sup.stop("a")
    assert sup.running() == ["b"]


def test_shutdown_releases_every_handle():
    sup = make_supervisor()
    sup.start("a")
    sup.start("b")
    sup.shutdown()
    assert sup.running() == []
    assert all(env.cleaned == 1 for env in FakeEnv.instances)
    assert all(env.removed == 0 for env in FakeEnv.instances)


# ----------------------------------------------------------- task scoping


def test_task_environment_is_task_scoped_and_not_cached():
    sup = make_supervisor()
    one = sup.task_environment("agent-1", "subagent-a")
    two = sup.task_environment("agent-1", "subagent-a")
    assert one is not two
    assert one.task_id == "subagent-a"
    # It is not the agent's session container, so it is not tracked as one.
    assert sup.running() == []


def test_task_environment_refuses_the_default_task_id():
    sup = make_supervisor()
    with pytest.raises(ValueError, match=DEFAULT_TASK_ID):
        sup.task_environment("agent-1", DEFAULT_TASK_ID)


# --------------------------------------------------------------- reaping


def test_live_session_ids_covers_started_agents_only():
    sup = make_supervisor()
    sup.start("a")
    sup.start("b")
    live = sup.live_session_ids()
    assert live == {env.session_id for env in FakeEnv.instances}
    sup.stop("a")
    assert len(sup.live_session_ids()) == 1


def test_reap_orphans_passes_the_live_sessions_to_the_reaper(monkeypatch):
    seen: dict[str, object] = {}

    def fake_reap(*, active_session_ids, cli):
        seen["sessions"] = set(active_session_ids)
        seen["cli"] = cli
        return ["cowork-old"]

    monkeypatch.setattr("cowork_manager.containers.reap_orphans", fake_reap)
    cli = FakeCli()
    sup = make_supervisor(cli=cli)
    sup.start("a")
    assert sup.reap_orphans() == ["cowork-old"]
    assert seen["sessions"] == {FakeEnv.instances[0].session_id}
    assert seen["cli"] is cli


# ---------------------------------------------------------------- roster


def test_roster_workspace_resolver_reads_the_agent_row():
    roster = RosterStore(":memory:")
    try:
        agent = roster.create(workspace_dir="/home/user/.cowork/agents/ada")
        resolve = roster_workspace_resolver(roster)
        assert resolve(agent.id) == "/home/user/.cowork/agents/ada"
        assert resolve("missing") is None
    finally:
        roster.close()


def test_roster_workspace_resolver_treats_an_empty_dir_as_none():
    roster = RosterStore(":memory:")
    try:
        agent = roster.create(workspace_dir="")
        assert roster_workspace_resolver(roster)(agent.id) is None
    finally:
        roster.close()


# ------------------------------------------------------- real docker path


def _docker_ready() -> bool:
    from cowork_sandbox import docker_available

    return docker_available()


@pytest.mark.skipif(not _docker_ready(), reason="docker CLI or daemon unavailable")
def test_supervisor_drives_a_real_container(tmp_path):
    """The whole path: start, run in the box, see the mount, destroy, reap."""
    image = os.environ.get("COWORK_TEST_IMAGE", "debian:stable-slim")
    agent_id = f"pytest-sup-{uuid.uuid4().hex[:8]}"
    workspace = tmp_path / "ws"
    workspace.mkdir()
    sup = ContainerSupervisor(
        workspace_resolver=lambda _a: str(workspace), image=image
    )
    try:
        state = sup.start(agent_id)
        assert state.status is RuntimeStatus.RUNNING, state.detail
        assert state.container_id

        env = sup.environment(agent_id)
        result = env.run_bash("echo from-the-agent > mounted.txt && pwd")
        assert result.ok, result.stderr
        assert (workspace / "mounted.txt").exists()

        # stop keeps the box: starting again finds the same container
        sup.stop(agent_id)
        again = sup.start(agent_id)
        assert again.container_id == state.container_id
    finally:
        sup.destroy(agent_id)
    from cowork_sandbox import find_agent_container

    assert find_agent_container(agent_id=agent_id) is None
