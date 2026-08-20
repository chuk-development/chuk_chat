"""Group rooms — several coworkers in one conversation (§16.1, §20).

A room is a small, capped, turn-based conversation between the user and up to a
handful of coworkers. The shape and the numbers are taken from Hermes Bot Mode,
which has already load-tested them in the wild: **at most six members, at most
three serial rounds per user message, and at most ten agent messages per send.**
The caps are a cost control as much as a UX one — a room with no ceiling is a
credit fire — so they are enforced here, in one pure module, rather than hoped
for at each call site.

This module is deliberately transport-free and model-free. It answers one
question: *given a room and a user message, in what order do members speak, and
when does the exchange stop?* Wiring it to real executors (each member is an
executor turn) and to the app is a later step; keeping the orchestration pure is
what makes the caps testable without a sandbox.

## The turn model

- **Round 1** is seeded by the user's message. If the user `@mentions` members,
  exactly those members speak, in mention order. If the user mentions nobody,
  every member speaks once, in room order — "everyone, weigh in".
- **A later round** is seeded by the `@mentions` that appeared in the previous
  round's outputs: a member can pull another member in by naming them. A member
  never re-triggers itself, and a member already queued for the next round is
  not queued twice.
- The exchange **stops** at the first of: no new mentions to answer
  (``no_more_mentions``), the round cap reached (``rounds_exhausted``), or the
  per-send message cap reached (``messages_exhausted``). The stop reason is
  reported, never silent — a truncated room must be legible as truncated.
"""

from __future__ import annotations

import re
from collections import deque
from dataclasses import dataclass, field, replace

#: Hermes Bot Mode's numbers. Kept as module constants so a caller (a plan tier,
#: a test) can build a different :class:`RoomCaps` without magic literals.
DEFAULT_MAX_MEMBERS = 6
DEFAULT_MAX_ROUNDS = 3
DEFAULT_MAX_MESSAGES_PER_SEND = 10

# An @mention: '@' then handle characters. The captured token is only treated as
# a mention when it is a known member handle, so '@' in prose (an email, a
# decorator) is ignored unless it exactly names a member.
_MENTION = re.compile(r"@([A-Za-z0-9][A-Za-z0-9-]*)")


@dataclass(frozen=True, slots=True)
class RoomCaps:
    """The three ceilings, each defaulting to the Hermes number."""

    max_members: int = DEFAULT_MAX_MEMBERS
    max_rounds: int = DEFAULT_MAX_ROUNDS
    max_messages_per_send: int = DEFAULT_MAX_MESSAGES_PER_SEND

    def __post_init__(self) -> None:
        for name in ("max_members", "max_rounds", "max_messages_per_send"):
            if getattr(self, name) < 1:
                raise ValueError(f"{name} must be >= 1")


class RoomError(ValueError):
    """A room rule was broken — too many members, a duplicate, an unknown id."""


@dataclass(frozen=True, slots=True)
class RoomMember:
    """One coworker in a room: the agent id and the handle it is mentioned by."""

    agent_id: str
    handle: str


@dataclass(frozen=True, slots=True)
class GroupRoom:
    """An ordered, capped set of members. Immutable — :meth:`with_member` and
    :meth:`without_member` return a new room, so a room is safe to share."""

    room_id: str
    name: str
    members: tuple[RoomMember, ...] = ()
    caps: RoomCaps = field(default_factory=RoomCaps)

    def __post_init__(self) -> None:
        if len(self.members) > self.caps.max_members:
            raise RoomError(
                f"a room holds at most {self.caps.max_members} members, "
                f"got {len(self.members)}"
            )
        handles = [m.handle for m in self.members]
        if len(set(handles)) != len(handles):
            raise RoomError("two members share a handle")
        ids = [m.agent_id for m in self.members]
        if len(set(ids)) != len(ids):
            raise RoomError("an agent is in the room twice")

    @property
    def handles(self) -> tuple[str, ...]:
        return tuple(m.handle for m in self.members)

    @property
    def member_ids(self) -> tuple[str, ...]:
        return tuple(m.agent_id for m in self.members)

    def member_by_handle(self, handle: str) -> RoomMember | None:
        for m in self.members:
            if m.handle == handle:
                return m
        return None

    def with_member(self, member: RoomMember) -> "GroupRoom":
        if len(self.members) >= self.caps.max_members:
            raise RoomError(
                f"the room is full ({self.caps.max_members} members)"
            )
        if any(m.handle == member.handle for m in self.members):
            raise RoomError(f"handle already in the room: {member.handle}")
        if any(m.agent_id == member.agent_id for m in self.members):
            raise RoomError(f"agent already in the room: {member.agent_id}")
        return replace(self, members=self.members + (member,))

    def without_member(self, agent_id: str) -> "GroupRoom":
        kept = tuple(m for m in self.members if m.agent_id != agent_id)
        if len(kept) == len(self.members):
            raise RoomError(f"not a member: {agent_id}")
        return replace(self, members=kept)


def parse_mentions(text: str, known_handles) -> list[str]:
    """The `@mentions` in ``text`` that name a known handle, in first-seen order.

    A handle is only a mention when it exactly matches one the room knows — so
    an email address or a stray '@' is not a mention, and a cross-machine handle
    (``@name-device``) is a mention only when that exact handle is a member.
    Deduped, so naming someone twice pulls them in once.
    """
    known = set(known_handles)
    seen: list[str] = []
    if not text:
        return seen
    for match in _MENTION.finditer(text):
        handle = match.group(1)
        if handle in known and handle not in seen:
            seen.append(handle)
    return seen


@dataclass(frozen=True, slots=True)
class RoomTurn:
    """One agent turn in a room exchange: which round, which member spoke."""

    round: int
    agent_id: str
    handle: str
    text: str


class RoomSession:
    """Drives one user message through a room, enforcing the three caps.

    Usage — the caller owns the model calls, this owns the order and the caps::

        session = RoomSession(room, "hey @amber-otter, what do you think?")
        while (member := session.next_speaker()) is not None:
            reply = run_the_agent(member.agent_id)   # the caller's job
            session.submit(reply)
        # session.stop_reason and session.transcript are now final
    """

    def __init__(
        self, room: GroupRoom, user_message: str, *, caps: RoomCaps | None = None
    ) -> None:
        self._room = room
        self._caps = caps or room.caps
        self._handles = set(room.handles)
        self._messages_sent = 0
        self._round = 1
        self._stop_reason: str | None = None
        self._current: RoomMember | None = None
        self._transcript: list[RoomTurn] = []
        self._next_round: list[str] = []

        # Round 1: the user's mentions, or everyone in room order.
        mentioned = parse_mentions(user_message, self._handles)
        if mentioned:
            order = [room.member_by_handle(h) for h in mentioned]
            self._queue: deque[RoomMember] = deque(m for m in order if m)
        else:
            self._queue = deque(room.members)
        if not self._queue:
            self._stop_reason = "no_members"

    # -- read-only state -------------------------------------------------

    @property
    def round(self) -> int:
        return self._round

    @property
    def messages_sent(self) -> int:
        return self._messages_sent

    @property
    def stop_reason(self) -> str | None:
        return self._stop_reason

    @property
    def transcript(self) -> list[RoomTurn]:
        return list(self._transcript)

    @property
    def finished(self) -> bool:
        return self._stop_reason is not None

    # -- driving ---------------------------------------------------------

    def next_speaker(self) -> RoomMember | None:
        """The next member to speak, or ``None`` when the exchange is over.

        Calling this again without a :meth:`submit` in between is a programming
        error — the previous speaker's output has not been recorded yet.
        """
        if self._current is not None:
            raise RoomError(
                "submit() the current speaker's output before asking for the next"
            )
        if self._stop_reason is not None:
            return None
        if not self._queue:
            self._advance_round()
            if self._stop_reason is not None:
                return None
        if self._messages_sent >= self._caps.max_messages_per_send:
            self._stop_reason = "messages_exhausted"
            return None
        self._current = self._queue.popleft()
        return self._current

    def submit(self, text: str) -> None:
        """Record the current speaker's output and harvest its mentions for the
        next round. A member never re-triggers itself."""
        if self._current is None:
            raise RoomError("no speaker is in flight; call next_speaker() first")
        speaker = self._current
        self._transcript.append(
            RoomTurn(
                round=self._round,
                agent_id=speaker.agent_id,
                handle=speaker.handle,
                text=text,
            )
        )
        self._messages_sent += 1
        for handle in parse_mentions(text, self._handles):
            if handle != speaker.handle and handle not in self._next_round:
                self._next_round.append(handle)
        self._current = None

    def _advance_round(self) -> None:
        if not self._next_round:
            self._stop_reason = "no_more_mentions"
            return
        if self._round >= self._caps.max_rounds:
            self._stop_reason = "rounds_exhausted"
            return
        self._round += 1
        order = [self._room.member_by_handle(h) for h in self._next_round]
        self._queue = deque(m for m in order if m)
        self._next_round = []
        if not self._queue:
            self._stop_reason = "no_more_mentions"
