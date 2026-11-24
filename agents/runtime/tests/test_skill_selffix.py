"""Skill self-fix after a failure or a user correction (CHAT-183)."""

from __future__ import annotations

import json

from chuk_agents_runtime.skill_proposals import KIND_PATCH, RecordingProposalSink
from chuk_agents_runtime.skill_selffix import (
    TRIGGER_CORRECTION,
    TRIGGER_FAILURE,
    find_trigger,
    looks_like_correction,
    run_skill_selffix,
    selffix_enabled,
)
from chuk_agents_runtime.skills import text_sha256


def _skill(root, name="deploy", body="# Deploy\n\nStep one: run ./deploy.sh."):
    d = root / name
    d.mkdir(parents=True, exist_ok=True)
    (d / "SKILL.md").write_text(f"---\nname: {name}\ndescription: Deploys.\n---\n\n{body}\n")


def _rows(*items):
    return [{"role_tag": tag, "content": content} for tag, content in items]


def _skill_task(prompt="deploy the app"):
    return [
        ("user", {"role": "user", "content": prompt}),
        ("assistant", {"role": "assistant", "content": None, "tool_calls": [
            {"id": "c0", "type": "function", "function": {"name": "skill", "arguments": "{}"}}]}),
        ("tool", {"role": "tool", "tool_call_id": "c0", "content": "loaded"}),
        ("skill", {"role": "user", "content": "## ACTIVE SKILL: deploy\n\nold copy"}),
        ("assistant", {"role": "assistant", "content": "deployed"}),
    ]


class _Model:
    def __init__(self, answer):
        self.answer = answer
        self.calls: list = []

    def complete(self, messages):
        self.calls.append(messages)

        class R:
            text = self.answer

        return R()


FIX = json.dumps({"skill": {
    "name": "deploy", "why": "the health check was missing",
    "description": "", "body": "# Deploy\n\n1. run ./deploy.sh\n2. watch /health"}})


def test_correction_filter():
    assert looks_like_correction("No, use the staging server")
    assert looks_like_correction("that's wrong, it must be CSV")
    assert looks_like_correction("Falsch, nimm den anderen Server")
    assert not looks_like_correction("thanks, now deploy the docs too")
    assert selffix_enabled({}) and not selffix_enabled({"AGENTS_SKILL_SELFFIX": "off"})


def test_trigger_on_failure_needs_a_loaded_skill():
    rows = _rows(*_skill_task())
    assert find_trigger(rows, "max_iterations").kind == TRIGGER_FAILURE
    assert find_trigger(rows, "finished") is None
    plain = _rows(("user", {"role": "user", "content": "hi"}),
                  ("assistant", {"role": "assistant", "content": "hello"}))
    assert find_trigger(plain, "budget_exhausted") is None


def test_trigger_on_a_correction_after_a_skill_run():
    rows = _rows(
        *_skill_task(),
        ("user", {"role": "user", "content": "no, you forgot the health check"}),
        ("assistant", {"role": "assistant", "content": "sorry, checked it now"}),
    )
    trigger = find_trigger(rows, "finished")
    assert trigger.kind == TRIGGER_CORRECTION and trigger.skills == ["deploy"]
    # Both tasks are in the rows the model reads.
    assert trigger.rows[0]["content"]["content"] == "deploy the app"
    # A synthetic prompt (goal round, schedule) is never a correction.
    synthetic = _rows(
        *_skill_task(),
        ("user", {"role": "user", "content": "no, again", "source": "schedule"}),
    )
    assert find_trigger(synthetic, "finished") is None
    friendly = _rows(*_skill_task(), ("user", {"role": "user", "content": "great, thanks"}))
    assert find_trigger(friendly, "finished") is None


def test_a_failed_skill_run_proposes_a_pinned_patch(tmp_path):
    root = tmp_path / "skills"
    _skill(root, body="# Deploy\n\nCURRENT ON DISK")
    sink = RecordingProposalSink()
    model = _Model(FIX)
    report = run_skill_selffix(model, _rows(*_skill_task()), "max_iterations",
                               skills_root=root, sink=sink)
    assert report.ran is True and report.proposal["trigger"] == TRIGGER_FAILURE
    assert report.proposal["kind"] == KIND_PATCH and report.proposal["why"]
    prompt = model.calls[0][0]["content"]
    assert "FAILED" in prompt and "CURRENT ON DISK" in prompt and "Do NOT capture" in prompt
    draft = sink.drafts[0]
    assert draft.base_sha256 == text_sha256((root / "deploy" / "SKILL.md").read_text())
    # Nothing is written without the user's accept.
    assert "watch /health" not in (root / "deploy" / "SKILL.md").read_text()


def test_no_fix_and_wrong_skill_and_no_trigger(tmp_path):
    root = tmp_path / "skills"
    _skill(root)
    sink = RecordingProposalSink()
    rows = _rows(*_skill_task())
    none = run_skill_selffix(_Model('{"skill": null}'), rows, "max_iterations",
                             skills_root=root, sink=sink)
    assert none.ran and none.skipped == "no fix" and sink.drafts == []
    other = json.dumps({"skill": {"name": "other", "body": "# x\n\ny"}})
    wrong = run_skill_selffix(_Model(other), rows, "max_iterations", skills_root=root, sink=sink)
    assert "not a skill the task used" in wrong.errors[0] and sink.drafts == []
    model = _Model(FIX)
    quiet = run_skill_selffix(model, rows, "finished", skills_root=root, sink=sink)
    assert quiet.ran is False and model.calls == []  # no trigger, no model call


def test_a_broken_model_costs_only_the_fix(tmp_path):
    root = tmp_path / "skills"
    _skill(root)

    class Boom:
        def complete(self, messages):
            raise RuntimeError("down")

    report = run_skill_selffix(Boom(), _rows(*_skill_task()), "max_iterations",
                               skills_root=root, sink=RecordingProposalSink())
    assert report.ran is False and "self-fix model failed" in report.errors[0]
