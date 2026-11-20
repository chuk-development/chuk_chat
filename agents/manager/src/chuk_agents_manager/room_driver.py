"""Room driver — binds a group room's turns to real per-member agents (§16.1/4b).

:class:`~chuk_agents_manager.room_runner.RoomRunner` drives the turn order behind a
`turn_fn` seam; this is the layer that fills that seam with **the right agent for
each speaker**. A room member is an agent with its own agent id, and each id
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

from collections.abc import Callable, Mapping

from chuk_agents_manager.group_room import GroupRoom, RoomCaps, RoomMember, RoomTurn
from chuk_agents_manager.room_lead import OFFLINE_REPLY, ArmHandoff, run_lead_exchange
from chuk_agents_manager.room_routing import (
    AUTO_PICK_TIMEOUT_SECONDS,
    AskModel,
    route_first_round,
)
from chuk_agents_manager.room_runner import RoomContext, RoomOutcome, RoomRunner

#: Runs one member's turn: (member, prompt) -> reply, or ``None`` when the member
#: is offline. The prompt is the fully rendered room context
#: (:meth:`RoomContext.as_prompt`).
MemberRunner = Callable[[RoomMember, str], "str | None"]



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
        on_start: Callable[[RoomMember], None] | None = None,
        history: tuple[RoomTurn, ...] = (),
        names: Mapping[str, str] | None = None,
        ask: AskModel | None = None,
        arm: ArmHandoff | None = None,
        auto_timeout: float = AUTO_PICK_TIMEOUT_SECONDS,
    ) -> RoomOutcome:
        """Run one user message: decide the first speakers with the room's
        responder mode (:func:`route_first_round`), then either the lead
        exchange (``lead`` mode, nobody named) or the ordinary turn order."""
        decision = route_first_round(
            room, user_message, ask=ask, names=names, timeout=auto_timeout
        )
        if decision.via == "lead":
            return run_lead_exchange(
                room,
                user_message,
                run_member=self._member_runner,
                arm=arm,
                on_turn=on_turn,
                on_start=on_start,
                stop=stop,
                history=history,
                names=names,
                routed_by=decision.routed_by(),
            )

        def turn_fn(ctx: RoomContext) -> str:
            reply = self._member_runner(ctx.speaker, ctx.as_prompt())
            # An offline member is not a crash: the room keeps going, its line
            # says nobody answered, and — crucially — an offline member's
            # placeholder carries no @mentions, so it cannot drag a fresh round
            # out of an agent that never really spoke.
            return OFFLINE_REPLY if reply is None else reply

        runner = RoomRunner(
            room,
            turn_fn,
            caps=self._caps,
            stop=stop,
            on_turn=on_turn,
            on_start=on_start,
            first_round=decision.members,
            routed_by=decision.routed_by(),
            history=history,
            names=names,
        )
        return runner.run(user_message)
