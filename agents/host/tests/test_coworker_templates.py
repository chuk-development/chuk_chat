"""Coworker templates: an ``agent_create`` with a ``template`` seeds soul.md.

The app sends the template's persona with the create frame
(docs/WIRE_CONTRACT.md, "Coworker templates"). The host writes it into the new
coworker's own ``memory/soul.md`` — never into its own agent's, never over a
soul.md somebody already changed.
"""

from __future__ import annotations

from pathlib import Path

from chuk_agents_executor.protocol import agent_create_payload

from chuk_agents_host import LocalHost
from chuk_agents_host.coworker_templates import (
    MAX_PERSONA_LEN,
    SOUL_RELATIVE,
    seed_persona,
    soul_text,
    template_seed,
)

PERSONA = "You are a research assistant.\n- Link every claim to its source."


def _create(agent_id: str = "local:Researcher:0:7", **template) -> dict:
    return agent_create_payload(
        agent_id=agent_id,
        name="Researcher",
        template=template or {"id": "research", "persona": PERSONA},
    )


# -- the frame -------------------------------------------------------------


def test_payload_helper_is_additive():
    assert agent_create_payload(agent_id="a", name="n") == {
        "type": "agent_create",
        "agent_id": "a",
        "name": "n",
    }
    assert _create()["template"] == {"id": "research", "persona": PERSONA}


def test_template_seed_reads_id_and_persona():
    assert template_seed(_create()) == ("research", PERSONA)


def test_template_seed_ignores_everything_else():
    assert template_seed({"type": "agent_rename", "template": {"persona": "x"}}) is None
    assert template_seed(agent_create_payload(agent_id="a", name="n")) is None
    assert template_seed({"type": "agent_create", "template": "research"}) is None
    assert template_seed(_create(id="research", persona="   ")) is None
    assert template_seed(_create(id="research", persona=7)) is None
    assert template_seed(_create(id="x", persona="a" * (MAX_PERSONA_LEN + 1))) is None
    # A strange id does not drop the persona; it is only logged as "custom".
    assert template_seed(_create(id="../etc", persona=PERSONA)) == ("custom", PERSONA)


# -- the file --------------------------------------------------------------


def test_seed_writes_soul_into_a_fresh_workspace(tmp_path: Path):
    assert seed_persona(tmp_path, PERSONA, template_id="research") is True
    text = (tmp_path / SOUL_RELATIVE).read_text(encoding="utf-8")
    assert text == soul_text(PERSONA, template_id="research")
    assert text.startswith("# Soul\n")
    assert PERSONA in text


def test_seed_replaces_the_packaged_default(tmp_path: Path):
    from chuk_agents_runtime import memory as runtime_memory

    soul = tmp_path / SOUL_RELATIVE
    soul.parent.mkdir(parents=True)
    soul.write_text(runtime_memory._default_template("soul"), encoding="utf-8")
    assert seed_persona(tmp_path, PERSONA, template_id="research") is True
    assert PERSONA in soul.read_text(encoding="utf-8")


def test_seed_never_overwrites_a_changed_soul(tmp_path: Path):
    soul = tmp_path / SOUL_RELATIVE
    soul.parent.mkdir(parents=True)
    soul.write_text("# Soul\n\nI am the user's own words.\n", encoding="utf-8")
    assert seed_persona(tmp_path, PERSONA, template_id="research") is False
    assert soul.read_text(encoding="utf-8") == "# Soul\n\nI am the user's own words.\n"


def test_runtime_reads_the_seeded_persona(tmp_path: Path):
    """The point of the file: the coworker's prompt snapshot carries it."""
    from chuk_agents_runtime.memory import MemoryStore

    seed_persona(tmp_path, PERSONA, template_id="research")
    snapshot = MemoryStore(tmp_path / "memory").snapshot()
    assert "Link every claim to its source." in snapshot


# -- the host --------------------------------------------------------------


def _host(tmp_path) -> LocalHost:
    return LocalHost(
        port=0,
        workspace_dir=str(tmp_path / "agents"),
        channel_id="testchannel",
        agent_name="pytest-agent",
        model_factory_override=lambda: None,
    )


def test_host_seeds_the_new_coworker_on_agent_create(tmp_path):
    host = _host(tmp_path)
    try:
        listed = host._on_agent_frame(_create())
        workspace = Path(host._workspace_for_agent("local:Researcher:0:7"))
        own = Path(host._workspace_for_agent(host._agent.id))
    finally:
        host._roster.close()
        host._coworker_names.close()

    # The name is kept and the list answered, as before.
    assert any(row["agent_id"] == "local:Researcher:0:7" for row in listed)
    assert PERSONA in (workspace / SOUL_RELATIVE).read_text(encoding="utf-8")
    # The host's own agent is not touched.
    assert workspace != own
    own_soul = own / SOUL_RELATIVE
    assert not own_soul.exists() or PERSONA not in own_soul.read_text(encoding="utf-8")


def test_a_repeated_create_does_not_undo_an_edit(tmp_path):
    host = _host(tmp_path)
    try:
        host._on_agent_frame(_create())
        soul = Path(host._workspace_for_agent("local:Researcher:0:7")) / SOUL_RELATIVE
        soul.write_text("# Soul\n\nEdited.\n", encoding="utf-8")
        host._on_agent_frame(_create(id="news", persona="You follow the news."))
        assert soul.read_text(encoding="utf-8") == "# Soul\n\nEdited.\n"
    finally:
        host._roster.close()
        host._coworker_names.close()


def test_a_plain_create_still_works_and_writes_no_persona(tmp_path):
    host = _host(tmp_path)
    try:
        listed = host._on_agent_frame(
            agent_create_payload(agent_id="local:amber:1:2", name="amber")
        )
        workspace = Path(host._workspace_for_agent("local:amber:1:2"))
    finally:
        host._roster.close()
        host._coworker_names.close()
    assert any(row["agent_id"] == "local:amber:1:2" for row in listed)
    soul = workspace / SOUL_RELATIVE
    assert not soul.exists() or "template:" not in soul.read_text(encoding="utf-8")


def test_a_bad_name_registers_nothing_and_seeds_nothing(tmp_path):
    """The persona follows the name store: no registration, no workspace."""
    host = _host(tmp_path)
    try:
        payload = _create()
        payload["name"] = "   "
        host._on_agent_frame(payload)
        assert not host._is_own_coworker("local:Researcher:0:7")
        assert not list((tmp_path / "agents").rglob("soul.md")) or all(
            PERSONA not in p.read_text(encoding="utf-8")
            for p in (tmp_path / "agents").rglob("soul.md")
        )
    finally:
        host._roster.close()
        host._coworker_names.close()
