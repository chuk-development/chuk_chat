"""Two coworkers, two sandboxes — end to end through the executor (cowork-jo2).

A ``session_key`` IS an agent id on the app side (``AgentRosterSource`` gives
every coworker one permanent thread whose key is the coworker's id). So the
executor must give each session key its own environment, or two coworkers work
in one box: same files, same shell state, same installed packages.

The test drives the real ``Executor`` over the real sealed-frame path with a
scripted model, one task per coworker, and asserts that each file landed in its
own workspace and nowhere else.
"""

from __future__ import annotations

from cowork_agent import MockModelClient, tool_call_response
from cowork_sandbox import LocalEnvironment

from cowork_executor import ControllerSession, Executor, loopback_pair

from wiring import paired_channel


def _model_writing(command: str):
    """A scripted model that runs one shell command, then answers."""

    def factory() -> MockModelClient:
        return MockModelClient(
            [tool_call_response(("run_command", {"command": command})), "ok"]
        )

    return factory


def _executor(tmp_path, environment, environment_factory, model_factory=None):
    channel = paired_channel()
    controller_ep, executor_ep = loopback_pair()
    executor = Executor(
        name="host-agent",
        endpoint=executor_ep,
        opener=channel.executor.opener,
        sealer=channel.executor.sealer,
        environment=environment,
        environment_factory=environment_factory,
        db_path=str(tmp_path / "state.db"),
        model_factory=model_factory or _model_writing("true"),
        workspace=getattr(environment, "workspace", None),
    )
    controller = ControllerSession(
        endpoint=controller_ep,
        sealer=channel.controller.sealer,
        opener=channel.controller.opener,
    )
    return executor, controller


def test_two_session_keys_run_in_two_sandboxes(tmp_path):
    """The regression this bead is about: one box for every coworker.

    Both coworkers run the SAME command: write a file, then try to read a file
    that was planted in the host coworker's workspace. One box would let the
    second coworker read it. Two boxes means it cannot — which is a stronger
    claim than "both wrote a file", because a shared box satisfies that too.
    """
    home = tmp_path / "agents"
    host_dir = home / "host"
    amber_dir = home / "amber"
    for path in (host_dir, amber_dir):
        path.mkdir(parents=True)
    (host_dir / "planted.txt").write_text("host-only\n")

    handed_out: dict[str, LocalEnvironment] = {}

    def environment_factory(session_key: str) -> LocalEnvironment:
        # One environment per agent, created once and reused — exactly what the
        # host's ``_environment_for`` does with a container behind it.
        if session_key not in handed_out:
            handed_out[session_key] = LocalEnvironment(workdir=str(home / session_key))
        return handed_out[session_key]

    host_env = LocalEnvironment(workdir=str(host_dir))
    executor, controller = _executor(
        tmp_path,
        host_env,
        environment_factory,
        model_factory=_model_writing(
            "echo made > mine.txt; cat planted.txt > peek.txt 2>&1"
        ),
    )
    executor.start()
    try:
        # The host's own coworker: no factory lookup, its own workspace.
        controller.collect(controller.send_task("do it", session_key=""), timeout=20.0)
        # A second coworker in the same app, its own session key.
        controller.collect(
            controller.send_task("do it", session_key="amber"), timeout=20.0
        )
    finally:
        executor.stop()

    # Each wrote into its own workspace.
    assert (host_dir / "mine.txt").exists()
    assert (amber_dir / "mine.txt").exists()
    # The host coworker could read what was planted in ITS box...
    assert "host-only" in (host_dir / "peek.txt").read_text()
    # ...and the second coworker could not: it is not in the same box.
    assert "host-only" not in (amber_dir / "peek.txt").read_text()
    assert not (amber_dir / "planted.txt").exists()
    assert handed_out["amber"].workspace == str(amber_dir)


def test_an_agent_keeps_one_environment_across_its_turns(tmp_path):
    """Isolation must not cost reuse: a coworker's box is built once."""
    built: list[str] = []
    envs: dict[str, LocalEnvironment] = {}

    def environment_factory(session_key: str) -> LocalEnvironment:
        built.append(session_key)
        envs[session_key] = LocalEnvironment(workdir=str(tmp_path / session_key))
        return envs[session_key]

    (tmp_path / "amber").mkdir()
    host_env = LocalEnvironment(workdir=str(tmp_path / "host"))
    executor, _controller = _executor(tmp_path, host_env, environment_factory)
    try:
        first = executor._environment_for("amber")
        second = executor._environment_for("amber")
        assert first is second
        assert built == ["amber"]
        # A different coworker is a different box.
        assert executor._environment_for("blue") is not first
        assert built == ["amber", "blue"]
        # The host's own coworker never goes through the factory.
        assert executor._environment_for("") is host_env
        assert executor._environment_for(None) is host_env
    finally:
        executor.stop()


def test_without_a_factory_every_session_shares_the_one_environment(tmp_path):
    """The single-agent path (and every existing test) is unchanged."""
    host_env = LocalEnvironment(workdir=str(tmp_path / "host"))
    executor, _controller = _executor(tmp_path, host_env, None)
    try:
        assert executor._environment_for("amber") is host_env
        assert executor._environment_for("blue") is host_env
    finally:
        executor.stop()


def test_stop_cleans_up_every_agents_environment(tmp_path):
    """A box per agent means a teardown per agent; none may be left running."""
    cleaned: list[str] = []

    class Recording(LocalEnvironment):
        def __init__(self, name: str, **opts) -> None:
            self._name = name
            super().__init__(**opts)

        def cleanup(self) -> None:  # noqa: D102 - see base
            cleaned.append(self._name)
            super().cleanup()

    host_env = Recording("host", workdir=str(tmp_path / "host"))
    executor, _controller = _executor(
        tmp_path,
        host_env,
        lambda key: Recording(key, workdir=str((tmp_path / key).as_posix())),
    )
    (tmp_path / "amber").mkdir()
    (tmp_path / "blue").mkdir()
    executor._environment_for("amber")
    executor._environment_for("blue")
    executor.stop()

    assert sorted(cleaned) == ["amber", "blue", "host"]
