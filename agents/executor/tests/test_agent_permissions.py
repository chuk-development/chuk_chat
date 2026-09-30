"""Per-agent permissions in the executor (docs/WIRE_CONTRACT.md, "Agent
permissions", bead chuk_chat-voq3).

The executor does four things with them: it routes the app's two frames to the
host, it re-reads a session's policy at the start of every task (and only
there), it keeps secrets out of an agent whose ``secrets_env`` is off, and it
builds a subagent's sandbox under its parent's policy.
"""

from __future__ import annotations

import json

import pytest

from chuk_agents_runtime import MockModelClient, tool_call_response
from chuk_agents_sandbox import DEFAULT_POLICY, LocalEnvironment, SandboxPolicy

from chuk_agents_executor import ControllerSession, Executor, SecretsVault, loopback_pair
from chuk_agents_executor.executor import SECRETS_OFF_MESSAGE
from chuk_agents_executor.protocol import BROWSER_TARGET_ENV, USER_BROWSER

from wiring import paired_channel

VALUE = "sk-live-0123456789abcdef"


def _boot(tmp_path, *, environment, model_factory=None, **kw):
    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    executor = Executor(
        name="agent",
        endpoint=executor_ep,
        opener=channel.executor.opener,
        sealer=channel.executor.sealer,
        environment=environment,
        db_path=str(tmp_path / "state.db"),
        model_factory=model_factory or (lambda: MockModelClient(["ok"])),
        workspace=str(tmp_path / "ws"),
        **kw,
    )
    controller = ControllerSession(
        endpoint=controller_ep,
        sealer=channel.controller.sealer,
        opener=channel.controller.opener,
    )
    return executor, controller


def _workspace(tmp_path):
    ws = tmp_path / "ws"
    ws.mkdir(exist_ok=True)
    return ws


# ------------------------------------------------------------------ frames


def test_both_frames_reach_the_host_hook_and_its_answer_is_the_terminal(tmp_path):
    seen: list[dict] = []

    def hook(payload: dict):
        seen.append(payload)
        return {
            "type": "agent_permissions",
            "agent_id": payload["agent_id"],
            "permissions": DEFAULT_POLICY.merged(payload.get("permissions") or {}).to_dict(),
            "applies_from": "next_task",
        }

    env = LocalEnvironment(workdir=str(_workspace(tmp_path)))
    executor, controller = _boot(tmp_path, environment=env, on_agent_frame=hook)
    executor.start()
    try:
        rid = controller.send_payload({"type": "agent_permissions_get", "agent_id": "a"})
        got = controller.collect(rid, timeout=10.0)[-1]
        rid = controller.send_payload(
            {"type": "agent_permissions_set", "agent_id": "a", "permissions": {"network": False}}
        )
        changed = controller.collect(rid, timeout=10.0)[-1]
    finally:
        executor.stop()

    assert [p["type"] for p in seen] == ["agent_permissions_get", "agent_permissions_set"]
    assert got["type"] == "agent_permissions"
    assert got["permissions"]["network"] is True
    assert changed["permissions"]["network"] is False
    assert changed["applies_from"] == "next_task"


def test_without_a_host_hook_the_answer_is_still_agent_permissions(tmp_path):
    """Never a bare ``error``: the app reads that as the end of a run."""
    env = LocalEnvironment(workdir=str(_workspace(tmp_path)))
    executor, controller = _boot(tmp_path, environment=env)
    executor.start()
    try:
        rid = controller.send_payload({"type": "agent_permissions_get", "agent_id": "a"})
        reply = controller.collect(rid, timeout=10.0)[-1]
    finally:
        executor.stop()
    assert reply["type"] == "agent_permissions"
    assert reply["agent_id"] == "a"
    assert "not enabled" in reply["error"]


def test_a_raising_host_hook_is_answered_with_agent_permissions(tmp_path):
    def hook(_payload):
        raise RuntimeError("boom")

    env = LocalEnvironment(workdir=str(_workspace(tmp_path)))
    executor, controller = _boot(tmp_path, environment=env, on_agent_frame=hook)
    executor.start()
    try:
        rid = controller.send_payload({"type": "agent_permissions_set", "agent_id": "a",
                                       "permissions": {"sudo": False}})
        reply = controller.collect(rid, timeout=10.0)[-1]
    finally:
        executor.stop()
    assert reply["type"] == "agent_permissions"
    assert "RuntimeError" in reply["error"]


def test_a_run_error_names_its_thread(tmp_path):
    """The app ends only the stream an error names."""

    def factory():
        raise RuntimeError("no model")

    env = LocalEnvironment(workdir=str(_workspace(tmp_path)))
    executor, controller = _boot(tmp_path, environment=env, model_factory=factory)
    executor.start()
    try:
        events = controller.collect(controller.send_task("go", session_key="s1"), timeout=20.0)
    finally:
        executor.stop()
    errors = [e for e in events if e.get("type") == "error"]
    assert errors and errors[-1]["session_key"] == "s1"


# ------------------------------------------ secrets_env, from the next task on


def test_secrets_off_keeps_values_out_and_request_secrets_explains(tmp_path):
    vault = SecretsVault()
    vault.replace({"X": VALUE}, revision=1)
    current = {"policy": SandboxPolicy(secrets_env=False)}
    env = LocalEnvironment(
        workdir=str(_workspace(tmp_path)), policy_provider=lambda: current["policy"]
    )

    def factory():
        return MockModelClient([
            tool_call_response(("run_command", {"command": 'echo "[$X]"'})),
            tool_call_response(("request_secrets", {"names": ["X"], "purpose": "test"})),
            "ok",
        ])

    executor, controller = _boot(tmp_path, environment=env, model_factory=factory, secrets=vault)
    executor.start()
    try:
        off = controller.collect(controller.send_task("go", session_key="s1"), timeout=20.0)
        # The user switches secrets back on between two tasks.
        current["policy"] = DEFAULT_POLICY
        on = controller.collect(controller.send_task("again", session_key="s1"), timeout=20.0)
    finally:
        executor.stop()

    off_tools = [e for e in off if e.get("type") == "tool"]
    assert off_tools[0]["stdout"] == "[]\n"
    assert "switched off" in json.dumps(off_tools[1])
    assert not any(e.get("type") == "secret_request" for e in off)
    on_tools = [e for e in on if e.get("type") == "tool"]
    assert on_tools[0]["stdout"] == "[[REDACTED:X]]\n"


def test_the_policy_is_read_at_the_start_of_a_task(tmp_path):
    reads: list[int] = []
    current = {"policy": DEFAULT_POLICY}

    def provider():
        reads.append(1)
        return current["policy"]

    env = LocalEnvironment(workdir=str(_workspace(tmp_path)), policy_provider=provider)
    at_construction = len(reads)
    executor, controller = _boot(tmp_path, environment=env)
    executor.start()
    try:
        current["policy"] = SandboxPolicy(network=False)
        assert env.policy == DEFAULT_POLICY  # nothing applied between tasks
        controller.collect(controller.send_task("go", session_key="s1"), timeout=20.0)
    finally:
        executor.stop()
    assert len(reads) == at_construction + 1
    assert env.policy == SandboxPolicy(network=False)


def test_the_secrets_off_access_raises_the_explanation():
    from chuk_agents_executor.executor import _SecretsOff

    vault = SecretsVault()
    vault.replace({"X": VALUE}, revision=1)
    access = _SecretsOff(vault)
    # No names for the model; the values only feed the result scrubber.
    assert access.names() == []
    assert access.env() == {"X": VALUE}
    with pytest.raises(PermissionError, match="switched off"):
        access.request(["X"], "why")
    assert "next task" in SECRETS_OFF_MESSAGE


# --------------------------------------------------------------- subagents


def test_a_subagent_sandbox_inherits_the_parents_policy(tmp_path):
    parent = SandboxPolicy(sudo=False, network=False, secrets_env=False)
    env = LocalEnvironment(workdir=str(_workspace(tmp_path)), policy=parent)
    executor, _controller = _boot(tmp_path, environment=env, subagent_sandbox="local")
    config = executor._subagent_config("req", "s1")
    child = config.env_factory("child-1")
    try:
        assert child.policy == parent
    finally:
        child.cleanup()


def test_a_parent_without_a_policy_gives_the_child_none(tmp_path):
    env = LocalEnvironment(workdir=str(_workspace(tmp_path)))
    executor, _controller = _boot(tmp_path, environment=env, subagent_sandbox="local")
    child = executor._subagent_config("req", "s1").env_factory("child-1")
    try:
        assert child.policy is None
    finally:
        child.cleanup()


# ------------------------------------------------------------ user browser


def test_user_browser_is_per_agent(tmp_path, monkeypatch):
    monkeypatch.setenv(BROWSER_TARGET_ENV, USER_BROWSER)
    off = LocalEnvironment(workdir=str(_workspace(tmp_path)), policy=DEFAULT_POLICY)
    executor, _c = _boot(tmp_path, environment=off)
    # The agent's own switch wins over the old host-wide setting.
    assert executor._uses_user_browser("s1") is False
    off.set_policy(SandboxPolicy(user_browser=True))
    assert executor._uses_user_browser("s1") is True


def test_no_policy_keeps_the_host_wide_browser_switch(tmp_path, monkeypatch):
    env = LocalEnvironment(workdir=str(_workspace(tmp_path)))
    executor, _c = _boot(tmp_path, environment=env)
    monkeypatch.delenv(BROWSER_TARGET_ENV, raising=False)
    assert executor._uses_user_browser("s1") is False
    monkeypatch.setenv(BROWSER_TARGET_ENV, USER_BROWSER)
    assert executor._uses_user_browser("s1") is True


# ------------------------------------------------------ one lease per run


class _LeaseRecorder(LocalEnvironment):
    """Records how many runs held the environment at every command."""

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self.seen_leases: list[int] = []

    def _run_bash(self, cmd, **kwargs):
        self.seen_leases.append(self.leases)
        return super()._run_bash(cmd, **kwargs)


def test_every_command_of_a_run_runs_under_its_lease(tmp_path):
    current = {"policy": DEFAULT_POLICY}
    env = _LeaseRecorder(workdir=str(_workspace(tmp_path)), policy_provider=lambda: current["policy"])

    def factory():
        return MockModelClient([
            tool_call_response(("run_command", {"command": "echo one"})),
            tool_call_response(("run_command", {"command": "echo two"})),
            "ok",
        ])

    executor, controller = _boot(tmp_path, environment=env, model_factory=factory)
    executor.start()
    try:
        controller.collect(controller.send_task("go", session_key="s1"), timeout=20.0)
    finally:
        executor.stop()
    assert env.seen_leases and all(n == 1 for n in env.seen_leases)
    assert env.leases == 0


def test_a_change_made_while_another_run_holds_the_box_waits(tmp_path):
    """A room turn holds the shared box: a direct task keeps its policy."""
    current = {"policy": DEFAULT_POLICY}
    env = LocalEnvironment(workdir=str(_workspace(tmp_path)), policy_provider=lambda: current["policy"])
    executor, controller = _boot(tmp_path, environment=env)
    env.begin_run()  # the room member's run, on the same environment
    current["policy"] = SandboxPolicy(network=False)
    executor.start()
    try:
        controller.collect(controller.send_task("go", session_key="s1"), timeout=20.0)
        assert env.policy == DEFAULT_POLICY
    finally:
        env.end_run()
        executor.stop()
    assert env.leases == 0
    assert env.begin_run() == SandboxPolicy(network=False)
    env.end_run()


# ------------------------------------------- masking with secrets switched off


def test_secrets_off_still_masks_a_value_left_in_a_file(tmp_path):
    vault = SecretsVault()
    vault.replace({"X": VALUE}, revision=1)
    ws = _workspace(tmp_path)
    (ws / "old.txt").write_text(f"token={VALUE}\n")
    env = LocalEnvironment(workdir=str(ws), policy=SandboxPolicy(secrets_env=False))

    def factory():
        return MockModelClient([
            tool_call_response(("run_command", {"command": "cat old.txt"})),
            "ok",
        ])

    executor, controller = _boot(tmp_path, environment=env, model_factory=factory, secrets=vault)
    executor.start()
    try:
        events = controller.collect(controller.send_task("go", session_key="s1"), timeout=20.0)
    finally:
        executor.stop()
    tools = [e for e in events if e.get("type") == "tool"]
    assert "[REDACTED:X]" in json.dumps(tools[0])
    assert VALUE not in json.dumps(events)


def test_switching_secrets_off_ends_the_agents_local_jobs(tmp_path):
    ws = _workspace(tmp_path)
    current = {"policy": DEFAULT_POLICY}
    env = LocalEnvironment(workdir=str(ws), policy_provider=lambda: current["policy"])
    executor, _controller = _boot(tmp_path, environment=env)
    from chuk_agents_runtime.shell_tools import JOB_RUNNING, JobManager

    jobs = JobManager(executor._shim_for("s1"), workspace=str(ws))
    started = jobs.start("sleep 60")
    assert started["ok"], started
    job_id = started["job_id"]
    try:
        current["policy"] = SandboxPolicy(secrets_env=False)
        leased = executor._lease_sandbox("s1")
        executor._release_sandbox(leased)
        states = {j["job_id"]: j["state"] for j in jobs.status()["jobs"]}
        assert states[job_id] != JOB_RUNNING
    finally:
        jobs.cancel(job_id)


# ------------------------------------------------------------ network off


def test_network_off_drops_the_forwarded_connectors(tmp_path):
    env = LocalEnvironment(workdir=str(_workspace(tmp_path)), policy=SandboxPolicy(network=False))
    executor, controller = _boot(tmp_path, environment=env)
    executor.start()
    try:
        rid = controller.send_payload({
            "type": "task", "prompt": "go", "session_key": "s1",
            "mcp_servers": [{"name": "remote", "url": "https://mcp.example.com/mcp"}],
        })
        controller.collect(rid, timeout=20.0)
    finally:
        executor.stop()
    assert executor._mcp_managers.get("s1") is None


def test_network_off_never_uses_the_users_browser(tmp_path):
    env = LocalEnvironment(
        workdir=str(_workspace(tmp_path)),
        policy=SandboxPolicy(user_browser=True, network=False),
    )
    executor, _c = _boot(tmp_path, environment=env)
    assert executor._uses_user_browser("s1") is False
