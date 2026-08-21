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
