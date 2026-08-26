"""Room driver — binds a group room's turns to real per-member agents (§16.1/4b).

:class:`~cowork_manager.room_runner.RoomRunner` drives the turn order behind a
`turn_fn` seam; this is the layer that fills that seam with **the right agent for
each speaker**. A room member is a coworker with its own agent id, and each id
has its own runtime (its own sandbox, its own model stream). So a room turn is
not "call the model" — it is "route this turn to *this member's* executor". That
routing, and what to do when a member's executor is not there, is what lives here.

The executor call itself stays behind one more seam, ``member_runner``: given the
speaking member and the rendered room prompt, return that member's reply, or
``None`` when the member is offline (its executor is not connected). A test passes
a scripted ``member_runner``; the host passes one that runs the member's real
executor turn over the relay. Keeping the driver pure — it never opens a socket —
is what makes the routing and the offline handling testable on their own.
"""

from __future__ import annotations

from collections.abc import Callable

from cowork_manager.group_room import GroupRoom, RoomCaps, RoomMember, RoomTurn
from cowork_manager.room_runner import RoomContext, RoomOutcome, RoomRunner

#: Runs one member's turn: (member, prompt) -> reply, or ``None`` when the member
#: is offline. The prompt is the fully rendered room context
#: (:meth:`RoomContext.as_prompt`).
MemberRunner = Callable[[RoomMember, str], "str | None"]

#: Shown in the transcript in place of an offline member's reply. It is a real
#: turn — the exchange advances past it — but it says plainly that nobody
#: answered, rather than inventing words for a coworker that was not there.
OFFLINE_REPLY = "(offline — no reply)"


class RoomDriver:
    """Runs a room's exchange by routing each turn to its member's agent.

    ``member_runner`` is the executor seam. ``caps`` overrides the room's own
    caps for a run. Neither the driver nor :class:`RoomRunner` decides who is
    online — that is ``member_runner``'s answer, per turn, because a member can
    drop between one turn and the next.
    """

    def __init__(
        self,
        member_runner: MemberRunner,
        *,
        caps: RoomCaps | None = None,
    ) -> None:
        self._member_runner = member_runner
        self._caps = caps

    def run(
        self,
        room: GroupRoom,
        user_message: str,
        *,
        on_turn: Callable[[RoomTurn], None] | None = None,
        stop: Callable[[], bool] | None = None,
    ) -> RoomOutcome:
        def turn_fn(ctx: RoomContext) -> str:
            reply = self._member_runner(ctx.speaker, ctx.as_prompt())
            # An offline member is not a crash: the room keeps going, its line
            # says nobody answered, and — crucially — an offline member's
            # placeholder carries no @mentions, so it cannot drag a fresh round
            # out of a coworker that never really spoke.
            return OFFLINE_REPLY if reply is None else reply

        runner = RoomRunner(
            room,
            turn_fn,
            caps=self._caps,
            stop=stop,
            on_turn=on_turn,
        )
        return runner.run(user_message)
