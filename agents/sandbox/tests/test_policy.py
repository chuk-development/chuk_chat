"""Per-agent permissions (docs/WIRE_CONTRACT.md, "Agent permissions").

No daemon: the fake CLI of ``test_lifecycle`` proves the ``docker run`` argv
of each permission and the rebuild decision. ``test_policy_docker.py`` proves
the same flags against a real daemon when one is there.
"""

from __future__ import annotations

import pytest

from chuk_agents_sandbox import (
    DEFAULT_POLICY,
    LABEL_POLICY,
    PERMISSION_KEYS,
    DockerEnvironment,
    LocalEnvironment,
    PolicyError,
    SandboxPolicy,
)
from chuk_agents_sandbox.docker import CONTAINER_WORKSPACE
from chuk_agents_sandbox.policy import READ_ONLY_BROWSER_PROFILE, enforced_permissions

from test_lifecycle import FakeCli, container


def _run_argv(cli: FakeCli) -> list[str]:
    runs = [list(c) for c in cli.calls if c and c[0] == "run"]
    assert runs, "no container was created"
    return runs[-1]


def _mounts(argv: list[str]) -> list[str]:
    return [argv[i + 1] for i, a in enumerate(argv) if a == "-v"]


def _pairs(argv: list[str], flag: str) -> list[str]:
    return [argv[i + 1] for i, a in enumerate(argv) if a == flag]


def _labels(argv: list[str]) -> dict[str, str]:
    return dict(p.partition("=")[::2] for p in _pairs(argv, "--label"))


# ------------------------------------------------------------------ the model


def test_defaults_allow_everything_but_the_users_browser():
    assert DEFAULT_POLICY.to_dict() == {
        "sudo": True,
        "network": True,
        "secrets_env": True,
        "workspace_mount": "rw",
        "user_browser": False,
    }
    assert tuple(DEFAULT_POLICY.to_dict()) == PERMISSION_KEYS
    assert DEFAULT_POLICY.docker_run_args() == ()


def test_merged_applies_a_partial_on_top():
    policy = DEFAULT_POLICY.merged({"network": False, "workspace_mount": "ro"})
    assert policy.network is False
    assert policy.workspace_mount == "ro"
    assert policy.sudo is True  # untouched
    assert SandboxPolicy.from_dict({"sudo": False}).sudo is False


@pytest.mark.parametrize(
    "partial, message",
    [
        ({"root": True}, "unknown permission"),
        ({"sudo": 1}, "sudo must be true or false"),
        ({"network": "no"}, "network must be true or false"),
        ({"secrets_env": None}, "secrets_env must be true or false"),
        ({"workspace_mount": "rwx"}, "workspace_mount"),
        ({"user_browser": 0}, "user_browser must be true or false"),
    ],
)
def test_merged_refuses_unknown_keys_and_wrong_types(partial, message):
    with pytest.raises(PolicyError, match=message):
        DEFAULT_POLICY.merged(partial)


def test_a_refused_partial_changes_nothing():
    with pytest.raises(PolicyError):
        DEFAULT_POLICY.merged({"network": False, "sudo": "yes"})
    assert DEFAULT_POLICY.network is True


def test_container_key_holds_everything_but_the_browser_target():
    base = DEFAULT_POLICY.container_key()
    assert DEFAULT_POLICY.merged({"user_browser": True}).container_key() == base
    # A secret the box got earlier can live on in it: secrets rebuild it.
    assert DEFAULT_POLICY.merged({"secrets_env": False}).container_key() != base
    assert DEFAULT_POLICY.merged({"sudo": False}).container_key() != base
    assert "," not in DEFAULT_POLICY.merged({"network": False}).container_key()


def test_enforced_permissions_per_backend():
    assert all(enforced_permissions("docker").values())
    local = enforced_permissions("local")
    assert local == {
        "sudo": False,
        "network": False,
        "secrets_env": True,
        "workspace_mount": False,
        "user_browser": True,
    }


# ------------------------------------------------------------ docker run argv


def _create(tmp_path, policy: SandboxPolicy | None) -> list[str]:
    workspace = tmp_path / "ws"
    workspace.mkdir(exist_ok=True)
    cli = FakeCli()
    env = DockerEnvironment(
        workdir=str(workspace), cli=cli, user="1000:1000", policy=policy,
        session_id="s1",
    )
    env._create()
    return _run_argv(cli)


def test_default_policy_creates_the_same_container_as_no_policy(tmp_path):
    plain = _create(tmp_path, None)
    default = _create(tmp_path, DEFAULT_POLICY)
    assert plain == default
    assert "--network" not in plain
    assert "--security-opt" not in plain
    assert _mounts(plain) == [f"{tmp_path / 'ws'}:{CONTAINER_WORKSPACE}"]


def test_network_off_runs_with_network_none(tmp_path):
    argv = _create(tmp_path, SandboxPolicy(network=False))
    assert _pairs(argv, "--network") == ["none"]


def test_read_only_workspace_is_a_read_only_bind(tmp_path):
    argv = _create(tmp_path, SandboxPolicy(workspace_mount="ro"))
    assert _mounts(argv) == [f"{tmp_path / 'ws'}:{CONTAINER_WORKSPACE}:ro"]
    # The browser profile normally lives in the workspace; it moves to /tmp.
    assert f"AGENTS_BROWSER_PROFILE={READ_ONLY_BROWSER_PROFILE}" in _pairs(argv, "-e")


def test_sudo_off_sets_no_new_privileges_and_tells_the_entrypoint(tmp_path):
    argv = _create(tmp_path, SandboxPolicy(sudo=False))
    assert _pairs(argv, "--security-opt") == ["no-new-privileges"]
    assert "AGENTS_SUDO=0" in _pairs(argv, "-e")


def test_policy_flags_go_before_the_image(tmp_path):
    argv = _create(tmp_path, SandboxPolicy(network=False, sudo=False))
    image_at = argv.index("sleep") - 1
    assert argv.index("--network") < image_at
    assert argv.index("--security-opt") < image_at


def test_container_carries_its_policy_label(tmp_path):
    argv = _create(tmp_path, SandboxPolicy(network=False))
    assert _labels(argv)[LABEL_POLICY] == "sudo=1;network=0;workspace=rw;secrets=1"


# ------------------------------------------------- applies from the next task


def test_a_change_waits_for_refresh_then_rebuilds_the_container():
    current = {"policy": DEFAULT_POLICY}
    cli = FakeCli()
    env = DockerEnvironment(
        agent_id="a1", image="img:1", cli=cli, policy_provider=lambda: current["policy"]
    )
    first = env._ensure_container()
    assert len(cli.created) == 1

    # The user switches the network off while a task runs: nothing happens yet.
    current["policy"] = SandboxPolicy(network=False)
    assert env._ensure_container() == first
    assert len(cli.created) == 1
    assert env.policy == DEFAULT_POLICY

    # The next task starts (no run holds the box): the next command rebuilds.
    assert env.begin_run() == SandboxPolicy(network=False)
    env.end_run()
    second = env._ensure_container()
    assert len(cli.created) == 2
    assert ("rm", "-f", first) in cli.calls
    assert _pairs(list(cli.created[-1]), "--network") == ["none"]
    assert [c["id"] for c in cli.containers] == [second]
    assert cli.containers[0]["labels"][LABEL_POLICY] == "sudo=1;network=0;workspace=rw;secrets=1"

    # A refresh with no change keeps the box.
    assert env.refresh_policy() is False
    assert env._ensure_container() == second
    assert len(cli.created) == 2


def test_a_browser_target_change_keeps_the_container():
    current = {"policy": DEFAULT_POLICY}
    cli = FakeCli()
    env = DockerEnvironment(
        agent_id="a1", image="img:1", cli=cli, policy_provider=lambda: current["policy"]
    )
    first = env._ensure_container()
    current["policy"] = SandboxPolicy(user_browser=True)
    assert env.refresh_policy() is True
    assert env._ensure_container() == first
    assert len(cli.created) == 1


def test_switching_secrets_off_rebuilds_the_box():
    """A tmux server, a job or a file in /tmp may still hold a value."""
    current = {"policy": DEFAULT_POLICY}
    cli = FakeCli()
    env = DockerEnvironment(
        agent_id="a1", image="img:1", cli=cli, policy_provider=lambda: current["policy"]
    )
    first = env._ensure_container()
    current["policy"] = SandboxPolicy(secrets_env=False)
    env.begin_run()
    try:
        env._ensure_container()
    finally:
        env.end_run()
    assert ("rm", "-f", first) in cli.calls
    assert len(cli.created) == 2
    assert cli.containers[0]["labels"][LABEL_POLICY].endswith(";secrets=0")


# ------------------------------------------------------ runs share one box


def test_a_second_concurrent_run_never_rebuilds_the_box():
    """A room turn and a direct task share one environment: the change waits
    until neither holds it."""
    current = {"policy": DEFAULT_POLICY}
    cli = FakeCli()
    env = DockerEnvironment(
        agent_id="a1", image="img:1", cli=cli, policy_provider=lambda: current["policy"]
    )
    assert env.begin_run() == DEFAULT_POLICY  # the direct task
    box = env._ensure_container()

    current["policy"] = SandboxPolicy(network=False, secrets_env=False)
    # The room turn starts while the task runs: same box, same policy.
    assert env.begin_run() == DEFAULT_POLICY
    assert env.refresh_policy() is False
    assert env.set_policy(SandboxPolicy(sudo=False)) is False
    assert env._ensure_container() == box
    env.end_run()  # the room turn ends; the task still runs
    assert env.begin_run() == DEFAULT_POLICY
    env.end_run()
    assert env._ensure_container() == box
    env.end_run()  # the task ends
    assert env.leases == 0
    assert len(cli.created) == 1
    assert not [c for c in cli.calls if c[:2] == ("rm", "-f")]

    # The next run with nobody holding the box takes the change.
    assert env.begin_run() == SandboxPolicy(network=False, secrets_env=False)
    env._ensure_container()
    env.end_run()
    assert len(cli.created) == 2


def test_two_threads_racing_runs_never_rebuild_mid_run():
    import threading

    current = {"policy": DEFAULT_POLICY}
    cli = FakeCli()
    env = DockerEnvironment(
        agent_id="a1", image="img:1", cli=cli, policy_provider=lambda: current["policy"]
    )
    started = threading.Event()
    release = threading.Event()
    seen: list[SandboxPolicy | None] = []

    def long_run():
        seen.append(env.begin_run())
        env._ensure_container()
        started.set()
        release.wait(5)
        env._ensure_container()  # still inside the run
        env.end_run()

    worker = threading.Thread(target=long_run)
    worker.start()
    assert started.wait(5)
    current["policy"] = SandboxPolicy(network=False)
    seen.append(env.begin_run())  # a concurrent run
    env._ensure_container()
    env.end_run()
    release.set()
    worker.join(5)
    assert seen == [DEFAULT_POLICY, DEFAULT_POLICY]
    assert len(cli.created) == 1


def test_a_pending_set_policy_lands_at_the_next_free_run():
    env = LocalEnvironment(policy=DEFAULT_POLICY)
    try:
        env.begin_run()
        assert env.set_policy(SandboxPolicy(secrets_env=False)) is False
        assert env.policy == DEFAULT_POLICY
        env.end_run()
        assert env.begin_run() == SandboxPolicy(secrets_env=False)
        env.end_run()
    finally:
        env.cleanup()


def test_a_container_from_before_the_label_is_kept_for_the_default_policy():
    cli = FakeCli([container(cid="old", agent="a1", image="img:1")])
    env = DockerEnvironment(agent_id="a1", image="img:1", cli=cli, policy=DEFAULT_POLICY)
    assert env._ensure_container() == "old"
    assert not cli.created


def test_a_container_from_before_the_label_is_rebuilt_for_a_narrower_policy():
    cli = FakeCli([container(cid="old", agent="a1", image="img:1")])
    env = DockerEnvironment(
        agent_id="a1", image="img:1", cli=cli, policy=SandboxPolicy(sudo=False)
    )
    env._ensure_container()
    assert ("rm", "-f", "old") in cli.calls
    assert len(cli.created) == 1


def test_the_provider_is_read_at_construction():
    env = DockerEnvironment(
        agent_id="a1", cli=FakeCli(), policy_provider=lambda: SandboxPolicy(network=False)
    )
    assert env.policy == SandboxPolicy(network=False)


def test_no_policy_means_none_and_the_defaults_apply():
    env = DockerEnvironment(agent_id="a1", cli=FakeCli())
    assert env.policy is None
    assert env.effective_policy == DEFAULT_POLICY
    assert env.refresh_policy() is False


# ---------------------------------------------------------------- secrets_env


def test_secrets_env_off_keeps_the_values_out_of_the_command(tmp_path):
    env = LocalEnvironment(workdir=str(tmp_path), policy=SandboxPolicy(secrets_env=False))
    try:
        out = env.run_bash('echo "[$API_KEY]"', env={"API_KEY": "secret-value-123"})
        assert out.stdout == "[]\n"
    finally:
        env.cleanup()


def test_secrets_env_on_passes_the_values(tmp_path):
    env = LocalEnvironment(workdir=str(tmp_path), policy=DEFAULT_POLICY)
    try:
        out = env.run_bash('echo "[$API_KEY]"', env={"API_KEY": "secret-value-123"})
        assert out.stdout == "[secret-value-123]\n"
    finally:
        env.cleanup()
