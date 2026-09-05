"""The automatic memory (bead cowork-2tq.3) is wired by ``build_runtime`` only
for a real backend writer. With the scripted mock as the only model — every
unit test — no recall row is injected, no extraction runs, no Mem0 is built:
the mock's replies belong to the loop, not to a fact extractor."""

from __future__ import annotations

from cowork_agent import LocalEnvironment, MockModelClient, build_runtime
from cowork_agent.memory import MemoryStore


def test_a_mock_writer_gets_no_automatic_memory(tmp_path, monkeypatch):
    built: list[str] = []
    monkeypatch.setattr(
        MemoryStore, "_memory", lambda self: built.append("built") or None
    )
    workspace = tmp_path / "ws"
    workspace.mkdir()
    model = MockModelClient(["done"])
    loop = build_runtime(
        model,
        db_path=str(tmp_path / "s.db"),
        environment=LocalEnvironment(),
        workspace=str(workspace),
    )
    result = loop.run("s1", "hi")
    assert result.final_answer == "done"
    # Exactly the loop's own call reached the mock; no extractor prompt.
    assert len(model.calls) == 1
    assert not any(
        "Memory Extractor" in str(m.get("content", "")) for m in model.calls[0]
    )
    rows = loop.store.get_conversation(result.session_id)
    assert [m.role for m in rows] == ["system", "user", "assistant"]
    # Mem0 was never even built for this run.
    assert built == []
    # The explicit tools are still there for the model.
    assert loop.registry.has("memory_search") and loop.registry.has("memory_add")


def test_a_clonable_writer_switches_the_automatic_memory_on(tmp_path):
    class Writer(MockModelClient):
        def cheap_clone(self):
            return MockModelClient(["{}"])

    workspace = tmp_path / "ws"
    workspace.mkdir()
    loop = build_runtime(
        MockModelClient(["done"]),
        db_path=str(tmp_path / "s.db"),
        environment=LocalEnvironment(),
        workspace=str(workspace),
        aux_model=Writer(["{}"]),
    )
    assert loop._recall_provider is not None
    assert loop._turn_observer is not None
