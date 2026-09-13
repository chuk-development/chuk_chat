"""Per-command environment (docs/WIRE_CONTRACT.md, "Secrets"): a value passed
as ``env`` reaches THAT command's process and nothing else — not the session
snapshot, not the next command."""

from __future__ import annotations

from chuk_agents_sandbox import LocalEnvironment
from chuk_agents_sandbox.base import _is_env_name


def test_env_reaches_the_command_only(tmp_path):
    env = LocalEnvironment(workdir=str(tmp_path))
    try:
        first = env.run_bash("echo \"$X\"; printenv X", env={"X": "secret-value-123"})
        assert first.stdout == "secret-value-123\nsecret-value-123\n"
        # The snapshot never carries the value ...
        snapshot = open(env._snapshot_path, encoding="utf-8", errors="replace").read()
        assert "secret-value-123" not in snapshot
        # ... so the next command, without env, does not see it.
        second = env.run_bash("echo \"[$X]\"")
        assert second.stdout == "[]\n"
    finally:
        env.cleanup()


def test_env_does_not_break_session_persistence(tmp_path):
    env = LocalEnvironment(workdir=str(tmp_path))
    try:
        env.run_bash("export KEEP=1; cd /", env={"X": "secret-value-123"})
        out = env.run_bash("echo $KEEP; pwd")
        assert out.stdout == "1\n/\n"
    finally:
        env.cleanup()


def test_invalid_names_are_dropped(tmp_path):
    env = LocalEnvironment(workdir=str(tmp_path))
    try:
        out = env.run_bash("echo \"[$GOOD]\"", env={"GOOD": "ok-value-1", "bad name": "x", "9x": "y"})
        assert out.stdout == "[ok-value-1]\n"
    finally:
        env.cleanup()


def test_is_env_name():
    assert _is_env_name("A_B9") and _is_env_name("_x")
    assert not _is_env_name("9a") and not _is_env_name("a-b") and not _is_env_name("")
