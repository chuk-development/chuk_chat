"""Run modes that stick to a chat (CHAT-183)."""

from __future__ import annotations

import json

import pytest

from chuk_agents_runtime import build_runtime
from chuk_agents_runtime.action_policy import (
    MODE_ALLOW,
    MODE_ASK,
    MODE_DENY,
    ActionApprovals,
    ActionPolicy,
)
from chuk_agents_runtime.model import MockModelClient, tool_call_response
from chuk_agents_runtime.registry import ToolRegistry
from chuk_agents_runtime.run_modes import (
    CORE_TOOLS,
    RunMode,
    RunModeError,
    RunModeState,
    apply_mode_to_approvals,
    apply_mode_to_registry,
    list_modes,
    load_modes,
    mode_context_rows,
    normalize_switch,
    parse_mode,
    parse_mode_prefix,
    resolve_run_mode,
    run_mode_payload,
)
from chuk_agents_runtime.sources import SOURCES
from chuk_agents_runtime.state import StateStore

KEY = "s1"


def test_builtin_modes_load():
    modes, errors = load_modes()
    assert errors == []
    assert {"review", "research", "plan", "quick", "careful"} <= set(modes)
    assert modes["plan"].plan is True
    assert modes["review"].approvals == "strict" and not modes["review"].allows("write_file")
    assert modes["quick"].reasoning_effort == "low" and not modes["quick"].allows("browser_task")
    assert all(m["builtin"] for m in list_modes())


def test_user_modes_override_and_bad_files_are_reported(tmp_path):
    own = tmp_path / "modes"
    own.mkdir()
    (own / "review.json").write_text(json.dumps({"prompt": "my own review", "title": "Mine"}))
    (own / "translate.json").write_text(
        json.dumps({"prompt": "Translate only.", "allow_groups": ["files_read"]})
    )
    (own / "broken.json").write_text("{nope")
    (own / "badgroup.json").write_text(json.dumps({"deny_groups": ["nope"]}))
    modes, errors = load_modes(tmp_path)
    assert modes["review"].prompt == "my own review" and modes["review"].builtin is False
    assert modes["translate"].allows("read_file") and not modes["translate"].allows("run_command")
    assert sorted(e.split(":")[0] for e in errors) == ["badgroup.json", "broken.json"]


def test_parse_mode_rules():
    with pytest.raises(RunModeError):
        parse_mode({"name": "Bad Name"})
    with pytest.raises(RunModeError):
        parse_mode({"name": "off"})
    with pytest.raises(RunModeError):
        parse_mode({"name": "x", "approvals": "relaxed"})
    mode = parse_mode({"name": "x", "deny_tools": ["mcp__*"], "model": " m1 "})
    assert mode.model == "m1" and not mode.allows("mcp__gh__issue") and mode.allows("read_file")
    # Core tools are never refused, even by an allow list.
    only = parse_mode({"name": "y", "allow_tools": ["read_file"]})
    assert all(only.allows(name) for name in CORE_TOOLS) and not only.allows("write_file")


def test_prefix_and_switch_parsing():
    assert parse_mode_prefix("/mode review check the PR") == ("review", "check the PR")
    assert parse_mode_prefix("/mode off thanks") == ("", "thanks")
    assert parse_mode_prefix("/mode quick")[0] == "quick"
    assert parse_mode_prefix("hello /mode x") == (None, "hello /mode x")
    assert normalize_switch(None) is None
    assert normalize_switch(" Review ") == "review"
    assert normalize_switch("default") == ""


def test_the_mode_sticks_until_changed(tmp_path):
    store = StateStore(str(tmp_path / "state.db"))
    first = resolve_run_mode(store, KEY, "review")
    assert first.mode.name == "review" and first.changed is True
    # A follow-up without a switch keeps it.
    follow = resolve_run_mode(store, KEY, None)
    assert follow.mode.name == "review" and follow.changed is False
    # An unknown name changes nothing and says so.
    unknown = resolve_run_mode(store, KEY, "nope")
    assert unknown.mode.name == "review" and "unknown run mode" in unknown.error
    cleared = resolve_run_mode(store, KEY, "")
    assert cleared.mode is None and cleared.changed is True
    assert RunModeState(store, KEY).name() is None


def test_plan_mode_ends_the_plan_run_mode(tmp_path):
    store = StateStore(str(tmp_path / "state.db"))
    assert resolve_run_mode(store, KEY, "plan", plan_active=True).mode.plan is True
    assert resolve_run_mode(store, KEY, None, plan_active=True).mode.name == "plan"
    # exit_plan_mode was approved: plan mode is off, so the run mode ends too.
    after = resolve_run_mode(store, KEY, None, plan_active=False)
    assert after.mode is None and after.changed is True


def test_context_row_and_payload():
    mode = parse_mode({"name": "x", "prompt": "Be brief."}, builtin=True)
    rows = mode_context_rows(mode)
    assert rows[0]["source"] == "mode" and "Be brief." in rows[0]["content"]
    assert "mode" in SOURCES
    assert mode_context_rows(None) == [] and mode_context_rows(RunMode(name="y")) == []
    assert run_mode_payload("k", mode)["mode"]["name"] == "x"
    assert run_mode_payload("k", None, error="bad")["error"] == "bad"


def test_registry_keeps_schemas_and_refuses_denied_tools():
    registry = ToolRegistry()
    registry.register("write_file", {"type": "object"}, lambda **_: {"ok": True})
    registry.register("read_file", {"type": "object"}, lambda **_: {"ok": True, "read": 1})
    before = registry.openai_tools()
    refused = apply_mode_to_registry(registry, parse_mode({"name": "r", "deny_groups": ["files_write"]}))
    assert refused == ["write_file"]
    assert registry.openai_tools() == before  # the prefix cache survives
    result = registry.dispatch("write_file", {"path": "a"})
    assert "not allowed in r mode" in json.dumps(result)
    assert registry.dispatch("read_file", {})["read"] == 1


def test_strict_approvals_only_tighten():
    base = ActionPolicy(modes={"browser_act": MODE_ALLOW, "publish": MODE_DENY},
                        sites={"browser_act": ("example.com",)})
    binding = ActionApprovals(policy=lambda: base, ask=lambda request: True)
    strict = apply_mode_to_approvals(binding, parse_mode({"name": "s", "approvals": "strict"}))
    policy = strict.policy()
    assert policy.mode("browser_act") == MODE_ASK
    assert policy.mode("publish") == MODE_DENY
    assert policy.evaluate("browser_act", "example.com") == MODE_ASK
    # A default mode, or nobody to ask, leaves the binding alone.
    assert apply_mode_to_approvals(binding, parse_mode({"name": "d"})) is binding
    lone = ActionApprovals(policy=lambda: base, ask=None)
    assert apply_mode_to_approvals(lone, parse_mode({"name": "s", "approvals": "strict"})) is lone


def test_a_run_in_a_mode_gets_the_block_and_the_refusal(tmp_path):
    db = str(tmp_path / "state.db")
    workspace = tmp_path / "ws"
    workspace.mkdir()
    mode = parse_mode(
        {"name": "readonly", "prompt": "Only read.", "deny_groups": ["files_write"]}
    )
    model = MockModelClient(
        [tool_call_response(("write_file", {"path": "a.txt", "content": "x"})), "ok"]
    )
    loop = build_runtime(
        model,
        db_path=db,
        workspace=str(workspace),
        context_ladder=False,
        version_workspace=False,
        enable_memory=False,
        enable_mcp=False,
        run_mode=mode,
    )
    result = loop.run(KEY, "write a file")
    # The loop reports the refused action as not done.
    assert result.final_answer.startswith("ok")
    assert "not allowed in readonly mode" in result.final_answer
    assert not (workspace / "a.txt").exists()
    sent = model.calls[0]
    assert any("<run_mode" in str(m.get("content")) for m in sent)
    tool_rows = [m for m in model.calls[1] if m.get("role") == "tool"]
    assert tool_rows and "not allowed in readonly mode" in str(tool_rows[-1].get("content"))
