"""The interactive shell tools and the background jobs
(docs/WIRE_CONTRACT.md, "Interactive shell and background commands").

Deterministic parts (key tokens, command shapes, registration) run against a
recording fake. The parts that prove the claim — a prompt answered with
``y`` + Enter, a job that returns at once and leaves ONE trigger line — run
against real tmux / a real local shell and are skipped where tmux is missing.
"""

from __future__ import annotations

import json
import os
import shutil
import time

import pytest

from cowork_agent import LocalEnvironment, ProcessResult, ToolRegistry
from cowork_agent.shell_tools import (
    DEFAULT_LINES,
    JOB_TOOL_NAMES,
    SHELL_OUTPUT_CAP,
    SHELL_TOOL_NAMES,
    JobManager,
    is_key_token,
    job_state,
    parse_send_items,
    register_job_tools,
    register_shell_tools,
)
from cowork_agent.terminal import TerminalError, TerminalManager
from cowork_agent.tools import make_run_command_handler, register_run_command

needs_tmux = pytest.mark.skipif(shutil.which("tmux") is None, reason="tmux is not installed")


# -- key tokens ---------------------------------------------------------------------


def test_key_tokens_are_case_sensitive_and_shaped():
    assert is_key_token("Enter") and is_key_token("C-c") and is_key_token("M-x")
    assert is_key_token("F12") and is_key_token("^c") and is_key_token("PageDown")
    assert not is_key_token("enter")  # a word, typed
    assert not is_key_token("home")
    assert not is_key_token("y")
    assert not is_key_token("F13")


def test_parse_send_items_types_text_and_presses_tokens():
    items = parse_send_items(["y", "Enter", "make -j4", "C-c", "Esc"])
    assert items == [
        ("text", "y"),
        ("key", "Enter"),
        ("text", "make -j4"),
        ("key", "C-c"),
        ("key", "Escape"),
    ]
    # ``literal`` types every item, even a token look-alike.
    assert parse_send_items(["Enter"], literal=True) == [("text", "Enter")]
    # A bare string is one item.
    assert parse_send_items("ls") == [("text", "ls")]
    with pytest.raises(TerminalError):
        parse_send_items({"not": "a list"})


# -- a recording environment --------------------------------------------------------


class RecordingEnv:
    """Records every command; answers with a canned result."""

    def __init__(self, stdout: str = "", exit_code: int = 0) -> None:
        self.commands: list[str] = []
        self.envs: list[dict | None] = []
        self.stdout = stdout
        self.exit_code = exit_code

    def run_bash(self, cmd, *, timeout=120, internal=False, env=None):
        self.commands.append(cmd)
        self.envs.append(dict(env) if env else None)
        return ProcessResult(self.exit_code, self.stdout, "")


def test_job_start_command_detaches_and_never_chains_setsid_into_an_and_list():
    env = RecordingEnv(stdout="4242\n/ws/.cowork/jobs\n")
    jobs = JobManager(env, session_key="thread-1", workspace="/ws", new_id=lambda: "j0000abcd")
    out = jobs.start("sleep 30 && echo done", cwd="/ws/sub")
    assert out == {
        "ok": True,
        "job_id": "j0000abcd",
        "pid": 4242,
        "log_path": ".cowork/jobs/j0000abcd.log",
        "jobs_dir": "/ws/.cowork/jobs",
        "state": "running",
        "note": out["note"],
    }
    (cmd,) = env.commands
    # The workspace root: the image's variable first, the host path as fallback.
    assert '"${COWORK_WORKSPACE:-/ws}"' in cmd
    # The detach line stands on its own: a ``&&`` right before ``setsid`` would
    # background the whole list and hold the caller's pipe until the job ends.
    setsid_at = cmd.index("setsid bash")
    assert cmd[setsid_at - 2:setsid_at] != "& "
    assert "&& setsid" not in cmd
    assert "</dev/null >/dev/null 2>&1 &" in cmd
    assert "timeout" not in cmd.split("setsid")[0]  # the cap lives in the wrapper
    # No value of the command on a command line: it travels base64.
    assert "sleep 30" not in cmd


def test_job_wrapper_writes_exit_and_one_trigger_line():
    jobs = JobManager(RecordingEnv(), session_key='thr"ead', workspace="/ws", new_id=lambda: "j0000abcd")
    wrapper = jobs._wrapper("j0000abcd", None)
    assert "timeout --signal=TERM -k 10 86400 bash" in wrapper
    assert 'echo $rc > "$D/$ID.exit"' in wrapper
    assert '"kind":"job"' in wrapper and '"job_id":"%s"' in wrapper
    # The session key is JSON, quoted for the shell, never interpolated raw.
    assert json.dumps('thr"ead') in wrapper.replace("'", "")
    # A cancelled job writes nothing: the model stopped it, nobody is woken.
    assert 'if [ -e "$D/$ID.cancelled" ]; then exit 0; fi' in wrapper


def test_job_start_passes_the_secrets_env_like_run_command():
    env = RecordingEnv(stdout="1\n/ws/.cowork/jobs\n")
    jobs = JobManager(env, workspace="/ws", secrets_env=lambda: {"PEXELS_API_KEY": "sk-0123456789"})
    jobs.start("echo hi")
    assert env.envs == [{"PEXELS_API_KEY": "sk-0123456789"}]
    # A provider that raises means "no secrets", never a failed start.
    env2 = RecordingEnv(stdout="1\n/ws\n")
    JobManager(env2, workspace="/ws", secrets_env=lambda: 1 / 0).start("echo hi")
    assert env2.envs == [None]


def test_job_ids_are_validated_before_they_reach_a_shell():
    env = RecordingEnv()
    jobs = JobManager(env, workspace="/ws")
    assert jobs.status("../etc")["ok"] is False
    assert jobs.output("j0; rm -rf /")["ok"] is False
    assert jobs.cancel("nope")["ok"] is False
    assert env.commands == []


def test_job_state_words():
    assert job_state(exit_code=0, cancelled=False, alive=False) == "finished"
    assert job_state(exit_code=3, cancelled=False, alive=False) == "failed"
    assert job_state(exit_code=124, cancelled=False, alive=False) == "timed_out"
    assert job_state(exit_code=None, cancelled=False, alive=True) == "running"
    assert job_state(exit_code=None, cancelled=False, alive=False) == "failed"
    assert job_state(exit_code=143, cancelled=True, alive=False) == "cancelled"


# -- registration -------------------------------------------------------------------


def test_run_command_background_delegates_to_the_job_manager_or_refuses():
    env = RecordingEnv(stdout="7\n/ws/.cowork/jobs\n")
    jobs = JobManager(env, workspace="/ws", new_id=lambda: "j00000001")
    handler = make_run_command_handler(env, None, jobs)
    out = handler("sleep 5", background=True)
    assert out["ok"] and out["job_id"] == "j00000001"
    # Without a manager the flag is refused with a message, not an exception.
    none = make_run_command_handler(RecordingEnv(), None, None)("sleep 5", background=True)
    assert none["ok"] is False and "background" in none["error"]
    # The foreground path is unchanged.
    fg = make_run_command_handler(RecordingEnv(stdout="hi\n"), None, jobs)("echo hi")
    assert fg["exit_code"] == 0 and fg["stdout"] == "hi\n"


def test_shell_and_job_tools_register_and_hide_without_tmux():
    registry = ToolRegistry()
    env = RecordingEnv(exit_code=1)  # ``command -v tmux`` fails
    manager = TerminalManager(env, task_id="t")
    register_shell_tools(registry, manager)
    register_job_tools(registry, JobManager(env, workspace="/ws"))
    register_run_command(registry, env, None, JobManager(env, workspace="/ws"))
    for name in SHELL_TOOL_NAMES:
        assert registry.has(name) and not registry.available(name)
    for name in JOB_TOOL_NAMES:
        assert registry.has(name) and registry.available(name)
    offered = {t["function"]["name"] for t in registry.openai_tools()}
    assert offered == set(JOB_TOOL_NAMES) | {"run_command"}
    schema = registry.spec("run_command").schema
    assert schema["properties"]["background"]["type"] == "boolean"
    assert registry.dispatch("shell_read", {})["error"].startswith("tool unavailable")


def test_register_job_tools_with_none_registers_nothing():
    registry = ToolRegistry()
    register_job_tools(registry, None)
    assert registry.names() == []


def test_build_runtime_offers_shell_not_terminal(tmp_path):
    from cowork_agent import MockModelClient, build_runtime

    loop = build_runtime(
        MockModelClient(["x"]),
        db_path=str(tmp_path / "s.db"),
        workspace=str(tmp_path),
        version_workspace=False,
        enable_memory=False,
        enable_skills=False,
        enable_mcp=False,
        enable_browser=False,
        shell_session_key="thread-1",
    )
    names = set(loop.registry.names())
    assert set(SHELL_TOOL_NAMES) <= names and set(JOB_TOOL_NAMES) <= names
    assert not any(n.startswith("terminal_") for n in names)


# -- against real tmux / a real shell ---------------------------------------------


@needs_tmux
def test_a_prompt_is_answered_with_y_and_enter(tmp_path):
    registry = ToolRegistry()
    manager = TerminalManager(LocalEnvironment(), task_id=f"st{os.getpid()}", rows=20, cols=90)
    register_shell_tools(registry, manager)
    try:
        started = registry.dispatch(
            "shell_start",
            {"name": "ask", "command": "python3 -c \"print(input('continue? [y/n] '))\"", "cwd": str(tmp_path)},
        )
        assert started["ok"], started
        deadline = time.time() + 10
        read = started
        while time.time() < deadline and not read["running"]:
            time.sleep(0.2)
            read = registry.dispatch("shell_read", {"name": "ask"})
        assert read["running"] is True and read["foreground"] == "python3", read
        assert read["cursor_line"].startswith("continue? [y/n]")

        sent = registry.dispatch("shell_send", {"name": "ask", "keys": ["y", "Enter"]})
        assert sent["ok"], sent
        deadline = time.time() + 10
        after = sent
        while time.time() < deadline and after["running"]:
            time.sleep(0.2)
            after = registry.dispatch("shell_read", {"name": "ask", "lines": 50})
        assert after["running"] is False and after["foreground"] == "bash", after
        # The answer echoed and python printed it back: the tail shows both.
        assert "continue? [y/n] y" in after["screen"]

        listed = registry.dispatch("shell_list", {})
        assert [s["name"] for s in listed["sessions"]] == ["ask"]

        # A second manager of the same task (the next task in this sandbox)
        # attaches to the live shell instead of killing it.
        other = ToolRegistry()
        register_shell_tools(other, TerminalManager(LocalEnvironment(), task_id=manager.task_id))
        again = other.dispatch("shell_start", {"name": "ask"})
        assert again["ok"] and again.get("attached") is True

        assert registry.dispatch("shell_kill", {"name": "ask"})["closed"] is True
        assert registry.dispatch("shell_read", {"name": "ask"})["ok"] is False
    finally:
        manager.close_all()


@needs_tmux
def test_shell_read_caps_the_screen(tmp_path):
    manager = TerminalManager(LocalEnvironment(), task_id=f"sc{os.getpid()}", rows=10, cols=90)
    registry = ToolRegistry()
    register_shell_tools(registry, manager)
    try:
        registry.dispatch("shell_start", {"name": "big", "command": "seq 1 600"})
        deadline = time.time() + 10
        while time.time() < deadline and registry.dispatch("shell_read", {"name": "big"})["running"]:
            time.sleep(0.2)
        few = registry.dispatch("shell_read", {"name": "big", "lines": 5})
        assert few["lines"] == 5
        many = registry.dispatch("shell_read", {"name": "big", "lines": 100000})
        assert many["lines"] <= 2000 and len(many["screen"]) <= SHELL_OUTPUT_CAP
        assert registry.dispatch("shell_read", {"name": "big"})["lines"] <= DEFAULT_LINES
    finally:
        manager.close_all()


def test_a_background_job_returns_at_once_and_ends_with_one_trigger_line(tmp_path):
    jobs = JobManager(LocalEnvironment(), session_key="thread-1", workspace=str(tmp_path))
    t0 = time.monotonic()
    started = jobs.start("echo one; sleep 1; echo two; exit 2", cwd=str(tmp_path))
    assert time.monotonic() - t0 < 1.0, "start must not wait for the job"
    assert started["ok"] and started["pid"]
    job_id = started["job_id"]
    running = jobs.status(job_id)
    assert running["state"] == "running" and running["command"].startswith("echo one")

    deadline = time.time() + 10
    while time.time() < deadline and jobs.status(job_id)["state"] == "running":
        time.sleep(0.2)
    done = jobs.status(job_id)
    assert done["state"] == "failed" and done["exit_code"] == 2 and done["log_lines"] == 2
    assert done["started_at"] and done["finished_at"] >= done["started_at"]
    out = jobs.output(job_id)
    assert out["output"] == "one\ntwo" and out["total_lines"] == 2
    window = jobs.output(job_id, lines=1, offset=2)
    assert window["output"] == "two" and window["offset"] == 2

    triggers = (tmp_path / ".cowork/automations/triggers.jsonl").read_text().splitlines()
    assert len(triggers) == 1
    record = json.loads(triggers[0])
    assert record == {
        "kind": "job",
        "job_id": job_id,
        "session_key": "thread-1",
        "exit_code": 2,
        "timed_out": False,
        "ts": record["ts"],
    }
    assert (tmp_path / ".cowork/jobs" / f"{job_id}.exit").read_text().strip() == "2"
    everything = jobs.status()
    assert [j["job_id"] for j in everything["jobs"]] == [job_id]


def test_cancel_kills_the_group_and_writes_no_trigger(tmp_path):
    jobs = JobManager(LocalEnvironment(), session_key="thread-1", workspace=str(tmp_path))
    started = jobs.start("sleep 60 & sleep 60; echo never", cwd=str(tmp_path))
    job_id = started["job_id"]
    time.sleep(0.3)
    cancelled = jobs.cancel(job_id)
    assert cancelled == {"ok": True, "job_id": job_id, "state": "cancelled"}
    status = jobs.status(job_id)
    assert status["state"] == "cancelled" and status["exit_code"] == 143
    time.sleep(0.5)
    assert not (tmp_path / ".cowork/automations/triggers.jsonl").exists()
    # The whole process group is gone, not just the wrapper.
    pid = int((tmp_path / ".cowork/jobs" / f"{job_id}.pid").read_text())
    with pytest.raises(ProcessLookupError):
        os.killpg(pid, 0)
    assert jobs.cancel(job_id)["state"] == "already finished"
