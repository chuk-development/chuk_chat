"""Agents on several computers of one user (CHAT-177).

Four tools, bound by the executor to one run when the host has linked peer
hosts (``chuk_agents_host.peer_hub.PeerTools``):

- ``share_file(path)``: put a workspace file into the host's shared store and
  get a reference ``{host_id, sha256, name, size}``. In a group the host also
  posts the reference to the group.
- ``fetch_file(ref)``: get a shared file from any of the user's computers into
  ``.agents/inbox/<sha256>/<name>`` of the own workspace.
- ``send_file_to_agent(agent, path)``: share a file and put it into another
  agent's inbox.
- ``ask_agent(agent, text)``: send one question to another agent (``name`` or
  ``name@computer``) and get its answer.

``None`` registers nothing, so a run on a host without peers has no extra
tool in its prompt.
"""

from __future__ import annotations

from typing import Protocol

from .registry import ToolRegistry

SHARE_FILE_SCHEMA = {
    "type": "object",
    "description": (
        "Share a file of your workspace with agents on the user's other "
        "computers. Returns a ref {host_id, sha256, name, size}."
    ),
    "properties": {"path": {"type": "string", "description": "Workspace path."}},
    "required": ["path"],
}

FETCH_FILE_SCHEMA = {
    "type": "object",
    "description": (
        "Get a shared file (a ref from share_file) into your workspace. "
        "Returns its path."
    ),
    "properties": {
        "ref": {
            "type": "object",
            "description": "The ref: {host_id, sha256, name, size}.",
        }
    },
    "required": ["ref"],
}

SEND_FILE_TO_AGENT_SCHEMA = {
    "type": "object",
    "description": "Send a file of your workspace to another agent's workspace.",
    "properties": {
        "agent": {"type": "string", "description": "Agent name, or name@computer."},
        "path": {"type": "string", "description": "Workspace path."},
    },
    "required": ["agent", "path"],
}

ASK_AGENT_SCHEMA = {
    "type": "object",
    "description": (
        "Ask another agent of the user (also on another computer) and get its "
        "answer. Self-contained text."
    ),
    "properties": {
        "agent": {"type": "string", "description": "Agent name, or name@computer."},
        "text": {"type": "string"},
    },
    "required": ["agent", "text"],
}

#: The tool names, in registration order.
PEER_TOOL_NAMES = ("share_file", "fetch_file", "send_file_to_agent", "ask_agent")


class PeerToolsBackend(Protocol):
    def share_file(self, path: str) -> dict: ...

    def fetch_file(self, ref: object) -> dict: ...

    def send_file_to_agent(self, agent: str, path: str) -> dict: ...

    def ask_agent(self, agent: str, text: str) -> dict: ...


def _guard(call):
    try:
        return call()
    except Exception as exc:  # noqa: BLE001 — a tool error, not a dead run
        return {"ok": False, "error": type(exc).__name__}


def register_peer_tools(registry: ToolRegistry, backend: PeerToolsBackend | None) -> None:
    """Register the four tools for one run. ``None`` registers nothing."""
    if backend is None:
        return

    def share_file(path: str) -> dict:
        return _guard(lambda: backend.share_file(str(path or "")))

    def fetch_file(ref: object) -> dict:
        return _guard(lambda: backend.fetch_file(ref))

    def send_file_to_agent(agent: str, path: str) -> dict:
        return _guard(lambda: backend.send_file_to_agent(str(agent or ""), str(path or "")))

    def ask_agent(agent: str, text: str) -> dict:
        return _guard(lambda: backend.ask_agent(str(agent or ""), str(text or "")))

    registry.register("share_file", SHARE_FILE_SCHEMA, share_file)
    registry.register("fetch_file", FETCH_FILE_SCHEMA, fetch_file)
    registry.register("send_file_to_agent", SEND_FILE_TO_AGENT_SCHEMA, send_file_to_agent)
    registry.register("ask_agent", ASK_AGENT_SCHEMA, ask_agent)


__all__ = [
    "PEER_TOOL_NAMES",
    "PeerToolsBackend",
    "register_peer_tools",
]
