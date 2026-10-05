"""Save a successful task as a skill (bead chuk_chat-al2u, docs/WIRE_CONTRACT.md
"Skill proposals").

The agent may only PROPOSE: ``propose_skill`` scrubs and validates a draft and
hands it to the host's sink. Nothing lands in ``skills/`` until the user's
accept, and the next task then finds the skill in its catalogue.
"""

from __future__ import annotations

import pytest

from chuk_agents_runtime import (
    LocalEnvironment,
    MockModelClient,
    build_runtime,
    load_skills,
    tool_call_response,
)
from chuk_agents_runtime.secrets import Scrubber
from chuk_agents_runtime.skill_proposals import (
    MAX_PROPOSAL_BODY_LINES,
    PROPOSE_SKILL_TOOL,
    STATUS_DISMISSED,
    STATUS_INVALID,
    STATUS_NOT_FOUND,
    STATUS_PENDING,
    STATUS_SAVED,
    STATUS_SAVING,
    RecordingProposalSink,
    SkillDraft,
    SkillProposalStore,
    decide_skill_proposal,
    make_propose_skill_handler,
    normalize_draft,
    render_skill_md,
    scrub_draft,
    scrub_text,
    validate_draft,
    write_skill,
)
from chuk_agents_runtime import skill_proposals as skill_proposals_mod
from chuk_agents_runtime.skills import MAX_SKILLS

BODY = (
    "# Export the monthly invoices\n\n"
    "1. Open the billing page with `browser_navigate`.\n"
    "2. Download the CSV.\n"
    "3. Check that the row count matches the page."
)
DESCRIPTION = "Export the monthly invoices as CSV. Load it when the user asks for the invoice export."


def _draft(**kw) -> SkillDraft:
    fields = {"name": "invoice-export", "description": DESCRIPTION, "body": BODY}
    fields.update(kw)
    return normalize_draft(fields["name"], fields["description"], fields["body"])


# -- scrubbing ----------------------------------------------------------------


def test_scrub_removes_vault_values_tokens_and_personal_data():
    vault = Scrubber(lambda: {"SHOP_TOKEN": "s3cr3t-value-123"}).scrub_obj
    text = (
        "use s3cr3t-value-123 and sk-abcdefghijklmnop1234, mail anna@example.com, "
        "call +49 151 2345678, password=hunter2222"
    )
    cleaned = scrub_text(text, vault)
    assert "s3cr3t-value-123" not in cleaned and "[REDACTED:SHOP_TOKEN]" in cleaned
    assert "sk-abcdefghijklmnop1234" not in cleaned
    assert "anna@example.com" not in cleaned and "<email>" in cleaned
    assert "2345678" not in cleaned and "<phone>" in cleaned
    assert "hunter2222" not in cleaned


def test_scrub_keeps_references_to_secrets_and_ordinary_numbers():
    text = (
        "curl -H 'Authorization: Bearer $SHOP_TOKEN' "
        "token=${API_TOKEN} api_key=os.environ['KEY'] version 1.2.3 on 2026-10-05"
    )
    assert scrub_text(text) == text


def test_scrub_draft_reports_whether_it_removed_something():
    clean, changed = scrub_draft(_draft())
    assert not changed and clean == _draft()
    dirty, changed = scrub_draft(_draft(body=BODY + "\nSend it to anna@example.com."))
    assert changed and "anna@example.com" not in dirty.body


# -- validation ---------------------------------------------------------------


def test_a_good_draft_is_valid_and_reads_back_unchanged():
    draft = _draft(description='Export the "monthly" invoices.\n  Use it for C:\\exports.')
    assert validate_draft(draft) == []
    # Quotes and backslashes are replaced: the description is a YAML scalar.
    assert draft.description == "Export the 'monthly' invoices. Use it for C:/exports."
    text = render_skill_md(draft)
    assert text.startswith("---\nname: invoice-export\n")


@pytest.mark.parametrize(
    ("fields", "reason"),
    [
        ({"name": ""}, "name is empty"),
        ({"name": "Invoice Export"}, "invalid name"),
        ({"name": "invoice--export"}, "invalid name"),
        ({"name": "-invoice"}, "invalid name"),
        ({"name": "a" * 65}, "the limit is 64"),
        ({"description": ""}, "description is empty"),
        ({"description": "x" * 301}, "the limit is 300"),
        ({"body": "  "}, "body is empty"),
        ({"body": "\n".join(["step"] * (MAX_PROPOSAL_BODY_LINES + 1))}, "lines"),
    ],
)
def test_validation_names_every_reason(fields, reason):
    errors = validate_draft(_draft(**fields))
    assert errors and any(reason in error for error in errors), errors


def test_a_description_of_exactly_300_characters_is_accepted():
    assert validate_draft(_draft(description="x" * 300)) == []


# -- the tool -----------------------------------------------------------------


def test_the_tool_hands_a_scrubbed_draft_to_the_sink(tmp_path):
    sink = RecordingProposalSink()
    handler = make_propose_skill_handler(sink, skills_root=tmp_path / "skills")
    result = handler("invoice-export", DESCRIPTION, BODY + "\nAsk anna@example.com.")
    assert result["ok"] is True and result["status"] == "waiting_for_user"
    assert result["proposal_id"] == "sp_1" and "scrubbed" in result
    (draft,) = sink.drafts
    assert "anna@example.com" not in draft.body
    assert sink.roots == [str(tmp_path / "skills")]
    # Nothing is written by the tool: only the user's accept writes.
    assert not (tmp_path / "skills").exists()


def test_the_tool_offers_one_skill_per_task(tmp_path):
    sink = RecordingProposalSink()
    handler = make_propose_skill_handler(sink, skills_root=tmp_path)
    assert handler("one", DESCRIPTION, BODY)["ok"] is True
    second = handler("two", DESCRIPTION, BODY)
    assert second["ok"] is False and "one offer per task" in second["error"]
    assert len(sink.drafts) == 1


def test_the_tool_refuses_an_invalid_draft_or_a_taken_name(tmp_path):
    root = tmp_path / "skills"
    (root / "deploy").mkdir(parents=True)
    sink = RecordingProposalSink()
    handler = make_propose_skill_handler(sink, skills_root=root)
    bad = handler("Bad Name", DESCRIPTION, BODY)
    assert bad["ok"] is False and "invalid name" in bad["error"]
    taken = handler("deploy", DESCRIPTION, BODY)
    assert taken["ok"] is False and "already exists" in taken["error"]
    assert sink.drafts == []
    # A refused draft is not the one offer of the task.
    assert handler("deploy-v2", DESCRIPTION, BODY)["ok"] is True


def test_a_failing_sink_is_reported_to_the_model(tmp_path):
    handler = make_propose_skill_handler(RecordingProposalSink(ok=False), skills_root=tmp_path)
    result = handler("invoice-export", DESCRIPTION, BODY)
    assert result == {"ok": False, "error": "refused"}


def test_build_runtime_offers_the_tool_deferred_only_with_a_sink(tmp_path):
    kwargs = dict(
        db_path=str(tmp_path / "s.db"), workspace=str(tmp_path),
        version_workspace=False, enable_memory=False, enable_mcp=False,
    )
    with_sink = build_runtime(
        MockModelClient(["ok"]), skill_proposals=RecordingProposalSink(), **kwargs
    )
    assert with_sink.registry.has(PROPOSE_SKILL_TOOL)
    assert with_sink.registry.available(PROPOSE_SKILL_TOOL)
    assert with_sink.registry.is_deferred(PROPOSE_SKILL_TOOL)
    without = build_runtime(MockModelClient(["ok"]), **kwargs)
    assert not without.registry.has(PROPOSE_SKILL_TOOL)


def test_the_prompt_tells_the_model_when_to_offer_a_skill(tmp_path):
    model = MockModelClient(["ok"])
    loop = build_runtime(
        model, db_path=str(tmp_path / "s.db"), workspace=str(tmp_path),
        version_workspace=False, enable_memory=False, enable_mcp=False,
    )
    loop.run("s", "hi")
    system = model.calls[0][0]["content"]
    assert "`propose_skill`" in system and "remember how to do this" in system


# -- the store and the decision -----------------------------------------------


def _pending(tmp_path, draft: SkillDraft | None = None) -> tuple[SkillProposalStore, str, object]:
    store = SkillProposalStore(tmp_path / "state.db")
    root = tmp_path / "ws" / "skills"
    pid = store.add(draft or _draft(), session_key="agent-1", skills_root=str(root), run_id="r1")
    return store, pid, root


def test_accept_writes_the_skill_and_the_next_catalogue_shows_it(tmp_path):
    store, pid, root = _pending(tmp_path)
    result = decide_skill_proposal(store, proposal_id=pid, accept=True)
    assert result["status"] == STATUS_SAVED and result["errors"] == []
    path = root / "invoice-export" / "SKILL.md"
    assert result["path"] == str(path) and path.is_file()
    library = load_skills(root)
    assert library.errors == []
    assert library.skills["invoice-export"].description == DESCRIPTION
    assert "`invoice-export` — Export the monthly invoices" in library.catalog()
    assert store.get(pid)["status"] == STATUS_SAVED
    # No temp file is left beside it.
    assert [p.name for p in path.parent.iterdir()] == ["SKILL.md"]


def test_accept_with_the_users_edits_saves_the_edits(tmp_path):
    store, pid, root = _pending(tmp_path)
    result = decide_skill_proposal(
        store, proposal_id=pid, accept=True,
        name="invoices", description="Export invoices.", body="# Invoices\n\n1. Do it.",
    )
    assert result["status"] == STATUS_SAVED and result["name"] == "invoices"
    skill = load_skills(root).skills["invoices"]
    assert skill.description == "Export invoices." and skill.body == "# Invoices\n\n1. Do it."
    assert store.get(pid)["name"] == "invoices"
    assert not (root / "invoice-export").exists()


def test_an_invalid_edit_is_refused_and_the_draft_stays_pending(tmp_path):
    store, pid, root = _pending(tmp_path)
    bad = decide_skill_proposal(store, proposal_id=pid, accept=True, description="x" * 301)
    assert bad["status"] == STATUS_INVALID and "the limit is 300" in bad["errors"][0]
    assert store.get(pid)["status"] == STATUS_PENDING
    assert not root.exists()
    good = decide_skill_proposal(store, proposal_id=pid, accept=True)
    assert good["status"] == STATUS_SAVED


def test_user_edits_are_scrubbed_too(tmp_path):
    store, pid, root = _pending(tmp_path)
    vault = Scrubber(lambda: {"SHOP_TOKEN": "s3cr3t-value-123"}).scrub_obj
    result = decide_skill_proposal(
        store, proposal_id=pid, accept=True, body="# X\n\nUse s3cr3t-value-123.", vault=vault
    )
    assert result["status"] == STATUS_SAVED and result["scrubbed"] is True
    assert "s3cr3t-value-123" not in (root / "invoice-export" / "SKILL.md").read_text()


def test_a_name_taken_since_the_proposal_is_refused(tmp_path):
    store, pid, root = _pending(tmp_path)
    (root / "invoice-export").mkdir(parents=True)
    result = decide_skill_proposal(store, proposal_id=pid, accept=True)
    assert result["status"] == STATUS_INVALID and "already exists" in result["errors"][0]
    assert store.get(pid)["status"] == STATUS_PENDING


def test_a_full_workspace_is_refused(tmp_path):
    store, pid, root = _pending(tmp_path)
    for index in range(MAX_SKILLS):
        (root / f"s{index}").mkdir(parents=True)
    result = decide_skill_proposal(store, proposal_id=pid, accept=True)
    assert result["status"] == STATUS_INVALID and "delete one first" in result["errors"][0]


def test_reject_drops_the_draft_and_writes_nothing(tmp_path):
    store, pid, root = _pending(tmp_path)
    result = decide_skill_proposal(store, proposal_id=pid, accept=False)
    assert result["status"] == STATUS_DISMISSED
    assert store.get(pid)["status"] == STATUS_DISMISSED
    assert not root.exists()
    # A later accept of the same card changes nothing.
    again = decide_skill_proposal(store, proposal_id=pid, accept=True)
    assert again["status"] == STATUS_DISMISSED and again["already_decided"] is True
    assert not root.exists()


def test_an_unknown_proposal_is_reported(tmp_path):
    store, _pid, _root = _pending(tmp_path)
    result = decide_skill_proposal(store, proposal_id="sp_nope", accept=True)
    assert result["status"] == STATUS_NOT_FOUND and result["errors"] == ["no skill proposal 'sp_nope'"]


def test_a_second_accept_during_the_write_is_already_decided_and_writes_nothing(
    tmp_path, monkeypatch
):
    store, pid, root = _pending(tmp_path)
    real_write = skill_proposals_mod.write_skill
    writes: list[str] = []
    inner: list[dict] = []

    def racing_write(target_root, draft):
        writes.append(draft.name)
        if len(writes) == 1:
            # Another device accepts (with its own edit) while this one writes.
            inner.append(
                decide_skill_proposal(store, proposal_id=pid, accept=True, name="other-name")
            )
        return real_write(target_root, draft)

    monkeypatch.setattr(skill_proposals_mod, "write_skill", racing_write)
    first = decide_skill_proposal(store, proposal_id=pid, accept=True)
    assert first["status"] == STATUS_SAVED
    assert inner[0]["status"] == STATUS_SAVING and inner[0]["already_decided"] is True
    assert writes == ["invoice-export"]
    assert not (root / "other-name").exists()
    assert store.get(pid)["status"] == STATUS_SAVED
    again = decide_skill_proposal(store, proposal_id=pid, accept=True)
    assert again["status"] == STATUS_SAVED and again["already_decided"] is True


def test_a_dismiss_during_the_write_is_already_decided_and_the_save_wins(
    tmp_path, monkeypatch
):
    store, pid, root = _pending(tmp_path)
    real_write = skill_proposals_mod.write_skill
    inner: list[dict] = []

    def racing_write(target_root, draft):
        inner.append(decide_skill_proposal(store, proposal_id=pid, accept=False))
        return real_write(target_root, draft)

    monkeypatch.setattr(skill_proposals_mod, "write_skill", racing_write)
    first = decide_skill_proposal(store, proposal_id=pid, accept=True)
    assert inner[0]["status"] == STATUS_SAVING and inner[0]["already_decided"] is True
    assert first["status"] == STATUS_SAVED
    assert store.get(pid)["status"] == STATUS_SAVED
    assert (root / "invoice-export" / "SKILL.md").is_file()


def test_an_accept_after_a_dismiss_writes_nothing(tmp_path):
    store, pid, root = _pending(tmp_path)
    assert store.decide(pid, STATUS_DISMISSED)
    late = decide_skill_proposal(store, proposal_id=pid, accept=False)
    assert late["status"] == STATUS_DISMISSED and late["already_decided"] is True
    assert not root.exists()


def test_a_failed_write_gives_the_draft_back(tmp_path, monkeypatch):
    store, pid, root = _pending(tmp_path)

    def failing_write(target_root, draft):
        assert store.get(pid)["status"] == STATUS_SAVING
        raise OSError("disk full")

    monkeypatch.setattr(skill_proposals_mod, "write_skill", failing_write)
    result = decide_skill_proposal(store, proposal_id=pid, accept=True)
    assert result["status"] == STATUS_INVALID and "disk full" in result["errors"][0]
    assert store.get(pid)["status"] == STATUS_PENDING
    monkeypatch.undo()
    assert decide_skill_proposal(store, proposal_id=pid, accept=True)["status"] == STATUS_SAVED


def test_a_stale_saving_claim_can_be_taken_over(tmp_path, monkeypatch):
    store, pid, _root = _pending(tmp_path)
    assert store.claim_for_save(pid)
    assert not store.claim_for_save(pid)
    later = skill_proposals_mod.time.time() + skill_proposals_mod.SAVING_STALE_SECONDS + 1
    monkeypatch.setattr(skill_proposals_mod.time, "time", lambda: later)
    assert store.claim_for_save(pid)


def test_a_failed_write_removes_the_temp_file_and_the_new_directory(tmp_path, monkeypatch):
    root = tmp_path / "skills"

    def broken_replace(src, dst):
        raise OSError("rename failed")

    monkeypatch.setattr(skill_proposals_mod.os, "replace", broken_replace)
    with pytest.raises(OSError):
        write_skill(root, _draft())
    assert not (root / "invoice-export").exists()
    # A directory that was there before stays, only the temp file goes.
    (root / "invoice-export").mkdir(parents=True)
    (root / "invoice-export" / "notes.txt").write_text("keep")
    with pytest.raises(OSError):
        write_skill(root, _draft())
    assert [p.name for p in (root / "invoice-export").iterdir()] == ["notes.txt"]


# -- end to end in one runtime ------------------------------------------------


class _StoreSink:
    """The executor's sink in miniature: store the draft, nothing else."""

    def __init__(self, store: SkillProposalStore) -> None:
        self.store = store
        self.ids: list[str] = []

    def submit(self, draft: SkillDraft, *, skills_root: str) -> dict:
        pid = self.store.add(draft, session_key="s1", skills_root=skills_root)
        self.ids.append(pid)
        return {"ok": True, "proposal_id": pid}


def test_proposed_then_accepted_skill_is_in_the_next_tasks_catalogue(tmp_path):
    workspace = tmp_path / "ws"
    db = str(tmp_path / "s.db")
    store = SkillProposalStore(db)
    sink = _StoreSink(store)
    model = MockModelClient(
        [
            tool_call_response(
                (PROPOSE_SKILL_TOOL, {"name": "invoice-export", "description": DESCRIPTION, "body": BODY})
            ),
            "Done. I offered to save this as a skill.",
            "second task",
        ]
    )
    loop = build_runtime(
        model, db_path=db, environment=LocalEnvironment(), workspace=str(workspace),
        version_workspace=False, enable_memory=False, enable_mcp=False,
        skill_proposals=sink,
    )
    first = loop.run("s1", "export the invoices")
    assert first.final_answer == "Done. I offered to save this as a skill."
    (pid,) = sink.ids
    # Proposed, not installed: the skills directory holds nothing yet.
    assert load_skills(workspace / "skills").skills == {}

    assert decide_skill_proposal(store, proposal_id=pid, accept=True)["status"] == STATUS_SAVED
    loop.run("s2", "hello again")
    assert "`invoice-export` — Export the monthly invoices" in model.calls[-1][0]["content"]
