"""External coding CLIs as a subagent backend (DeepSeek harness #57).

No CLI is ever run: a fake environment answers ``command -v`` and returns the
canned output of ``claude -p --output-format json`` / ``codex exec --json``."""

import json

import pytest

from chuk_agents_runtime.acp_runner import (
    detect_backends,
    make_acp_runner,
    parse_claude,
    parse_codex,
)
from chuk_agents_runtime.environment import ProcessResult
from chuk_agents_runtime.loop import KillSwitch, StopReason
from chuk_agents_runtime.runtime import SubagentConfig, make_child_runner
from chuk_agents_runtime.state import StateStore
from chuk_agents_runtime.subagents import ChildContext, SubagentLimits, SubagentSupervisor


class FakeEnv:
    def __init__(self, installed=("claude", "codex"), stdout="", exit_code=0, timed_out=False):
        self.installed = set(installed)
        self.stdout = stdout
        self.exit_code = exit_code
        self.timed_out = timed_out
        self.commands: list[str] = []
        self.cleaned = False

    def run_bash(self, cmd, *, timeout=120, internal=False, env=None):
        self.commands.append(cmd)
        if cmd.startswith("command -v "):
            name = cmd.split()[-1].strip("'")
            if name in self.installed:
                return ProcessResult(0, f"/usr/bin/{name}\n", "")
            return ProcessResult(1, "", "")
        return ProcessResult(self.exit_code, self.stdout, "boom" if self.exit_code else "", timed_out=self.timed_out)

    def cleanup(self):
        self.cleaned = True


CLAUDE_OK = json.dumps(
    {
        "type": "result",
        "subtype": "success",
        "is_error": False,
        "result": "fixed the bug in util.py",
        "usage": {"input_tokens": 100, "output_tokens": 20},
    }
)

CODEX_OK = "\n".join(
    json.dumps(e)
    for e in [
        {"type": "thread.started", "thread_id": "t1"},
        {"type": "turn.started"},
        {"type": "item.completed", "item": {"id": "i1", "type": "agent_message", "text": "draft"}},
        {"type": "item.completed", "item": {"id": "i2", "type": "command_execution"}},
        {"type": "item.completed", "item": {"id": "i3", "type": "agent_message", "text": "all tests pass"}},
        {"type": "turn.completed", "usage": {"input_tokens": 50, "cached_input_tokens": 10, "output_tokens": 5}},
    ]
)


def _ctx(backend: str, prompt: str = "fix it") -> ChildContext:
    events: list[dict] = []
    ctx = ChildContext(
        subagent_id="sa_1",
        task_id="t.s1",
        title="t",
        prompt=prompt,
        depth=1,
        session_key="subagent:sa_1",
        db_path="/dev/null",
        workspace=None,
        branch=None,
        kill_switch=KillSwitch(),
        emit=events.append,
        limits=SubagentLimits(),
        gates={},
        root="/tmp",
        backend=backend,
    )
    ctx.events = events  # type: ignore[attr-defined]
    return ctx


def test_parse_claude_success_and_error():
    assert parse_claude(CLAUDE_OK) == (True, "fixed the bug in util.py", 120, None)
    ok, answer, _, error = parse_claude(json.dumps({"type": "result", "is_error": True, "subtype": "error_max_turns", "result": ""}))
    assert not ok and answer is None and "error_max_turns" in error
    assert parse_claude("not json")[0] is False


def test_parse_codex_takes_the_last_agent_message():
    assert parse_codex(CODEX_OK) == (True, "all tests pass", 55, None)
    failed = "\n".join(
        [json.dumps({"type": "turn.failed", "error": {"message": "rate limited"}})]
    )
    ok, _, _, error = parse_codex(failed)
    assert not ok and "rate limited" in error
    assert parse_codex("")[0] is False


def test_claude_runner_maps_the_answer_back():
    env = FakeEnv(stdout=CLAUDE_OK)
    ctx = _ctx("claude", prompt="fix it; don't rm -rf")
    result = make_acp_runner(lambda task_id: env)(ctx)
    assert result.reason is StopReason.FINISHED
    assert result.final_answer == "fixed the bug in util.py"
    assert result.tokens_spent == 120
    cmd = env.commands[-1]
    assert cmd.startswith("claude -p ")
    assert "--output-format json" in cmd
    assert "'fix it; don'\"'\"'t rm -rf'" in cmd  # quoted, not interpreted
    assert env.cleaned
    assert {"type": "delta", "text": "fixed the bug in util.py"} in ctx.events


def test_codex_runner_uses_exec_json():
    env = FakeEnv(stdout=CODEX_OK)
    result = make_acp_runner(lambda task_id: env)(_ctx("codex"))
    assert result.final_answer == "all tests pass"
    assert env.commands[-1].startswith("codex exec --json --skip-git-repo-check")


def test_missing_cli_fails_with_a_sentence():
    env = FakeEnv(installed=())
    with pytest.raises(RuntimeError, match="not installed"):
        make_acp_runner(lambda task_id: env)(_ctx("claude"))
    assert env.cleaned


def test_cli_error_and_timeout_fail_the_child():
    env = FakeEnv(stdout="", exit_code=2)
    with pytest.raises(RuntimeError, match="claude"):
        make_acp_runner(lambda task_id: env)(_ctx("claude"))
    env = FakeEnv(stdout="", timed_out=True)
    with pytest.raises(RuntimeError, match="did not finish"):
        make_acp_runner(lambda task_id: env)(_ctx("codex"))


def test_detect_backends_probes_inside_the_env():
    assert detect_backends(FakeEnv(installed=("codex",))) == ("codex",)
    assert detect_backends(FakeEnv(installed=())) == ()


def test_child_runner_routes_by_backend(tmp_path):
    env = FakeEnv(stdout=CLAUDE_OK)
    config = SubagentConfig(
        model_factory=lambda: None,  # never called for an external backend
        env_factory=lambda task_id: env,
        acp_backends=("claude",),
    )
    runner = make_child_runner(config)
    assert runner(_ctx("claude")).final_answer == "fixed the bug in util.py"
    with pytest.raises(RuntimeError, match="not enabled"):
        runner(_ctx("codex"))


def test_end_to_end_through_the_supervisor(tmp_path):
    env = FakeEnv(stdout=CODEX_OK)
    config = SubagentConfig(
        model_factory=lambda: None,
        env_factory=lambda task_id: env,
        acp_backends=("codex",),
    )
    sup = SubagentSupervisor(
        parent_key="agent:x",
        store=StateStore(str(tmp_path / "p.db")),
        runner=make_child_runner(config),
        root=str(tmp_path / "subs"),
        backends=config.acp_backends,
    )
    out = sup.delegate([{"prompt": "run the tests", "backend": "codex"}])
    child = out["subagents"][0]
    assert child["state"] == "succeeded", child
    assert child["backend"] == "codex"
    assert child["result"] == "all tests pass"
