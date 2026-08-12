"""Docker backend tests. Skipped whole if docker is unavailable."""

from __future__ import annotations

import os

import pytest

from cowork_sandbox import (
    DockerEnvironment,
    ProcessResult,
    docker_available,
    make_environment,
)

pytestmark = pytest.mark.skipif(
    not docker_available(),
    reason="docker CLI or daemon unavailable in this environment",
)

IMAGE = os.environ.get("COWORK_TEST_IMAGE", "debian:stable-slim")


@pytest.fixture()
def env():
    e = DockerEnvironment(image=IMAGE)
    try:
        yield e
    finally:
        e.cleanup()


def test_runs_inside_container(env):
    result = env.run("cat /etc/os-release")
    assert result.ok, result.stderr
    # debian:stable-slim reports debian.
    assert "debian" in result.stdout.lower()


def test_env_and_cwd_persist_across_commands(env):
    first = env.run("export TOKEN=in_container && cd /tmp")
    assert first.ok, first.stderr
    second = env.run("echo \"$TOKEN @ $(pwd)\"")
    assert second.ok, second.stderr
    assert "in_container" in second.stdout
    assert "/tmp" in second.stdout
    assert env.cwd == "/tmp"


def test_container_is_labelled_and_removed():
    import subprocess

    env = DockerEnvironment(image=IMAGE)
    try:
        env.run("true")  # forces container creation
        ps = subprocess.run(
            [
                "docker", "ps", "-q",
                "--filter", f"label=cowork-session={env.session_id}",
            ],
            capture_output=True,
            text=True,
            timeout=30,
        )
        assert ps.stdout.strip() != ""
    finally:
        env.cleanup()
    ps = subprocess.run(
        [
            "docker", "ps", "-aq",
            "--filter", f"label=cowork-session={env.session_id}",
        ],
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert ps.stdout.strip() == ""


def test_run_bash_protocol_shape(env):
    result = env.run_bash("echo docker-protocol", timeout=30)
    assert isinstance(result, ProcessResult)
    assert "docker-protocol" in result.stdout


def test_factory_builds_docker():
    e = make_environment("docker", image=IMAGE)
    try:
        assert isinstance(e, DockerEnvironment)
    finally:
        e.cleanup()
