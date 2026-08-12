"""Stub supervisor lifecycle — start/stop/status idempotence."""

from __future__ import annotations

from cowork_manager.supervisor import RuntimeStatus, StubSupervisor


def test_status_defaults_to_stopped() -> None:
    sup = StubSupervisor()
    st = sup.status("amber-otter")
    assert st.agent_id == "amber-otter"
    assert st.status is RuntimeStatus.STOPPED


def test_start_then_status_running() -> None:
    sup = StubSupervisor()
    started = sup.start("amber-otter")
    assert started.status is RuntimeStatus.RUNNING
    assert started.container_id == "stub-amber-otter"
    assert started.started_at is not None
    assert sup.status("amber-otter").status is RuntimeStatus.RUNNING
    assert sup.running() == ["amber-otter"]


def test_start_is_idempotent() -> None:
    sup = StubSupervisor()
    first = sup.start("a")
    second = sup.start("a")
    assert first == second  # same snapshot, not restarted


def test_stop_transitions_and_is_idempotent() -> None:
    sup = StubSupervisor()
    sup.start("a")
    stopped = sup.stop("a")
    assert stopped.status is RuntimeStatus.STOPPED
    assert stopped.container_id is None
    # Stopping an already-stopped agent is safe.
    assert sup.stop("a").status is RuntimeStatus.STOPPED
    assert sup.running() == []
