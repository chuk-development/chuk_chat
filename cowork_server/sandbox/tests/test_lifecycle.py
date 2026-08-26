"""Container lifecycle unit tests — no daemon involved.

Every docker call goes through :class:`DockerCli`, so a fake CLI proves the
*decisions* (reuse this container, replace that one, reap the orphan) without a
container runtime. ``test_docker_environment.py`` then proves the same rules
against a real daemon when one is available.
"""

from __future__ import annotations

import pytest

from cowork_sandbox import (
    DEFAULT_TASK_ID,
    LABEL_AGENT,
    LABEL_IMAGE,
    LABEL_MANAGED,
    LABEL_SESSION,
    LABEL_TASK,
    LABEL_WORKSPACE,
    CliResult,
    DockerEnvironment,
    build_labels,
    find_agent_container,
    label_args,
    list_containers,
    parse_labels,
    reap_orphans,
    resolve_image,
)
from cowork_sandbox.docker import BASE_IMAGE, IMAGE_ENV_VAR


class FakeCli:
    """A ``DockerCli`` stand-in backed by a dict of fake containers."""

    binary = "docker"

    def __init__(self, containers: list[dict] | None = None, *, up: bool = True) -> None:
        # each container: {id, name, state, labels}
        self.containers = list(containers or [])
        self.calls: list[tuple[str, ...]] = []
        self.up = up
        self.created: list[tuple[str, ...]] = []

    # -- DockerCli surface ------------------------------------------------
    def available(self) -> bool:
        return self.up

    def run(self, *args: str, timeout: int | None = None) -> CliResult:
        self.calls.append(args)
        verb = args[0] if args else ""
        if verb == "ps":
            return CliResult(self._ps(args), "", 0)
        if verb == "run":
            return CliResult(self._create(args), "", 0)
        if verb == "rm":
            target = args[-1]
            before = len(self.containers)
            self.containers = [
                c for c in self.containers if c["id"] != target and c["name"] != target
            ]
            return CliResult("", "", 0 if len(self.containers) < before else 1)
        if verb == "start":
            for c in self.containers:
                if c["id"] == args[-1] or c["name"] == args[-1]:
                    c["state"] = "running"
                    return CliResult("", "", 0)
            return CliResult("", "no such container", 1)
        if verb == "stop":
            for c in self.containers:
                if c["id"] == args[-1]:
                    c["state"] = "exited"
            return CliResult("", "", 0)
        if verb == "exec":
            # The user probe: pretend the image has no `cowork` user unless asked.
            return CliResult("1000\n", "", 0 if "id" in args else 0)
        return CliResult("", "", 0)

    # -- helpers ----------------------------------------------------------
    def _filters(self, args: tuple[str, ...]) -> dict[str, str]:
        out: dict[str, str] = {}
        for index, arg in enumerate(args):
            if arg == "--filter" and index + 1 < len(args):
                spec = args[index + 1]
                if spec.startswith("label="):
                    key, _, value = spec[len("label="):].partition("=")
                    out[key] = value
        return out

    def _ps(self, args: tuple[str, ...]) -> str:
        wanted = self._filters(args)
        lines = []
        for c in self.containers:
            labels = c.get("labels", {})
            if any(labels.get(k) != v for k, v in wanted.items()):
                continue
            rendered = ",".join(f"{k}={v}" for k, v in labels.items())
            lines.append(f"{c['id']}\t{c['name']}\t{c['state']}\t{rendered}")
        return "\n".join(lines) + ("\n" if lines else "")

    def _create(self, args: tuple[str, ...]) -> str:
        self.created.append(args)
        labels: dict[str, str] = {}
        name = "unnamed"
        for index, arg in enumerate(args):
            if arg == "--label" and index + 1 < len(args):
                key, _, value = args[index + 1].partition("=")
                labels[key] = value
            if arg == "--name" and index + 1 < len(args):
                name = args[index + 1]
        cid = f"cid-{len(self.containers) + 1}"
        self.containers.append(
            {"id": cid, "name": name, "state": "running", "labels": labels}
        )
        return cid + "\n"


def container(
    *,
    cid: str,
    agent: str,
    task: str = DEFAULT_TASK_ID,
    session: str = "sess",
    state: str = "running",
    workspace: str | None = None,
    image: str | None = None,
    managed: bool = True,
) -> dict:
    labels = {}
    if managed:
        labels[LABEL_MANAGED] = "true"
    labels[LABEL_AGENT] = agent
    labels[LABEL_TASK] = task
    labels[LABEL_SESSION] = session
    if workspace:
        labels[LABEL_WORKSPACE] = workspace
    if image:
        labels[LABEL_IMAGE] = image
    return {"id": cid, "name": f"cowork-{agent}", "state": state, "labels": labels}


# ---------------------------------------------------------------- labels


def test_parse_and_build_labels_round_trip():
    labels = build_labels(
        agent_id="a1", task_id="default", session_id="s1", workspace="/w", image="img"
    )
    rendered = ",".join(f"{k}={v}" for k, v in labels.items())
    assert parse_labels(rendered) == labels


def test_label_args_are_sorted_pairs():
    assert label_args({"b": "2", "a": "1"}) == ["--label", "a=1", "--label", "b=2"]


def test_list_containers_filters_on_labels():
    cli = FakeCli([container(cid="c1", agent="alice"), container(cid="c2", agent="bob")])
    found = list_containers(cli=cli, filters={LABEL_AGENT: "bob"})
    assert [c.id for c in found] == ["c2"]


def test_resolve_image_prefers_explicit_then_env(monkeypatch):
    monkeypatch.delenv(IMAGE_ENV_VAR, raising=False)
    assert resolve_image() == BASE_IMAGE
    monkeypatch.setenv(IMAGE_ENV_VAR, "from-env:1")
    assert resolve_image() == "from-env:1"
    assert resolve_image("explicit:2") == "explicit:2"


# ---------------------------------------------------------------- reuse


def test_running_container_is_reused_not_recreated():
    existing = container(cid="c1", agent="a1", workspace=None, image="img:1")
    cli = FakeCli([existing])
    env = DockerEnvironment(agent_id="a1", image="img:1", cli=cli)
    assert env._ensure_container() == "c1"
    assert env.reused_container is True
    assert not cli.created


def test_reuse_adopts_the_existing_session_label():
    """Otherwise the reaper would not recognise the box as owned by a live run."""
    cli = FakeCli([container(cid="c1", agent="a1", session="older", image="img:1")])
    env = DockerEnvironment(agent_id="a1", image="img:1", cli=cli)
    env._ensure_container()
    assert env.session_id == "older"


def test_stopped_container_is_started_again():
    cli = FakeCli(
        [container(cid="c1", agent="a1", state="exited", image="img:1")]
    )
    env = DockerEnvironment(agent_id="a1", image="img:1", cli=cli)
    assert env._ensure_container() == "c1"
    assert ("start", "c1") in [tuple(c[:2]) for c in cli.calls]
    assert not cli.created


def test_container_with_a_different_workspace_is_replaced(tmp_path):
    cli = FakeCli(
        [container(cid="c1", agent="a1", workspace="/old/ws", image="img:1")]
    )
    env = DockerEnvironment(
        agent_id="a1", image="img:1", workdir=str(tmp_path / "ws"), cli=cli
    )
    cid = env._ensure_container()
    assert cid != "c1"
    assert env.reused_container is False
    assert any(call[0] == "rm" for call in cli.calls)


def test_container_from_another_image_is_replaced():
    cli = FakeCli([container(cid="c1", agent="a1", image="old:1")])
    env = DockerEnvironment(agent_id="a1", image="new:2", cli=cli)
    assert env._ensure_container() != "c1"


def test_a_second_agent_gets_its_own_container():
    cli = FakeCli([container(cid="c1", agent="a1", image="img:1")])
    env = DockerEnvironment(agent_id="a2", image="img:1", cli=cli)
    cid = env._ensure_container()
    assert cid != "c1"
    assert len(cli.containers) == 2


def test_creation_labels_carry_agent_task_session_workspace_and_image():
    cli = FakeCli()
    env = DockerEnvironment(
        agent_id="a1", task_id="sub-7", image="img:1", workdir="/tmp", cli=cli
    )
    env._ensure_container()
    labels = cli.containers[0]["labels"]
    assert labels[LABEL_MANAGED] == "true"
    assert labels[LABEL_AGENT] == "a1"
    assert labels[LABEL_TASK] == "sub-7"
    assert labels[LABEL_SESSION] == env.session_id
    assert labels[LABEL_IMAGE] == "img:1"
    assert labels[LABEL_WORKSPACE] == "/tmp"


def test_workspace_is_bind_mounted_with_owner_env():
    cli = FakeCli()
    env = DockerEnvironment(agent_id="a1", workdir="/tmp", cli=cli)
    env._ensure_container()
    argv = cli.created[0]
    assert "-v" in argv
    assert f"/tmp:{'/workspace'}" in argv
    assert any(a.startswith("COWORK_UID=") for a in argv)
    assert any(a.startswith("COWORK_GID=") for a in argv)


def test_no_workspace_means_no_mount():
    cli = FakeCli()
    env = DockerEnvironment(agent_id="a1", cli=cli)
    env._ensure_container()
    assert "-v" not in cli.created[0]


def test_snapshot_lives_outside_the_mounted_workspace():
    env = DockerEnvironment(agent_id="a1", workdir="/tmp", cli=FakeCli())
    assert env._snapshot_path.startswith("/tmp/.cowork-session-")
    assert not env._snapshot_path.startswith("/workspace")


# ---------------------------------------------------------------- teardown


def test_default_task_container_survives_cleanup():
    cli = FakeCli()
    env = DockerEnvironment(agent_id="a1", cli=cli)
    env._ensure_container()
    env.cleanup()
    assert cli.containers, "the agent's own box must survive for reuse"
    assert env.is_task_scoped is False


def test_task_scoped_container_is_removed_by_cleanup():
    cli = FakeCli()
    env = DockerEnvironment(agent_id="a1", task_id="sub-1", cli=cli)
    env._ensure_container()
    assert env.is_task_scoped is True
    env.cleanup()
    assert cli.containers == []


def test_remove_kills_the_default_container_too():
    cli = FakeCli()
    env = DockerEnvironment(agent_id="a1", cli=cli)
    env._ensure_container()
    assert env.remove() is True
    assert cli.containers == []
    # Idempotent: a second remove finds nothing and says so.
    assert env.remove() is False


def test_remove_finds_a_container_this_process_never_started():
    cli = FakeCli([container(cid="c1", agent="a1")])
    env = DockerEnvironment(agent_id="a1", cli=cli)
    assert env.remove() is True
    assert cli.containers == []


def test_container_names_are_stable_for_default_and_unique_for_tasks():
    default = DockerEnvironment(agent_id="agent-1", cli=FakeCli())
    assert default.container_name == "cowork-agent-1"
    task = DockerEnvironment(agent_id="agent-1", task_id="sub", cli=FakeCli())
    assert task.container_name.startswith("cowork-agent-1-sub-")
    other = DockerEnvironment(agent_id="agent-1", task_id="sub", cli=FakeCli())
    assert task.container_name != other.container_name


# ---------------------------------------------------------------- reaper


def test_reaper_removes_containers_of_dead_sessions():
    cli = FakeCli(
        [
            container(cid="c1", agent="a1", session="alive"),
            container(cid="c2", agent="a2", session="dead"),
        ]
    )
    reaped = reap_orphans(active_session_ids={"alive"}, cli=cli)
    assert reaped == ["cowork-a2"]
    assert [c["id"] for c in cli.containers] == ["c1"]


def test_reaper_with_no_live_sessions_clears_everything_managed():
    """A starting Manager: whatever is labelled ours is left over from a kill."""
    cli = FakeCli(
        [
            container(cid="c1", agent="a1", session="s1"),
            container(cid="c2", agent="a2", task="sub", session="s2"),
        ]
    )
    reaped = reap_orphans(active_session_ids=set(), cli=cli)
    assert len(reaped) == 2
    assert cli.containers == []


def test_reaper_never_touches_containers_it_does_not_manage():
    foreign = {
        "id": "user-1",
        "name": "the-users-postgres",
        "state": "running",
        "labels": {"com.example": "1"},
    }
    cli = FakeCli([foreign, container(cid="c1", agent="a1", session="dead")])
    reaped = reap_orphans(active_session_ids=set(), cli=cli)
    assert reaped == ["cowork-a1"]
    assert [c["id"] for c in cli.containers] == ["user-1"]


def test_find_agent_container_prefers_a_running_one():
    cli = FakeCli(
        [
            {
                "id": "stopped",
                "name": "cowork-a1-old",
                "state": "exited",
                "labels": {LABEL_MANAGED: "true", LABEL_AGENT: "a1", LABEL_TASK: "default"},
            },
            {
                "id": "live",
                "name": "cowork-a1",
                "state": "running",
                "labels": {LABEL_MANAGED: "true", LABEL_AGENT: "a1", LABEL_TASK: "default"},
            },
        ]
    )
    found = find_agent_container(agent_id="a1", cli=cli)
    assert found is not None and found.id == "live"


def test_unavailable_runtime_raises_a_clear_error():
    from cowork_sandbox import DockerUnavailableError

    env = DockerEnvironment(agent_id="a1", cli=FakeCli(up=False))
    with pytest.raises(DockerUnavailableError):
        env._ensure_container()
