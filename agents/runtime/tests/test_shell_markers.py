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
