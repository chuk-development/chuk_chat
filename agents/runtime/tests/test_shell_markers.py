"""Shell result markers and the required description (research items 5, 27, 40)."""

from __future__ import annotations

from chuk_agents_runtime import LocalEnvironment, ToolRegistry, register_builtin_tools
from chuk_agents_runtime.shell_tools import JobManager
from chuk_agents_runtime.tools import make_run_command_handler
from chuk_agents_runtime import tool_event_fields


def _reg(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    reg = ToolRegistry()
    register_builtin_tools(reg, LocalEnvironment())
    return reg


def test_run_command_keeps_exit_code_last_and_adds_markers(tmp_path, monkeypatch):
    reg = _reg(tmp_path, monkeypatch)
    out = reg.dispatch("run_command", {"description": "echo hi", "command": "echo hi"})
    assert list(out)[-1] == "exit_code"
    assert out["stopped"] is None and out["timeout_ms"] == 120_000
    assert out["exit_code"] == 0


def test_non_zero_exit_is_a_normal_result(tmp_path, monkeypatch):
    reg = _reg(tmp_path, monkeypatch)
    out = reg.dispatch("run_command", {"description": "fail", "command": "exit 7"})
    assert out["exit_code"] == 7 and "error" not in out
    assert out["stopped"] is None


def test_timeout_marks_stopped(tmp_path, monkeypatch):
    reg = _reg(tmp_path, monkeypatch)
    out = reg.dispatch(
        "run_command", {"description": "sleep too long", "command": "sleep 5", "timeout": 1}
    )
    # No JobManager wired here, so it is a plain timed-out result.
    assert out["timed_out"] is True and out["stopped"] == "timeout"
    assert out["timeout_ms"] == 1000


def test_blank_description_is_rejected_but_absent_runs(tmp_path, monkeypatch):
    reg = _reg(tmp_path, monkeypatch)
    blank = reg.dispatch("run_command", {"description": "  ", "command": "echo hi"})
    assert blank["ok"] is False and "description" in blank["error"]
    absent = reg.dispatch("run_command", {"command": "echo hi"})
    assert absent["exit_code"] == 0


def test_foreground_timeout_moves_to_a_background_job(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    env = LocalEnvironment()
    jobs = JobManager(env, workspace=str(tmp_path), new_id=lambda: "j0000beef")
    handler = make_run_command_handler(env, None, jobs)
    out = handler(command="sleep 5", description="sleep", timeout=1)
    assert out["moved_to_background"] is True
    assert out["job_id"] == "j0000beef"
    assert "output_so_far" in out and out["timeout_ms"] == 1000


def test_description_rides_the_tool_event(tmp_path, monkeypatch):
    fields = tool_event_fields(
        name="run_command",
        arguments={"description": "Run the unit tests", "command": "pytest"},
        result={"exit_code": 0, "stdout": "", "stderr": "", "timed_out": False},
    )
    assert fields["description"] == "Run the unit tests"
    assert fields["command"] == "pytest"


def test_a_timed_out_command_is_adopted_not_run_twice(tmp_path, monkeypatch):
    """CodeRabbit: the old move stopped the command and started it again, so a
    non-idempotent command (an append, a POST, a push) ran twice."""
    import time as _time

    monkeypatch.chdir(tmp_path)
    env = LocalEnvironment()
    jobs = JobManager(env, workspace=str(tmp_path), new_id=lambda: "j0000cafe")
    handler = make_run_command_handler(env, None, jobs)
    counter = tmp_path / "count.txt"
    out = handler(
        command=f"echo ran >> {counter}; echo started; sleep 2; echo finished",
        description="append then wait",
        timeout=1,
    )
    assert out["moved_to_background"] is True
    assert out["job_id"] == "j0000cafe"
    assert "started" in out["output_so_far"]
    deadline = _time.monotonic() + 10
    while _time.monotonic() < deadline:
        status = jobs.status("j0000cafe")
        if status.get("state") != "running":
            break
        _time.sleep(0.1)
    assert status["state"] == "finished" and status["exit_code"] == 0
    # The same process went on to the end: one line, never a second start.
    assert counter.read_text().splitlines() == ["ran"]
    assert "finished" in jobs.output("j0000cafe")["output"]
    # The adopted job wakes the model when it ends.
    triggers = tmp_path / ".agents" / "automations" / "triggers.jsonl"
    assert "j0000cafe" in triggers.read_text()


def test_a_quick_foreground_command_keeps_its_streams_and_leaves_no_job(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    env = LocalEnvironment()
    jobs = JobManager(env, workspace=str(tmp_path), new_id=lambda: "j0000f00d")
    handler = make_run_command_handler(env, None, jobs)
    out = handler(command="echo out; echo err >&2; exit 3", description="streams", timeout=30)
    assert out["stdout"].strip() == "out"
    assert out["stderr"].strip() == "err"
    assert out["exit_code"] == 3 and out["timed_out"] is False
    assert jobs.status()["jobs"] == []
    triggers = tmp_path / ".agents" / "automations" / "triggers.jsonl"
    assert not triggers.exists() or "j0000f00d" not in triggers.read_text()


class _PersistentShell(LocalEnvironment):
    """A stand-in for the sandbox envelope: restore the snapshot and the cwd,
    run the command in ``{ }``, unset the secrets, dump the state again."""

    def __init__(self, root):
        self.cwd = str(root)
        self.snap = str(root / "snap")

    def run_bash(self, cmd, *, timeout=120, internal=False, env=None):
        forget = f"unset -v {' '.join(env)}\n" if env else ""
        wrapped = (
            "shopt -s expand_aliases\n"
            f"source {self.snap} 2>/dev/null\n"
            f"cd {self.cwd}\n{{\n{cmd}\n}}\n__rc=$?\n{forget}"
            f"{{ declare -px; declare -f; alias; }} > {self.snap} 2>/dev/null\n"
            "printf '\\nCWD:%s\\n' \"$PWD\"\nexit $__rc\n"
        )
        result = super().run_bash(wrapped, timeout=timeout, internal=internal, env=env)
        kept = []
        for line in result.stdout.split("\n"):
            if line.startswith("CWD:"):
                self.cwd = line[4:]
            else:
                kept.append(line)
        result.stdout = "\n".join(kept)
        return result


def test_an_adoptable_foreground_keeps_the_persistent_shell_and_no_secret_on_disk(tmp_path):
    (tmp_path / "sub").mkdir()
    env = _PersistentShell(tmp_path)
    jobs = JobManager(env, workspace=str(tmp_path))
    first = jobs.run_foreground(
        "myfn(){ echo fn-ok; }; export FOO=bar; alias ll='echo alias-ok'; cd sub",
        timeout=10,
        env={"SECRET_TOKEN": "s3cr3t"},
    )
    assert first["finished"] is True
    assert env.cwd == str(tmp_path / "sub")
    second = jobs.run_foreground(
        "myfn; echo $FOO; ll; echo key=$SECRET_TOKEN; exit 4", timeout=10, env={"SECRET_TOKEN": "s3cr3t"}
    )
    result = second["result"]
    assert result.exit_code == 4
    assert result.stdout.split() == ["fn-ok", "bar", "alias-ok", "key=s3cr3t"]
    snapshot = (tmp_path / "snap").read_text()
    assert "s3cr3t" not in snapshot and "__CW_" not in snapshot and "__cw_stop" not in snapshot
    # A job that is adopted leaves no secret in its files either.
    moved = jobs.run_foreground("echo start; sleep 2", timeout=1, env={"SECRET_TOKEN": "s3cr3t"})
    assert moved["moved"] is True
    jobs_dir = tmp_path / ".agents" / "jobs"
    for path in jobs_dir.iterdir():
        assert "s3cr3t" not in path.read_text(errors="ignore")
