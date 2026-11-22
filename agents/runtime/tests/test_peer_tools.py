"""The peer tools (CHAT-177): registered only with a backend, and a backend
error is a tool result, never a dead run."""

from __future__ import annotations

from chuk_agents_runtime.peer_tools import PEER_TOOL_NAMES, register_peer_tools
from chuk_agents_runtime.registry import ToolRegistry


class Backend:
    def __init__(self) -> None:
        self.calls: list[tuple] = []

    def share_file(self, path):
        self.calls.append(("share_file", path))
        return {"ok": True, "ref": {"sha256": "a" * 64}}

    def fetch_file(self, ref):
        self.calls.append(("fetch_file", ref))
        return {"ok": True, "path": ".agents/inbox/x/y"}

    def send_file_to_agent(self, agent, path):
        self.calls.append(("send_file_to_agent", agent, path))
        return {"ok": True}

    def ask_agent(self, agent, text):
        raise RuntimeError("boom")


def test_no_backend_registers_nothing():
    registry = ToolRegistry()
    register_peer_tools(registry, None)
    assert not any(registry.has(name) for name in PEER_TOOL_NAMES)


def test_the_four_tools_reach_the_backend():
    registry = ToolRegistry()
    backend = Backend()
    register_peer_tools(registry, backend)
    assert all(registry.has(name) for name in PEER_TOOL_NAMES)
    assert registry.spec("share_file").handler(path="out.csv")["ok"] is True
    assert registry.spec("fetch_file").handler(ref={"sha256": "a" * 64})["ok"] is True
    assert registry.spec("send_file_to_agent").handler(agent="bob", path="p")["ok"] is True
    assert registry.spec("ask_agent").handler(agent="bob", text="hi") == {
        "ok": False,
        "error": "RuntimeError",
    }
    assert [c[0] for c in backend.calls] == ["share_file", "fetch_file", "send_file_to_agent"]


def test_descriptions_stay_short():
    registry = ToolRegistry()
    register_peer_tools(registry, Backend())
    for name in PEER_TOOL_NAMES:
        assert len(registry.spec(name).schema["description"]) <= 160
