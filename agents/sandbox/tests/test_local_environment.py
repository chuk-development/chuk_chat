"""Tests for the local backend: session persistence, bounding, timeout."""

from __future__ import annotations

import time

import pytest

from cowork_sandbox import LocalEnvironment, ProcessResult, make_environment
from cowork_sandbox.result import Environment


@pytest.fixture()
def env():
    e = LocalEnvironment()
    try:
        yield e
    finally:
        e.cleanup()


def test_env_and_cwd_persist_across_commands(env):
    """Export a var and cd in command 1; observe both in command 2."""
    first = env.run("export GREETING=hello_cowork && mkdir -p sub && cd sub")
    assert first.ok, first.stderr

    second = env.run("echo \"$GREETING @ $(pwd)\"")
    assert second.ok, second.stderr
    assert "hello_cowork" in second.stdout
    # cd in the first command carried over to the second.
    assert second.stdout.strip().endswith("/sub")
    # The environment also tracks cwd out of band.
    assert env.cwd.endswith("/sub")


def test_alias_persists_across_commands(env):
    env.run("alias greet='echo aliased-output'")
    result = env.run("greet")
    assert result.ok, result.stderr
    assert "aliased-output" in result.stdout


def test_cwd_marker_is_stripped_from_output(env):
    result = env.run("printf 'clean'")
    assert result.stdout == "clean"
    assert "__COWORK_CWD" not in result.stdout


def test_bounded_output_truncation():
    env = LocalEnvironment(max_output_chars=100)
    try:
        # Emit far more than the cap.
        result = env.run("for i in $(seq 1 5000); do echo -n X; done")
        assert result.stdout_truncated is True
        assert "output truncated" in result.stdout
        assert len(result.stdout) < 400
    finally:
        env.cleanup()


def test_timeout_kills_sleep(env):
    start = time.monotonic()
    result = env.run("sleep 30", timeout=2)
    elapsed = time.monotonic() - start
    assert result.timed_out is True
    assert result.exit_code == -9
    # It must not have waited the full sleep.
    assert elapsed < 10


def test_nonzero_exit_code(env):
    result = env.run("exit 7")
    assert result.exit_code == 7
    assert not result.ok


def test_run_bash_protocol_shape(env):
    result = env.run_bash("echo protocol", timeout=30)
    assert isinstance(result, ProcessResult)
    assert "protocol" in result.stdout
    # The instance satisfies the agent runtime's Environment protocol.
    assert isinstance(env, Environment)


def test_factory_builds_local():
    e = make_environment("local")
    try:
        assert isinstance(e, LocalEnvironment)
    finally:
        e.cleanup()


def test_factory_rejects_unknown():
    with pytest.raises(ValueError):
        make_environment("nope")
