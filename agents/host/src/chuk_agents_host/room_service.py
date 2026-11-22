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

import threading
from collections.abc import Callable

from chuk_agents_executor import (
    room_done_payload,
    room_history_payload,
    room_list_payload,
    room_turn_payload,
    room_working_payload,
)

from chuk_agents_manager import (
    TURN_USER,
    GroupRoom,
    RoomBinding,
    RoomCaps,
    RoomDriver,
    RoomError,
    RoomMember,
    RoomStore,
    RoomTranscriptStore,
    RoomTurn,
)

#: The group settings a ``room_create`` / ``room_settings`` frame may carry.
SETTING_KEYS = ("responder", "lead_agent_id", "fallback_agent_id", "bulletin", "workdir")

#: The cheap model of ``auto`` mode: (system text, user text) -> reply text.
AskModel = Callable[[str, str], str]
#: Gives (or with ``None`` takes back) one agent the lead's hand-off tool.
ArmHandoff = Callable[[str, "object | None"], None]

#: Emits one room payload (``room_turn`` / ``room_done``) toward the app. The
#: host binds this to seal-and-send; a test captures the dicts.
RoomEmit = Callable[[dict], None]

#: Brings a room's members online just before it runs: the host binds this to its
#: :class:`~chuk_agents_host.room_agents.RoomAgentPool`, which starts one executor per
#: member and registers its sender in the binding. It is a seam, and an optional
#: one — without it the service drives whatever the binding already holds, which
#: is what every unit test wants. Members are started here rather than at startup
#: so a room nobody opens costs nothing.
RoomMembersReady = Callable[[str, "tuple[RoomMember, ...]"], None]


class RoomService:
    """Runs ``room_task`` frames against the host's rooms.

    ``binding`` carries the per-member task senders (registered as members'
    executors connect). ``members_ready`` is what registers them: it is called
    with the room and its members just before an exchange runs, so the host can
    start a member's executor on demand instead of holding one open for every
    agent that might one day be in a room. ``caps`` overrides the stored
    per-room caps for every run — leave it ``None`` to honour each room's own
    caps.
    """

    def __init__(
        self,
        *,
        room_store: RoomStore,
        binding: RoomBinding,
        emit: RoomEmit,
        caps: RoomCaps | None = None,
        transcript: RoomTranscriptStore | None = None,
        members_ready: RoomMembersReady | None = None,
        ask_model: Callable[[], AskModel | None] | None = None,
        arm_handoff: ArmHandoff | None = None,
        name_for: Callable[[str], str] | None = None,
        background: bool = False,
        auto_timeout: float | None = None,
        local_host_id: str | None = None,
    ) -> None:
        self._rooms = room_store
        # This host's relay device id (CHAT-177). A member whose ``host_id`` is
        # this id, empty or missing runs here; any other id is a peer host.
        self._local_host_id = local_host_id
        self._binding = binding
        self._raw_emit = emit
        self._caps = caps
        self._transcript = transcript
        self._members_ready = members_ready
        # ``auto`` mode's cheap model, read per message (the account may be
        # provisioned after the service is built). ``None`` -> fallback member.
        self._ask_model = ask_model
        self._arm_handoff = arm_handoff
        self._name_for = name_for
        # ``True`` (the host): an exchange runs on its own thread, so the
        # executor's frame loop that handed the frame up is free at once. A
        # group run is several whole agent runs; holding the reader thread for
        # it froze every other frame of the session (stop, chat, approvals).
        self._background = background
        # How long ``auto`` waits for its pick before the fallback answers.
        self._auto_timeout = auto_timeout
        self._room_locks: dict[str, threading.Lock] = {}
        self._stops: dict[str, threading.Event] = {}
        self._threads: set[threading.Thread] = set()
        self._guard = threading.Lock()

    def _emit(self, payload: dict) -> None:
        """Send one frame to the app. A send that fails (the app went away
        while members worked) loses the frame, never the exchange: the
        transcript keeps every turn and the app replays it on the next open."""
        try:
            self._raw_emit(payload)
        except Exception:  # noqa: BLE001 — the group runs on without a reader
            pass

    def handle_room_create(
        self,
        room_id: str,
        name: str,
        members: list[dict],
        agent_to_agent: bool = True,
        settings: dict | None = None,
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
        room stays usable.

        ``agent_to_agent`` is the room's policy — may an agent's reply pull
        another agent in. It defaults to ``True``, so an app that predates the
        policy keeps creating the rooms it always did, and it is reconciled like
        the name, because the app owns room state."""
        wanted = [
            (m["agent_id"], m["handle"], self._member_host(m.get("host_id")))
            for m in members
            if isinstance(m, dict)
            and isinstance(m.get("agent_id"), str)
            and isinstance(m.get("handle"), str)
        ]

        existing = self._rooms.get(room_id)
        if existing is None:
            self._rooms.create_room(
                name=name, room_id=room_id, agent_to_agent=agent_to_agent
            )
        else:
            if existing.name != name:
                self._rooms.rename_room(room_id, name)
            if existing.agent_to_agent != agent_to_agent:
                self._rooms.set_agent_to_agent(room_id, agent_to_agent)
            wanted_ids = {agent_id for agent_id, _, _ in wanted}
            # Remove members the app no longer has.
            for member in existing.members:
                if member.agent_id not in wanted_ids:
                    try:
                        self._rooms.remove_member(room_id, member.agent_id)
                    except RoomError:
                        pass

        have = {m.agent_id: m for m in (self._rooms.get(room_id).members)}
        for agent_id, handle, host_id in wanted:
            if agent_id in have:
                if have[agent_id].host_id != host_id:
                    # The app moved the member to another computer.
                    try:
                        self._rooms.set_member_host(room_id, agent_id, host_id)
                    except RoomError:
                        pass
                continue
            try:
                self._rooms.add_member(room_id, agent_id, handle, host_id)
            except RoomError:
                # Over the cap or a duplicate: skip this member, keep the room.
                continue
        if settings:
            self.handle_room_settings(room_id, settings)

    def handle_room_settings(self, room_id: str, settings: dict) -> None:
        """Change a group's settings (who answers, the lead, the fallback, the
        instructions, the folder). Only the keys present change. Each key is
        applied on its own, so one bad value (an unknown mode, instructions
        that are too long) does not drop the good ones. A no-op on an unknown
        room."""
        if self._rooms.get(room_id) is None:
            return
        for key in SETTING_KEYS:
            if key not in settings:
                continue
            try:
                self._rooms.set_settings(room_id, **{key: settings[key]})
            except RoomError:
                continue

    def handle_room_list(self) -> None:
        """Answer ``room_list_request`` with every group the host keeps, so an
        app that starts (or a second device) shows the groups at once."""
        self._emit(
            room_list_payload(rooms=[room_wire(room) for room in self._rooms.list()])
        )

    def handle_room_stop(self, room_id: str) -> None:
        """Stop a running exchange of ``room_id`` after the turn in flight. A
        no-op when nothing runs."""
        with self._guard:
            event = self._stops.get(room_id)
        if event is not None:
            event.set()

    def wait_idle(self, timeout: float | None = None) -> bool:
        """Wait for every background exchange to end (tests, probes). True when
        none is left running."""
        with self._guard:
            threads = list(self._threads)
        for thread in threads:
            thread.join(timeout)
        with self._guard:
            return not any(t.is_alive() for t in self._threads)

    def _member_host(self, raw: object) -> str | None:
        """The stored host id of a member: ``None`` for this host (no id, an
        empty id, or this host's own id), else the peer's relay device id."""
        if not isinstance(raw, str) or not raw.strip():
            return None
        value = raw.strip()
        if self._local_host_id and value == self._local_host_id:
            return None
        return value

    def post_note(self, room_id: str, agent_id: str, text: str) -> bool:
        """Put one line from a member into the group, outside a turn (a file
        that member shared, CHAT-177). Stored in the transcript and sent to
        the app as a ``room_turn``. ``False`` when the room or the member is
        not on this host."""
        room = self._rooms.get(room_id)
        member = room.member_by_id(agent_id) if room is not None else None
        if member is None:
            return False
        turn = RoomTurn(round=0, agent_id=agent_id, handle=member.handle, text=text)
        if self._transcript is not None:
            self._transcript.append(room_id, turn)
        self._emit(
            room_turn_payload(
                room_id=room_id,
                round=0,
                agent_id=agent_id,
                handle=member.handle,
                text=text,
                kind=turn.kind,
            )
        )
        return True

    def handle_room_add_member(
        self, room_id: str, agent_id: str, handle: str, host_id: str | None = None
    ) -> None:
        """Add an agent to a room the host holds (§16.1). Ignored on an unknown
        room or a member the room cannot take (full, or a duplicate) — the room
        stays valid rather than the call raising into the frame loop."""
        if self._rooms.get(room_id) is None:
            return
        try:
            self._rooms.add_member(room_id, agent_id, handle, self._member_host(host_id))
        except RoomError:
            return

    def handle_room_remove_member(self, room_id: str, agent_id: str) -> None:
        """Remove an agent from a room (§16.1). Ignored on an unknown room or a
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

    def handle_room_set_agent_to_agent(self, room_id: str, enabled: bool) -> None:
        """Switch a room between agents-may-summon-each-other and
        user-driven (§16.1). A no-op on an unknown room — the host does not have
        it yet and the next ``room_create`` carries the policy with it."""
        if self._rooms.get(room_id) is None:
            return
        try:
            self._rooms.set_agent_to_agent(room_id, enabled)
        except RoomError:
            return

    def handle_room_delete(self, room_id: str) -> None:
        """Forget a room: drop it from the store and clear its transcript, so a
        deleted room leaves no orphaned history behind. Safe on an unknown room —
        deleting what is already gone is a no-op, not an error. A run in flight
        is stopped after its current turn."""
        self.handle_room_stop(room_id)
        self._rooms.delete(room_id)
        if self._transcript is not None:
            self._transcript.clear(room_id)

    def handle_room_task(self, room_id: str, message: str) -> None:
        """Drive one room exchange to completion, streaming its turns out.

        An unknown room ends immediately with ``room_done`` reason
        ``no_such_room`` rather than silence — the app asked for a room the host
        does not have, and must be told, not left waiting. With ``background``
        the exchange runs on its own thread; two messages to one group run one
        after the other, in the order they came.
        """
        if self._rooms.get(room_id) is None:
            self._emit(
                room_done_payload(
                    room_id=room_id,
                    reason="no_such_room",
                    messages_sent=0,
                    rounds=0,
                )
            )
            return
        if not self._background:
            self._run_exchange(room_id, message)
            return

        def work() -> None:
            try:
                self._run_exchange(room_id, message)
            finally:
                with self._guard:
                    self._threads.discard(threading.current_thread())

        thread = threading.Thread(target=work, name=f"room-{room_id}", daemon=True)
        with self._guard:
            self._threads.add(thread)
        thread.start()

    def _run_exchange(self, room_id: str, message: str) -> None:
        with self._guard:
            lock = self._room_locks.setdefault(room_id, threading.Lock())
        with lock:
            stop = threading.Event()
            with self._guard:
                self._stops[room_id] = stop
            try:
                self._exchange(room_id, message, stop)
            finally:
                with self._guard:
                    if self._stops.get(room_id) is stop:
                        del self._stops[room_id]

    def _exchange(self, room_id: str, message: str, stop: threading.Event) -> None:
        room = self._rooms.get(room_id)
        if room is None:  # deleted while the message waited its turn
            self._emit(
                room_done_payload(
                    room_id=room_id, reason="no_such_room", messages_sent=0, rounds=0
                )
            )
            return

        # Bring the members online before the first turn is routed. A member
        # whose runtime cannot be started stays unregistered and the room shows
        # its offline placeholder, so a failure here never costs the exchange.
        if self._members_ready is not None:
            try:
                self._members_ready(room_id, tuple(room.members))
            except Exception:  # noqa: BLE001 — an offline member, not a dead room
                pass

        # A group is a persistent thread: the history is the whole conversation
        # (the newest entries, bounded by the transcript store), and the user's
        # own message is part of it.
        history: tuple[RoomTurn, ...] = ()
        if self._transcript is not None:
            history = tuple(self._transcript.history(room_id))
            self._transcript.append(
                room_id,
                RoomTurn(round=0, agent_id="", handle="", text=message, kind=TURN_USER),
            )

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
                    kind=turn.kind,
                    routed_by=turn.routed_by,
                    to_agent_id=turn.to_agent_id,
                    to_handle=turn.to_handle,
                )
            )

        def on_start(member: RoomMember) -> None:
            self._emit(
                room_working_payload(
                    room_id=room_id, agent_id=member.agent_id, handle=member.handle
                )
            )

        ask = None
        if self._ask_model is not None:
            try:
                ask = self._ask_model()
            except Exception:  # noqa: BLE001 — auto falls back, never fails
                ask = None

        driver = RoomDriver(self._binding.member_runner(), caps=self._caps)
        try:
            outcome = driver.run(
                room,
                message,
                on_turn=on_turn,
                on_start=on_start,
                stop=stop.is_set,
                history=history,
                names=self._names(room),
                ask=ask,
                arm=self._arm_handoff,
                **(
                    {"auto_timeout": self._auto_timeout}
                    if self._auto_timeout is not None
                    else {}
                ),
            )
            reason, sent, rounds = outcome.stop_reason, outcome.messages_sent, outcome.rounds
        except Exception:  # noqa: BLE001 — the app must hear the end, always
            reason, sent, rounds = "turn_failed", 0, 0
        self._emit(
            room_done_payload(
                room_id=room_id,
                reason=reason,
                messages_sent=sent,
                rounds=rounds,
            )
        )

    def _names(self, room: GroupRoom) -> dict[str, str]:
        if self._name_for is None:
            return {}
        names: dict[str, str] = {}
        for member in room.members:
            try:
                name = self._name_for(member.agent_id)
            except Exception:  # noqa: BLE001 — a name is a nicety
                continue
            if isinstance(name, str) and name.strip():
                names[member.agent_id] = name.strip()
        return names

    def handle_room_history(self, room_id: str) -> None:
        """Answer a ``room_history_request`` with the room's stored transcript
        (§16.1). Emits an empty history when nothing is stored (or no transcript
        store is configured) rather than staying silent, so the app can tell
        "no history" from "still waiting"."""
        turns: list[dict] = []
        if self._transcript is not None:
            turns = [turn_wire(t) for t in self._transcript.history(room_id)]
        self._emit(room_history_payload(room_id=room_id, turns=turns))


def turn_wire(turn: RoomTurn) -> dict:
    """One stored entry as ``room_history`` carries it: the ``room_turn`` keys
    without ``type``/``room_id``, plus ``kind`` (``agent``/``user``/``handoff``)."""
    out = {
        "round": turn.round,
        "agent_id": turn.agent_id,
        "handle": turn.handle,
        "text": turn.text,
        "kind": turn.kind,
    }
    if turn.routed_by:
        out["routed_by"] = turn.routed_by
    if turn.to_agent_id is not None:
        out["to_agent_id"] = turn.to_agent_id
    if turn.to_handle is not None:
        out["to_handle"] = turn.to_handle
    return out


def _member_wire(member: RoomMember) -> dict:
    """One member as ``room_list`` carries it. ``host_id`` only for a member
    on a peer host (CHAT-177), so the frame of a one-host group is unchanged."""
    out = {"agent_id": member.agent_id, "handle": member.handle}
    if member.host_id:
        out["host_id"] = member.host_id
    return out


def room_wire(room: GroupRoom) -> dict:
    """One group as ``room_list`` carries it."""
    return {
        "room_id": room.room_id,
        "name": room.name,
        "members": [_member_wire(m) for m in room.members],
        "agent_to_agent": room.agent_to_agent,
        "responder": room.responder,
        "lead_agent_id": room.lead_agent_id,
        "fallback_agent_id": room.fallback_agent_id,
        "bulletin": room.bulletin,
        "workdir": room.workdir,
    }


def dispatch_room_frame(service: RoomService, payload: dict) -> None:
    """Route one decoded ``room_*`` payload to the right :class:`RoomService`
    method (§16.1). The executor hands these up via ``on_room_frame``; this is
    the one place the room wire types map to service calls. An unknown type or a
    payload missing its ``room_id`` is ignored — the executor already validated
    the frame's authenticity, so a malformed body is a client bug, not an attack,
    and dropping it is safer than guessing."""
    kind = payload.get("type")
    if kind == "room_list_request":
        # The one room frame about all groups, so it carries no room id.
        service.handle_room_list()
        return
    room_id = payload.get("room_id")
    if not isinstance(room_id, str) or not room_id:
        return
    settings = {key: payload[key] for key in SETTING_KEYS if key in payload}
    if kind == "room_create":
        name = payload.get("name")
        members = payload.get("members")
        # A missing (or null, or non-bool) key means the permissive default, so
        # an app that predates the policy keeps creating the rooms it always did.
        a2a = payload.get("agent_to_agent")
        service.handle_room_create(
            room_id,
            name if isinstance(name, str) else "",
            members if isinstance(members, list) else [],
            a2a if isinstance(a2a, bool) else True,
            settings,
        )
    elif kind == "room_settings":
        service.handle_room_settings(room_id, settings)
    elif kind == "room_stop":
        service.handle_room_stop(room_id)
    elif kind == "room_task":
        message = payload.get("message")
        service.handle_room_task(room_id, message if isinstance(message, str) else "")
    elif kind == "room_add_member":
        agent_id = payload.get("agent_id")
        handle = payload.get("handle")
        host_id = payload.get("host_id")
        if isinstance(agent_id, str) and isinstance(handle, str):
            service.handle_room_add_member(
                room_id, agent_id, handle, host_id if isinstance(host_id, str) else None
            )
    elif kind == "room_remove_member":
        agent_id = payload.get("agent_id")
        if isinstance(agent_id, str):
            service.handle_room_remove_member(room_id, agent_id)
    elif kind == "room_rename":
        name = payload.get("name")
        if isinstance(name, str) and name.strip():
            service.handle_room_rename(room_id, name)
    elif kind == "room_set_agent_to_agent":
        enabled = payload.get("enabled")
        if isinstance(enabled, bool):
            service.handle_room_set_agent_to_agent(room_id, enabled)
    elif kind == "room_delete":
        service.handle_room_delete(room_id)
    elif kind == "room_history_request":
        service.handle_room_history(room_id)
