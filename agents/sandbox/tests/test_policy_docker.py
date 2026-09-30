"""Per-agent permissions against a real daemon (docs/WIRE_CONTRACT.md, "Agent
permissions"). Skipped whole without docker; the sudo checks also need the
agent image (``agents-base:latest``), which is the one image with sudo in it.

Every container carries a unique agent id and is removed in a ``finally``.
"""

from __future__ import annotations

import os
import subprocess
import uuid

import pytest

from chuk_agents_sandbox import DockerEnvironment, SandboxPolicy, docker_available

pytestmark = pytest.mark.skipif(
    not docker_available(),
    reason="docker CLI or daemon unavailable in this environment",
)

AGENT_IMAGE = os.environ.get("AGENTS_TEST_AGENT_IMAGE", "agents-base:latest")
IMAGE = os.environ.get("AGENTS_TEST_IMAGE", "debian:stable-slim")


def _image_present(image: str) -> bool:
    proc = subprocess.run(
        ["docker", "image", "inspect", image], capture_output=True, timeout=30
    )
    return proc.returncode == 0


needs_agent_image = pytest.mark.skipif(
    not _image_present(AGENT_IMAGE), reason=f"{AGENT_IMAGE} is not built here"
)


def _env(image: str, policy: SandboxPolicy, workdir: str | None = None) -> DockerEnvironment:
    return DockerEnvironment(
        image=image,
        agent_id=f"pytest-perm-{uuid.uuid4().hex[:10]}",
        workdir=workdir,
        policy=policy,
    )


def test_network_off_leaves_only_loopback():
    on = _env(IMAGE, SandboxPolicy())
    off = _env(IMAGE, SandboxPolicy(network=False))
    try:
        assert "eth0" in on.run("ls /sys/class/net").stdout
        devices = off.run("ls /sys/class/net").stdout.split()
        assert devices == ["lo"]
    finally:
        on.remove()
        off.remove()


@needs_agent_image
def test_network_off_makes_curl_fail():
    env = _env(AGENT_IMAGE, SandboxPolicy(network=False))
    try:
        result = env.run("curl -sS -m 5 https://example.com -o /dev/null")
        assert not result.ok
    finally:
        env.remove()


@needs_agent_image
def test_sudo_off_makes_sudo_fail_and_on_keeps_it():
    on = _env(AGENT_IMAGE, SandboxPolicy())
    off = _env(AGENT_IMAGE, SandboxPolicy(sudo=False))
    try:
        assert on.run("sudo -n true").ok
        result = off.run("sudo -n true")
        assert not result.ok
    finally:
        on.remove()
        off.remove()


def test_read_only_workspace_refuses_writes(tmp_path):
    (tmp_path / "hello.txt").write_text("hi\n")
    env = _env(IMAGE, SandboxPolicy(workspace_mount="ro"), workdir=str(tmp_path))
    try:
        assert env.run("cat /workspace/hello.txt").stdout == "hi\n"
        result = env.run("touch /workspace/new.txt")
        assert not result.ok
        assert not (tmp_path / "new.txt").exists()
    finally:
        env.remove()


def test_a_changed_policy_rebuilds_the_box_at_refresh():
    current = {"policy": SandboxPolicy()}
    env = DockerEnvironment(
        image=IMAGE,
        agent_id=f"pytest-perm-{uuid.uuid4().hex[:10]}",
        policy_provider=lambda: current["policy"],
    )
    try:
        assert "eth0" in env.run("ls /sys/class/net").stdout
        first = env.container_id
        current["policy"] = SandboxPolicy(network=False)
        # Mid-task: still the same box, still online.
        assert "eth0" in env.run("ls /sys/class/net").stdout
        assert env.container_id == first
        # Next task: no run holds the box, so the change lands.
        env.begin_run()
        env.end_run()
        assert env.run("ls /sys/class/net").stdout.split() == ["lo"]
        assert env.container_id != first
    finally:
        env.remove()
