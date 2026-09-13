"""Live proof, no UI (docs/WIRE_CONTRACT.md, "Interactive shell and
background commands"; bead cowork-63z.6). NOT pytest-collected: run it by hand
against the real host with `uv run python tests/live_jobs_probe.py`.

It drives the REAL agent sandbox (the Docker container the running host
uses, found by its labels) and proves:

1. the interactive shell: ``shell_start`` runs a program that asks
   ``continue? [y/n]``, ``shell_read`` sees the question (``running`` true,
   ``cursor_line`` is the prompt), ``shell_send(["y", "Enter"])`` answers it;
2. the background job: ``sleep 20 && echo done`` started with
   ``run_command(background=true)`` returns at once; when it ends the RUNNING
   host wakes the agent — a new ``runs`` row of the session whose prompt
   starts with ``[job <id> finished: exit 0]``, the host log says
   ``[jobs] job <id> exit 0 -> task``, and the run is notified.

Costs cents: the wake is a real model run on the host. Env:
``AGENTS_LIVE_SESSION_KEY`` (default ``host:cowork-host``),
``AGENTS_LIVE_HOSTLOG`` (default ``../.hostlive``).
"""

from __future__ import annotations

import json
import os
import sqlite3
import subprocess
import sys
import time
from pathlib import Path

from chuk_agents_runtime import ToolRegistry
from chuk_agents_runtime.shell_tools import JobManager, register_job_tools, register_shell_tools
from chuk_agents_runtime.terminal import TerminalManager
from chuk_agents_runtime.tools import register_run_command
from chuk_agents_sandbox import make_environment

SESSION_KEY = os.environ.get("AGENTS_LIVE_SESSION_KEY", "host:cowork-host")
HOSTLOG = Path(os.environ.get("AGENTS_LIVE_HOSTLOG", "../.hostlive"))
DB = Path(os.environ.get("AGENTS_LIVE_DB", "~/.agents/executor-state.db")).expanduser()


def say(*parts: object) -> None:
    print(time.strftime("%H:%M:%S"), *parts, flush=True)


def find_agent_container() -> dict:
    out = subprocess.run(
        ["docker", "ps", "--filter", "label=cowork.managed=true", "--filter", "label=cowork.task=default",
         "--format", "{{.ID}}"],
        capture_output=True, text=True, check=True,
    ).stdout.split()
    if not out:
        raise SystemExit("no running agents agent container (label cowork.task=default)")
    labels = json.loads(
        subprocess.run(["docker", "inspect", "-f", "{{json .Config.Labels}}", out[0]], capture_output=True, text=True, check=True).stdout
    )
    return {"id": out[0], "agent_id": labels["cowork.agent"], "workspace": labels.get("cowork.workspace"), "image": labels.get("cowork.image")}


def wait_until(predicate, *, timeout: float, every: float = 1.0, what: str = ""):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(every)
    raise SystemExit(f"timeout waiting for {what}")


def main() -> int:
    box = find_agent_container()
    say("agent container", box)
    env = make_environment("docker", agent_id=box["agent_id"], workdir=box["workspace"], image=box["image"])
    who = env.run_bash("id -un; id -u; sudo -n true && echo SUDO_OK; tmux -V; echo $AGENTS_WORKSPACE", timeout=60)
    say("in the sandbox:", who.stdout.strip().replace("\n", " | "))
    assert "SUDO_OK" in who.stdout and "tmux" in who.stdout, who

    registry = ToolRegistry()
    manager = TerminalManager(env, task_id="live75")
    register_shell_tools(registry, manager)
    jobs = JobManager(env, session_key=SESSION_KEY, workspace=box["workspace"])
    register_job_tools(registry, jobs)
    register_run_command(registry, env, None, jobs)

    # -- 1. the interactive shell -------------------------------------------------
    say("-- shell_start with an interactive program")
    started = registry.dispatch("shell_start", {"name": "ask", "command": "python3 -c \"print('answer:', input('continue? [y/n] '))\""})
    say("shell_start ->", json.dumps({k: started[k] for k in ("ok", "running", "foreground", "cursor_line")}))
    def prompt_shown():
        r = registry.dispatch("shell_read", {"name": "ask"})
        return r if r.get("running") else None

    read = wait_until(prompt_shown, timeout=15, every=0.5, what="the prompt")
    say("shell_read  ->", json.dumps({k: read[k] for k in ("running", "foreground", "cursor_line")}))
    assert read["running"] and read["cursor_line"].startswith("continue? [y/n]"), read
    sent = registry.dispatch("shell_send", {"name": "ask", "keys": ["y", "Enter"]})
    def program_ended():
        r = registry.dispatch("shell_read", {"name": "ask", "lines": 20})
        return r if not r.get("running") else None

    after = wait_until(program_ended, timeout=15, every=0.5, what="the program to end")
    say("shell_send  ->", json.dumps({k: sent[k] for k in ("ok", "running")}))
    say("after       ->", json.dumps({k: after[k] for k in ("running", "foreground")}), "| screen tail:", after["screen"].splitlines()[-3:])
    assert "answer: y" in after["screen"], after["screen"]
    say("shell_list  ->", registry.dispatch("shell_list", {}))
    say("shell_kill  ->", registry.dispatch("shell_kill", {"name": "ask"}))

    # -- 2. the background job + the wake-up on the running host -----------------------
    say("-- run_command background=true: sleep 20 && echo done")
    log_offset = HOSTLOG.stat().st_size if HOSTLOG.exists() else 0
    t0 = time.monotonic()
    job = registry.dispatch("run_command", {"command": "sleep 20 && echo done", "background": True})
    say(f"run_command returned in {time.monotonic() - t0:.2f} s ->", json.dumps({k: job.get(k) for k in ("ok", "job_id", "pid", "log_path", "state")}))
    assert job["ok"], job
    job_id = job["job_id"]
    say("job_status  ->", json.dumps({k: registry.dispatch("job_status", {"job_id": job_id}).get(k) for k in ("state", "exit_code", "started_at")}))

    def woke():
        text = HOSTLOG.read_text(errors="replace")[log_offset:] if HOSTLOG.exists() else ""
        lines = [l for l in text.splitlines() if "[jobs]" in l and job_id in l]
        return lines or None

    lines = wait_until(woke, timeout=120, what="the host log line for the job")
    say("host log    ->", *lines)
    status = registry.dispatch("job_status", {"job_id": job_id})
    say("job_status  ->", json.dumps({k: status.get(k) for k in ("state", "exit_code", "log_lines")}))
    say("job_output  ->", json.dumps(registry.dispatch("job_output", {"job_id": job_id})["output"]))

    def run_row():
        conn = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
        try:
            row = conn.execute(
                "select run_id, state, reason, notified_at, substr(prompt,1,120), substr(final_answer,1,200) from runs "
                "where session_key=? and prompt like ? order by started_at desc limit 1",
                (SESSION_KEY, f"[job {job_id} finished%"),
            ).fetchone()
        finally:
            conn.close()
        return row

    row = wait_until(run_row, timeout=60, what="the runs row of the wake task")
    say("runs row    ->", json.dumps({"run_id": row[0], "state": row[1], "reason": row[2], "notified_at": row[3], "prompt": row[4]}))
    def run_closed():
        r = run_row()
        return r if r and r[1] != "running" else None

    finished = wait_until(run_closed, timeout=600, every=2.0, what="the wake task to finish")
    say("runs row    ->", json.dumps({"run_id": finished[0], "state": finished[1], "reason": finished[2], "notified_at": finished[3], "final_answer": finished[5]}))
    notify_lines = [l for l in HOSTLOG.read_text(errors="replace")[log_offset:].splitlines() if "notif" in l.lower() or "toast" in l.lower()]
    say("notifier    ->", *(notify_lines[-3:] or ["(no notifier line in the host log; see runs.notified_at)"]))
    ok = finished[1] == "finished" and finished[3] is not None
    say("RESULT:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
