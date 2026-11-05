"""Sandbox escalation (docs/WIRE_CONTRACT.md, "Sandbox escalation", DeepSeek
research item 28): what a box withholds, the widened policy of one call, and
that the grant ends with that call."""

from __future__ import annotations

import pytest

from chuk_agents_sandbox import (
    DockerEnvironment,
    PolicyError,
    ProcessResult,
    SandboxPolicy,
    widened_policy,
    withheld_permissions,
)
from chuk_agents_sandbox.base import BaseEnvironment
from chuk_agents_sandbox.lifecycle import CliResult


class _Recording(BaseEnvironment):
    """Records the policy each command ran under."""

    def __init__(self, policy: SandboxPolicy, kind: str = "local-bwrap") -> None:
        super().__init__(snapshot_path="/nonexistent/snap", initial_cwd="/", policy=policy)
        self._kind = kind
        self._session_initialized = True
        self.seen: list[SandboxPolicy] = []

    @property
    def kind(self) -> str:
        return self._kind

    def _run_bash(self, cmd, *, login=False, timeout=120, stdin=None, env=None):
        self.seen.append(self.effective_policy)
        return ProcessResult("ok", "", 0)

    def cleanup(self) -> None:
        pass


def test_withheld_needs_the_switch_off_and_enforced():
    closed = SandboxPolicy(network=False, sudo=False, workspace_mount="ro")
    assert withheld_permissions(closed, "docker") == ("network", "sudo", "workspace_write")
    # bwrap enforces network and the read-only bind, never sudo.
    assert withheld_permissions(closed, "local-bwrap") == ("network", "workspace_write")
    # The plain local backend withholds nothing: escalation widens nothing.
    assert withheld_permissions(closed, "local") == ()
    assert withheld_permissions(SandboxPolicy(), "docker") == ()


def test_widened_policy_switches_on_only_the_grant():
    closed = SandboxPolicy(network=False, sudo=False, workspace_mount="ro", secrets_env=False)
    wide = widened_policy(closed, ["network", "workspace_write"])
    assert wide.network is True and wide.workspace_mount == "rw"
    assert wide.sudo is False and wide.secrets_env is False
    with pytest.raises(PolicyError):
        widened_policy(closed, ["secrets_env"])


def test_run_escalated_widens_one_call_only():
    env = _Recording(SandboxPolicy(network=False))
    assert env.withheld_permissions() == ("network",)
    env.run_escalated("curl x", grant=("network",))
    env.run("curl x")
    assert env.seen[0].network is True
    assert env.seen[1].network is False
    assert env.policy.network is False


class _FakeCli:
    binary = "docker"

    def run(self, *args, timeout=None):
        return CliResult(stdout="cid\n", stderr="", exit_code=0)


def test_docker_escalation_uses_a_temporary_wider_box(tmp_path):
    env = DockerEnvironment(
        workdir=str(tmp_path / "ws"),
        cli=_FakeCli(),
        user="agents",
        policy=SandboxPolicy(network=False, sudo=False),
    )
    assert env.kind == "docker"
    assert env.withheld_permissions() == ("network", "sudo")
    argv = env.escalation_argv("apt-get install -y jq", ["network"], ["API_KEY"])
    assert argv[:4] == ["docker", "run", "--rm", "-i"]
    # Network granted: no ``--network none``. sudo not granted: still locked.
    assert "--network" not in argv
    assert "no-new-privileges" in argv
    # The command text never sits on the command line.
    assert "apt-get install -y jq" not in " ".join(argv)
    assert "AGENTS_ESCALATED_CMD" in argv
    # A secret rides as a bare name, its value from the client environment.
    assert argv[argv.index("API_KEY") - 1] == "-e"
    assert f"{tmp_path / 'ws'}:/workspace" in argv
    # The agent's own policy is unchanged.
    assert env.policy.network is False
