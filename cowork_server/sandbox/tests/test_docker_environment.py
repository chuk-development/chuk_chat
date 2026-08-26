"""Docker backend tests against a real daemon. Skipped whole if docker is absent.

These prove the lifecycle rules end to end: label-keyed reuse, the bind mount in
both directions, snapshot persistence across separate ``docker exec`` calls, and
the orphan reaper. ``test_lifecycle.py`` covers the same decisions with a fake
CLI, so nothing here is the only cover for a rule.

Every container these tests create carries a unique agent id and is removed in a
``finally``; the reaper test filters on its own agent ids, so a developer's own
containers are never at risk.
"""

from __future__ import annotations

import os
import subprocess
import threading
import time
import uuid

import pytest

from cowork_sandbox import (
    CONTAINER_WORKSPACE,
    LABEL_AGENT,
    LABEL_MANAGED,
    DockerEnvironment,
    ProcessResult,
    docker_available,
    find_agent_container,
    list_containers,
    make_environment,
    reap_orphans,
)

pytestmark = pytest.mark.skipif(
    not docker_available(),
    reason="docker CLI or daemon unavailable in this environment",
)

#: Small image every developer already has. Point this at ``cowork-base:latest``
#: to exercise the real agent image (passwordless sudo, python 3.12, tmux).
IMAGE = os.environ.get("COWORK_TEST_IMAGE", "debian:stable-slim")


def unique_agent() -> str:
    return f"pytest-{uuid.uuid4().hex[:10]}"


def docker_ps(*filters: str) -> str:
    proc = subprocess.run(
        ["docker", "ps", "-aq", *[arg for f in filters for arg in ("--filter", f)]],
        capture_output=True,
        text=True,
        timeout=30,
    )
    return proc.stdout.strip()


@pytest.fixture()
def env():
    e = DockerEnvironment(image=IMAGE, agent_id=unique_agent())
    try:
        yield e
    finally:
        e.remove()


# ------------------------------------------------------------------ basics


def test_runs_inside_container(env):
    result = env.run("cat /etc/os-release")
    assert result.ok, result.stderr
    assert "debian" in result.stdout.lower()


def test_env_and_cwd_persist_across_commands(env):
    first = env.run("export TOKEN=in_container && cd /tmp")
    assert first.ok, first.stderr
    second = env.run('echo "$TOKEN @ $(pwd)"')
    assert second.ok, second.stderr
    assert "in_container" in second.stdout
    assert "/tmp" in second.stdout
    assert env.cwd == "/tmp"


def test_snapshot_carries_aliases_and_functions_across_three_calls(env):
    """Snapshot-file persistence, the §6 steal: no long-lived shell, yet the
    session survives — env var, alias, function and cwd, over separate execs."""
    assert env.run("export STAGE=one").ok
    assert env.run("alias hello='echo aliased'; greet() { echo greeted; }").ok
    assert env.run("cd /var && export STAGE=two").ok
    result = env.run('echo "$STAGE $(pwd)"; hello; greet')
    assert result.ok, result.stderr
    assert "two /var" in result.stdout
    assert "aliased" in result.stdout
    assert "greeted" in result.stdout
    assert env.cwd == "/var"


def test_run_bash_protocol_shape(env):
    result = env.run_bash("echo docker-protocol", timeout=30)
    assert isinstance(result, ProcessResult)
    assert "docker-protocol" in result.stdout


def test_factory_builds_docker():
    e = make_environment("docker", image=IMAGE, agent_id=unique_agent())
    try:
        assert isinstance(e, DockerEnvironment)
    finally:
        e.remove()


# ------------------------------------------------------------- bind mount


def test_workspace_bind_mount_is_visible_both_ways(tmp_path):
    workspace = tmp_path / "agent-workspace"
    workspace.mkdir()
    (workspace / "from_host.txt").write_text("written on the host\n", encoding="utf-8")

    e = DockerEnvironment(image=IMAGE, agent_id=unique_agent(), workdir=str(workspace))
    try:
        seen = e.run("cat from_host.txt")
        assert seen.ok, seen.stderr
        assert "written on the host" in seen.stdout
        # The initial cwd IS the mount, which is what the agent's tools assume.
        assert e.cwd == CONTAINER_WORKSPACE

        made = e.run("echo written in the container > from_container.txt")
        assert made.ok, made.stderr
    finally:
        e.remove()

    # ...and the host sees it, which is what the ffmpeg passthrough needs (§9).
    produced = workspace / "from_container.txt"
    assert produced.exists()
    assert "written in the container" in produced.read_text(encoding="utf-8")


def test_files_written_in_the_container_belong_to_the_host_user(tmp_path):
    """Wrong ownership here would break the git-versioned workspace on the host."""
    workspace = tmp_path / "owned"
    workspace.mkdir()
    e = DockerEnvironment(image=IMAGE, agent_id=unique_agent(), workdir=str(workspace))
    try:
        assert e.run("echo owner-check > owned.txt").ok
    finally:
        e.remove()
    created = workspace / "owned.txt"
    assert created.exists()
    assert created.stat().st_uid == os.getuid()


# ---------------------------------------------------------------- reuse


def test_second_environment_reuses_the_same_container():
    agent = unique_agent()
    first = DockerEnvironment(image=IMAGE, agent_id=agent)
    try:
        assert first.run("touch /tmp/marker-from-first").ok
        container_id = first.container_id
        # Session over: the agent's own box stays up on purpose.
        first.cleanup()

        second = DockerEnvironment(image=IMAGE, agent_id=agent)
        try:
            found = second.run("test -f /tmp/marker-from-first && echo reused")
            assert found.ok, found.stderr
            assert "reused" in found.stdout
            assert second.container_id == container_id
            assert second.reused_container is True
        finally:
            second.remove()
    finally:
        first.remove()


def test_a_stopped_container_is_started_again_and_keeps_its_state():
    agent = unique_agent()
    first = DockerEnvironment(image=IMAGE, agent_id=agent)
    try:
        assert first.run("echo survived > /tmp/persisted.txt").ok
        subprocess.run(["docker", "stop", first.container_id], capture_output=True, timeout=60)

        second = DockerEnvironment(image=IMAGE, agent_id=agent)
        try:
            result = second.run("cat /tmp/persisted.txt")
            assert result.ok, result.stderr
            assert "survived" in result.stdout
        finally:
            second.remove()
    finally:
        first.remove()


def test_two_agents_never_share_a_container():
    one = DockerEnvironment(image=IMAGE, agent_id=unique_agent())
    two = DockerEnvironment(image=IMAGE, agent_id=unique_agent())
    try:
        assert one.run("touch /tmp/only-in-one").ok
        result = two.run("test -f /tmp/only-in-one && echo shared || echo isolated")
        assert "isolated" in result.stdout
        assert one.container_id != two.container_id
    finally:
        one.remove()
        two.remove()


# --------------------------------------------------------------- teardown


def test_labels_are_set_and_a_task_scoped_container_is_torn_down():
    agent = unique_agent()
    env = DockerEnvironment(image=IMAGE, agent_id=agent, task_id="subagent-1")
    try:
        assert env.run("true").ok
        assert docker_ps(f"label={LABEL_AGENT}={agent}") != ""
        assert env.container_label(LABEL_MANAGED) == "true"
    finally:
        env.cleanup()  # task_id != default -> the container must be gone
    assert docker_ps(f"label={LABEL_AGENT}={agent}") == ""


def test_default_container_survives_cleanup_and_the_reaper_collects_it():
    agent = unique_agent()
    env = DockerEnvironment(image=IMAGE, agent_id=agent)
    try:
        assert env.run("true").ok
        env.cleanup()
        # Still there: this is the box the agent installed into.
        assert find_agent_container(agent_id=agent) is not None

        # A fresh Manager with nothing live reaps it as an orphan.
        reaped = reap_orphans(active_session_ids=set())
        assert any(agent in name for name in reaped), reaped
        assert find_agent_container(agent_id=agent) is None
    finally:
        DockerEnvironment(image=IMAGE, agent_id=agent).remove()


def test_reaper_keeps_a_container_whose_session_is_live():
    agent = unique_agent()
    env = DockerEnvironment(image=IMAGE, agent_id=agent)
    try:
        assert env.run("true").ok
        reaped = reap_orphans(active_session_ids={env.session_id})
        assert all(agent not in name for name in reaped)
        assert find_agent_container(agent_id=agent) is not None
    finally:
        env.remove()


def test_managed_containers_are_all_labelled_for_the_reaper():
    """The reaper only ever looks at ``cowork.managed=true``; every container we
    create must therefore carry it, or it becomes unreapable litter."""
    agent = unique_agent()
    env = DockerEnvironment(image=IMAGE, agent_id=agent)
    try:
        assert env.run("true").ok
        managed = list_containers(filters={LABEL_MANAGED: "true", LABEL_AGENT: agent})
        assert [c.id for c in managed] == [env.container_id]
    finally:
        env.remove()


def test_timeout_kills_the_command_but_keeps_the_container(env):
    result = env.run("sleep 30", timeout=2)
    assert result.timed_out is True
    assert result.exit_code == -9
    # The box is still usable: only the command died, not the agent's Debian.
    assert env.run("echo alive").stdout.strip().endswith("alive")


def test_cancel_kills_the_command_in_flight_but_keeps_the_container(env):
    """The §7.1 Stop reaching into the container: the exec client AND the tree it
    started inside must die, or the command would keep running in a box we
    deliberately keep alive for the next turn.

    The marker is checked with a plain ``docker exec``, never through ``env``:
    one environment serves one command thread by construction (it tracks one cwd,
    one snapshot and one in-flight process), so a second caller would race it.
    """
    marker = "/tmp/cowork-cancel-marker"
    env.run(f"rm -f {marker}")
    container = env.container_id
    assert container is not None
    outcome: dict[str, ProcessResult] = {}

    def work() -> None:
        outcome["r"] = env.run(f"touch {marker} && sleep 90", timeout=180)

    def marker_exists() -> bool:
        probe = subprocess.run(
            ["docker", "exec", container, "test", "-e", marker],
            capture_output=True,
            timeout=30,
        )
        return probe.returncode == 0

    worker = threading.Thread(target=work, daemon=True)
    worker.start()
    deadline = time.monotonic() + 30.0
    while not marker_exists() and time.monotonic() < deadline:
        time.sleep(0.05)
    assert marker_exists(), "the command never started in the container"

    start = time.monotonic()
    env.cancel()
    worker.join(30.0)
    assert not worker.is_alive(), "run() never returned after the cancel"
    assert time.monotonic() - start < 20.0
    assert outcome["r"].exit_code != 0

    # No leftover `sleep 90` in the container, and the box still works.
    leftovers = subprocess.run(
        ["docker", "exec", container, "pgrep", "-f", "sleep 90"],
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert leftovers.returncode != 0, f"orphaned command: {leftovers.stdout}"
    assert env.run("echo alive").stdout.strip().endswith("alive")


def test_base_image_gives_the_agent_sudo_python_and_tmux():
    """Only runs where the base image exists; asserts what §6/§9 promise it has."""
    e = DockerEnvironment(image="cowork-base:latest", agent_id=unique_agent())
    try:
        who = e.run("whoami")
        assert who.stdout.strip() == "cowork"
        assert e.run("sudo -n true").ok, "passwordless sudo is missing"
        version = e.run("python3 --version")
        assert version.stdout.strip().startswith("Python 3.12"), version.stdout
        for tool in ("uv", "tmux", "git", "curl"):
            assert e.run(f"command -v {tool}").ok, f"{tool} is missing from the image"
    finally:
        e.remove()
