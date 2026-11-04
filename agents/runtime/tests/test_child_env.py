"""Bead B9 for the runtime's own stand-in environment: a command never sees
the host's credentials, and a timeout is SIGTERM first, SIGKILL later."""

from __future__ import annotations

import os
import subprocess
import time

import pytest

from chuk_agents_runtime import child_env as rt_child_env
from chuk_agents_runtime.environment import LocalEnvironment


def test_the_host_secrets_never_reach_a_command(monkeypatch):
    monkeypatch.setenv("AGENTS_ACCOUNT_TOKEN", "leak-account")
    monkeypatch.setenv("OPENAI_API_KEY", "leak-openai")
    monkeypatch.setenv("SOME_SECRET", "leak-secret")
    result = LocalEnvironment().run_bash("env")
    assert result.exit_code == 0
    assert "leak-" not in result.stdout
    for line in ("NO_COLOR=1", "TERM=dumb", "PAGER=cat", "GIT_PAGER=cat"):
        assert line in result.stdout.splitlines()
    granted = LocalEnvironment().run_bash('echo "$OPENAI_API_KEY"', env={"OPENAI_API_KEY": "mine"})
    assert granted.stdout.strip() == "mine"


def test_timeout_term_then_kill():
    import subprocess

    import chuk_agents_runtime.environment as environment

    start = time.monotonic()
    result = LocalEnvironment().run_bash(
        "trap 'echo got-term; exit 3' TERM; sleep 30 & wait", timeout=1
    )
    assert result.timed_out and "got-term" in result.stdout
    proc = subprocess.Popen(["bash", "-c", "trap '' TERM; sleep 30"], start_new_session=True)
    time.sleep(0.2)
    environment.terminate_group(proc, grace=0.3)
    assert proc.wait(5) == -9
    assert time.monotonic() - start < 15


def test_the_two_copies_agree():
    """``chuk_agents_runtime.child_env`` copies ``chuk_agents_sandbox.child_env``."""
    assert rt_child_env.FIXED == {
        "NO_COLOR": "1", "TERM": "dumb", "PAGER": "cat", "GIT_PAGER": "cat",
    }
    assert not rt_child_env.is_allowed("GH_TOKEN")
    assert rt_child_env.is_allowed("LC_ALL")


@pytest.mark.parametrize("module", ["chuk_agents_runtime.child_env"])
def test_the_scrub_snippet_runs_on_bash_3_2(module):
    """macOS ships bash 3.2: no ``${var^^}``. The scrub must still drop names
    in any case, keep the rest, and leave ``nocasematch`` as it found it."""
    import importlib

    snippet = importlib.import_module(module).SCRUB_SNIPPET
    assert "^^" not in snippet and ",," not in snippet
    script = (
        f"{snippet}; "
        'echo "lower=${my_api_key-unset} mixed=${Github_Token-unset} '
        'keep=${KEEP_ME-unset}"; shopt -q nocasematch && echo nc=on || echo nc=off'
    )
    env = {
        "PATH": os.environ["PATH"],
        "my_api_key": "s1",
        "Github_Token": "s2",
        "KEEP_ME": "yes",
    }
    out = subprocess.run(
        ["bash", "--norc", "--noprofile", "-c", script],
        capture_output=True,
        text=True,
        env=env,
        check=True,
    )
    assert out.stderr == ""
    assert "lower=unset mixed=unset keep=yes" in out.stdout
    assert "nc=off" in out.stdout
