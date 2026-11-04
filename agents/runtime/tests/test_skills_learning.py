"""Skill support files, the hashed catalogue, ``disable-model-invocation``,
usage counting, the curator, skill updates and the background review."""

from __future__ import annotations

import json
import os
import time

from chuk_agents_runtime.background_review import (
    build_review_messages,
    parse_review,
    run_background_review,
    transcript_digest,
)
from chuk_agents_runtime.skill_curator import (
    ARCHIVE_DIRNAME,
    curate_skills,
    list_archived,
    restore_skill,
)
from chuk_agents_runtime.skill_proposals import (
    KIND_PATCH,
    STATUS_SAVED,
    STATUS_STALE,
    RecordingProposalSink,
    SkillProposalStore,
    decide_skill_proposal,
    make_propose_skill_handler,
)
from chuk_agents_runtime.skills import (
    CATALOG_ROLE_TAG,
    SkillSettingsStore,
    catalog_hash,
    load_skills,
    skills_inventory,
)

BODY = "# Deploy\n\nStep one: run ./deploy.sh.\nStep two: watch the health check."


def _skill(root, name, description="Does a thing.", body=BODY, extra=""):
    d = root / name
    d.mkdir(parents=True, exist_ok=True)
    (d / "SKILL.md").write_text(
        f"---\nname: {name}\ndescription: {description}\n{extra}---\n\n{body}\n"
    )
    return d


# -- support files ------------------------------------------------------------


def test_support_files_and_base_directory_are_listed_on_load(tmp_path):
    root = tmp_path / "skills"
    d = _skill(root, "deploy")
    (d / "references").mkdir()
    (d / "references" / "api.md").write_text("x")
    (d / "scripts").mkdir()
    (d / "scripts" / "check.sh").write_text("x")
    (d / "scripts" / ".hidden").write_text("x")
    (d / "notes.txt").write_text("not a support dir")
    library = load_skills(root)
    library.activate("deploy")
    text = library.pending_context()[0]["content"]
    assert "Base directory of this skill: `skills/deploy/`" in text
    assert "`skills/deploy/references/api.md`" in text
    assert "`skills/deploy/scripts/check.sh`" in text
    assert ".hidden" not in text and "notes.txt" not in text


def test_a_skill_without_support_files_names_only_its_base(tmp_path):
    root = tmp_path / "custom"
    _skill(root, "deploy")
    library = load_skills(root)
    library.activate("deploy")
    text = library.pending_context()[0]["content"]
    assert f"Base directory of this skill: `{root / 'deploy'}/`" in text
    assert "Support files" not in text


# -- disable-model-invocation -------------------------------------------------


def test_disable_model_invocation_hides_the_skill_from_the_model(tmp_path):
    root = tmp_path / "skills"
    _skill(root, "deploy")
    _skill(root, "release", extra="disable-model-invocation: true\n")
    library = load_skills(root)
    assert library.names() == ["deploy"]
    assert "`release`" not in library.catalog()
    refused = library.activate("release")
    assert refused["ok"] is False and "only be started by the user" in refused["error"]
    assert library.activate("release", by_user=True)["ok"] is True
    rows = {r["name"]: r for r in skills_inventory(root)["skills"]}
    assert rows["release"]["model_invocable"] is False


# -- usage + inventory ---------------------------------------------------------


def test_loads_are_counted_and_shown_in_the_inventory(tmp_path):
    root = tmp_path / "skills"
    _skill(root, "deploy")
    settings = SkillSettingsStore(tmp_path / "s.db")
    library = load_skills(root, settings=settings)
    library.activate("deploy")
    library.activate("deploy")  # already active: not counted twice
    load_skills(root, settings=settings).activate("deploy")
    row = skills_inventory(root, settings=settings)["skills"][0]
    assert row["use_count"] == 2
    assert row["last_used_at"] is not None


# -- hashed catalogue ----------------------------------------------------------


def test_catalog_delta_is_sent_only_when_the_list_changes(tmp_path):
    root = tmp_path / "skills"
    _skill(root, "deploy")
    library = load_skills(root)
    system = {"role_tag": "system", "content": {"role": "system", "content": "P\n\n" + library.catalog()}}
    assert library.catalog_delta([system]) == []
    _skill(root, "song-id", "Identify songs.")
    newer = load_skills(root)
    delta = newer.catalog_delta([system])
    assert len(delta) == 1 and delta[0]["role_tag"] == CATALOG_ROLE_TAG
    assert f'hash="{catalog_hash(newer.catalog())}"' in delta[0]["content"]
    stored = {"role_tag": CATALOG_ROLE_TAG, "content": {"role": "user", "content": delta[0]["content"]}}
    assert newer.catalog_delta([system, stored]) == []
    # every skill removed: one message that says so
    empty = load_skills(tmp_path / "none")
    gone = empty.catalog_delta([system, stored])
    assert "No skills are available now" in gone[0]["content"]


# -- curator -------------------------------------------------------------------


def test_curator_archives_unused_skills_and_never_deletes(tmp_path):
    root = tmp_path / "skills"
    _skill(root, "old")
    _skill(root, "fresh")
    _skill(root, "pinned-one", extra="pinned: true\n")
    _skill(root, "seeded")
    seed = tmp_path / "seed" / "builtin" / "seeded"
    seed.mkdir(parents=True)
    (seed / "SKILL.md").write_text("x")
    settings = SkillSettingsStore(tmp_path / "s.db")
    now = time.time()
    first = curate_skills(root, settings, seed_root=tmp_path / "seed", now=now)
    assert first["archived"] == []  # first sight starts the clock
    old_stamp = now - 40 * 86_400
    for name in ("old", "pinned-one"):
        os.utime(root / name / "SKILL.md", (old_stamp, old_stamp))
    with settings._connect() as conn:  # backdate first sight
        conn.execute("UPDATE skill_usage SET first_seen_at = ?", (old_stamp,))
    settings.record_use("fresh", now=now)
    report = curate_skills(root, settings, seed_root=tmp_path / "seed", now=now)
    assert [a["name"] for a in report["archived"]] == ["old"]
    assert {s["name"]: s["reason"] for s in report["skipped"]} == {
        "pinned-one": "pinned",
        "seeded": "seed",
    }
    assert not (root / "old").exists()
    archived = list_archived(root)
    assert len(archived) == 1 and (root / ARCHIVE_DIRNAME / archived[0] / "SKILL.md").is_file()
    assert "old" not in load_skills(root).names()
    assert restore_skill(root, archived[0])["ok"] is True
    assert "old" in load_skills(root).names()


def test_curator_dry_run_moves_nothing(tmp_path):
    root = tmp_path / "skills"
    _skill(root, "old")
    settings = SkillSettingsStore(tmp_path / "s.db")
    settings.record_use("old", now=0.0)
    os.utime(root / "old" / "SKILL.md", (0, 0))
    report = curate_skills(root, settings, now=100 * 86_400, dry_run=True)
    assert [a["name"] for a in report["archived"]] == ["old"]
    assert (root / "old").is_dir()


# -- skill updates (read-before-write) ----------------------------------------


def _store_sink(tmp_path, root):
    store = SkillProposalStore(tmp_path / "s.db")

    class Sink:
        def submit(self, draft, *, skills_root):
            return {"ok": True, "proposal_id": store.add(draft, session_key="k", skills_root=skills_root)}

    return store, Sink()


def test_update_needs_the_skill_loaded_first_and_saves_on_accept(tmp_path):
    root = tmp_path / "skills"
    _skill(root, "deploy", extra="pinned: true\n")
    library = load_skills(root)
    store, sink = _store_sink(tmp_path, root)
    propose = make_propose_skill_handler(sink, skills_root=root, library=library)
    refused = propose("deploy", "", "# Deploy v2\n\n1. new step", update=True)
    assert refused["ok"] is False and "load the skill" in refused["error"]
    library.activate("deploy")
    reply = propose("deploy", "", "# Deploy v2\n\n1. new step", update=True)
    assert reply["ok"] is True and reply["kind"] == KIND_PATCH
    row = store.get(reply["proposal_id"])
    assert row["kind"] == KIND_PATCH and row["base_sha256"]
    result = decide_skill_proposal(store, proposal_id=reply["proposal_id"], accept=True)
    assert result["status"] == STATUS_SAVED
    text = (root / "deploy" / "SKILL.md").read_text()
    assert "Deploy v2" in text
    assert "pinned: true" in text  # the skill's own frontmatter survives
    assert 'description: "Does a thing."' in text


def test_update_of_a_skill_changed_since_load_is_refused(tmp_path):
    root = tmp_path / "skills"
    _skill(root, "deploy")
    library = load_skills(root)
    library.activate("deploy")
    _skill(root, "deploy", body="# Edited by the user\n\nstep")
    store, sink = _store_sink(tmp_path, root)
    propose = make_propose_skill_handler(sink, skills_root=root, library=library)
    reply = propose("deploy", "", "# v2\n\nstep", update=True)
    assert reply["ok"] is False and "changed since you loaded it" in reply["error"]


def test_a_stale_update_is_closed_without_writing(tmp_path):
    root = tmp_path / "skills"
    _skill(root, "deploy")
    library = load_skills(root)
    library.activate("deploy")
    store, sink = _store_sink(tmp_path, root)
    propose = make_propose_skill_handler(sink, skills_root=root, library=library)
    reply = propose("deploy", "New desc.", "# v2\n\nstep", update=True)
    _skill(root, "deploy", body="# Edited meanwhile\n\nstep")
    result = decide_skill_proposal(store, proposal_id=reply["proposal_id"], accept=True)
    assert result["status"] == STATUS_STALE
    assert "Edited meanwhile" in (root / "deploy" / "SKILL.md").read_text()
    again = decide_skill_proposal(store, proposal_id=reply["proposal_id"], accept=True)
    assert again["already_decided"] is True


def test_old_proposal_table_gets_the_new_columns(tmp_path):
    import sqlite3

    db = tmp_path / "old.db"
    with sqlite3.connect(db) as conn:
        conn.execute(
            "CREATE TABLE skill_proposals (proposal_id TEXT PRIMARY KEY, session_key TEXT NOT NULL,"
            " run_id TEXT NOT NULL DEFAULT '', skills_root TEXT NOT NULL, name TEXT NOT NULL,"
            " description TEXT NOT NULL, body TEXT NOT NULL, status TEXT NOT NULL DEFAULT 'pending',"
            " event_mid INTEGER, created_at REAL NOT NULL, decided_at REAL)"
        )
    SkillProposalStore(db)
    with sqlite3.connect(db) as conn:
        cols = {row[1] for row in conn.execute("PRAGMA table_info(skill_proposals)")}
    assert {"kind", "base_sha256"} <= cols


# -- background review ---------------------------------------------------------


def _rows(*items):
    return [{"role_tag": tag, "content": content} for tag, content in items]


def _task(skill_text=None):
    rows = [
        ("system", {"role": "system", "content": "sys"}),
        ("user", {"role": "user", "content": "old task"}),
        ("assistant", {"role": "assistant", "content": "old answer"}),
        ("user", {"role": "user", "content": "export the invoices, and always as CSV"}),
        ("assistant", {"role": "assistant", "content": None, "tool_calls": [
            {"id": "c0", "type": "function", "function": {"name": "skill", "arguments": "{}"}}]}),
        ("tool", {"role": "tool", "tool_call_id": "c0", "content": "x" * 1000}),
    ]
    if skill_text is not None:
        rows.append(("skill", {"role": "user", "content": f"## ACTIVE SKILL: deploy\n\n{skill_text}"}))
    rows.append(("assistant", {"role": "assistant", "content": "done, saved invoices.csv"}))
    return _rows(*rows)


class _Model:
    def __init__(self, answer):
        self.answer = answer
        self.calls = []

    def complete(self, messages):
        self.calls.append(messages)

        class R:
            text = self.answer

        return R()


def test_digest_reads_only_the_last_task_and_cuts_tool_results():
    from chuk_agents_runtime.background_review import last_task

    digest = transcript_digest(last_task(_task()))
    assert "old task" not in digest
    assert "USER: export the invoices" in digest
    assert "TOOL CALL skill" in digest
    assert "x" * 400 not in digest


def test_review_proposes_a_new_skill_through_the_card_path(tmp_path):
    root = tmp_path / "skills"
    root.mkdir()
    sink = RecordingProposalSink()
    answer = json.dumps({
        "memory": ["The user wants exports as CSV."],
        "skill": {"action": "create", "name": "invoice-export",
                  "description": "Export invoices as CSV.", "body": "# Export\n\n1. step"},
    })
    model = _Model(f"```json\n{answer}\n```")
    report = run_background_review(model, _task(), skills_root=root, sink=sink)
    assert report.ran is True
    assert report.memory_candidates == ["The user wants exports as CSV."]
    assert [d.name for d in sink.drafts] == ["invoice-export"]
    assert not (root / "invoice-export").exists()  # nothing written without the user
    prompt = model.calls[0][0]["content"]
    assert "Do NOT capture" in prompt and "GROUNDED" in prompt


def test_review_update_rereads_the_current_skill_and_pins_its_hash(tmp_path):
    from chuk_agents_runtime.skills import text_sha256

    root = tmp_path / "skills"
    _skill(root, "deploy", body="# Deploy\n\nCURRENT ON DISK")
    sink = RecordingProposalSink()
    answer = json.dumps({"memory": [], "skill": {
        "action": "update", "name": "deploy", "description": "", "body": "# Deploy\n\nfixed"}})
    model = _Model(answer)
    # The conversation holds an OLD copy; the review must show the disk text.
    report = run_background_review(model, _task("OLD COPY"), skills_root=root, sink=sink)
    assert "CURRENT ON DISK" in model.calls[0][0]["content"]
    assert report.proposal and report.proposal["kind"] == KIND_PATCH
    draft = sink.drafts[0]
    assert draft.base_sha256 == text_sha256((root / "deploy" / "SKILL.md").read_text())


def test_review_refuses_an_update_of_a_skill_the_task_did_not_load(tmp_path):
    root = tmp_path / "skills"
    _skill(root, "deploy")
    sink = RecordingProposalSink()
    answer = json.dumps({"skill": {"action": "update", "name": "deploy", "body": "# x\n\ny"}})
    report = run_background_review(_Model(answer), _task(), skills_root=root, sink=sink)
    assert sink.drafts == [] and "only a skill the task loaded" in report.errors[0]


def test_review_skips_when_the_task_proposed_itself_and_survives_bad_output(tmp_path):
    rows = _task() + _rows(("assistant", {"role": "assistant", "content": None, "tool_calls": [
        {"id": "c1", "type": "function", "function": {"name": "propose_skill", "arguments": "{}"}}]}))
    report = run_background_review(_Model("{}"), rows, skills_root=tmp_path, sink=RecordingProposalSink())
    assert report.skipped
    bad = run_background_review(_Model("no json here"), _task(), skills_root=tmp_path, sink=RecordingProposalSink())
    assert bad.ran is True and bad.proposal is None

    def broken(messages):
        raise RuntimeError("down")

    failed = run_background_review(broken, _task(), skills_root=tmp_path, sink=RecordingProposalSink())
    assert failed.ran is False and failed.errors


def test_parse_review_and_messages_shape():
    assert parse_review('noise {"skill": null} noise') == {"skill": None}
    assert parse_review("[]") == {}
    messages = build_review_messages("D", catalog="# Skills", current_skills={"a": "TEXT"})
    assert messages[0]["role"] == "system" and "TEXT" in messages[0]["content"]
