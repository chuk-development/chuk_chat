"""Lead mode of a group (§16.1): one member leads and hands tasks to the others.

A group whose default responder is ``lead`` answers a message that names nobody
like a small team: the **lead** member reads it first. It answers alone when it
can. When the work needs others it hands **tasks** to members through a tool
(``hand_off_tasks``, see :mod:`chuk_agents_runtime.room_handoff`): one
self-contained task per member, independent tasks in one call. The members run
those tasks (at the same time, each on its own executor), report back in a line
or two, and the lead is woken **once** with their results to give the user the
combined answer.

Hard caps per user message, so a lead cannot start a credit fire:

- at most :data:`LEAD_MAX_ROUNDS` lead turns (the first answer plus wake-ups);
- at most :data:`LEAD_MAX_TASKS` tasks in total.

A task over a cap is refused **to the model**, with a reason, so the lead can
say what it could not do instead of silently losing work. At the last lead turn
the tool refuses every task: that turn must answer the user.

A lead whose model does not call the tool but writes ``@member`` in its reply
still reaches that member: the mention becomes a task that carries the lead's
reply. The tool is the clear path; the mention keeps the group working when a
model ignores tools.

Everything here is pure orchestration behind seams (run one member, arm the
tool for one member, emit a turn), so the caps are tested without a model.
"""

from __future__ import annotations

import threading
from collections.abc import Callable, Mapping
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass

from chuk_agents_manager.group_room import (
    TURN_HANDOFF,
    GroupRoom,
    RoomMember,
    RoomTurn,
    parse_mentions,
)
from chuk_agents_manager.room_runner import RoomContext, RoomOutcome

#: Lead turns per user message: the first answer and at most two wake-ups.
LEAD_MAX_ROUNDS = 3
#: Tasks a lead may hand out per user message.
LEAD_MAX_TASKS = 8
#: The longest task text a member gets.
MAX_TASK_CHARS = 4_000

#: Runs one member's turn: (member, prompt) -> reply, or ``None`` when offline.
MemberRunner = Callable[[RoomMember, str], "str | None"]
#: Gives (or with ``None`` takes back) the hand-off tool for one agent's runs.
ArmHandoff = Callable[[str, "HandoffCollector | None"], None]

#: Shown in the transcript in place of an offline member's reply. It is a real
#: turn — the exchange advances past it — but it says plainly that nobody
#: answered, rather than inventing words for an agent that was not there.
OFFLINE_REPLY = "(offline — no reply)"


@dataclass(frozen=True, slots=True)
class Handoff:
    """One task the lead gave one member."""

    member: RoomMember
    task: str


class HandoffCollector:
    """The backend of the lead's ``hand_off_tasks`` tool for one user message.

    The tool runs on the lead's executor thread; the exchange reads the tasks
    after the lead's turn. A lock keeps the two apart. ``closed`` refuses every
    task (the last lead turn must answer the user).
    """

    def __init__(
        self,
        room: GroupRoom,
        lead: RoomMember,
        *,
        max_tasks: int = LEAD_MAX_TASKS,
        names: Mapping[str, str] | None = None,
    ) -> None:
        self._room = room
        self._lead = lead
        self._max_tasks = max_tasks
        self._names = dict(names or {})
        self._used = 0
        self._pending: list[Handoff] = []
        self._lock = threading.Lock()
        self.closed = False

    @property
    def used(self) -> int:
        with self._lock:
            return self._used

    def members(self) -> list[dict]:
        """The members a task can go to (everybody but the lead)."""
        return [
            {"handle": m.handle, "name": self._names.get(m.agent_id) or m.handle}
            for m in self._room.members
            if m != self._lead
        ]

    def hand_off(self, tasks: object) -> dict:
        """Record tasks. Returns what was accepted and what was refused, and
        why, in words the model can act on."""
        if not isinstance(tasks, list) or not tasks:
            return {"ok": False, "error": "tasks must be a non-empty list of {member, task}"}
        accepted: list[dict] = []
        refused: list[dict] = []
        with self._lock:
            for item in tasks:
                handle = item.get("member") if isinstance(item, dict) else None
                task = item.get("task") if isinstance(item, dict) else None
                if not isinstance(handle, str) or not isinstance(task, str) or not task.strip():
                    refused.append({"member": handle, "reason": "each task needs a member handle and a task text"})
                    continue
                member = self._room.member_by_handle(handle.strip().lstrip("@"))
                if member is None or member == self._lead:
                    refused.append({"member": handle, "reason": "not a member you can give work to"})
                    continue
                if self.closed:
                    refused.append({"member": handle, "reason": "no rounds left: answer the user now with what you have"})
                    continue
                if self._used >= self._max_tasks:
                    refused.append({"member": handle, "reason": f"task limit reached ({self._max_tasks} per message)"})
                    continue
                self._used += 1
                self._pending.append(Handoff(member=member, task=task.strip()[:MAX_TASK_CHARS]))
                accepted.append({"member": member.handle})
        result: dict = {"ok": bool(accepted), "accepted": accepted}
        if refused:
            result["refused"] = refused
        if accepted:
            result["note"] = (
                "The members start when your turn ends. End your turn now with "
                "one short line to the user; you are woken with their results."
            )
        return result

    def has_pending(self) -> bool:
        with self._lock:
            return bool(self._pending)

    def take(self) -> list[Handoff]:
        """The tasks recorded since the last call, emptied."""
        with self._lock:
            tasks, self._pending = self._pending, []
            return tasks

    def add_from_mentions(self, text: str) -> None:
        """A lead that wrote ``@member`` instead of calling the tool: each named
        member gets the lead's reply as its task, within the same caps."""
        handles = [
            h for h in parse_mentions(text, self._room.handles) if h != self._lead.handle
        ]
        if handles:
            self.hand_off([{"member": h, "task": text} for h in handles])


def lead_note(collector: HandoffCollector, lead: RoomMember, names: Mapping[str, str]) -> str:
    team = ", ".join(
        f"@{m['handle']} ({m['name']})" if m["name"] != m["handle"] else f"@{m['handle']}"
        for m in collector.members()
    )
    return (
        f"You lead this group. Your team: {team}.\n"
        "Answer the user yourself when you can. When the work needs your team, "
        "call the tool hand_off_tasks: one self-contained task per member, all "
        "independent tasks in one call (they run at the same time). Then end "
        "your turn with one short line to the user. You are woken once with "
        f"the results. At most {LEAD_MAX_TASKS} tasks and {LEAD_MAX_ROUNDS} "
        "lead turns per user message."
    )


def wake_note(round_no: int, max_rounds: int, tasks_left: int, final: bool) -> str:
    if final:
        return (
            "Your team has reported (above). Give the user the combined answer "
            "now. You cannot hand off more tasks in this message."
        )
    return (
        "Your team has reported (above). Give the user the combined answer. "
        f"Hand off more tasks only if really needed ({tasks_left} tasks left, "
        f"lead turn {round_no} of {max_rounds})."
    )


def member_note(lead: RoomMember, task: str) -> str:
    return (
        f"The lead @{lead.handle} gave you this task:\n{task}\n"
        "Do it alone. Report the result to the lead in one or two plain lines. "
        "Ask the lead if you are blocked. Do not pass the task on to anyone."
    )


def run_lead_exchange(
    room: GroupRoom,
    user_message: str,
    *,
    run_member: MemberRunner,
    arm: ArmHandoff | None = None,
    on_turn: Callable[[RoomTurn], None] | None = None,
    on_start: Callable[[RoomMember], None] | None = None,
    stop: Callable[[], bool] | None = None,
    history: tuple[RoomTurn, ...] = (),
    names: Mapping[str, str] | None = None,
    routed_by: dict | None = None,
    max_rounds: int = LEAD_MAX_ROUNDS,
    max_tasks: int = LEAD_MAX_TASKS,
) -> RoomOutcome:
    """Run one user message through a group in lead mode."""
    names = dict(names or {})
    lead = room.lead
    transcript: list[RoomTurn] = []
    emit_lock = threading.Lock()
    sent = 0

    def record(turn: RoomTurn) -> None:
        with emit_lock:
            transcript.append(turn)
            if on_turn is not None:
                on_turn(turn)

    def outcome(reason: str, rounds: int) -> RoomOutcome:
        return RoomOutcome(
            transcript=tuple(transcript),
            stop_reason=reason,
            messages_sent=sent,
            rounds=rounds,
        )

    if lead is None:
        return outcome("no_members", 0)
    collector = HandoffCollector(room, lead, max_tasks=max_tasks, names=names)

    def context(speaker: RoomMember, note: str) -> str:
        return RoomContext(
            speaker=speaker,
            user_message=user_message,
            transcript=tuple(transcript),
            room=room,
            history=history,
            names=names,
            note=note,
        ).as_prompt()

    def lead_turn(round_no: int, note: str) -> bool:
        """One lead turn. False when it failed (the exchange stops)."""
        nonlocal sent
        if on_start is not None:
            on_start(lead)
        if arm is not None:
            arm(lead.agent_id, collector)
        try:
            reply = run_member(lead, context(lead, note))
        except Exception:  # noqa: BLE001 — a crashed turn stops, never hangs
            reply = None
            failed = True
        else:
            failed = False
        finally:
            if arm is not None:
                arm(lead.agent_id, None)
        text = OFFLINE_REPLY if reply is None else reply
        # The first turn only, and only when the tool was not used: a wake-up
        # that names members is reporting on them, not tasking.
        if (
            reply is not None
            and round_no == 1
            and not collector.closed
            and not collector.has_pending()
        ):
            collector.add_from_mentions(reply)
        sent += 1
        record(
            RoomTurn(
                round=round_no,
                agent_id=lead.agent_id,
                handle=lead.handle,
                text=text,
                routed_by=routed_by if round_no == 1 else None,
            )
        )
        return not failed

    round_no = 1
    if max_rounds <= 1:
        collector.closed = True
    if not lead_turn(round_no, lead_note(collector, lead, names)):
        return outcome("turn_failed", round_no)

    while True:
        tasks = _merge_by_member(collector.take())
        if not tasks:
            return outcome("lead_done", round_no)
        if stop is not None and stop():
            return outcome("stopped", round_no)
        round_no += 1
        for handoff in tasks:
            record(
                RoomTurn(
                    round=round_no,
                    agent_id=lead.agent_id,
                    handle=lead.handle,
                    text=handoff.task,
                    kind=TURN_HANDOFF,
                    to_agent_id=handoff.member.agent_id,
                    to_handle=handoff.member.handle,
                )
            )
        snapshot = tuple(transcript)

        def work(
            handoff: Handoff, snapshot: tuple[RoomTurn, ...] = snapshot
        ) -> tuple[Handoff, str | None]:
            if on_start is not None:
                on_start(handoff.member)
            prompt = RoomContext(
                speaker=handoff.member,
                user_message=user_message,
                transcript=snapshot,
                room=room,
                history=history,
                names=names,
                note=member_note(lead, handoff.task),
            ).as_prompt()
            try:
                return handoff, run_member(handoff.member, prompt)
            except Exception:  # noqa: BLE001 — one member, not the team
                return handoff, None

        with ThreadPoolExecutor(max_workers=len(tasks), thread_name_prefix="room-lead") as pool:
            futures = [pool.submit(work, h) for h in tasks]
            for future in as_completed(futures):
                handoff, reply = future.result()
                sent += 1
                record(
                    RoomTurn(
                        round=round_no,
                        agent_id=handoff.member.agent_id,
                        handle=handoff.member.handle,
                        text=OFFLINE_REPLY if reply is None else reply,
                    )
                )
        if stop is not None and stop():
            return outcome("stopped", round_no)
        final = round_no >= max_rounds
        collector.closed = final
        if not lead_turn(
            round_no,
            wake_note(round_no, max_rounds, max_tasks - collector.used, final),
        ):
            return outcome("turn_failed", round_no)
        if final:
            # Tasks the last turn tried to give were refused by the tool.
            collector.take()
            return outcome("lead_done", round_no)


def _merge_by_member(tasks: list[Handoff]) -> list[Handoff]:
    """One task per member: two tasks for one member run as one, in order, so a
    member never runs twice at once on its one executor."""
    merged: dict[str, Handoff] = {}
    for h in tasks:
        prior = merged.get(h.member.agent_id)
        if prior is None:
            merged[h.member.agent_id] = h
        else:
            merged[h.member.agent_id] = Handoff(
                member=h.member, task=f"{prior.task}\n\nAlso: {h.task}"
            )
    return list(merged.values())
