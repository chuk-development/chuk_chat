"""Room binding — which member is reachable right now, and how (§16.1/4b).

:class:`~cowork_manager.room_driver.RoomDriver` routes each room turn to a
``member_runner`` seam; this is what the host fills that seam with. A room member
is a coworker with its own executor, and an executor may or may not be connected
at the moment its turn comes up. This registry tracks the ones that are: when a
member's executor connects the host registers a **task sender** for its agent id,
and when it drops the host unregisters it. The ``member_runner`` this produces
returns a reply for a registered member and ``None`` for one that is not — which
:class:`RoomDriver` turns into the offline placeholder, so a member that dropped
between two turns is handled without the room stalling.

The task sender itself — send one task to one executor over the relay and wait
for its final answer — stays a seam (``TaskSender``): a test registers a scripted
callable, the host registers one that speaks to the real executor. The binding
never opens a socket, so the routing and the connect/disconnect bookkeeping are
testable on their own.
"""

from __future__ import annotations

import threading
from collections.abc import Callable

from cowork_manager.group_room import RoomMember

#: Sends one task (the rendered room prompt) to one member's executor and returns
#: its final answer, or ``None`` if the turn produced none.
TaskSender = Callable[[str], "str | None"]

#: The seam :class:`RoomDriver` consumes.
MemberRunner = Callable[[RoomMember, str], "str | None"]


class RoomBinding:
    """The host's registry of reachable room members.

    Thread-safe: members connect and drop on transport threads while a room runs
    on another, so registration is guarded. Registering the same agent again
    replaces its sender (a reconnect), which is the correct last-writer-wins
    behaviour for "where do I reach this agent now".
    """

    def __init__(self) -> None:
        self._senders: dict[str, TaskSender] = {}
        self._lock = threading.Lock()

    def register(self, agent_id: str, sender: TaskSender) -> None:
        """Mark ``agent_id`` reachable through ``sender``. A reconnect re-registers
        and replaces the previous sender."""
        with self._lock:
            self._senders[agent_id] = sender

    def unregister(self, agent_id: str) -> None:
        """Mark ``agent_id`` no longer reachable. A no-op if it was not registered
        — a double-drop must not raise."""
        with self._lock:
            self._senders.pop(agent_id, None)

    def is_online(self, agent_id: str) -> bool:
        with self._lock:
            return agent_id in self._senders

    @property
    def online_ids(self) -> frozenset[str]:
        with self._lock:
            return frozenset(self._senders)

    def member_runner(self) -> MemberRunner:
        """The seam for :class:`RoomDriver`. Reads the registry per call, so a
        member that drops mid-room is offline from its next turn on."""

        def run(member: RoomMember, prompt: str) -> str | None:
            with self._lock:
                sender = self._senders.get(member.agent_id)
            if sender is None:
                return None  # not connected -> RoomDriver's offline placeholder
            return sender(prompt)

        return run
