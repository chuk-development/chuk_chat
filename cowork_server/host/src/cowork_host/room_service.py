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

from cowork_manager import (
    RoomBinding,
    RoomCaps,
    RoomDriver,
    RoomError,
    RoomStore,
    RoomTranscriptStore,
    RoomTurn,
)

from cowork_executor import (
    room_done_payload,
    room_history_payload,
    room_turn_payload,
)

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
        transcript: RoomTranscriptStore | None = None,
    ) -> None:
        self._rooms = room_store
        self._binding = binding
        self._emit = emit
        self._caps = caps
        self._transcript = transcript

    def handle_room_create(
        self, room_id: str, name: str, members: list[dict]
    ) -> None:
        """Create or reconcile an app-built room on the host so ``room_task`` can
        find it (§16.1). The app owns room identity and membership, and re-sends
        the room whenever it is opened, so this is idempotent AND self-healing:
        a room that does not exist is created; a room that does is reconciled to
        the payload — the name updated, members in the payload but not on the
        host added, members on the host but not in the payload removed. That is
        what repairs a membership edit (or a rename) the app made while the host
        was offline: the next open brings the host back in step. A member the
        room cannot take (over the cap, a bad row) is skipped; the rest of the
        room stays usable."""
        wanted = [
            (m["agent_id"], m["handle"])
            for m in members
            if isinstance(m, dict)
            and isinstance(m.get("agent_id"), str)
            and isinstance(m.get("handle"), str)
        ]

        existing = self._rooms.get(room_id)
        if existing is None:
            self._rooms.create_room(name=name, room_id=room_id)
        else:
            if existing.name != name:
                self._rooms.rename_room(room_id, name)
            wanted_ids = {agent_id for agent_id, _ in wanted}
            # Remove members the app no longer has.
            for member in existing.members:
                if member.agent_id not in wanted_ids:
                    try:
                        self._rooms.remove_member(room_id, member.agent_id)
                    except RoomError:
                        pass

        have_ids = {m.agent_id for m in (self._rooms.get(room_id).members)}
        for agent_id, handle in wanted:
            if agent_id in have_ids:
                continue
            try:
                self._rooms.add_member(room_id, agent_id, handle)
            except RoomError:
                # Over the cap or a duplicate: skip this member, keep the room.
                continue

    def handle_room_add_member(
        self, room_id: str, agent_id: str, handle: str
    ) -> None:
        """Add a coworker to a room the host holds (§16.1). Ignored on an unknown
        room or a member the room cannot take (full, or a duplicate) — the room
        stays valid rather than the call raising into the frame loop."""
        if self._rooms.get(room_id) is None:
            return
        try:
            self._rooms.add_member(room_id, agent_id, handle)
        except RoomError:
            return

    def handle_room_remove_member(self, room_id: str, agent_id: str) -> None:
        """Remove a coworker from a room (§16.1). Ignored on an unknown room or a
        non-member. Removing the transcript is not this call's job — the room
        lives on with fewer members."""
        if self._rooms.get(room_id) is None:
            return
        try:
            self._rooms.remove_member(room_id, agent_id)
        except RoomError:
            return

    def handle_room_rename(self, room_id: str, name: str) -> None:
        """Rename a room the host holds (§16.1). A no-op on an unknown room —
        the host simply does not have it yet (it syncs on the next create)."""
        if self._rooms.get(room_id) is not None:
            self._rooms.rename_room(room_id, name)

    def handle_room_delete(self, room_id: str) -> None:
        """Forget a room: drop it from the store and clear its transcript, so a
        deleted room leaves no orphaned history behind. Safe on an unknown room —
        deleting what is already gone is a no-op, not an error."""
        self._rooms.delete(room_id)
        if self._transcript is not None:
            self._transcript.clear(room_id)

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

        # A room is a persistent thread, but each user message starts a fresh
        # exchange — clear the last one so the stored history is the current
        # conversation, not every conversation ever concatenated.
        if self._transcript is not None:
            self._transcript.clear(room_id)

        def on_turn(turn: RoomTurn) -> None:
            if self._transcript is not None:
                self._transcript.append(room_id, turn)
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

    def handle_room_history(self, room_id: str) -> None:
        """Answer a ``room_history_request`` with the room's stored transcript
        (§16.1). Emits an empty history when nothing is stored (or no transcript
        store is configured) rather than staying silent, so the app can tell
        "no history" from "still waiting"."""
        turns: list[dict] = []
        if self._transcript is not None:
            turns = [
                {
                    "round": t.round,
                    "agent_id": t.agent_id,
                    "handle": t.handle,
                    "text": t.text,
                }
                for t in self._transcript.history(room_id)
            ]
        self._emit(room_history_payload(room_id=room_id, turns=turns))


def dispatch_room_frame(service: RoomService, payload: dict) -> None:
    """Route one decoded ``room_*`` payload to the right :class:`RoomService`
    method (§16.1). The executor hands these up via ``on_room_frame``; this is
    the one place the room wire types map to service calls. An unknown type or a
    payload missing its ``room_id`` is ignored — the executor already validated
    the frame's authenticity, so a malformed body is a client bug, not an attack,
    and dropping it is safer than guessing."""
    room_id = payload.get("room_id")
    if not isinstance(room_id, str) or not room_id:
        return
    kind = payload.get("type")
    if kind == "room_create":
        name = payload.get("name")
        members = payload.get("members")
        service.handle_room_create(
            room_id,
            name if isinstance(name, str) else "",
            members if isinstance(members, list) else [],
        )
    elif kind == "room_task":
        message = payload.get("message")
        service.handle_room_task(room_id, message if isinstance(message, str) else "")
    elif kind == "room_add_member":
        agent_id = payload.get("agent_id")
        handle = payload.get("handle")
        if isinstance(agent_id, str) and isinstance(handle, str):
            service.handle_room_add_member(room_id, agent_id, handle)
    elif kind == "room_remove_member":
        agent_id = payload.get("agent_id")
        if isinstance(agent_id, str):
            service.handle_room_remove_member(room_id, agent_id)
    elif kind == "room_rename":
        name = payload.get("name")
        if isinstance(name, str) and name.strip():
            service.handle_room_rename(room_id, name)
    elif kind == "room_delete":
        service.handle_room_delete(room_id)
    elif kind == "room_history_request":
        service.handle_room_history(room_id)
