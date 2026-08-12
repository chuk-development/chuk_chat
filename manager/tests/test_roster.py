"""Roster CRUD + unique-name assignment."""

from __future__ import annotations

import random

import pytest

from cowork_manager.roster import RosterStore


@pytest.fixture
def store() -> RosterStore:
    s = RosterStore(":memory:")
    yield s
    s.close()


def test_create_assigns_name_and_id(store: RosterStore) -> None:
    agent = store.create(workspace_dir="/w/a", persona="fetch crypto news")
    assert agent.id
    assert "-" in agent.name  # adjective-noun
    assert agent.workspace_dir == "/w/a"
    assert agent.persona == "fetch crypto news"
    assert agent.created_at

    fetched = store.get(agent.id)
    assert fetched == agent


def test_create_with_explicit_name(store: RosterStore) -> None:
    agent = store.create(workspace_dir="/w", name="amber-otter")
    assert agent.name == "amber-otter"
    assert store.get_by_name("amber-otter") == agent


def test_names_are_unique_across_many_creates(store: RosterStore) -> None:
    # Deterministic RNG that would collide freely if uniqueness were not enforced.
    rng = random.Random(1234)
    names = set()
    for _ in range(40):
        agent = store.create(workspace_dir="/w", rng=rng)
        assert agent.name not in names, "roster handed out a duplicate name"
        names.add(agent.name)
    assert len(store.list()) == 40


def test_duplicate_explicit_name_rejected(store: RosterStore) -> None:
    store.create(workspace_dir="/w", name="amber-otter")
    with pytest.raises(Exception):
        store.create(workspace_dir="/w", name="amber-otter")


def test_list_is_ordered_and_complete(store: RosterStore) -> None:
    a = store.create(workspace_dir="/1", name="a-one")
    b = store.create(workspace_dir="/2", name="b-two")
    c = store.create(workspace_dir="/3", name="c-three")
    ids = [ag.id for ag in store.list()]
    assert ids == [a.id, b.id, c.id]


def test_update_patches_mutable_fields(store: RosterStore) -> None:
    agent = store.create(workspace_dir="/w", schedule="every 30m")
    updated = store.update(
        agent.id, persona="new job", schedule="0 9 * * *", platform="linux"
    )
    assert updated is not None
    assert updated.persona == "new job"
    assert updated.schedule == "0 9 * * *"
    assert updated.platform == "linux"
    assert updated.name == agent.name  # identity immutable
    assert updated.workspace_dir == "/w"  # untouched field preserved


def test_update_missing_returns_none(store: RosterStore) -> None:
    assert store.update("nope", persona="x") is None


def test_delete(store: RosterStore) -> None:
    agent = store.create(workspace_dir="/w")
    assert store.delete(agent.id) is True
    assert store.get(agent.id) is None
    assert store.delete(agent.id) is False
