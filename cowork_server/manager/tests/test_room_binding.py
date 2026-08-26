"""RoomBinding (§16.1/4b): the reachable-member registry + its RoomDriver seam."""

from __future__ import annotations

import threading

from cowork_manager import (
    OFFLINE_REPLY,
    GroupRoom,
    RoomBinding,
    RoomDriver,
    RoomMember,
)


def _room(handles):
    members = tuple(RoomMember(agent_id=f"id-{h}", handle=h) for h in handles)
    return GroupRoom(room_id="r", name="n", members=members)


def test_register_makes_a_member_reachable_and_routes_the_prompt():
    binding = RoomBinding()
    seen = []

    def sender(prompt):
        seen.append(prompt)
        return "amber replied"

    binding.register("id-amber", sender)
    assert binding.is_online("id-amber")
    assert binding.online_ids == frozenset({"id-amber"})

    runner = binding.member_runner()
    member = RoomMember(agent_id="id-amber", handle="amber")
    assert runner(member, "the prompt") == "amber replied"
    assert seen == ["the prompt"]


def test_an_unregistered_member_runs_as_offline():
    binding = RoomBinding()
    runner = binding.member_runner()
    assert runner(RoomMember(agent_id="id-ghost", handle="ghost"), "p") is None


def test_unregister_drops_reachability_and_is_idempotent():
    binding = RoomBinding()
    binding.register("id-amber", lambda p: "hi")
    binding.unregister("id-amber")
    assert not binding.is_online("id-amber")
    binding.unregister("id-amber")  # double-drop must not raise


def test_reconnect_replaces_the_sender():
    binding = RoomBinding()
    binding.register("id-amber", lambda p: "old")
    binding.register("id-amber", lambda p: "new")
    runner = binding.member_runner()
    assert runner(RoomMember(agent_id="id-amber", handle="amber"), "p") == "new"


def test_the_runner_reads_the_registry_per_call():
    # A member that drops mid-room is offline from its next turn on: the runner
    # is not a snapshot taken when it was built.
    binding = RoomBinding()
    binding.register("id-amber", lambda p: "hi")
    runner = binding.member_runner()
    member = RoomMember(agent_id="id-amber", handle="amber")
    assert runner(member, "p") == "hi"
    binding.unregister("id-amber")
    assert runner(member, "p") is None


def test_binding_drives_a_whole_room_with_a_mix_of_online_and_offline():
    room = _room(["amber", "cobalt", "jade"])
    binding = RoomBinding()
    binding.register("id-amber", lambda p: "amber here")
    binding.register("id-jade", lambda p: "jade here")
    # cobalt never registers -> offline.

    outcome = RoomDriver(binding.member_runner()).run(room, "everyone")
    texts = {t.handle: t.text for t in outcome.transcript}
    assert texts["amber"] == "amber here"
    assert texts["cobalt"] == OFFLINE_REPLY
    assert texts["jade"] == "jade here"


def test_registration_is_thread_safe():
    binding = RoomBinding()

    def worker(i):
        binding.register(f"id-{i}", lambda p: "x")

    threads = [threading.Thread(target=worker, args=(i,)) for i in range(50)]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert len(binding.online_ids) == 50
