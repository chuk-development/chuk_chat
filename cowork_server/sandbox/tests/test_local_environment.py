"""Tests for the local backend: session persistence, bounding, timeout."""

from __future__ import annotations

import os
import threading
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


# -- cancel: the §7.1 Stop reaching a command already running ---------------


def test_cancel_kills_the_command_in_flight(env, tmp_path):
    """A Stop must not wait out a long command. The barrier is the file the
    command creates before it blocks, so the cancel provably lands while the
    shell is running."""
    marker = tmp_path / "started"
    result: dict[str, ProcessResult] = {}

    def work() -> None:
        result["r"] = env.run(f"touch {marker} && sleep 60", timeout=120)

    worker = threading.Thread(target=work, daemon=True)
    worker.start()
    deadline = time.monotonic() + 20.0
    while not marker.exists() and time.monotonic() < deadline:
        time.sleep(0.01)
    assert marker.exists(), "the command never started"

    start = time.monotonic()
    env.cancel()
    worker.join(20.0)
    elapsed = time.monotonic() - start

    assert not worker.is_alive(), "run() never returned after the cancel"
    assert elapsed < 15.0, f"the cancel took {elapsed:.1f}s"
    # A killed command is a failed command, not an exception and not a timeout.
    assert result["r"].exit_code != 0
    assert result["r"].timed_out is False


def test_cancel_kills_the_whole_process_group(env, tmp_path):
    """The command's children die with it: a `sleep` left behind would keep
    holding the workspace with nobody watching it."""
    marker = tmp_path / "child-pid"
    done = threading.Event()

    def work() -> None:
        env.run(f"sleep 90 & echo $! > {marker}; wait", timeout=120)
        done.set()

    threading.Thread(target=work, daemon=True).start()
    deadline = time.monotonic() + 20.0
    while not (marker.exists() and marker.read_text().strip()) and (
        time.monotonic() < deadline
    ):
        time.sleep(0.01)
    pid = int(marker.read_text().strip())

    env.cancel()
    assert done.wait(20.0), "run() never returned"

    gone_by = time.monotonic() + 5.0
    while time.monotonic() < gone_by:
        try:
            os.kill(pid, 0)
        except OSError:
            break
        time.sleep(0.01)
    with pytest.raises(OSError):
        os.kill(pid, 0)  # the background sleep went with the group


def test_cancel_with_nothing_running_is_a_no_op(env):
    env.cancel()
    # And the environment still works afterwards: cancel is not a mode.
    assert env.run("echo alive").stdout.strip() == "alive"


def test_cancel_does_not_poison_the_next_command(env, tmp_path):
    marker = tmp_path / "go"
    threading.Thread(
        target=lambda: env.run(f"touch {marker} && sleep 60", timeout=120), daemon=True
    ).start()
    deadline = time.monotonic() + 20.0
    while not marker.exists() and time.monotonic() < deadline:
        time.sleep(0.01)
    env.cancel()
    # The plumbing that runs after a stop (a journal commit, a cleanup) still
    # needs a working shell.
    assert env.run("echo still here").stdout.strip() == "still here"
