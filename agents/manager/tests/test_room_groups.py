"""Groups (§16.1): who answers, auto pick, lead mode, settings, transcript."""

from __future__ import annotations

import sqlite3
import threading
import time

import pytest

from chuk_agents_manager import (
    LEAD_MAX_ROUNDS,
    LEAD_MAX_TASKS,
    GroupRoom,
    HandoffCollector,
    RoomDriver,
    RoomError,
    RoomMember,
    RoomSession,
    RoomStore,
    RoomTranscriptStore,
    RoomTurn,
    auto_pick,
    route_first_round,
    run_lead_exchange,
)
from chuk_agents_manager.room_runner import RoomContext

AMBER = RoomMember("id-amber", "amber")
COBALT = RoomMember("id-cobalt", "cobalt")
SLATE = RoomMember("id-slate", "slate")


def _room(**kw) -> GroupRoom:
    return GroupRoom(room_id="r1", name="team", members=(AMBER, COBALT, SLATE), **kw)


# -- who answers -------------------------------------------------------------


def test_a_mention_beats_every_mode():
    for mode in ("everyone", "mentions", "auto", "lead"):
        decision = route_first_round(_room(responder=mode), "hey @cobalt")
        assert decision.members == (COBALT,)
        assert decision.via == "mention"
        assert decision.routed_by() is None


def test_at_all_reaches_everyone_in_every_mode():
    for mode in ("everyone", "mentions", "auto", "lead"):
        decision = route_first_round(_room(responder=mode), "@all status?")
        assert decision.members == (AMBER, COBALT, SLATE)


def test_everyone_mode_without_a_mention_asks_every_member():
    assert route_first_round(_room(), "hi").members == (AMBER, COBALT, SLATE)


def test_mentions_mode_without_a_mention_asks_nobody_and_says_why():
    room = _room(responder="mentions")
    decision = route_first_round(room, "hi")
    assert decision.members == ()
    session = RoomSession(room, "hi", first_round=decision.members)
    assert session.next_speaker() is None
    assert session.stop_reason == "no_addressee"


def test_lead_mode_asks_the_lead_or_the_first_member():
    assert route_first_round(_room(responder="lead", lead_agent_id="id-slate"), "x").members == (SLATE,)
    # A lead that left the group: the first member leads.
    assert route_first_round(_room(responder="lead", lead_agent_id="id-gone"), "x").members == (AMBER,)


def test_an_unknown_mode_is_refused():
    with pytest.raises(RoomError):
        _room(responder="loudest")


# -- auto ----------------------------------------------------------------------


def test_auto_takes_a_confident_pick():
    room = _room(responder="auto")
    decision = route_first_round(room, "fix the css", ask=lambda s, u: '{"pick": ["cobalt"], "confidence": 0.94}')
    assert decision.members == (COBALT,)
    assert decision.routed_by() == {"mode": "auto", "fallback": False, "confidence": 0.94}


def test_auto_reads_names_and_instructions():
    seen = {}

    def ask(system, user):
        seen["user"] = user
        return '{"pick": ["slate"], "confidence": 0.8}'

    room = _room(responder="auto", bulletin="Ship on Friday.")
    route_first_round(room, "who does design?", ask=ask, names={"id-slate": "Designer"})
    assert "slate: Designer" in seen["user"]
    assert "Ship on Friday." in seen["user"]


@pytest.mark.parametrize(
    "reply",
    [
        '{"pick": ["cobalt"], "confidence": 0.4}',  # unsure
        '{"pick": ["nobody"], "confidence": 0.99}',  # not a member
        "cobalt, surely",  # not JSON
        '{"pick": ["cobalt"]}',  # no confidence
    ],
)
def test_auto_falls_back_on_a_weak_answer(reply):
    room = _room(responder="auto", fallback_agent_id="id-slate")
    decision = route_first_round(room, "x", ask=lambda s, u: reply)
    assert decision.members == (SLATE,)
    assert decision.fallback is True


def test_auto_falls_back_on_an_error():
    def boom(system, user):
        raise RuntimeError("model down")

    decision = route_first_round(_room(responder="auto"), "x", ask=boom)
    assert decision.members == (AMBER,)
    assert decision.routed_by()["fallback"] is True


def test_auto_falls_back_fast_when_the_model_is_slow():
    release = threading.Event()

    def slow(system, user):
        release.wait(5)
        return '{"pick": ["cobalt"], "confidence": 0.99}'

    started = time.monotonic()
    decision = auto_pick(_room(responder="auto"), "x", ask=slow, timeout=0.2)
    elapsed = time.monotonic() - started
    release.set()
    assert decision.members == (AMBER,)
    assert decision.fallback is True
    assert elapsed < 1.0


def test_auto_without_a_model_answers_with_the_fallback():
    decision = route_first_round(_room(responder="auto", fallback_agent_id="id-cobalt"), "x")
    assert decision.members == (COBALT,)


def test_auto_may_pick_several_members():
    decision = route_first_round(
        _room(responder="auto"), "x", ask=lambda s, u: '{"pick": ["@slate", "amber"], "confidence": 0.7}'
    )
    assert decision.members == (SLATE, AMBER)


def test_the_driver_marks_only_the_routed_turn():
    room = _room(responder="auto")
    replies = {"id-cobalt": "on it, @amber check this", "id-amber": "checked"}
    turns = []
    RoomDriver(lambda m, p: replies.get(m.agent_id, "?")).run(
        room,
        "fix it",
        on_turn=turns.append,
        ask=lambda s, u: '{"pick": ["cobalt"], "confidence": 0.9}',
    )
    assert [(t.handle, t.routed_by is not None) for t in turns] == [("cobalt", True), ("amber", False)]


# -- the prompt ----------------------------------------------------------------


def test_a_member_reads_names_instructions_folder_and_history():
    room = _room(bulletin="Answer in German.", workdir="/srv/shared")
    prompt = RoomContext(
        speaker=COBALT,
        user_message="next step?",
        transcript=(),
        room=room,
        history=(RoomTurn(0, "", "", "earlier question", kind="user"), RoomTurn(1, "id-amber", "amber", "earlier answer")),
        names={"id-amber": "Planner"},
    ).as_prompt()
    assert 'The group is called "team".' in prompt
    assert "@amber (Planner)" in prompt
    assert "Answer in German." in prompt
    assert "/srv/shared" in prompt
    assert "User: earlier question" in prompt
    assert "@amber: earlier answer" in prompt
    assert prompt.rstrip().endswith("Reply as @cobalt.")


# -- lead mode -------------------------------------------------------------------


class _Team:
    """Scripted members; the lead's script may call the armed hand-off tool."""

    def __init__(self, lead_script, member_reply=lambda m, p: f"{m.handle} done"):
        self.lead_script = list(lead_script)
        self.member_reply = member_reply
        self.armed: dict[str, object] = {}
        self.prompts: dict[str, list[str]] = {}

    def arm(self, agent_id, backend):
        if backend is None:
            self.armed.pop(agent_id, None)
        else:
            self.armed[agent_id] = backend

    def run(self, member, prompt):
        self.prompts.setdefault(member.agent_id, []).append(prompt)
        if member == AMBER:
            step = self.lead_script.pop(0) if self.lead_script else "final"
            backend = self.armed.get(member.agent_id)
            if callable(step):
                return step(backend)
            return step
        return self.member_reply(member, prompt)


def _lead_room():
    return _room(responder="lead", lead_agent_id="id-amber")


def test_a_lead_that_answers_alone_ends_the_exchange():
    team = _Team(["I can answer that myself."])
    turns = []
    out = run_lead_exchange(_lead_room(), "q", run_member=team.run, arm=team.arm, on_turn=turns.append, routed_by={"mode": "lead"})
    assert out.stop_reason == "lead_done"
    assert [(t.handle, t.kind) for t in turns] == [("amber", "agent")]
    assert turns[0].routed_by == {"mode": "lead"}
    assert "hand_off_tasks" in team.prompts["id-amber"][0]
    assert team.armed == {}


def test_a_lead_hands_off_and_is_woken_once_with_the_results():
    def hand_off(backend):
        result = backend.hand_off(
            [{"member": "cobalt", "task": "write the css"}, {"member": "slate", "task": "check the copy"}]
        )
        assert result["ok"] is True
        return "Asked the team."

    team = _Team([hand_off, "All done: css and copy."])
    started = []
    turns = []
    out = run_lead_exchange(
        _lead_room(), "ship the page", run_member=team.run, arm=team.arm, on_turn=turns.append, on_start=lambda m: started.append(m.handle)
    )
    assert out.stop_reason == "lead_done"
    kinds = [(t.handle, t.kind, t.to_handle) for t in turns]
    assert kinds[0] == ("amber", "agent", None)
    assert ("amber", "handoff", "cobalt") in kinds and ("amber", "handoff", "slate") in kinds
    assert {t.handle for t in turns if t.kind == "agent"} == {"amber", "cobalt", "slate"}
    assert turns[-1].text == "All done: css and copy."
    assert started.count("amber") == 2
    # The member got its task and the member rules.
    cobalt_prompt = team.prompts["id-cobalt"][0]
    assert "write the css" in cobalt_prompt and "Do not pass the task on" in cobalt_prompt
    # The woken lead saw the members' reports.
    assert "cobalt done" in team.prompts["id-amber"][1]


def test_the_task_cap_refuses_tasks_to_the_model():
    results = {}

    def greedy(backend):
        tasks = [{"member": "cobalt" if i % 2 else "slate", "task": f"t{i}"} for i in range(LEAD_MAX_TASKS + 2)]
        results["first"] = backend.hand_off(tasks)
        return "go"

    team = _Team([greedy, "summary"])
    run_lead_exchange(_lead_room(), "q", run_member=team.run, arm=team.arm)
    assert len(results["first"]["accepted"]) == LEAD_MAX_TASKS
    assert len(results["first"]["refused"]) == 2
    assert "task limit" in results["first"]["refused"][0]["reason"]


def test_the_round_cap_stops_a_lead_that_never_stops_handing_off():
    seen = []

    def again(backend):
        seen.append(backend.hand_off([{"member": "cobalt", "task": "more"}]))
        return "more work"

    team = _Team([again] * 10)
    turns = []
    out = run_lead_exchange(_lead_room(), "q", run_member=team.run, arm=team.arm, on_turn=turns.append)
    lead_turns = [t for t in turns if t.handle == "amber" and t.kind == "agent"]
    assert len(lead_turns) == LEAD_MAX_ROUNDS
    assert out.stop_reason == "lead_done"
    # The last lead turn could not hand off any more.
    assert seen[-1]["ok"] is False
    assert "no rounds left" in seen[-1]["refused"][0]["reason"]


def test_a_lead_that_writes_a_mention_still_reaches_the_member():
    team = _Team(["@cobalt please look at the logs", "cobalt found it"])
    turns = []
    run_lead_exchange(_lead_room(), "q", run_member=team.run, arm=team.arm, on_turn=turns.append)
    assert [t.to_handle for t in turns if t.kind == "handoff"] == ["cobalt"]
    assert len(team.prompts["id-cobalt"]) == 1


def test_two_tasks_for_one_member_run_as_one():
    def twice(backend):
        backend.hand_off([{"member": "cobalt", "task": "a"}, {"member": "cobalt", "task": "b"}])
        return "ok"

    team = _Team([twice, "done"])
    run_lead_exchange(_lead_room(), "q", run_member=team.run, arm=team.arm)
    assert len(team.prompts["id-cobalt"]) == 1
    assert "Also: b" in team.prompts["id-cobalt"][0]


def test_the_lead_cannot_hand_work_to_itself_or_a_stranger():
    collector = HandoffCollector(_lead_room(), AMBER)
    result = collector.hand_off([{"member": "amber", "task": "x"}, {"member": "ghost", "task": "y"}])
    assert result["ok"] is False
    assert len(result["refused"]) == 2
    assert collector.take() == []


def test_the_driver_runs_lead_mode_only_without_a_mention():
    team = _Team(["lead answer"])
    turns = []
    RoomDriver(team.run).run(_lead_room(), "plan it", on_turn=turns.append, arm=team.arm)
    assert [t.handle for t in turns] == ["amber"]
    turns.clear()
    RoomDriver(team.run).run(_lead_room(), "@slate only you", on_turn=turns.append, arm=team.arm)
    assert [t.handle for t in turns] == ["slate"]


# -- stores ---------------------------------------------------------------------


def test_group_settings_are_stored_and_validated(tmp_path):
    store = RoomStore(str(tmp_path / "rooms.db"))
    store.create_room(name="g", room_id="g1")
    store.add_member("g1", "id-amber", "amber")
    room = store.set_settings("g1", responder="lead", lead_agent_id="id-amber", bulletin="Be brief.", workdir=" /srv/x ")
    assert (room.responder, room.lead_agent_id, room.bulletin, room.workdir) == ("lead", "id-amber", "Be brief.", "/srv/x")
    with pytest.raises(RoomError):
        store.set_settings("g1", responder="loudest")
    with pytest.raises(RoomError):
        store.set_settings("g1", bulletin="x" * 12_001)
    # Only the given keys change.
    assert store.set_settings("g1", bulletin="").responder == "lead"
    store.close()
    assert RoomStore(str(tmp_path / "rooms.db")).get("g1").lead_agent_id == "id-amber"


def test_an_old_rooms_file_gets_the_settings_columns(tmp_path):
    path = tmp_path / "rooms.db"
    con = sqlite3.connect(path)
    con.executescript(
        """
        CREATE TABLE rooms (id TEXT PRIMARY KEY, name TEXT NOT NULL, max_members INTEGER,
            max_rounds INTEGER NOT NULL, max_messages INTEGER, created_at TEXT NOT NULL,
            agent_to_agent INTEGER NOT NULL DEFAULT 1);
        CREATE TABLE room_members (room_id TEXT NOT NULL, agent_id TEXT NOT NULL,
            handle TEXT NOT NULL, position INTEGER NOT NULL, PRIMARY KEY (room_id, agent_id),
            UNIQUE (room_id, handle));
        INSERT INTO rooms VALUES ('old', 'Old', NULL, 3, NULL, '2026-01-01', 1);
        """
    )
    con.commit()
    con.close()
    room = RoomStore(str(path)).get("old")
    assert room.responder == "everyone"
    assert room.bulletin == ""


def test_the_store_can_be_used_from_another_thread():
    store = RoomStore()
    store.create_room(name="g", room_id="g1")
    errors = []

    def work():
        try:
            store.add_member("g1", "id-amber", "amber")
        except Exception as exc:  # noqa: BLE001
            errors.append(exc)

    thread = threading.Thread(target=work)
    thread.start()
    thread.join()
    assert errors == []
    assert store.get("g1").handles == ("amber",)


def test_the_transcript_keeps_kinds_and_notes_and_stays_bounded():
    transcript = RoomTranscriptStore(max_entries=3)
    transcript.append("g", RoomTurn(0, "", "", "hi", kind="user"))
    transcript.append("g", RoomTurn(1, "id-amber", "amber", "hello", routed_by={"mode": "auto", "confidence": 0.9}))
    transcript.append("g", RoomTurn(2, "id-amber", "amber", "do x", kind="handoff", to_agent_id="id-cobalt", to_handle="cobalt"))
    transcript.append("g", RoomTurn(2, "id-cobalt", "cobalt", "x done"))
    history = transcript.history("g")
    assert [t.text for t in history] == ["hello", "do x", "x done"]
    assert history[0].routed_by == {"mode": "auto", "confidence": 0.9}
    assert (history[1].kind, history[1].to_handle) == ("handoff", "cobalt")


def test_an_old_transcript_file_reads_as_agent_turns(tmp_path):
    path = tmp_path / "t.db"
    con = sqlite3.connect(path)
    con.executescript(
        """
        CREATE TABLE room_transcript (room_id TEXT NOT NULL, seq INTEGER NOT NULL,
            round INTEGER NOT NULL, agent_id TEXT NOT NULL, handle TEXT NOT NULL,
            text TEXT NOT NULL, created_at TEXT NOT NULL, PRIMARY KEY (room_id, seq));
        INSERT INTO room_transcript VALUES ('g', 1, 1, 'id-amber', 'amber', 'old reply', 'x');
        """
    )
    con.commit()
    con.close()
    [turn] = RoomTranscriptStore(str(path)).history("g")
    assert (turn.kind, turn.text) == ("agent", "old reply")
