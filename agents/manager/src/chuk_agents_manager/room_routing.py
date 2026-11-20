"""Who answers a group message (§16.1): the room's default responder.

:class:`~chuk_agents_manager.group_room.RoomSession` knows how a room runs once
the first speakers are known. This module decides those first speakers, in one
fixed order:

1. ``@all`` / ``@everyone`` / ``@room`` anywhere in the message: every member.
2. ``@handle`` mentions of members: exactly those, in mention order.
3. Nobody named: the room's ``responder`` mode decides.

   - ``everyone``: every member, in room order (the old behaviour).
   - ``mentions``: nobody. The exchange ends with ``no_addressee``, so the user
     sees why nothing happened.
   - ``auto``: a cheap model reads the message and the member list and picks
     the best member (or several). It **fails open**: a pick under the
     confidence floor, an answer that names no member, an error or a reply
     slower than the time limit all give the room's fallback member. A group
     message is never left without an answer because the picker had a bad
     moment.
   - ``lead``: the lead member alone (:mod:`chuk_agents_manager.room_lead`).

The model call is a seam (``ask``: system text, user text -> reply text), so the
routing and the fail-open rules are tested without a model.
"""

from __future__ import annotations

import json
import re
import threading
from collections.abc import Callable, Mapping
from dataclasses import dataclass

from chuk_agents_manager.group_room import (
    GroupRoom,
    RoomMember,
    has_broadcast_mention,
    parse_mentions,
)

#: The picker's answer must arrive within this time, else the fallback answers.
AUTO_PICK_TIMEOUT_SECONDS = 1.5
#: A pick below this confidence is not trusted; the fallback answers instead.
AUTO_PICK_MIN_CONFIDENCE = 0.6
#: The picker sees at most this much of the user's message.
_MAX_PICK_MESSAGE_CHARS = 2_000

#: The model seam: ``ask(system, user) -> reply text``. It may raise.
AskModel = Callable[[str, str], str]


@dataclass(frozen=True, slots=True)
class RouteDecision:
    """The first speakers of an exchange, and why they were chosen.

    ``via`` is ``broadcast``, ``mention``, ``everyone``, ``mentions`` (nobody
    named in ``mentions`` mode, so ``members`` is empty), ``auto`` or ``lead``.
    ``confidence`` and ``fallback`` are set for ``auto`` only.
    """

    members: tuple[RoomMember, ...]
    via: str
    confidence: float | None = None
    fallback: bool = False

    def routed_by(self) -> dict | None:
        """The ``routed_by`` note a turn of a routed speaker carries, or
        ``None`` when the user chose the speakers himself."""
        if self.via == "auto":
            note: dict = {"mode": "auto", "fallback": self.fallback}
            if self.confidence is not None:
                note["confidence"] = round(self.confidence, 2)
            return note
        if self.via == "lead":
            return {"mode": "lead"}
        return None


def route_first_round(
    room: GroupRoom,
    message: str,
    *,
    ask: AskModel | None = None,
    names: Mapping[str, str] | None = None,
    timeout: float = AUTO_PICK_TIMEOUT_SECONDS,
    min_confidence: float = AUTO_PICK_MIN_CONFIDENCE,
) -> RouteDecision:
    """Decide who speaks first for ``message`` in ``room``.

    ``ask`` is the cheap model for ``auto`` mode; without one, ``auto`` gives
    the fallback member at once. ``names`` maps an agent id to its display name,
    so the picker reads names, not only handles.
    """
    if not room.members:
        return RouteDecision(members=(), via="everyone")
    if has_broadcast_mention(message):
        return RouteDecision(members=room.members, via="broadcast")
    mentioned = parse_mentions(message, room.handles)
    if mentioned:
        order = tuple(
            m for m in (room.member_by_handle(h) for h in mentioned) if m is not None
        )
        return RouteDecision(members=order, via="mention")
    mode = room.responder
    if mode == "mentions":
        return RouteDecision(members=(), via="mentions")
    if mode == "lead":
        lead = room.lead
        return RouteDecision(members=(lead,) if lead else (), via="lead")
    if mode == "auto":
        return auto_pick(
            room,
            message,
            ask=ask,
            names=names,
            timeout=timeout,
            min_confidence=min_confidence,
        )
    return RouteDecision(members=room.members, via="everyone")


def _fallback(room: GroupRoom, confidence: float | None = None) -> RouteDecision:
    member = room.fallback
    return RouteDecision(
        members=(member,) if member else (),
        via="auto",
        confidence=confidence,
        fallback=True,
    )


def auto_pick_prompt(
    room: GroupRoom, message: str, names: Mapping[str, str] | None = None
) -> tuple[str, str]:
    """The picker's system and user text. Plain and short: the cheap model
    answers one JSON object, nothing else."""
    system = (
        "You route a message in a group chat to the member who should answer. "
        "Reply with one JSON object only, no other text: "
        '{"pick": ["<handle>"], "confidence": <0..1>}. '
        "Pick one handle. Pick several only when the message clearly needs "
        "several members. confidence is how sure you are."
    )
    lines = ["Members:"]
    for m in room.members:
        name = (names or {}).get(m.agent_id) or m.handle
        lines.append(f"- {m.handle}: {name}")
    if room.bulletin:
        lines.append("")
        lines.append("Group instructions: " + room.bulletin[:1_000])
    lines.append("")
    lines.append("Message: " + message[:_MAX_PICK_MESSAGE_CHARS])
    return system, "\n".join(lines)


_JSON_OBJECT = re.compile(r"\{.*\}", re.DOTALL)


def parse_auto_pick(
    room: GroupRoom, reply: str
) -> tuple[tuple[RoomMember, ...], float | None]:
    """The members and the confidence a picker reply names. Unknown handles are
    dropped; a reply that is not the asked JSON gives no members."""
    match = _JSON_OBJECT.search(reply or "")
    if match is None:
        return (), None
    try:
        data = json.loads(match.group(0))
    except (json.JSONDecodeError, ValueError):
        return (), None
    if not isinstance(data, dict):
        return (), None
    raw = data.get("pick")
    if isinstance(raw, str):
        raw = [raw]
    picked: list[RoomMember] = []
    if isinstance(raw, list):
        for item in raw:
            if not isinstance(item, str):
                continue
            member = room.member_by_handle(item.strip().lstrip("@"))
            if member is not None and member not in picked:
                picked.append(member)
    confidence = data.get("confidence")
    if isinstance(confidence, bool) or not isinstance(confidence, (int, float)):
        confidence = None
    else:
        confidence = max(0.0, min(1.0, float(confidence)))
    return tuple(picked), confidence


def auto_pick(
    room: GroupRoom,
    message: str,
    *,
    ask: AskModel | None,
    names: Mapping[str, str] | None = None,
    timeout: float = AUTO_PICK_TIMEOUT_SECONDS,
    min_confidence: float = AUTO_PICK_MIN_CONFIDENCE,
) -> RouteDecision:
    """Let the cheap model pick, and fail open to the fallback member.

    The model runs on a daemon thread joined with ``timeout``: a slow model
    cannot hold the group up. Its late answer is dropped.
    """
    if ask is None or len(room.members) < 2:
        return _fallback(room)
    system, user = auto_pick_prompt(room, message, names)
    result: dict = {}

    def work() -> None:
        try:
            result["reply"] = ask(system, user)
        except Exception as exc:  # noqa: BLE001 — any failure means fallback
            result["error"] = exc

    thread = threading.Thread(target=work, name="room-auto-pick", daemon=True)
    thread.start()
    thread.join(timeout)
    reply = result.get("reply")
    if thread.is_alive() or not isinstance(reply, str):
        return _fallback(room)
    members, confidence = parse_auto_pick(room, reply)
    if not members or confidence is None or confidence < min_confidence:
        return _fallback(room, confidence)
    return RouteDecision(members=members, via="auto", confidence=confidence)
