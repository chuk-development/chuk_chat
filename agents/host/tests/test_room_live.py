"""A room that really drives its members (docs/ROOMS_GOING_LIVE.md, step 3).

This is the acceptance test for going live, minus the credits. Every layer is
the production one — ``RoomService`` takes the app's frame, ``RoomAgentPool``
starts one executor per member on its own sealed loopback, ``RoomBinding`` hands
``RoomDriver`` a real task sender, and each member answers over encrypted frames
— except the model, which is a ``MockModelClient``. So it proves the wiring that
used to answer ``(offline — no reply)`` now answers with the member's own words,
and it spends nothing and touches no relay to do it.

The one that matters most is ``test_a_mention_pulls_the_next_agent_in``: agent A
writes ``@b`` in its reply and agent B speaks next. That is agent-to-agent
messaging, end to end, on the real path.
"""

from __future__ import annotations

import pytest

from chuk_agents_runtime import MockModelClient
from chuk_agents_manager import RoomBinding, RoomStore
from chuk_agents_sandbox import make_environment

from chuk_agents_host import RoomAgentPool, RoomService
from chuk_agents_host.room_service import dispatch_room_frame


class _Members:
    """The scripted members of one test room, and the pool that runs them.

    Each member gets its own model script, its own local sandbox directory and
    its own executor — exactly the shape the runbook demands, because the
    executor serving the room frame cannot serve itself a turn.
    """

    def __init__(self, tmp_path, scripts: dict[str, list[str]]):
        self._tmp = tmp_path
        self._scripts = scripts
        #: Every model client built, per agent id, so a test can read what a
        #: member was actually shown when its turn came.
        self.clients: dict[str, list[MockModelClient]] = {
            agent_id: [] for agent_id in scripts
        }
        self.binding = RoomBinding()
        self.pool = RoomAgentPool(
            binding=self.binding,
            model_wiring=self._wiring,
            environment_factory=self._environment,
            db_dir=tmp_path / "room-agents",
            system_prompt="You are a coworker in a room.",
            turn_timeout=30.0,
        )

    def _wiring(self, agent_id: str):
        def factory():
            client = MockModelClient(list(self._scripts.get(agent_id, [])))
            self.clients.setdefault(agent_id, []).append(client)
            return client

        return factory, None

    def _environment(self, agent_id: str):
        workdir = self._tmp / "boxes" / agent_id
        workdir.mkdir(parents=True, exist_ok=True)
        return make_environment("local", workdir=str(workdir))

    def prompts_seen_by(self, agent_id: str) -> list[str]:
        """Every user-role prompt this member's models were given."""
        seen: list[str] = []
        for client in self.clients.get(agent_id, []):
            for call in client.calls:
                for message in call:
                    if message.get("role") == "user":
                        seen.append(str(message.get("content") or ""))
        return seen


def _service(members: _Members, frames: list[dict], store: RoomStore) -> RoomService:
    return RoomService(
        room_store=store,
        binding=members.binding,
        emit=frames.append,
        members_ready=members.pool.ensure_room,
    )


@pytest.fixture
def room_store():
    return RoomStore()


def test_three_members_all_answer_through_the_room_service(tmp_path, room_store):
    """The whole room runs through the host's own service: three members, three
    real executors, three real answers — and not one offline placeholder."""
    members = _Members(
        tmp_path,
        {
            "id-amber": ["amber weighs in"],
            "id-cobalt": ["cobalt weighs in"],
            "id-slate": ["slate weighs in"],
        },
    )
    frames: list[dict] = []
    service = _service(members, frames, room_store)

    dispatch_room_frame(
        service,
        {
            "type": "room_create",
            "room_id": "r1",
            "name": "launch",
            "members": [
                {"agent_id": "id-amber", "handle": "amber"},
                {"agent_id": "id-cobalt", "handle": "cobalt"},
                {"agent_id": "id-slate", "handle": "slate"},
            ],
        },
    )
    try:
        dispatch_room_frame(
            service,
            {"type": "room_task", "room_id": "r1", "message": "everyone weigh in"},
        )
    finally:
        members.pool.shutdown()

    turns = [f for f in frames if f["type"] == "room_turn"]
    assert [t["handle"] for t in turns] == ["amber", "cobalt", "slate"]
    assert [t["text"] for t in turns] == [
        "amber weighs in",
        "cobalt weighs in",
        "slate weighs in",
    ]
    assert all("offline" not in t["text"] for t in turns)

    done = frames[-1]
    assert done["type"] == "room_done"
    assert done["reason"] == "no_more_mentions"
    assert done["messages_sent"] == 3


def test_a_mention_pulls_the_next_agent_in(tmp_path, room_store):
    """The point of the whole feature: agent A writes ``@cobalt`` and agent B is
    the one who speaks next — over the real service, the real binding and two
    real executors."""
    members = _Members(
        tmp_path,
        {
            "id-amber": ["starting. @cobalt take the numbers"],
            "id-cobalt": ["numbers are done"],
        },
    )
    frames: list[dict] = []
    service = _service(members, frames, room_store)

    dispatch_room_frame(
        service,
        {
            "type": "room_create",
            "room_id": "r1",
            "name": "launch",
            "members": [
                {"agent_id": "id-amber", "handle": "amber"},
                {"agent_id": "id-cobalt", "handle": "cobalt"},
            ],
        },
    )
    try:
        # Only amber is addressed, so only amber speaks in round 1. Anything
        # cobalt says is something amber's own reply pulled out of it.
        dispatch_room_frame(
            service,
            {"type": "room_task", "room_id": "r1", "message": "@amber kick us off"},
        )
    finally:
        members.pool.shutdown()

    turns = [f for f in frames if f["type"] == "room_turn"]
    assert [(t["round"], t["handle"]) for t in turns] == [(1, "amber"), (2, "cobalt")]
    assert turns[0]["text"] == "starting. @cobalt take the numbers"
    assert turns[1]["text"] == "numbers are done"

    # cobalt was not merely scheduled — it was shown what amber said.
    cobalt_saw = "\n".join(members.prompts_seen_by("id-cobalt"))
    assert "@cobalt take the numbers" in cobalt_saw
    assert "Reply as @cobalt." in cobalt_saw

    done = frames[-1]
    assert done["type"] == "room_done"
    assert done["reason"] == "no_more_mentions"
    assert done["messages_sent"] == 2


def test_members_come_online_only_when_a_room_runs(tmp_path, room_store):
    """Cost control: a room nobody opens starts no executor. The members are
    built on the first ``room_task`` and stay warm for the next one."""
    members = _Members(tmp_path, {"id-amber": ["hi"], "id-cobalt": ["hi"]})
    frames: list[dict] = []
    service = _service(members, frames, room_store)

    dispatch_room_frame(
        service,
        {
            "type": "room_create",
            "room_id": "r1",
            "name": "launch",
            "members": [
                {"agent_id": "id-amber", "handle": "amber"},
                {"agent_id": "id-cobalt", "handle": "cobalt"},
            ],
        },
    )
    # Created, not opened: nothing runs and nobody is registered as reachable.
    assert members.pool.running_ids == frozenset()
    assert members.binding.online_ids == frozenset()

    try:
        service.handle_room_task("r1", "hello")
        assert members.pool.running_ids == {"id-amber", "id-cobalt"}
        assert members.binding.online_ids == {"id-amber", "id-cobalt"}

        # A second exchange reuses the same two executors.
        before = members.pool.running_ids
        service.handle_room_task("r1", "again")
        assert members.pool.running_ids == before
    finally:
        members.pool.shutdown()

    # Shutdown takes them offline again — nothing stays registered as reachable.
    assert members.pool.running_ids == frozenset()
    assert members.binding.online_ids == frozenset()


def test_a_member_that_cannot_start_is_offline_and_the_room_runs_on(
    tmp_path, room_store
):
    """One member's runtime failing is one offline line, not a dead room."""
    members = _Members(tmp_path, {"id-amber": ["amber weighs in"]})

    broken = members._environment

    def environment(agent_id: str):
        if agent_id == "id-cobalt":
            raise RuntimeError("no sandbox for this one")
        return broken(agent_id)

    members.pool = RoomAgentPool(
        binding=members.binding,
        model_wiring=members._wiring,
        environment_factory=environment,
        db_dir=tmp_path / "room-agents",
        system_prompt="You are a coworker in a room.",
        turn_timeout=30.0,
    )

    frames: list[dict] = []
    service = _service(members, frames, room_store)
    dispatch_room_frame(
        service,
        {
            "type": "room_create",
            "room_id": "r1",
            "name": "launch",
            "members": [
                {"agent_id": "id-amber", "handle": "amber"},
                {"agent_id": "id-cobalt", "handle": "cobalt"},
            ],
        },
    )
    try:
        service.handle_room_task("r1", "everyone weigh in")
    finally:
        members.pool.shutdown()

    turns = [f for f in frames if f["type"] == "room_turn"]
    assert [t["handle"] for t in turns] == ["amber", "cobalt"]
    assert turns[0]["text"] == "amber weighs in"
    assert "offline" in turns[1]["text"]
    assert frames[-1]["type"] == "room_done"


def test_no_model_wiring_means_offline_not_a_crash(tmp_path, room_store):
    """Before an account is provisioned there is nothing to run a turn on. The
    room must say so, not raise into the frame loop."""
    members = _Members(tmp_path, {"id-amber": ["never asked"]})
    members.pool = RoomAgentPool(
        binding=members.binding,
        model_wiring=lambda _agent_id: (None, None),
        environment_factory=members._environment,
        db_dir=tmp_path / "room-agents",
        system_prompt="You are a coworker in a room.",
    )

    frames: list[dict] = []
    service = _service(members, frames, room_store)
    dispatch_room_frame(
        service,
        {
            "type": "room_create",
            "room_id": "r1",
            "name": "launch",
            "members": [{"agent_id": "id-amber", "handle": "amber"}],
        },
    )
    try:
        service.handle_room_task("r1", "anyone there?")
    finally:
        members.pool.shutdown()

    turns = [f for f in frames if f["type"] == "room_turn"]
    assert len(turns) == 1
    assert "offline" in turns[0]["text"]
    assert members.binding.online_ids == frozenset()
