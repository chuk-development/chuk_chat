"""Room runner — drives a group-room exchange through real agent turns (§16.1/4b).

:class:`~chuk_agents_manager.group_room.RoomSession` owns *who speaks and when*; this
owns *what a speaker sees and where its reply comes from*. It builds the shared
context each member reads (the user's message plus every reply so far, so an
agent can answer what another just said), calls a **turn function** to produce
that member's reply, feeds it back into the session, and checks a stop seam
between turns so a room can be cancelled without waiting out the whole exchange.

The turn function is the seam the executor plugs into later: today a test passes
a scripted callable, tomorrow the Manager passes one that runs the member's real
executor turn over the relay. Keeping the runner pure — no sandbox, no socket —
is what makes the caps and the context assembly testable on their own.
"""

from __future__ import annotations

from collections.abc import Callable, Mapping
from dataclasses import dataclass, field, replace

from chuk_agents_manager.group_room import (
    TURN_HANDOFF,
    TURN_USER,
    GroupRoom,
    RoomCaps,
    RoomMember,
    RoomSession,
    RoomTurn,
)

#: How much earlier conversation a member reads with its turn. The member's own
#: thread on its executor keeps what it said before; this is what the OTHERS
#: said, so it stays short.
MAX_HISTORY_CHARS = 6_000
MAX_HISTORY_TURNS = 24


def _speaker_line(turn: RoomTurn) -> str:
    if turn.kind == TURN_USER:
        return f"User: {turn.text}"
    if turn.kind == TURN_HANDOFF:
        return f"@{turn.handle} -> @{turn.to_handle}: {turn.text}"
    return f"@{turn.handle}: {turn.text}"


@dataclass(frozen=True, slots=True)
class RoomContext:
    """What one speaker sees when it is their turn.

    ``user_message`` is what the user posted to the room; ``transcript`` is every
    agent reply so far, in order. ``speaker`` is the member about to reply.
    """

    speaker: RoomMember
    user_message: str
    transcript: tuple[RoomTurn, ...]
    #: The room itself, for its name, members, instructions and folder. ``None``
    #: renders the bare prompt of the first rooms.
    room: GroupRoom | None = None
    #: Earlier exchanges of this group (user messages and replies), oldest first.
    history: tuple[RoomTurn, ...] = ()
    #: Agent id -> display name, so members know who is who.
    names: Mapping[str, str] = field(default_factory=dict)
    #: A role note for this turn (the lead's team note, a member's task note).
    note: str = ""

    def _name(self, member: RoomMember) -> str:
        name = self.names.get(member.agent_id)
        return f"@{member.handle} ({name})" if name and name != member.handle else f"@{member.handle}"

    def as_prompt(self) -> str:
        """Render the room so far into a plain-text prompt for the speaker.

        Deterministic and self-describing: who the speaker is and who else is in
        the group, the shared instructions, the earlier conversation, the user's
        message, then each prior reply as ``@handle: text``, then a line naming
        who is being asked to reply. A real executor turn takes this as its
        task prompt; a test reads it to assert the speaker saw what it should.
        """
        lines = [f"You are @{self.speaker.handle} in a group chat."]
        room = self.room
        if room is not None:
            lines.append(f'The group is called "{room.name}".')
            others = [self._name(m) for m in room.members if m != self.speaker]
            if others:
                lines.append("The other members: " + ", ".join(others) + ".")
            if room.bulletin.strip():
                lines.append("")
                lines.append("Group instructions (shared by every member):")
                lines.append(room.bulletin.strip())
            if room.workdir.strip():
                lines.append("")
                lines.append(f"Shared working folder of the group: {room.workdir.strip()}")
        history = _bounded_history(self.history)
        if history:
            lines.append("")
            lines.append("Earlier in this group:")
            lines.extend(_speaker_line(t) for t in history)
        lines.append("")
        lines.append(f"User: {self.user_message}")
        for turn in self.transcript:
            lines.append(_speaker_line(turn))
        if self.note:
            lines.append("")
            lines.append(self.note)
        lines.append("")
        lines.append(f"Reply as @{self.speaker.handle}.")
        return "\n".join(lines)


def _bounded_history(history: tuple[RoomTurn, ...]) -> list[RoomTurn]:
    """The newest part of ``history`` that fits the history budget."""
    kept: list[RoomTurn] = []
    used = 0
    for turn in reversed(history[-MAX_HISTORY_TURNS:]):
        size = len(turn.text) + 16
        if kept and used + size > MAX_HISTORY_CHARS:
            break
        kept.append(turn)
        used += size
    kept.reverse()
    return kept


#: A turn function: given the context, return the speaker's reply text. This is
#: the executor seam. It may raise; the runner turns a raised turn into a stop.
TurnFn = Callable[[RoomContext], str]


@dataclass(frozen=True, slots=True)
class RoomOutcome:
    """The result of one user message run through a room."""

    transcript: tuple[RoomTurn, ...]
    stop_reason: str
    messages_sent: int
    rounds: int


class RoomRunner:
    """Runs one user message through a room to completion.

    ``turn_fn`` produces each member's reply. ``stop`` is an optional predicate
    checked *before* each turn — return ``True`` from it and the exchange ends
    with reason ``stopped``, the already-produced turns kept. ``caps`` overrides
    the room's own caps for this run (a plan tier lowering them, say).
    """

    def __init__(
        self,
        room: GroupRoom,
        turn_fn: TurnFn,
        *,
        caps: RoomCaps | None = None,
        stop: Callable[[], bool] | None = None,
        on_turn: Callable[[RoomTurn], None] | None = None,
        on_start: Callable[[RoomMember], None] | None = None,
        first_round: tuple[RoomMember, ...] | None = None,
        routed_by: dict | None = None,
        history: tuple[RoomTurn, ...] = (),
        names: Mapping[str, str] | None = None,
    ) -> None:
        self._room = room
        self._turn_fn = turn_fn
        self._caps = caps
        self._stop = stop
        self._on_turn = on_turn
        self._on_start = on_start
        self._first_round = first_round
        # Only the routed first speakers carry the note; a member an agent
        # pulled in later was not picked by the router.
        self._routed_by = routed_by
        self._routed = set(first_round or ())
        self._history = history
        self._names = dict(names or {})

    def run(self, user_message: str) -> RoomOutcome:
        session = RoomSession(
            self._room,
            user_message,
            caps=self._caps,
            first_round=self._first_round,
        )
        while True:
            # The stop seam wins between turns: a cancelled room must not start a
            # new speaker just because the session would allow one.
            if self._stop is not None and self._stop():
                return RoomOutcome(
                    transcript=tuple(session.transcript),
                    stop_reason="stopped",
                    messages_sent=session.messages_sent,
                    rounds=session.round,
                )
            speaker = session.next_speaker()
            if speaker is None:
                break
            context = RoomContext(
                speaker=speaker,
                user_message=user_message,
                transcript=tuple(session.transcript),
                room=self._room,
                history=self._history,
                names=self._names,
            )
            if self._on_start is not None:
                self._on_start(speaker)
            try:
                reply = self._turn_fn(context)
            except Exception:
                # A member whose turn crashed does not sink the room: record an
                # empty reply so the session advances, and stop the exchange —
                # a half-run room is better than a hung one, and the crash is
                # the caller's to log at the seam.
                session.submit("")
                return RoomOutcome(
                    transcript=tuple(session.transcript),
                    stop_reason="turn_failed",
                    messages_sent=session.messages_sent,
                    rounds=session.round,
                )
            session.submit(reply)
            if self._on_turn is not None:
                # The turn just recorded is the last one; stream it live so the
                # app shows the exchange as it unfolds, not only at the end.
                turn = session.transcript[-1]
                if (
                    self._routed_by is not None
                    and turn.round == 1
                    and speaker in self._routed
                ):
                    turn = replace(turn, routed_by=self._routed_by)
                self._on_turn(turn)
        return RoomOutcome(
            transcript=tuple(session.transcript),
            stop_reason=session.stop_reason or "finished",
            messages_sent=session.messages_sent,
            rounds=session.round,
        )
