"""Every inbound relay frame, and what the host decided to do with it.

Why this exists. On 2026-09-13 a message left the phone, the app showed a sent
bubble and a typing indicator, and on the host **nothing happened at all**: no
run row in ``executor-state.db``, no trace line, not one word in ``host.log``.
The run tracer (:mod:`chuk_agents_runtime.trace`) starts at ``task_received``,
which is inside the agent loop, so it could only say "no run started" — it could
not say whether the frame had arrived and been thrown away, or had never
arrived. Those two are the same picture from the host's side, and telling them
apart is the whole diagnosis: one is a host bug, the other is a transport bug.

So the rule here is simple and absolute: **a frame that arrives leaves a line.**
Either the host says what it did with it, or it says why it did nothing.

Two levels, on purpose:

- A frame the host **acted on** is trace-only. It is one line per user message
  in a healthy session, and the trace is where the per-run detail already
  lives, so it costs nothing when tracing is off (``NullTracer.emit`` returns
  before it allocates).
- A frame the host **dropped or ignored** goes to the ordinary log as well. A
  swallowed message is not a debug detail — it is the failure the user sees —
  and it must be visible on a host nobody thought to start with ``--trace``.

Nothing here reads message content. A frame's type, the device or connection
that sent it, the session key it names and the decision are structure, and
structure is always safe to write; the prompt, the token and the tool arguments
never appear.
"""

from __future__ import annotations

from typing import Any, Callable

try:  # pragma: no cover - the runtime is always present in a real host
    from chuk_agents_runtime.trace import get_tracer
except Exception:  # noqa: BLE001 - a missing tracer must never break the pipe

    def get_tracer() -> Any:  # type: ignore[misc]
        return _NO_TRACER


class _NoTracer:
    """Stand-in for a runtime that is not importable (tests of this module
    alone). Same shape as :class:`chuk_agents_runtime.trace.NullTracer`."""

    enabled = False

    def emit(self, phase: str, **fields: Any) -> None:
        return None


_NO_TRACER = _NoTracer()

#: The trace phase for a frame the host acted on.
PHASE_FRAME_IN = "relay_frame_in"
#: The trace phase for a frame the host did not act on. Also logged plainly.
PHASE_FRAME_DROPPED = "relay_frame_dropped"

# -- decisions (a frame was acted on) ---------------------------------------

#: Opened, read as a task, and handed to the executor as a run.
DECISION_DISPATCHED_RUN = "dispatched_run"
#: Opened and handed to the executor as something other than a task — a stop, a
#: replay, a document read. It is the executor that dispatches on the payload
#: type, so this side only records that the frame got there.
DECISION_DISPATCHED_EXECUTOR = "dispatched_executor"
#: Handed to the room service rather than to a run.
DECISION_DISPATCHED_ROOM = "dispatched_room"
#: An ``account_authentication`` that built or refreshed the task server.
DECISION_PROVISIONED = "provisioned"
#: Part of a handshake (``controller_resume`` / ``controller_proof``, or a step
#: of the §15 pairing ceremony).
DECISION_HANDSHAKE = "handshake"
#: A controller said goodbye and its session was closed.
DECISION_CLOSED = "closed"
#: The frame named a task the host already took. Acked as a duplicate, not run
#: a second time.
DECISION_DUPLICATE = "duplicate"
#: The codec was rebuilt for this frame rather than the frame being dropped.
DECISION_REPAIRED = "repaired"
#: The pipe unwrapped the payload and handed it to the party. The party then
#: reports what it routed it to, so a frame that stops between the two layers
#: has a line on one side and none on the other.
DECISION_DELIVERED = "delivered_to_party"

# -- reasons (a frame was dropped or ignored) -------------------------------

#: The host has no task server yet for this controller session: the app sent a
#: task before its ``account_authentication``. The frame is acked as rejected
#: so the app can re-send after it provisions.
REASON_NOT_PROVISIONED = "not_provisioned"
#: A legacy ``frame`` / ``pairing`` message arrived while authenticated
#: controller sessions are live. The old ceremony no longer owns this host.
REASON_LEGACY_SUPERSEDED = "legacy_superseded"
#: A ``controller_frame`` with no ``frame`` string in it.
REASON_MALFORMED = "malformed"
#: The sealed frame did not open: an unapproved device, a bad signature, a key
#: version mismatch, a replayed sequence number or a stale timestamp.
REASON_REJECTED = "rejected"
#: The one-use ticket table for the executor is full.
REASON_QUEUE_FULL = "queue_full"
#: A frame type this host does not know. Forward compatibility, not a fault.
REASON_UNKNOWN_TYPE = "unknown_type"
#: A frame arrived before any pairing or reconnect finished, so there is no
#: codec to open it with.
REASON_NOT_PAIRED = "not_paired"
#: The account was mid-refresh and the session the frame names was replaced.
REASON_SESSION_REPLACED = "session_replaced"


class InboundFrameLog:
    """Reports what became of each inbound relay frame.

    ``log`` is the host's ordinary line printer (``print`` in production, a list
    in a test). ``tracer`` is read lazily through a callable so a tracer
    installed after the host started is still picked up — the host wires tracing
    in :mod:`chuk_agents_host.cli` before the party exists, but a test installs
    one afterwards.
    """

    def __init__(
        self,
        log: Callable[[str], None] | None = None,
        *,
        tracer: Callable[[], Any] = get_tracer,
    ) -> None:
        self._log = log or (lambda _msg: None)
        self._tracer = tracer

    # -- acted on --------------------------------------------------------

    def acted(self, kind: str | None, decision: str, **fields: Any) -> None:
        """One frame the host did something with. Trace only."""
        tracer = self._tracer()
        if not getattr(tracer, "enabled", False):
            return
        tracer.emit(
            PHASE_FRAME_IN,
            frame_type=str(kind),
            decision=decision,
            **_clean(fields),
        )

    # -- not acted on ----------------------------------------------------

    def dropped(self, kind: str | None, reason: str, **fields: Any) -> None:
        """One frame the host did NOT act on, and why.

        Always logged, never only traced: this is the line whose absence made
        the 2026-09-13 incident undiagnosable.
        """
        clean = _clean(fields)
        self._log(
            f"relay frame dropped: type={kind!r} reason={reason}" + _suffix(clean)
        )
        tracer = self._tracer()
        if getattr(tracer, "enabled", False):
            tracer.emit(
                PHASE_FRAME_DROPPED,
                frame_type=str(kind),
                reason=reason,
                **clean,
            )


def _clean(fields: dict[str, Any]) -> dict[str, Any]:
    """Drop empty values so a line carries only what is known. Keeps the log
    readable and the trace lines comparable across frames."""
    return {key: value for key, value in fields.items() if value not in (None, "")}


def _suffix(fields: dict[str, Any]) -> str:
    if not fields:
        return ""
    return " " + " ".join(f"{key}={value}" for key, value in sorted(fields.items()))
