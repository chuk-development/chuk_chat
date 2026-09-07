"""Every coworker gets its own box on this host (bead cowork-jo2).

The executor asks the host for one environment per ``session_key``, and a
session key IS an app-side agent id. These tests hold the host to that: two
coworkers get two workspaces (and, with the docker backend, two containers with
two ``cowork.agent`` labels), while the host's own coworker keeps the single
workspace it always had — under every name it answers to.
"""

from __future__ import annotations

from cowork_sandbox import LABEL_AGENT, DockerCli, DockerEnvironment

from cowork_host import LocalHost
from cowork_host.coworker_names import host_agent_id
from cowork_host.identity import HOST_DEVICE_ID


def _register(host: LocalHost, agent_id: str, name: str) -> None:
    """What the app does with ``agent_create`` when the user makes a coworker.

    Registration is what makes a session key a coworker of its own; without it
    the key belongs to this host's own agent.
    """
    host._coworker_names.upsert(agent_id, name, created_by_app=True)


def _host(tmp_path, **opts) -> LocalHost:
    return LocalHost(
        port=0,
        workspace_dir=str(tmp_path / "cowork"),
        channel_id="testchannel",
        agent_name="pytest-agent",
        model_factory_override=lambda: None,
        **opts,
    )


def test_two_coworkers_get_two_workspaces(tmp_path):
    host = _host(tmp_path)
    _register(host, "local:amber:1", "amber")
    _register(host, "local:blue:2", "blue")
    try:
        mine = host._workspace_for_agent("local:amber:1")
        hers = host._workspace_for_agent("local:blue:2")
    finally:
        host._roster.close()
        host._coworker_names.close()

    assert mine != hers
    # Both are real directories under the host's agents folder, ready to mount.
    assert mine.startswith(str(tmp_path / "cowork" / "agents"))
    assert hers.startswith(str(tmp_path / "cowork" / "agents"))


def test_coworkers_whose_names_read_alike_still_get_two_workspaces(tmp_path):
    """A coworker name is whatever the user typed; ids are what separate them."""
    host = _host(tmp_path)
    _register(host, "local:amber:1", "amber")
    _register(host, "local:amber:2", "amber")
    try:
        first = host._workspace_for_agent("local:amber:1")
        second = host._workspace_for_agent("local:amber:2")
    finally:
        host._roster.close()
        host._coworker_names.close()

    assert first != second


def test_the_host_coworker_keeps_one_box_under_every_name_it_answers_to(tmp_path):
    """``host:<device>``, the roster id and "no session" are ONE coworker."""
    host = _host(tmp_path)
    _register(host, "local:amber:1", "amber")
    try:
        primary = host._environment_for(host._agent.id)
        assert host._environment_for(host_agent_id(HOST_DEVICE_ID)) is primary
        assert host._environment_for("") is primary
        assert host._environment_for("default") is primary
        # A key nobody registered as a coworker is this host's own agent, not
        # a new one: a typo must not get a container and an empty workspace.
        assert host._environment_for("thread-1") is primary
        # A different coworker is a different box.
        other = host._environment_for("local:amber:1")
        assert other is not primary
        assert other.workspace != primary.workspace
        # ...and its own box comes back on the next turn, not a fresh one.
        assert host._environment_for("local:amber:1") is other
    finally:
        host._roster.close()
        host._coworker_names.close()


def test_the_docker_backend_labels_a_container_per_coworker(tmp_path):
    """No daemon: the fake CLI proves which container each coworker asks for."""
    cli = _FakeCli()
    host = _host(tmp_path, sandbox_kind="docker")
    host._containers.cli = cli
    _register(host, "local:amber:1", "amber")
    _register(host, "local:blue:2", "blue")
    try:
        first = host._environment_for("local:amber:1")
        second = host._environment_for("local:blue:2")
        assert isinstance(first, DockerEnvironment)
        first._ensure_container()
        second._ensure_container()
    finally:
        host._roster.close()
        host._coworker_names.close()

    assert first.container_name != second.container_name
    labels = sorted(c["labels"][LABEL_AGENT] for c in cli.containers)
    assert labels == ["local:amber:1", "local:blue:2"]
    # The workspace mounted into each is that coworker's own, never a peer's.
    mounts = {c["labels"][LABEL_AGENT]: c["labels"]["cowork.workspace"]
              for c in cli.containers}
    assert mounts["local:amber:1"] != mounts["local:blue:2"]


class _FakeCli(DockerCli):
    """A ``DockerCli`` that records ``run``/``ps`` instead of calling docker."""

    def __init__(self) -> None:
        super().__init__()
        self.containers: list[dict] = []

    def available(self) -> bool:
        return True

    def run(self, *args: str, timeout: int | None = None):
        from cowork_sandbox import CliResult, parse_labels

        verb = args[0] if args else ""
        if verb == "ps":
            wanted: dict[str, str] = {}
            for index, arg in enumerate(args):
                if arg == "--filter" and index + 1 < len(args):
                    spec = args[index + 1]
                    if spec.startswith("label="):
                        key, _, value = spec[len("label="):].partition("=")
                        wanted[key] = value
            lines = []
            for c in self.containers:
                if any(c["labels"].get(k) != v for k, v in wanted.items()):
                    continue
                rendered = ",".join(f"{k}={v}" for k, v in c["labels"].items())
                lines.append(f"{c['id']}\t{c['name']}\trunning\t{rendered}")
            return CliResult("\n".join(lines) + ("\n" if lines else ""), "", 0)
        if verb == "run":
            labels: dict[str, str] = {}
            name = "unnamed"
            for index, arg in enumerate(args):
                if arg == "--label" and index + 1 < len(args):
                    key, _, value = args[index + 1].partition("=")
                    labels[key] = value
                if arg == "--name" and index + 1 < len(args):
                    name = args[index + 1]
            cid = f"cid-{len(self.containers) + 1}"
            self.containers.append({"id": cid, "name": name, "labels": labels})
            return CliResult(cid + "\n", "", 0)
        if verb == "inspect":
            return CliResult("", "", 0)
        _ = parse_labels  # imported for symmetry with the sandbox tests
        return CliResult("", "", 0)
