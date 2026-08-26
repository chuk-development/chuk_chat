"""Room runner — drives a group-room exchange through real agent turns (§16.1/4b).

:class:`~cowork_manager.group_room.RoomSession` owns *who speaks and when*; this
owns *what a speaker sees and where its reply comes from*. It builds the shared
context each member reads (the user's message plus every reply so far, so a
coworker can answer what another just said), calls a **turn function** to produce
that member's reply, feeds it back into the session, and checks a stop seam
between turns so a room can be cancelled without waiting out the whole exchange.

The turn function is the seam the executor plugs into later: today a test passes
a scripted callable, tomorrow the Manager passes one that runs the member's real
executor turn over the relay. Keeping the runner pure — no sandbox, no socket —
is what makes the caps and the context assembly testable on their own.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass

from cowork_manager.group_room import (
    GroupRoom,
    RoomCaps,
    RoomMember,
    RoomSession,
    RoomTurn,
)


@dataclass(frozen=True, slots=True)
class RoomContext:
    """What one speaker sees when it is their turn.

    ``user_message`` is what the user posted to the room; ``transcript`` is every
    agent reply so far, in order. ``speaker`` is the member about to reply.
    """

    speaker: RoomMember
    user_message: str
    transcript: tuple[RoomTurn, ...]

    def as_prompt(self) -> str:
        """Render the room so far into a plain-text prompt for the speaker.

        Deterministic and self-describing: the user's message, then each prior
        reply as ``@handle: text``, then a line naming who is being asked to
        reply. A real executor turn takes this as its task prompt; a test reads
        it to assert the speaker saw what it should.
        """
        lines = [f"You are @{self.speaker.handle} in a group chat.", ""]
        lines.append(f"User: {self.user_message}")
        for turn in self.transcript:
            lines.append(f"@{turn.handle}: {turn.text}")
        lines.append("")
        lines.append(f"Reply as @{self.speaker.handle}.")
        return "\n".join(lines)


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
    ) -> None:
        self._room = room
        self._turn_fn = turn_fn
        self._caps = caps
        self._stop = stop
        self._on_turn = on_turn

    def run(self, user_message: str) -> RoomOutcome:
        session = RoomSession(self._room, user_message, caps=self._caps)
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
            )
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
                self._on_turn(session.transcript[-1])
        return RoomOutcome(
            transcript=tuple(session.transcript),
            stop_reason=session.stop_reason or "finished",
            messages_sent=session.messages_sent,
            rounds=session.round,
        )
