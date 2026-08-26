"""Room task sender — one member's turn over the relay (§16.1/4b).

This is the last mile the manager's ``RoomBinding`` was built around. A room
member is a coworker with its own executor; running its turn is sending it one
task (the rendered room prompt) and reading back its final answer. That is
exactly what a :class:`ControllerSession` already does — this wraps one into the
``TaskSender`` shape the binding registers: ``(prompt) -> reply | None``.

``None`` means "no usable reply": the executor errored, or the run ended without
a final answer. The manager turns that into the room's offline placeholder, so a
member whose turn failed does not stall the exchange. Room turns ride a dedicated
``session_key`` (``room:<room_id>`` by convention) so they land in the room's own
thread on the executor side rather than polluting the member's one-to-one chat.
"""

from __future__ import annotations

from collections.abc import Callable

from cowork_executor.controller import ControllerSession

#: The shape the manager's RoomBinding registers. Structural, so no import of the
#: manager is needed here — the two packages meet at the callable, not a type.
TaskSender = Callable[[str], "str | None"]


def make_room_task_sender(
    controller: ControllerSession,
    *,
    session_key: str,
    timeout: float = 120.0,
) -> TaskSender:
    """Wrap ``controller`` into a :data:`TaskSender` for one room member.

    Each call sends the prompt as a task, waits up to ``timeout`` for the run to
    finish, and returns the ``done`` frame's ``final_answer`` — or ``None`` when
    the run produced no answer (an ``error`` terminal, a timeout with no ``done``,
    or a ``done`` that carried no text). One member, one controller, one sender:
    a room binds several of these, one per reachable member.
    """

    def send(prompt: str) -> str | None:
        request_id = controller.send_task(prompt, session_key=session_key)
        events = controller.collect(request_id, timeout=timeout)
        for event in events:
            if event.get("type") == "done":
                answer = event.get("final_answer")
                return answer if isinstance(answer, str) and answer else None
        # No done terminal: an error frame, or the collect timed out. Either way
        # there is no reply to show, which the room renders as offline.
        return None

    return send
