"""One container per agent — the isolation proof (bead cowork-jo2).

The rule the platform claims is narrow and testable: **two agents never share a
sandbox.** These tests prove it at the layer that decides it, with the fake CLI
of ``test_lifecycle.py``, so no daemon is needed:

* two agent ids create two containers, with two names and two ``cowork.agent``
  labels;
* neither agent can find or reuse the other's container, even when their names
  slug down to the same string;
* the same agent DOES find its own container again, which is the reuse the
  isolation must not break;
* a container whose workspace mount belongs to another agent is replaced, not
  adopted;
* the reaper only removes what no live session owns.
"""

from __future__ import annotations

from cowork_sandbox import (
    LABEL_AGENT,
    LABEL_WORKSPACE,
    DockerEnvironment,
    find_agent_container,
    list_containers,
    reap_orphans,
)

from test_lifecycle import FakeCli, container


def _create(cli: FakeCli, agent_id: str, **opts) -> DockerEnvironment:
    env = DockerEnvironment(agent_id=agent_id, image="img:1", cli=cli, **opts)
    env._ensure_container()
    return env


def test_two_agents_get_two_containers():
    cli = FakeCli()
    first = _create(cli, "agent-a")
    second = _create(cli, "agent-b")

    assert first.container_id != second.container_id
    assert first.container_name != second.container_name
    assert len(cli.containers) == 2
    labels = sorted(c["labels"][LABEL_AGENT] for c in cli.containers)
    assert labels == ["agent-a", "agent-b"]


def test_agent_ids_that_slug_alike_still_get_their_own_container():
    """The readable half of a container name is lossy; the name must not be.

    ``my agent`` and ``my/agent`` both slug to ``my-agent``, and an id longer
    than the slug limit is cut. Sharing a name would mean sharing a box.
    """
    cli = FakeCli()
    first = _create(cli, "my agent")
    second = _create(cli, "my/agent")
    third = _create(cli, "coworker-with-a-very-long-identifier-0001")
    fourth = _create(cli, "coworker-with-a-very-long-identifier-0002")

    names = {e.container_name for e in (first, second, third, fourth)}
    assert len(names) == 4
    ids = {e.container_id for e in (first, second, third, fourth)}
    assert len(ids) == 4


def test_one_agent_cannot_find_the_other_agents_container():
    cli = FakeCli()
    _create(cli, "agent-a")

    assert find_agent_container(agent_id="agent-b", cli=cli) is None
    # ...and asking for agent-b builds a second box rather than adopting a-'s.
    second = _create(cli, "agent-b")
    assert len(cli.containers) == 2
    assert second.reused_container is False


def test_an_agent_reuses_its_own_container_across_environments():
    """Isolation must not cost reuse: the same agent gets the same box back."""
    cli = FakeCli()
    first = _create(cli, "agent-a")

    # A restarted host: a fresh environment object, the same agent id.
    again = _create(cli, "agent-a")
    assert again.container_id == first.container_id
    assert again.reused_container is True
    assert len(cli.containers) == 1


def test_a_container_mounted_on_another_agents_workspace_is_replaced(tmp_path):
    """A stale box pointing at someone else's files is removed, never adopted."""
    mine = tmp_path / "agents" / "agent-a"
    theirs = tmp_path / "agents" / "agent-b"
    cli = FakeCli(
        [container(cid="stale", agent="agent-a", workspace=str(theirs), image="img:1")]
    )
    env = DockerEnvironment(
        agent_id="agent-a", image="img:1", workdir=str(mine), cli=cli
    )
    cid = env._ensure_container()

    assert cid != "stale"
    assert [c["id"] for c in cli.containers] == [cid]
    assert cli.containers[0]["labels"][LABEL_WORKSPACE] == str(mine)


def test_reaper_leaves_the_live_agents_box_and_takes_the_dead_one():
    cli = FakeCli()
    live = _create(cli, "agent-a")
    _create(cli, "agent-b")

    reaped = reap_orphans(active_session_ids={live.session_id}, cli=cli)

    assert len(reaped) == 1
    remaining = list_containers(cli=cli)
    assert [c.labels[LABEL_AGENT] for c in remaining] == ["agent-a"]
