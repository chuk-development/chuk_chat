"""``hand_off_tasks`` (§16.1 lead mode): only a lead's run gets it."""

from chuk_agents_runtime.registry import ToolRegistry
from chuk_agents_runtime.room_handoff import register_handoff_tools


class _Backend:
    def __init__(self):
        self.calls = []

    def members(self):
        return [{"handle": "cobalt", "name": "Cobalt"}]

    def hand_off(self, tasks):
        self.calls.append(tasks)
        return {"ok": True, "accepted": [{"member": "cobalt"}]}


def test_no_backend_registers_nothing():
    registry = ToolRegistry()
    register_handoff_tools(registry, None)
    assert not registry.has("hand_off_tasks")


def test_the_tool_passes_tasks_to_the_backend():
    registry = ToolRegistry()
    backend = _Backend()
    register_handoff_tools(registry, backend)
    handler = registry.spec("hand_off_tasks").handler
    assert handler(tasks=[{"member": "cobalt", "task": "x"}])["ok"] is True
    assert backend.calls == [[{"member": "cobalt", "task": "x"}]]


def test_a_backend_error_is_a_tool_error():
    class Broken(_Backend):
        def hand_off(self, tasks):
            raise RuntimeError("boom")

    registry = ToolRegistry()
    register_handoff_tools(registry, Broken())
    assert registry.spec("hand_off_tasks").handler(tasks=[])["ok"] is False
