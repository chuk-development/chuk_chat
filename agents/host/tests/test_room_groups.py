"""Groups on the host (§16.1): settings, list, background runs, stop, auto, lead.

The last test runs lead mode through the production path: ``RoomService`` ->
``RoomAgentPool`` (one real executor per member) -> the lead's model calls the
real ``hand_off_tasks`` tool -> the members answer -> the lead is woken. Only
the models are scripted.
"""

from __future__ import annotations

import threading
from collections import defaultdict

from chuk_agents_manager import RoomBinding, RoomStore, RoomTranscriptStore
from chuk_agents_runtime import MockModelClient
from chuk_agents_runtime.model import tool_call_response
from chuk_agents_sandbox import make_environment

from chuk_agents_host import RoomAgentPool, RoomService
from chuk_agents_host.room_service import dispatch_room_frame

MEMBERS = [
    {"agent_id": "id-amber", "handle": "amber"},
    {"agent_id": "id-cobalt", "handle": "cobalt"},
]


def _service(binding=None, frames=None, **kw):
    frames = frames if frames is not None else []
    service = RoomService(
        room_store=RoomStore(),
        binding=binding or RoomBinding(),
        emit=frames.append,
        transcript=RoomTranscriptStore(),
        **kw,
    )
    return service, frames


def _create(service, **settings):
    dispatch_room_frame(
        service,
        {"type": "room_create", "room_id": "g1", "name": "Test", "members": MEMBERS, **settings},
    )


def test_create_carries_settings_and_the_list_returns_them():
    service, frames = _service()
    _create(service, responder="auto", fallback_agent_id="id-cobalt", bulletin="Be brief.")
    dispatch_room_frame(service, {"type": "room_list_request"})
    [listing] = [f for f in frames if f["type"] == "room_list"]
    [room] = listing["rooms"]
    assert room["room_id"] == "g1"
    assert room["responder"] == "auto"
    assert room["fallback_agent_id"] == "id-cobalt"
    assert room["bulletin"] == "Be brief."
    assert [m["handle"] for m in room["members"]] == ["amber", "cobalt"]


def test_an_old_create_does_not_reset_the_settings():
    service, frames = _service()
    _create(service, responder="mentions")
    _create(service)  # an app that predates groups re-sends the room on open
    dispatch_room_frame(service, {"type": "room_list_request"})
    assert frames[-1]["rooms"][0]["responder"] == "mentions"


def test_room_settings_changes_only_the_given_keys_and_skips_bad_ones():
    service, frames = _service()
    _create(service, bulletin="keep me")
    dispatch_room_frame(
        service, {"type": "room_settings", "room_id": "g1", "responder": "nonsense", "lead_agent_id": "id-cobalt"}
    )
    dispatch_room_frame(service, {"type": "room_list_request"})
    room = frames[-1]["rooms"][0]
    assert room["responder"] == "everyone"
    assert room["lead_agent_id"] == "id-cobalt"
    assert room["bulletin"] == "keep me"


def test_mentions_mode_without_a_mention_ends_with_no_addressee():
    binding = RoomBinding()
    binding.register("id-amber", lambda p: "should not run")
    service, frames = _service(binding)
    _create(service, responder="mentions")
    service.handle_room_task("g1", "anyone?")
    assert [f["type"] for f in frames] == ["room_done"]
    assert frames[0]["reason"] == "no_addressee"


def test_working_frames_come_before_each_turn_and_auto_is_noted():
    binding = RoomBinding()
    binding.register("id-amber", lambda p: "amber here")
    binding.register("id-cobalt", lambda p: "cobalt here")
    service, frames = _service(
        binding, ask_model=lambda: (lambda s, u: '{"pick": ["cobalt"], "confidence": 0.94}')
    )
    _create(service, responder="auto")
    service.handle_room_task("g1", "fix the css")
    kinds = [(f["type"], f.get("handle")) for f in frames]
    assert kinds == [("room_working", "cobalt"), ("room_turn", "cobalt"), ("room_done", None)]
    assert frames[1]["routed_by"] == {"mode": "auto", "fallback": False, "confidence": 0.94}
    # The history carries the user's message and the note.
    dispatch_room_frame(service, {"type": "room_history_request", "room_id": "g1"})
    turns = frames[-1]["turns"]
    assert [t["kind"] for t in turns] == ["user", "agent"]
    assert turns[1]["routed_by"]["confidence"] == 0.94


def test_a_background_run_frees_the_caller_and_can_be_stopped():
    release = threading.Event()
    binding = RoomBinding()
    binding.register("id-amber", lambda p: release.wait(5) and "amber done")
    binding.register("id-cobalt", lambda p: "cobalt done")
    service, frames = _service(binding, background=True)
    _create(service)

    service.handle_room_task("g1", "everyone")  # returns at once
    assert not any(f["type"] == "room_done" for f in frames)
    for _ in range(200):  # amber's turn is in flight
        if any(f["type"] == "room_working" for f in frames):
            break
        threading.Event().wait(0.01)
    dispatch_room_frame(service, {"type": "room_stop", "room_id": "g1"})
    release.set()
    assert service.wait_idle(timeout=5)
    done = frames[-1]
    assert done["type"] == "room_done"
    assert done["reason"] == "stopped"
    assert [f["handle"] for f in frames if f["type"] == "room_turn"] == ["amber"]


def test_two_messages_to_one_group_run_in_order():
    order = []
    gate = threading.Event()

    def amber(prompt):
        gate.wait(2)
        order.append("amber")
        return "a"

    binding = RoomBinding()
    binding.register("id-amber", amber)
    binding.register("id-cobalt", lambda p: order.append("cobalt") or "c")
    service, frames = _service(binding, background=True)
    _create(service)
    service.handle_room_task("g1", "@amber first")
    service.handle_room_task("g1", "@cobalt second")
    gate.set()
    assert service.wait_idle(timeout=5)
    assert order == ["amber", "cobalt"]


# -- lead mode through real executors -------------------------------------------


class _ScriptedPool:
    """One shared script per member across runs, so a woken lead continues."""

    def __init__(self, tmp_path, scripts):
        self.scripts = {k: list(v) for k, v in scripts.items()}
        self.prompts = defaultdict(list)
        self.binding = RoomBinding()
        self._tmp = tmp_path
        self.pool = RoomAgentPool(
            binding=self.binding,
            model_wiring=self._wiring,
            environment_factory=self._environment,
            db_dir=tmp_path / "room-agents",
            system_prompt="You are an agent in a group.",
            turn_timeout=30.0,
        )

    def _wiring(self, agent_id):
        pool = self

        class _Client(MockModelClient):
            def complete(self, messages):
                for m in messages:
                    if m.get("role") == "user":
                        pool.prompts[agent_id].append(str(m.get("content") or ""))
                script = pool.scripts.get(agent_id) or []
                item = script.pop(0) if script else "(done)"
                self._responses = [item]
                return super().complete(messages)

        return (lambda: _Client([])), None

    def _environment(self, agent_id):
        workdir = self._tmp / "boxes" / agent_id
        workdir.mkdir(parents=True, exist_ok=True)
        return make_environment("local", workdir=str(workdir))


def test_a_lead_hands_off_through_the_real_tool(tmp_path):
    members = _ScriptedPool(
        tmp_path,
        {
            "id-amber": [
                tool_call_response(
                    ("hand_off_tasks", {"tasks": [{"member": "cobalt", "task": "count the files"}]})
                ),
                "I asked cobalt.",
                "Cobalt counted 3 files.",
            ],
            "id-cobalt": ["3 files"],
        },
    )
    frames: list[dict] = []
    service = RoomService(
        room_store=RoomStore(),
        binding=members.binding,
        emit=frames.append,
        transcript=RoomTranscriptStore(),
        members_ready=members.pool.ensure_room,
        arm_handoff=members.pool.arm_handoff,
    )
    _create(service, responder="lead", lead_agent_id="id-amber")
    try:
        service.handle_room_task("g1", "how many files?")
    finally:
        members.pool.shutdown()

    turns = [f for f in frames if f["type"] == "room_turn"]
    assert [(t["handle"], t.get("kind", "agent")) for t in turns] == [
        ("amber", "agent"),
        ("amber", "handoff"),
        ("cobalt", "agent"),
        ("amber", "agent"),
    ]
    assert turns[0]["text"] == "I asked cobalt."
    assert turns[0]["routed_by"] == {"mode": "lead"}
    assert turns[1]["to_handle"] == "cobalt"
    assert turns[2]["text"] == "3 files"
    assert turns[3]["text"] == "Cobalt counted 3 files."
    assert frames[-1]["reason"] == "lead_done"
    # The member never had the tool's task text pass through another member.
    assert any("count the files" in p for p in members.prompts["id-cobalt"])
