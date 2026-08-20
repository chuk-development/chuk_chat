"""RoomRunner (§16.1/4b): drives a room through scripted turns, builds context,
respects the stop seam and the caps."""

from __future__ import annotations

from cowork_manager import (
    GroupRoom,
    RoomCaps,
    RoomContext,
    RoomMember,
    RoomRunner,
)


def _room(handles, caps=None):
    members = tuple(RoomMember(agent_id=f"id-{h}", handle=h) for h in handles)
    return GroupRoom(room_id="r", name="n", members=members, caps=caps or RoomCaps())


def test_no_mentions_everyone_replies_once_in_order():
    room = _room(["amber", "cobalt", "jade"])
    seen = []

    def turn(ctx: RoomContext) -> str:
        seen.append(ctx.speaker.handle)
        return f"{ctx.speaker.handle} says hi"

    outcome = RoomRunner(room, turn).run("hello all")
    assert seen == ["amber", "cobalt", "jade"]
    assert [t.handle for t in outcome.transcript] == ["amber", "cobalt", "jade"]
    assert outcome.stop_reason == "no_more_mentions"
    assert outcome.messages_sent == 3


def test_context_shows_the_user_message_and_prior_replies():
    room = _room(["amber", "cobalt"])
    prompts = []

    def turn(ctx: RoomContext) -> str:
        prompts.append(ctx.as_prompt())
        return f"reply from {ctx.speaker.handle}"

    RoomRunner(room, turn).run("what's the plan?")
    # amber sees only the user message; cobalt sees the user message + amber's
    # reply, so a coworker can answer what another just said.
    assert "User: what's the plan?" in prompts[0]
    assert "@amber:" not in prompts[0]
    assert "@amber: reply from amber" in prompts[1]
    assert "Reply as @cobalt." in prompts[1]


def test_a_mention_in_a_reply_drives_the_next_round():
    room = _room(["amber", "cobalt", "jade"])

    def turn(ctx: RoomContext) -> str:
        if ctx.speaker.handle == "amber":
            return "good question for @jade"
        return "ok"

    outcome = RoomRunner(room, turn).run("@amber start")
    assert [t.handle for t in outcome.transcript] == ["amber", "jade"]
    assert outcome.rounds == 2
    assert outcome.stop_reason == "no_more_mentions"


def test_the_stop_seam_ends_the_room_between_turns():
    room = _room(["amber", "cobalt", "jade"])
    calls = {"n": 0}

    def turn(ctx: RoomContext) -> str:
        calls["n"] += 1
        return "hi"

    # Stop after the first turn has run.
    def stop() -> bool:
        return calls["n"] >= 1

    outcome = RoomRunner(room, turn, stop=stop).run("everyone")
    assert calls["n"] == 1
    assert outcome.stop_reason == "stopped"
    assert outcome.messages_sent == 1


def test_a_stop_true_from_the_start_runs_nobody():
    room = _room(["amber"])
    ran = []
    outcome = RoomRunner(
        room, lambda ctx: ran.append(ctx) or "x", stop=lambda: True
    ).run("hi")
    assert ran == []
    assert outcome.stop_reason == "stopped"
    assert outcome.messages_sent == 0


def test_a_crashing_turn_stops_the_room_without_raising():
    room = _room(["amber", "cobalt"])

    def turn(ctx: RoomContext) -> str:
        if ctx.speaker.handle == "amber":
            raise RuntimeError("boom")
        return "ok"

    outcome = RoomRunner(room, turn).run("everyone")
    assert outcome.stop_reason == "turn_failed"
    # The crashed speaker recorded an empty reply so the transcript is honest.
    assert outcome.transcript[-1].handle == "amber"
    assert outcome.transcript[-1].text == ""


def test_caps_override_lowers_the_ceiling_for_this_run():
    room = _room(["amber", "cobalt"])

    def turn(ctx: RoomContext) -> str:
        return "over to @cobalt" if ctx.speaker.handle == "amber" else "done"

    outcome = RoomRunner(room, turn, caps=RoomCaps(max_rounds=1)).run("@amber go")
    assert [t.handle for t in outcome.transcript] == ["amber"]
    assert outcome.stop_reason == "rounds_exhausted"


def test_on_turn_streams_each_turn_live():
    room = _room(["amber", "cobalt"])

    def turn(ctx: RoomContext) -> str:
        return "over to @cobalt" if ctx.speaker.handle == "amber" else "done"

    streamed = []
    outcome = RoomRunner(
        room, turn, on_turn=lambda t: streamed.append((t.round, t.handle, t.text))
    ).run("@amber go")
    # Streamed live, in order, and matching the final transcript.
    assert streamed == [(1, "amber", "over to @cobalt"), (2, "cobalt", "done")]
    assert [(t.round, t.handle, t.text) for t in outcome.transcript] == streamed


def test_on_turn_does_not_fire_for_a_crashed_turn():
    room = _room(["amber", "cobalt"])

    def turn(ctx: RoomContext) -> str:
        raise RuntimeError("boom")

    streamed = []
    RoomRunner(room, turn, on_turn=streamed.append).run("everyone")
    # The crashed turn recorded an empty transcript entry but never streamed —
    # on_turn only fires for a real reply, so the app is not told of a turn that
    # did not happen.
    assert streamed == []
