"""The watcher supervisor's docker path, against a real agent container
(docs/WIRE_CONTRACT.md, "Automations"): the script runs INSIDE the container
(``docker exec``), its trigger lands in the bind-mounted workspace, the
secrets env reaches it by name only, and a kill reaches the tree inside.
Skipped without a usable docker."""

from __future__ import annotations

import json
import os
import subprocess
import time

import pytest

from cowork_host.automations import AutomationManager
from cowork_sandbox import make_environment

pytestmark = pytest.mark.skipif(
    os.environ.get("COWORK_SANDBOX_KIND", "docker") != "docker"
    or subprocess.run(["docker", "info"], capture_output=True, timeout=20).returncode != 0,
    reason="docker not available",
)

WATCHER = """
import os, socket, time
from cowork_hooks import trigger
trigger("inside", payload={"host": socket.gethostname(), "cwd": os.getcwd(),
        "secret_seen": os.environ.get("MY_KEY"), "aid": os.environ.get("COWORK_AUTOMATION_ID")})
time.sleep(120)
"""


def _wait(predicate, timeout: float = 30.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.1)
    return predicate()


def test_a_watcher_runs_inside_the_agents_container(tmp_path):
    workspace = tmp_path / "ws"
    workspace.mkdir()
    (workspace / "watch.py").write_text(WATCHER)
    env = make_environment("docker", workdir=str(workspace), agent_id="automations-test", task_id="t1")
    fired: list[tuple[str, str, dict]] = []
    manager = AutomationManager(
        db_path=str(tmp_path / "state.db"),
        workspace=str(workspace),
        fire=lambda key, prompt, meta: fired.append((key, prompt, meta)) or "run-1",
        env_provider=lambda: {"MY_KEY": "s3cr3t"},
        environment_provider=lambda: env,
        tick=1000.0,
        poll=1000.0,
    )
    try:
        out = manager.start_watcher("s1", "watch.py", "in-container", True)
        assert out["ok"], out
        watcher = manager._watchers[out["id"]]
        assert watcher.docker_cid, "the watcher was not started through docker exec"
        # The value never appears on the exec command line, only its name.
        argv = subprocess.run(["ps", "-o", "args=", "-p", str(watcher.proc.pid)], capture_output=True, text=True).stdout
        assert "-e MY_KEY" in argv and "s3cr3t" not in argv
        assert _wait(lambda: manager.triggers_path().exists() and manager.triggers_path().read_text().strip())
        assert manager.run_watchdog_once() == 1
        _, prompt, _ = fired[0]
        payload = json.loads(prompt.splitlines()[-1])
        assert payload["cwd"] == "/workspace"
        assert payload["secret_seen"] == "s3cr3t"
        assert payload["aid"] == out["id"]
        assert payload["host"] != os.uname().nodename  # a container, not this box
        # ``[p]ython`` keeps pgrep's own shell out of the count.
        inside = env.run_bash("pgrep -f '[p]ython3 watch.py' | wc -l", internal=True).stdout.strip()
        assert inside and int(inside) >= 1
    finally:
        manager.stop()
        after = env.run_bash("pgrep -f '[p]ython3 watch.py' | wc -l", internal=True).stdout.strip()
        env.cleanup()
    assert after == "0", f"watcher still alive in the container: {after}"
