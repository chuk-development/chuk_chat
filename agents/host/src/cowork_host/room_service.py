"""Room service — the host side of a group room (§16.1/4b).

The app sends a ``room_task`` (§16.1: which room, what message). This turns that
into a running exchange: it looks the room up in the :class:`RoomStore`, drives
its members with a :class:`RoomDriver` over the :class:`RoomBinding` (each member
routed to its own executor), and emits the room's turns and its end back to the
app as ``room_turn`` / ``room_done`` payloads.

Everything the transport needs is behind one seam: ``emit`` takes a payload dict
and the host wires it to seal-and-send. So this service is testable without a
socket — a test captures the emitted dicts — while the host binds ``emit`` to the
same sealed channel every other frame rides. The whole path below it
(RoomDriver → RoomBinding → the members' executors) is already proven end to end
over the sealed loopback in the executor tests; this is the piece that starts it
from a frame.
"""

from __future__ import annotations

from collections.abc import Callable

from cowork_manager import RoomBinding, RoomCaps, RoomDriver, RoomStore, RoomTurn

from cowork_executor import room_done_payload, room_turn_payload

#: Emits one room payload (``room_turn`` / ``room_done``) toward the app. The
#: host binds this to seal-and-send; a test captures the dicts.
RoomEmit = Callable[[dict], None]


class RoomService:
    """Runs ``room_task`` frames against the host's rooms.

    ``binding`` carries the per-member task senders (registered as members'
    executors connect). ``caps`` overrides the stored per-room caps for every run
    — leave it ``None`` to honour each room's own caps.
    """

    def __init__(
        self,
        *,
        room_store: RoomStore,
        binding: RoomBinding,
        emit: RoomEmit,
        caps: RoomCaps | None = None,
    ) -> None:
        self._rooms = room_store
        self._binding = binding
        self._emit = emit
        self._caps = caps

    def handle_room_task(self, room_id: str, message: str) -> None:
        """Drive one room exchange to completion, streaming its turns out.

        An unknown room ends immediately with ``room_done`` reason
        ``no_such_room`` rather than silence — the app asked for a room the host
        does not have, and must be told, not left waiting.
        """
        room = self._rooms.get(room_id)
        if room is None:
            self._emit(
                room_done_payload(
                    room_id=room_id,
                    reason="no_such_room",
                    messages_sent=0,
                    rounds=0,
                )
            )
            return

        def on_turn(turn: RoomTurn) -> None:
            self._emit(
                room_turn_payload(
                    room_id=room_id,
                    round=turn.round,
                    agent_id=turn.agent_id,
                    handle=turn.handle,
                    text=turn.text,
                )
            )

        driver = RoomDriver(self._binding.member_runner(), caps=self._caps)
        outcome = driver.run(room, message, on_turn=on_turn)
        self._emit(
            room_done_payload(
                room_id=room_id,
                reason=outcome.stop_reason,
                messages_sent=outcome.messages_sent,
                rounds=outcome.rounds,
            )
        )
