"""Sandbox escalation (docs/WIRE_CONTRACT.md, "Sandbox escalation", DeepSeek
research item 28): what a box withholds, the widened policy of one call, and
that the grant ends with that call."""

from __future__ import annotations

import subprocess
import threading

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
from chuk_agents_sandbox import LocalEnvironment, bwrap as _bwrap
from chuk_agents_sandbox import docker as docker_mod
from chuk_agents_sandbox.lifecycle import CliResult, reap_orphans


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

    def _run_bash(self, cmd, *, login=False, timeout=120, stdin=None, env=None, policy=None):
        self.seen.append(policy or self.effective_policy)
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


# --------------------------------------------------------------------------- #
# Security review C1: the widened policy belongs to ONE call, not the env.
# --------------------------------------------------------------------------- #
class _Blocking(_Recording):
    """The escalated call blocks inside ``_run_bash`` until released, so a
    second caller can run while the grant is live."""

    def __init__(self, policy: SandboxPolicy) -> None:
        super().__init__(policy)
        self.inside = threading.Event()
        self.release = threading.Event()

    def _run_bash(self, cmd, *, login=False, timeout=120, stdin=None, env=None, policy=None):
        if "ESCALATED" in cmd:
            self.inside.set()
            assert self.release.wait(5)
        return super()._run_bash(
            cmd, login=login, timeout=timeout, stdin=stdin, env=env, policy=policy
        )


def test_concurrent_plain_call_during_escalation_stays_narrow():
    env = _Blocking(SandboxPolicy(network=False, workspace_mount="ro"))
    worker = threading.Thread(
        target=env.run_escalated, args=("ESCALATED curl x",), kwargs={"grant": ("network",)}
    )
    worker.start()
    try:
        assert env.inside.wait(5)
        # Exploit scenario: a parallel run_command (or a room turn) while the
        # user-approved escalation is in flight.
        assert env.effective_policy.network is False
        env.run("curl evil.example")
        plain = env.seen[-1]
        assert plain.network is False
        assert plain.read_only_workspace is True
    finally:
        env.release.set()
        worker.join(5)
    escalated = env.seen[-1]
    assert escalated.network is True
    assert env.effective_policy.network is False


def test_background_job_started_during_escalation_is_narrow(tmp_path, monkeypatch):
    """A background job / shell_start builds its argv from the env while the
    escalated call is live; it must get ``--unshare-net``."""
    monkeypatch.setattr(_bwrap, "bwrap_binary", lambda: "/usr/bin/bwrap")
    monkeypatch.setattr(_bwrap, "wants_bwrap", lambda mode=None: True)
    env = LocalEnvironment(workdir=str(tmp_path), policy=SandboxPolicy(network=False))
    env._session_initialized = True
    inside, release = threading.Event(), threading.Event()
    argvs: dict[str, list[str]] = {}

    class _Proc:
        returncode = 0

        def __init__(self, argv, **kwargs):
            self.argv = argv

        def communicate(self, input=None, timeout=None):
            if "ESCALATED" in " ".join(self.argv):
                argvs["escalated"] = self.argv
                inside.set()
                assert release.wait(5)
            else:
                argvs["job"] = self.argv
            return ("", "")

        def poll(self):
            return 0

    monkeypatch.setattr(subprocess, "Popen", _Proc)
    try:
        worker = threading.Thread(
            target=env.run_escalated,
            args=("ESCALATED curl x",),
            kwargs={"grant": ("network",)},
        )
        worker.start()
        assert inside.wait(5)
        env.run("long-running-job &")
        release.set()
        worker.join(5)
    finally:
        release.set()
        env.cleanup()
    assert "--unshare-net" in argvs["job"]
    assert "--unshare-net" not in argvs["escalated"]


# --------------------------------------------------------------------------- #
# Security review H4: an escalation box never outlives its call.
# --------------------------------------------------------------------------- #
class _LoggingCli(_FakeCli):
    def __init__(self) -> None:
        self.calls: list[tuple[str, ...]] = []

    def run(self, *args, timeout=None):
        self.calls.append(args)
        return CliResult(stdout="", stderr="", exit_code=0)


def _docker_env(tmp_path, cli):
    return DockerEnvironment(
        workdir=str(tmp_path / "ws"),
        cli=cli,
        user="agents",
        owner="host-1",
        policy=SandboxPolicy(network=False, sudo=False),
    )


def test_escalation_argv_names_the_box(tmp_path):
    env = _docker_env(tmp_path, _FakeCli())
    argv = env.escalation_argv("x", ["network"], name="cowork-esc-a-1", cidfile="/c/cid")
    assert argv[argv.index("--name") + 1] == "cowork-esc-a-1"
    assert argv[argv.index("--cidfile") + 1] == "/c/cid"
    labels = [argv[i + 1] for i, a in enumerate(argv) if a == "--label"]
    assert "cowork.escalation=1" in labels
    assert f"cowork.session={env.session_id}" in labels
    assert "cowork.owner=host-1" in labels


class _HangingProc:
    """A ``docker run`` client that never ends by itself."""

    instances: list["_HangingProc"] = []

    def __init__(self, argv, **kwargs):
        self.argv = argv
        self.killed = threading.Event()
        self.returncode = None
        _HangingProc.instances.append(self)

    def communicate(self, input=None, timeout=None):
        if self.killed.is_set():
            return ("", "")
        if not self.killed.wait(timeout if timeout is not None else 5):
            raise subprocess.TimeoutExpired(self.argv, timeout)
        self.returncode = -9
        return ("", "")

    def kill(self):
        self.returncode = -9
        self.killed.set()

    def poll(self):
        return self.returncode


def _name_of(argv):
    return argv[argv.index("--name") + 1]


def test_escalation_timeout_kills_and_removes_the_box(tmp_path, monkeypatch):
    cli = _LoggingCli()
    env = _docker_env(tmp_path, cli)
    _HangingProc.instances.clear()
    monkeypatch.setattr(docker_mod.subprocess, "Popen", _HangingProc)
    result = env.run_escalated("sleep 999", grant=("network",), timeout=0.05)
    assert result.timed_out
    name = _name_of(_HangingProc.instances[0].argv)
    assert ("kill", name) in cli.calls
    assert ("rm", "-f", name) in cli.calls
    assert cli.calls.index(("kill", name)) < cli.calls.index(("rm", "-f", name))


def test_escalation_stop_kills_and_removes_the_box(tmp_path, monkeypatch):
    cli = _LoggingCli()
    env = _docker_env(tmp_path, cli)
    _HangingProc.instances.clear()
    monkeypatch.setattr(docker_mod.subprocess, "Popen", _HangingProc)
    out: list[ProcessResult] = []
    worker = threading.Thread(
        target=lambda: out.append(env.run_escalated("sleep 999", grant=("network",), timeout=30))
    )
    worker.start()
    for _ in range(200):
        if _HangingProc.instances:
            break
        threading.Event().wait(0.01)
    proc = _HangingProc.instances[0]
    env.cancel()  # the kill switch
    worker.join(5)
    assert not worker.is_alive() and out
    assert proc.killed.is_set()
    name = _name_of(proc.argv)
    assert ("kill", name) in cli.calls
    assert ("rm", "-f", name) in cli.calls


def test_startup_reaper_removes_leftover_escalation_boxes():
    class _Cli:
        binary = "docker"

        def __init__(self):
            self.removed: list[str] = []

        def run(self, *args, timeout=None):
            if args[0] == "ps":
                if "label=cowork.escalation=1" in args:
                    return CliResult(
                        stdout="e1\tcowork-esc-a-1\trunning\t"
                        "cowork.escalation=1,cowork.owner=host-1,cowork.session=s1\n"
                        "e2\tcowork-esc-b-1\trunning\t"
                        "cowork.escalation=1,cowork.owner=other,cowork.session=s2\n",
                        stderr="",
                        exit_code=0,
                    )
                return CliResult("", "", 0)
            if args[:2] == ("rm", "-f"):
                self.removed.append(args[2])
            return CliResult("", "", 0)

    cli = _Cli()
    reaped = reap_orphans(active_session_ids=set(), cli=cli, owner="host-1")
    assert reaped == ["cowork-esc-a-1"]
    assert cli.removed == ["e1"]  # another host's box stays
    # A live session's escalation box is not touched mid-run.
    cli.removed.clear()
    assert reap_orphans(active_session_ids={"s1"}, cli=cli, owner="host-1") == []
