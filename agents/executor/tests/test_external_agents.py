"""The ``external_agents`` permission wires the claude / codex CLI subagent
backend (docs/WIRE_CONTRACT.md, "Subagents"). No CLI runs: the probe is
answered by a stub environment."""

from __future__ import annotations

from chuk_agents_runtime import MockModelClient
from chuk_agents_runtime.environment import ProcessResult
from chuk_agents_sandbox import LocalEnvironment, SandboxPolicy

from chuk_agents_executor import Executor, loopback_pair

from wiring import paired_channel


class ProbedEnv(LocalEnvironment):
    """A real local environment whose ``command -v`` sees only ``installed``."""

    def __init__(self, *args, installed=(), **kwargs):
        super().__init__(*args, **kwargs)
        self.installed = set(installed)

    def run_bash(self, cmd, **kwargs):
        if cmd.startswith("command -v "):
            name = cmd.split()[-1].strip("'")
            ok = name in self.installed
            return ProcessResult(0 if ok else 1, f"/bin/{name}\n" if ok else "", "")
        return super().run_bash(cmd, **kwargs)


def _executor(tmp_path, env):
    channel = paired_channel()
    _controller_ep, executor_ep = loopback_pair()
    (tmp_path / "ws").mkdir(exist_ok=True)
    return Executor(
        name="agent",
        endpoint=executor_ep,
        opener=channel.executor.opener,
        sealer=channel.executor.sealer,
        environment=env,
        db_path=str(tmp_path / "state.db"),
        model_factory=lambda: MockModelClient(["ok"]),
        workspace=str(tmp_path / "ws"),
        subagent_sandbox="local",
    )


def test_off_by_default_offers_no_backend(tmp_path):
    env = ProbedEnv(workdir=str(tmp_path), policy=SandboxPolicy(), installed=("claude",))
    config = _executor(tmp_path, env)._subagent_config("req", "s1")
    assert config.acp_backends == ()


def test_on_offers_only_the_installed_clis(tmp_path):
    env = ProbedEnv(
        workdir=str(tmp_path),
        policy=SandboxPolicy(external_agents=True),
        installed=("codex",),
    )
    config = _executor(tmp_path, env)._subagent_config("req", "s1")
    assert config.acp_backends == ("codex",)
