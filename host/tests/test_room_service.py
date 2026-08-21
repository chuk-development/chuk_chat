"""RoomService (§16.1/4b): room_task -> RoomStore -> RoomDriver -> room frames.

The emit seam is captured, so the whole server-side room flow is checked without
a socket. The path below (RoomDriver -> RoomBinding -> executors) is proven over
the sealed loopback in the executor tests; this checks the frame in, frames out.
"""

from __future__ import annotations

from cowork_manager import RoomBinding, RoomCaps, RoomStore

from cowork_host import RoomService


def _store_with_room(handles):
    store = RoomStore()
    room = store.create_room(name="launch")
    for h in handles:
        store.add_member(room.room_id, f"id-{h}", h)
    return store, room.room_id


def test_a_room_task_streams_turns_then_done():
    store, room_id = _store_with_room(["amber", "cobalt"])
    binding = RoomBinding()
    binding.register("id-amber", lambda p: "amber says hi")
    binding.register("id-cobalt", lambda p: "cobalt says hi")

    frames = []
    service = RoomService(room_store=store, binding=binding, emit=frames.append)
    service.handle_room_task(room_id, "everyone weigh in")

    turns = [f for f in frames if f["type"] == "room_turn"]
    assert [t["handle"] for t in turns] == ["amber", "cobalt"]
    assert [t["text"] for t in turns] == ["amber says hi", "cobalt says hi"]
    assert all(t["room_id"] == room_id for t in turns)

    done = frames[-1]
    assert done["type"] == "room_done"
    assert done["room_id"] == room_id
    assert done["reason"] == "no_more_mentions"
    assert done["messages_sent"] == 2


def test_an_unknown_room_ends_with_no_such_room():
    store = RoomStore()
    binding = RoomBinding()
    frames = []
    service = RoomService(room_store=store, binding=binding, emit=frames.append)
    service.handle_room_task("ghost", "hi?")

    assert len(frames) == 1
    assert frames[0]["type"] == "room_done"
    assert frames[0]["reason"] == "no_such_room"
    assert frames[0]["room_id"] == "ghost"


def test_an_offline_member_shows_the_offline_placeholder():
    store, room_id = _store_with_room(["amber", "cobalt"])
    binding = RoomBinding()
    binding.register("id-amber", lambda p: "amber here")
    # cobalt never registers -> offline.

    frames = []
    RoomService(room_store=store, binding=binding, emit=frames.append).handle_room_task(
        room_id, "everyone"
    )
    turns = {f["handle"]: f["text"] for f in frames if f["type"] == "room_turn"}
    assert turns["amber"] == "amber here"
    assert "offline" in turns["cobalt"].lower()


def test_a_mention_in_a_reply_drives_a_second_round_of_frames():
    store, room_id = _store_with_room(["amber", "cobalt"])
    binding = RoomBinding()
    binding.register("id-amber", lambda p: "over to @cobalt")
    binding.register("id-cobalt", lambda p: "done")

    frames = []
    RoomService(room_store=store, binding=binding, emit=frames.append).handle_room_task(
        room_id, "@amber start"
    )
    turns = [f for f in frames if f["type"] == "room_turn"]
    assert [(t["round"], t["handle"]) for t in turns] == [(1, "amber"), (2, "cobalt")]


def test_caps_override_reaches_the_service():
    store, room_id = _store_with_room(["amber", "cobalt"])
    binding = RoomBinding()
    binding.register("id-amber", lambda p: "over to @cobalt")
    binding.register("id-cobalt", lambda p: "done")

    frames = []
    RoomService(
        room_store=store,
        binding=binding,
        emit=frames.append,
        caps=RoomCaps(max_rounds=1),
    ).handle_room_task(room_id, "@amber go")
    turns = [f for f in frames if f["type"] == "room_turn"]
    assert [t["handle"] for t in turns] == ["amber"]
    assert frames[-1]["reason"] == "rounds_exhausted"


def test_the_service_records_the_transcript_and_starts_fresh_each_time():
    from cowork_manager import RoomTranscriptStore

    store, room_id = _store_with_room(["amber", "cobalt"])
    binding = RoomBinding()
    binding.register("id-amber", lambda p: "amber says hi")
    binding.register("id-cobalt", lambda p: "cobalt says hi")
    transcript = RoomTranscriptStore()

    service = RoomService(
        room_store=store,
        binding=binding,
        emit=lambda f: None,
        transcript=transcript,
    )
    service.handle_room_task(room_id, "first message")
    assert [t.text for t in transcript.history(room_id)] == [
        "amber says hi",
        "cobalt says hi",
    ]

    # A second message starts a fresh exchange: the history is the new one only.
    binding.register("id-amber", lambda p: "amber again")
    binding.register("id-cobalt", lambda p: "cobalt again")
    service.handle_room_task(room_id, "second message")
    assert [t.text for t in transcript.history(room_id)] == [
        "amber again",
        "cobalt again",
    ]


def test_handle_room_history_replays_the_stored_transcript():
    from cowork_manager import RoomTranscriptStore

    store, room_id = _store_with_room(["amber", "cobalt"])
    binding = RoomBinding()
    binding.register("id-amber", lambda p: "amber hi")
    binding.register("id-cobalt", lambda p: "cobalt hi")
    transcript = RoomTranscriptStore()

    frames = []
    service = RoomService(
        room_store=store,
        binding=binding,
        emit=frames.append,
        transcript=transcript,
    )
    service.handle_room_task(room_id, "go")

    frames.clear()
    service.handle_room_history(room_id)
    assert len(frames) == 1
    hist = frames[0]
    assert hist["type"] == "room_history"
    assert hist["room_id"] == room_id
    assert [t["text"] for t in hist["turns"]] == ["amber hi", "cobalt hi"]


def test_handle_room_history_is_empty_without_a_transcript_store():
    store, room_id = _store_with_room(["amber", "cobalt"])
    frames = []
    RoomService(
        room_store=store, binding=RoomBinding(), emit=frames.append
    ).handle_room_history(room_id)
    assert frames == [{"type": "room_history", "room_id": room_id, "turns": []}]


def test_handle_room_create_makes_the_room_drivable():
    store = RoomStore()
    binding = RoomBinding()
    binding.register("id-amber", lambda p: "amber hi")
    binding.register("id-cobalt", lambda p: "cobalt hi")
    frames = []
    service = RoomService(room_store=store, binding=binding, emit=frames.append)

    service.handle_room_create(
        "room:1",
        "launch",
        [
            {"agent_id": "id-amber", "handle": "amber"},
            {"agent_id": "id-cobalt", "handle": "cobalt"},
        ],
    )
    # Now a task finds the room and drives it (instead of no_such_room).
    service.handle_room_task("room:1", "go")
    turns = [f for f in frames if f["type"] == "room_turn"]
    assert [t["handle"] for t in turns] == ["amber", "cobalt"]


def test_handle_room_create_is_idempotent():
    store = RoomStore()
    service = RoomService(room_store=store, binding=RoomBinding(), emit=lambda f: None)
    members = [{"agent_id": "id-amber", "handle": "amber"}]
    service.handle_room_create("room:1", "launch", members)
    # A re-create (reconnect) does not raise or duplicate.
    service.handle_room_create("room:1", "launch", members)
    assert len(store.get("room:1").members) == 1


def test_handle_room_create_skips_members_over_the_cap():
    store = RoomStore()
    service = RoomService(room_store=store, binding=RoomBinding(), emit=lambda f: None)
    members = [{"agent_id": f"id-{i}", "handle": f"h{i}"} for i in range(8)]
    service.handle_room_create("room:1", "big", members)
    # Six taken, the rest skipped; the room is still valid.
    assert len(store.get("room:1").members) == 6


def test_handle_room_delete_drops_the_room_and_its_transcript():
    from cowork_manager import RoomTranscriptStore

    store, room_id = _store_with_room(["amber", "cobalt"])
    binding = RoomBinding()
    binding.register("id-amber", lambda p: "amber hi")
    binding.register("id-cobalt", lambda p: "cobalt hi")
    transcript = RoomTranscriptStore()
    service = RoomService(
        room_store=store, binding=binding, emit=lambda f: None, transcript=transcript
    )
    service.handle_room_task(room_id, "go")
    assert transcript.history(room_id)  # some history exists

    service.handle_room_delete(room_id)
    assert store.get(room_id) is None
    assert transcript.history(room_id) == []  # no orphaned transcript


def test_handle_room_delete_of_an_unknown_room_is_a_noop():
    store = RoomStore()
    RoomService(
        room_store=store, binding=RoomBinding(), emit=lambda f: None
    ).handle_room_delete("ghost")  # must not raise


def test_handle_room_rename_renames_a_held_room():
    store, room_id = _store_with_room(["amber", "cobalt"])
    service = RoomService(room_store=store, binding=RoomBinding(), emit=lambda f: None)
    service.handle_room_rename(room_id, "renamed")
    assert store.get(room_id).name == "renamed"


def test_handle_room_rename_of_an_unknown_room_is_a_noop():
    store = RoomStore()
    RoomService(
        room_store=store, binding=RoomBinding(), emit=lambda f: None
    ).handle_room_rename("ghost", "x")  # must not raise
