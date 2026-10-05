"""Per-agent permissions on the host (docs/WIRE_CONTRACT.md, "Agent
permissions", bead chuk_chat-voq3).

The host keeps them, validates every change, answers the app's two frames and
hands every per-agent sandbox a provider over the store. A change applies at
the next container creation, which is the next task.
"""

from __future__ import annotations

import json
import os
import stat

import pytest

from chuk_agents_manager import ContainerSupervisor
from chuk_agents_runtime.action_policy import ActionPolicy
from chuk_agents_sandbox import (
    DEFAULT_POLICY,
    LABEL_POLICY,
    CliResult,
    DockerCli,
    DockerEnvironment,
    SandboxPolicy,
    enforced_permissions,
)

from chuk_agents_host import LocalHost
from chuk_agents_host.agent_permissions import (
    APPLIES_FROM,
    FILE_NAME,
    AgentPermissionsStore,
    handle_permissions_frame,
    host_defaults,
    permissions_env_factory,
)
from chuk_agents_host.coworker_names import host_agent_id
from chuk_agents_host.identity import HOST_DEVICE_ID


class _FakeCli(DockerCli):
    """Records every ``docker run`` and answers ``ps`` from what it made."""

    def __init__(self) -> None:
        super().__init__()
        self.containers: list[dict] = []
        self.created: list[list[str]] = []
        self.removed: list[str] = []
        self._next = 0

    def available(self) -> bool:
        return True

    def run(self, *args: str, timeout: int | None = None) -> CliResult:
        verb = args[0] if args else ""
        if verb == "ps":
            wanted = {}
            for index, arg in enumerate(args):
                if arg == "--filter" and args[index + 1].startswith("label="):
                    key, _, value = args[index + 1][len("label="):].partition("=")
                    wanted[key] = value
            lines = [
                f"{c['id']}\t{c['name']}\trunning\t"
                + ",".join(f"{k}={v}" for k, v in c["labels"].items())
                for c in self.containers
                if all(c["labels"].get(k) == v for k, v in wanted.items())
            ]
            return CliResult("\n".join(lines) + ("\n" if lines else ""), "", 0)
        if verb == "run":
            self.created.append(list(args))
            labels = {}
            for index, arg in enumerate(args):
                if arg == "--label":
                    key, _, value = args[index + 1].partition("=")
                    labels[key] = value
            self._next += 1
            cid = f"cid-{self._next}"
            self.containers.append({"id": cid, "name": cid, "labels": labels})
            return CliResult(cid + "\n", "", 0)
        if verb == "rm":
            self.removed.append(args[-1])
            self.containers = [c for c in self.containers if c["id"] != args[-1]]
            return CliResult("", "", 0)
        return CliResult("1000\n", "", 0)


def _pairs(argv: list[str], flag: str) -> list[str]:
    return [argv[i + 1] for i, a in enumerate(argv) if a == flag]


# ---------------------------------------------------------------- the store


def test_defaults_allow_everything_but_the_users_browser(tmp_path):
    store = AgentPermissionsStore(tmp_path / FILE_NAME)
    assert store.get("local:amber:1").to_dict() == {
        "sudo": True,
        "network": True,
        "secrets_env": True,
        "workspace_mount": "rw",
        "user_browser": False,
    }
    assert not (tmp_path / FILE_NAME).exists()  # nothing written for a read


def test_the_old_host_wide_browser_switch_becomes_the_default(tmp_path):
    store = AgentPermissionsStore(None, defaults=host_defaults(user_browser=True))
    assert store.get("a").user_browser is True
    assert store.update("a", {"user_browser": False}).user_browser is False


def test_persistence_round_trip(tmp_path):
    path = tmp_path / FILE_NAME
    store = AgentPermissionsStore(path)
    store.update("local:amber:1", {"network": False})
    store.update("local:amber:1", {"workspace_mount": "ro"})
    store.update("local:blue:2", {"sudo": False})

    again = AgentPermissionsStore(path)
    assert again.get("local:amber:1") == SandboxPolicy(network=False, workspace_mount="ro")
    assert again.get("local:blue:2") == SandboxPolicy(sudo=False)
    assert again.get("never-set") == DEFAULT_POLICY
    # Only what the user set is stored, so a later default still reaches the rest.
    raw = json.loads(path.read_text())
    assert raw["agents"]["local:amber:1"] == {"network": False, "workspace_mount": "ro"}
    assert stat.S_IMODE(os.stat(path).st_mode) == 0o600


def test_a_corrupt_file_falls_back_to_the_defaults(tmp_path):
    path = tmp_path / FILE_NAME
    path.write_text("{ not json")
    assert AgentPermissionsStore(path).get("a") == DEFAULT_POLICY
    path.write_text(json.dumps({"agents": {"a": {"sudo": "yes"}, "b": {"sudo": False}}}))
    store = AgentPermissionsStore(path)
    assert store.get("a") == DEFAULT_POLICY  # the bad entry is dropped
    assert store.get("b").sudo is False


# ----------------------------------------------------------------- frames


def _frame(store, payload, **kw) -> dict:
    reply, _before, _after = handle_permissions_frame(store, payload, **kw)
    return reply


def test_get_answers_the_whole_set_what_is_enforced_and_when_it_applies(tmp_path):
    store = AgentPermissionsStore(tmp_path / FILE_NAME)
    reply = _frame(store, {"type": "agent_permissions_get", "agent_id": "local:amber:1"})
    assert reply == {
        "type": "agent_permissions",
        "agent_id": "local:amber:1",
        "permissions": DEFAULT_POLICY.to_dict(),
        "applies_from": APPLIES_FROM,
        "enforced": enforced_permissions("docker"),
        # Per-action approvals ride the same reply (docs/WIRE_CONTRACT.md,
        # "Per-action approvals").
        "approvals": {**ActionPolicy().to_dict(), "applies_from": "next_action"},
        # The weekly budget too (docs/WIRE_CONTRACT.md, "Cost per run and
        # weekly budget"): 0 = none.
        "budget_weekly": 0.0,
    }
    assert APPLIES_FROM == "next_task"


def test_the_local_backend_says_what_it_does_not_enforce(tmp_path):
    store = AgentPermissionsStore(tmp_path / FILE_NAME)
    reply = _frame(
        store,
        {"type": "agent_permissions_get", "agent_id": "a"},
        enforced=enforced_permissions("local"),
    )
    assert reply["enforced"]["sudo"] is False
    assert reply["enforced"]["secrets_env"] is True


def test_set_takes_a_partial_and_answers_the_new_set(tmp_path):
    store = AgentPermissionsStore(tmp_path / FILE_NAME)
    reply, before, after = handle_permissions_frame(
        store,
        {"type": "agent_permissions_set", "agent_id": "a", "permissions": {"network": False}},
    )
    assert reply["permissions"]["network"] is False
    assert reply["permissions"]["sudo"] is True
    assert "error" not in reply
    assert store.get("a").network is False
    assert before == DEFAULT_POLICY and after == SandboxPolicy(network=False)
    # The same set again changes nothing.
    _reply, before, after = handle_permissions_frame(
        store,
        {"type": "agent_permissions_set", "agent_id": "a", "permissions": {"network": False}},
    )
    assert before is None and after is None


@pytest.mark.parametrize(
    "permissions, message",
    [
        ({"root": True}, "unknown permission"),
        ({"sudo": 1}, "sudo must be true or false"),
        ({"network": "off"}, "network must be true or false"),
        ({"workspace_mount": "none"}, "workspace_mount"),
        ({"network": False, "secrets_env": "no"}, "secrets_env"),
        ("sudo=false", "permissions must be an object"),
    ],
)
def test_a_bad_set_changes_nothing_and_says_why(tmp_path, permissions, message):
    path = tmp_path / FILE_NAME
    store = AgentPermissionsStore(path)
    reply = _frame(
        store, {"type": "agent_permissions_set", "agent_id": "a", "permissions": permissions}
    )
    assert message in reply["error"]
    assert reply["type"] == "agent_permissions"
    assert reply["permissions"] == DEFAULT_POLICY.to_dict()
    assert store.get("a") == DEFAULT_POLICY
    assert not path.exists()


@pytest.mark.parametrize(
    "payload",
    [
        {"type": "agent_permissions_get"},
        {"type": "agent_permissions_get", "agent_id": ""},
        {"type": "agent_permissions_get", "agent_id": 7},
        {"type": "agent_permissions_get", "agent_id": "x" * 300},
        {"type": "agent_permissions_delete", "agent_id": "a"},
    ],
)
def test_a_malformed_frame_is_answered_with_agent_permissions_and_an_error(tmp_path, payload):
    """Never a bare ``error``: the app reads that as the end of a run."""
    store = AgentPermissionsStore(tmp_path / FILE_NAME)
    reply = _frame(store, payload)
    assert reply["type"] == "agent_permissions"
    assert reply["error"]
    assert "permissions" not in reply


def test_an_unknown_agent_is_an_error_and_changes_nobody(tmp_path):
    store = AgentPermissionsStore(tmp_path / FILE_NAME)
    reply = _frame(
        store,
        {"type": "agent_permissions_set", "agent_id": "local:gone:9",
         "permissions": {"sudo": False}},
        key_for=lambda _agent: None,
    )
    assert reply["type"] == "agent_permissions"
    assert reply["agent_id"] == "local:gone:9"
    assert "unknown agent" in reply["error"]
    assert "permissions" not in reply
    assert store.overrides() == {}


def test_key_for_maps_the_app_id_and_the_reply_keeps_it(tmp_path):
    store = AgentPermissionsStore(tmp_path / FILE_NAME)
    reply = _frame(
        store,
        {"type": "agent_permissions_set", "agent_id": "host:dev", "permissions": {"sudo": False}},
        key_for=lambda _agent: "roster-row-1",
    )
    assert reply["agent_id"] == "host:dev"
    assert store.get("roster-row-1").sudo is False
    assert store.get("host:dev").sudo is True


# ------------------------------------------------ enforcement at creation


def _supervisor(store: AgentPermissionsStore, cli: _FakeCli) -> ContainerSupervisor:
    return ContainerSupervisor(
        image="img:1", cli=cli, env_factory=permissions_env_factory(store)
    )


def test_docker_run_args_per_permission(tmp_path):
    store = AgentPermissionsStore(tmp_path / FILE_NAME)
    store.update("net", {"network": False})
    store.update("ro", {"workspace_mount": "ro"})
    store.update("nosudo", {"sudo": False})
    cli = _FakeCli()
    workspaces = {a: str(tmp_path / a) for a in ("net", "ro", "nosudo", "plain")}
    sup = ContainerSupervisor(
        image="img:1",
        cli=cli,
        workspace_resolver=workspaces.get,
        env_factory=permissions_env_factory(store),
    )
    argv = {}
    for agent in workspaces:
        sup.environment(agent)._ensure_container()
        argv[agent] = cli.created[-1]

    assert _pairs(argv["net"], "--network") == ["none"]
    assert f"{workspaces['ro']}:/workspace:ro" in _pairs(argv["ro"], "-v")
    assert _pairs(argv["nosudo"], "--security-opt") == ["no-new-privileges"]
    assert "AGENTS_SUDO=0" in _pairs(argv["nosudo"], "-e")
    plain = argv["plain"]
    assert "--network" not in plain and "--security-opt" not in plain
    assert f"{workspaces['plain']}:/workspace" in _pairs(plain, "-v")


def test_a_change_applies_at_the_next_container_creation(tmp_path):
    store = AgentPermissionsStore(tmp_path / FILE_NAME)
    cli = _FakeCli()
    env = _supervisor(store, cli).environment("a")
    first = env._ensure_container()
    assert "--network" not in cli.created[-1]

    # The app switches the network off while a task runs.
    env.begin_run()
    _frame(
        store, {"type": "agent_permissions_set", "agent_id": "a", "permissions": {"network": False}}
    )
    assert env._ensure_container() == first  # same run: same box
    env.end_run()
    assert len(cli.created) == 1

    # The next task starts with no run holding the box.
    env.begin_run()
    second = env._ensure_container()
    env.end_run()
    assert second != first
    assert cli.removed == [first]
    assert _pairs(cli.created[-1], "--network") == ["none"]
    assert cli.containers[0]["labels"][LABEL_POLICY] == "sudo=1;network=0;workspace=rw;secrets=1"


def test_a_subagent_box_gets_its_parents_permissions(tmp_path):
    store = AgentPermissionsStore(tmp_path / FILE_NAME)
    store.update("a", {"sudo": False, "network": False})
    cli = _FakeCli()
    child = _supervisor(store, cli).task_environment("a", "sub-1")
    assert isinstance(child, DockerEnvironment)
    assert child.policy == SandboxPolicy(sudo=False, network=False)
    child._ensure_container()
    assert _pairs(cli.created[-1], "--network") == ["none"]
    assert _pairs(cli.created[-1], "--security-opt") == ["no-new-privileges"]


# ------------------------------------------------------------ the host


def _host(tmp_path, **opts) -> LocalHost:
    return LocalHost(
        port=0,
        workspace_dir=str(tmp_path / "state"),
        channel_id="testchannel",
        agent_name="pytest-agent",
        model_factory_override=lambda: None,
        **opts,
    )


def test_the_host_answers_both_frames_through_its_agent_hook(tmp_path):
    host = _host(tmp_path)
    host._coworker_names.upsert("local:amber:1", "amber", created_by_app=True)
    try:
        reply = host._on_agent_frame(
            {"type": "agent_permissions_set", "agent_id": "local:amber:1",
             "permissions": {"secrets_env": False}}
        )
        assert reply["permissions"]["secrets_env"] is False
        got = host._on_agent_frame(
            {"type": "agent_permissions_get", "agent_id": "local:amber:1"}
        )
        assert got["permissions"]["secrets_env"] is False
        # Coworker frames still get the name list.
        assert isinstance(host._on_agent_frame({"type": "agent_list"}), list)
        # The local sandbox of that coworker reads the same store.
        env = host._environment_for("local:amber:1")
        assert env.policy.secrets_env is False
        # ...and persisted in the state directory.
        assert (tmp_path / "state" / FILE_NAME).exists()
    finally:
        host._roster.close()
        host._coworker_names.close()


def test_the_host_agent_is_one_agent_under_every_name(tmp_path):
    host = _host(tmp_path)
    try:
        host._on_agent_frame(
            {"type": "agent_permissions_set", "agent_id": host_agent_id(HOST_DEVICE_ID),
             "permissions": {"workspace_mount": "ro"}}
        )
        assert host._permissions.get(host._agent.id).workspace_mount == "ro"
        env = host._environment_for(host._agent.id)
        assert env.policy.workspace_mount == "ro"
    finally:
        host._roster.close()
        host._coworker_names.close()


def test_the_docker_host_builds_boxes_with_the_agents_permissions(tmp_path):
    host = _host(tmp_path, sandbox_kind="docker")
    cli = _FakeCli()
    host._containers.cli = cli
    host._coworker_names.upsert("local:amber:1", "amber", created_by_app=True)
    try:
        host._on_agent_frame(
            {"type": "agent_permissions_set", "agent_id": "local:amber:1",
             "permissions": {"network": False, "sudo": False}}
        )
        env = host._environment_for("local:amber:1")
        env._ensure_container()
    finally:
        host._roster.close()
        host._coworker_names.close()
    argv = cli.created[-1]
    assert _pairs(argv, "--network") == ["none"]
    assert _pairs(argv, "--security-opt") == ["no-new-privileges"]


def test_automation_watchers_follow_the_host_agents_secrets_switch(tmp_path):
    host = _host(tmp_path)
    try:
        host._secrets_vault.replace({"API_KEY": "secret-value-123"}, revision=1)
        assert host._watcher_env() == {"API_KEY": "secret-value-123"}
        host._on_agent_frame(
            {"type": "agent_permissions_set", "agent_id": host_agent_id(HOST_DEVICE_ID),
             "permissions": {"secrets_env": False}}
        )
        assert host._watcher_env() == {}
    finally:
        host._roster.close()
        host._coworker_names.close()


def test_an_unknown_agent_never_changes_the_host_agent(tmp_path):
    host = _host(tmp_path)
    try:
        reply = host._on_agent_frame(
            {"type": "agent_permissions_set", "agent_id": "local:deleted:3",
             "permissions": {"sudo": False}}
        )
        assert reply["type"] == "agent_permissions"
        assert "unknown agent" in reply["error"]
        assert host._permissions.get(host._agent.id).sudo is True
        assert host._permissions.overrides() == {}
    finally:
        host._roster.close()
        host._coworker_names.close()


def test_the_local_host_reports_what_it_cannot_enforce(tmp_path):
    host = _host(tmp_path)
    try:
        reply = host._on_agent_frame(
            {"type": "agent_permissions_get", "agent_id": host_agent_id(HOST_DEVICE_ID)}
        )
        assert reply["enforced"] == enforced_permissions("local")
    finally:
        host._roster.close()
        host._coworker_names.close()


def test_a_change_is_sent_to_every_device_and_the_host_names_the_capability(tmp_path):
    host = _host(tmp_path)
    sent: list[dict] = []
    host._send_host_payload = lambda payload: sent.append(payload) or True
    host._coworker_names.upsert("local:amber:1", "amber", created_by_app=True)
    try:
        host._on_agent_frame({"type": "agent_list"})
        route = [p for p in sent if p["type"] == "host_route"][-1]
        assert "agent_permissions" in route["capabilities"]
        sent.clear()
        host._on_agent_frame(
            {"type": "agent_permissions_get", "agent_id": "local:amber:1"}
        )
        assert sent == []  # a read goes to the asker only
        reply = host._on_agent_frame(
            {"type": "agent_permissions_set", "agent_id": "local:amber:1",
             "permissions": {"network": False}}
        )
        assert sent == [reply]
    finally:
        host._roster.close()
        host._coworker_names.close()


class _Watcher:
    def __init__(self, automation_id: str) -> None:
        self.automation_id = automation_id


class _FakeAutomations:
    def __init__(self) -> None:
        import threading

        self._lock = threading.Lock()
        self._watchers = {"w1": _Watcher("w1"), "w2": _Watcher("w2")}
        self.killed: list[str] = []

    def running_watchers(self) -> list[str]:
        return ["w1", "w2"]

    def _kill(self, watcher) -> None:
        self.killed.append(watcher.automation_id)


def test_switching_the_host_agents_secrets_off_restarts_its_watchers(tmp_path):
    host = _host(tmp_path)
    host._automations = _FakeAutomations()
    try:
        host._on_agent_frame(
            {"type": "agent_permissions_set", "agent_id": host_agent_id(HOST_DEVICE_ID),
             "permissions": {"network": False}}
        )
        assert host._automations.killed == []  # not a secrets change
        host._on_agent_frame(
            {"type": "agent_permissions_set", "agent_id": host_agent_id(HOST_DEVICE_ID),
             "permissions": {"secrets_env": False}}
        )
        assert host._automations.killed == ["w1", "w2"]
    finally:
        host._roster.close()
        host._coworker_names.close()
