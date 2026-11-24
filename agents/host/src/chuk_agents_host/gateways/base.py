"""The gateway seam (CHAT-184, docs/agents/GATEWAYS.md).

A gateway lets the user talk to an agent from a chat network (Telegram first;
Matrix or Discord later) without the app. It runs inside the host process.

Two halves:

- :class:`GatewayHost` is what the host gives a gateway: start a run, stop a
  run, answer an approval, see the agents, observe the events of the runs.
  :class:`chuk_agents_host.gateways.host_bridge.HostBridge` is the real one;
  tests use a fake.
- :class:`Gateway` is what every gateway gives the host: ``start``, ``stop``,
  ``status`` and ``owns_run`` (so the host does not notify a second time for
  an answer that the gateway already delivered).

A gateway never reaches the executor or the relay in another way. Its runs
are normal runs of the agent's thread, with ``origin`` set to the gateway
name, so they are in the app history too.
"""

from __future__ import annotations

from abc import ABC, abstractmethod
from typing import Any, Callable, Protocol

#: The marker of a thread that belongs to an agent but is not its main
#: thread. It must be the automations marker: the host and the app resolve
#: the owning agent of ``<agent>#auto-<rest>`` (sandbox, workspace, model),
#: and the app shows such a thread as a chat of that agent.
DERIVED_MARK = "#auto-"


class GatewayHost(Protocol):
    """What the host offers a gateway. Every method is safe to call from any
    thread. ``ready()`` is False while the host has no task server (it was
    restarted and no app connected since)."""

    def ready(self) -> bool: ...

    def subscribe(self, listener: Callable[[dict], None]) -> bool: ...

    def submit(self, session_key: str, prompt: str, meta: dict) -> str | None: ...

    def stop(self, session_key: str) -> int: ...

    def resolve_approval(self, approval_id: str, approved: bool, scope: str | None) -> None: ...

    def agents(self) -> list[dict[str, Any]]: ...

    def default_agent(self) -> str: ...

    def workspace_for(self, session_key: str) -> str | None: ...

    def secret(self, name: str) -> str | None: ...


class Gateway(ABC):
    """One chat network. ``start`` returns at once (the gateway runs its own
    threads); ``stop`` ends them. A gateway that is not configured is never
    built, so ``start`` may assume a usable configuration."""

    #: Short lower-case name: ``telegram``. It is also the run ``origin``.
    name: str = ""

    @abstractmethod
    def start(self) -> None: ...

    @abstractmethod
    def stop(self) -> None: ...

    @abstractmethod
    def status(self) -> dict[str, Any]: ...

    def owns_run(self, run_id: str) -> bool:
        """True when this gateway delivers the answer of ``run_id`` itself."""
        return False


def gateway_session_key(agent_id: str, gateway: str, token: str) -> str:
    """A thread of ``agent_id`` that a gateway opened: ``<agent>#auto-<gw>-<t>``."""
    return f"{agent_id}{DERIVED_MARK}{gateway}-{token}"


def split_message(text: str, limit: int) -> list[str]:
    """Split ``text`` into parts of at most ``limit`` characters. A part ends
    at the last newline (else the last space) in its window when there is one
    in the second half, so a part seldom ends inside a word."""
    text = text or ""
    if limit <= 0:
        raise ValueError("limit must be positive")
    parts: list[str] = []
    while len(text) > limit:
        window = text[:limit]
        cut = window.rfind("\n")
        if cut < limit // 2:
            cut = window.rfind(" ")
        if cut < limit // 2:
            cut = limit
        parts.append(text[:cut])
        # A cut at a separator drops it; a hard cut keeps every character.
        text = text[cut + 1:] if cut < limit else text[cut:]
    if text or not parts:
        parts.append(text)
    return parts
