"""A stalled optional memory service cannot stall foreground chat streaming."""

import threading
import time

from chuk_agents_runtime.memory import MemoryStore


def test_slow_recall_is_bounded_and_cannot_queue_more_workers(tmp_path, monkeypatch):
    memory = MemoryStore(tmp_path, seed_defaults=False)
    entered, release, finished = threading.Event(), threading.Event(), threading.Event()
    calls = []

    def slow(query, **kwargs):
        calls.append(query)
        entered.set()
        try:
            assert release.wait(2)
            return [{'content': 'late result'}]
        finally:
            finished.set()

    monkeypatch.setattr(memory, 'recall_messages', slow)
    try:
        start = time.monotonic()
        assert memory.recall_messages_bounded('Hey', timeout=0.01) == []
        assert entered.is_set()
        assert time.monotonic() - start < 0.5
        # Subsequent turns do not build unbounded blocked worker queues.
        assert memory.recall_messages_bounded('another question', timeout=0.01) == []
        assert calls == ['Hey']
    finally:
        release.set()
        assert finished.wait(2)
        # Join the admitted worker before leaving global semaphore to next test.
        for thread in threading.enumerate():
            if thread.name == 'memory-recall':
                thread.join(2)


def test_fast_recall_keeps_the_existing_context_shape(tmp_path, monkeypatch):
    memory = MemoryStore(tmp_path, seed_defaults=False)
    rows = [{'role_tag': 'memory', 'role': 'user', 'content': 'remembered'}]
    monkeypatch.setattr(memory, 'recall_messages', lambda *a, **k: rows)
    assert memory.recall_messages_bounded('Hey', timeout=1) == rows


def test_runtime_foreground_uses_bounded_recall(tmp_path):
    from chuk_agents_runtime import LocalEnvironment, MockModelClient, build_runtime

    class Writer(MockModelClient):
        def cheap_clone(self):
            return MockModelClient(['{}'])

    loop = build_runtime(MockModelClient(['done']),
                         db_path=str(tmp_path / 'state.db'),
                         workspace=str(tmp_path), environment=LocalEnvironment(),
                         aux_model=Writer(['{}']))
    assert loop._recall_provider.__name__ == 'recall_messages_bounded'


def test_chat_reaches_model_while_memory_service_is_still_blocked(tmp_path, monkeypatch):
    from chuk_agents_runtime import LocalEnvironment, MockModelClient, build_runtime

    entered, release = threading.Event(), threading.Event()

    class Writer(MockModelClient):
        def cheap_clone(self):
            return MockModelClient(['{}'])

    def slow_recall(self, query, **kwargs):
        entered.set()
        assert release.wait(3)
        return [{'role_tag': 'memory', 'role': 'user', 'content': 'late'}]

    monkeypatch.setattr(MemoryStore, 'recall_messages', slow_recall)
    monkeypatch.setattr(MemoryStore, 'observe_turn', lambda *a, **k: None)
    model = MockModelClient(['Hello'])
    loop = build_runtime(model, db_path=str(tmp_path / 'state.db'),
                         workspace=str(tmp_path), environment=LocalEnvironment(),
                         aux_model=Writer(['{}']))
    try:
        start = time.monotonic()
        result = loop.run('test', 'Hey')
        assert entered.is_set() and not release.is_set()
        assert result.final_answer == 'Hello'
        assert time.monotonic() - start < 1
        assert len(model.calls) == 1
        assert all(m.role != 'memory' for m in loop.store.get_conversation(result.session_id))
    finally:
        release.set()
        for thread in threading.enumerate():
            if thread.name == 'memory-recall':
                thread.join(3)
