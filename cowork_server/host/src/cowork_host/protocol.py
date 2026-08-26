"""The local relay protocol — the exact wire the blind localhost relay carries.

The relay is **blind**: it never reads past ``type`` for routing. Two parties
join a channel and then exchange three kinds of JSON message, defined here so the
host and the Dart app build byte-identical envelopes.

1. **join** (first message on a connection)::

       {"type": "join", "channel": "<channel_id>", "role": "executor" | "controller"}

   The relay pairs the ``executor`` and ``controller`` on the same ``channel`` and
   forwards every later message from one to the other verbatim.

2. **pairing** (the §15 ceremony, hand-carried through the relay)::

       {"type": "pairing", "step": "<step>", "data": {...}}

   ``data`` is the exact dict a :class:`cowork_crypto.Pairing` step produced or
   consumes. ``step`` is one of ``commit``, ``pubkey``, ``reveal``, ``confirm-d``,
   ``confirm-c``, ``device-d`` (joiner's device key), ``device-c`` (initiator's).

3. **frame** (everything after pairing: token provisioning, tasks, results)::

       {"type": "frame", "frame": "<base64 of a sealed CoWork frame>"}

The host is the ``executor`` role and the pairing **initiator**; the app is the
``controller`` role and the pairing **joiner**.
"""

from __future__ import annotations

from typing import Any

# Message ``type`` discriminators.
TYPE_JOIN = "join"
TYPE_PAIRING = "pairing"
TYPE_FRAME = "frame"

# Relay roles. The two ends of one channel.
ROLE_EXECUTOR = "executor"
ROLE_CONTROLLER = "controller"
ROLES = (ROLE_EXECUTOR, ROLE_CONTROLLER)

# Pairing envelope steps, in ceremony order.
STEP_COMMIT = "commit"
STEP_PUBKEY = "pubkey"
STEP_REVEAL = "reveal"
STEP_CONFIRM_D = "confirm-d"
STEP_CONFIRM_C = "confirm-c"
STEP_DEVICE_D = "device-d"  # the joiner's (app's) device key
STEP_DEVICE_C = "device-c"  # the initiator's (host's) device key

# Reconnect handshake steps (code-free resume of an already-paired session).
# ``hello``/``confirm`` are sent by the initiator (host); ``response`` by the
# joiner (app). The envelope ``step`` mirrors each message's own ``type``.
STEP_RECONNECT_HELLO = "reconnect-hello"
STEP_RECONNECT_RESPONSE = "reconnect-response"
STEP_RECONNECT_CONFIRM = "reconnect-confirm"


def join_message(channel: str, role: str) -> dict[str, Any]:
    """Build the join message a party sends first on a fresh connection."""
    if role not in ROLES:
        raise ValueError(f"role must be one of {ROLES}, got {role!r}")
    return {"type": TYPE_JOIN, "channel": channel, "role": role}


def pairing_envelope(step: str, data: dict[str, Any]) -> dict[str, Any]:
    """Wrap a pairing state-machine ``data`` dict in its relay envelope."""
    return {"type": TYPE_PAIRING, "step": step, "data": data}


def frame_envelope(frame_b64: str) -> dict[str, Any]:
    """Wrap a base64 sealed CoWork frame in its relay envelope."""
    return {"type": TYPE_FRAME, "frame": frame_b64}


# The device-key state-machine dict is ``{"type": "device-key", ...}`` for both
# sides; the envelope step distinguishes which side sent it.
def device_step_for_role(role: str) -> str:
    """The pairing envelope step for *this* party's own device-key message."""
    return STEP_DEVICE_C if role == ROLE_EXECUTOR else STEP_DEVICE_D
