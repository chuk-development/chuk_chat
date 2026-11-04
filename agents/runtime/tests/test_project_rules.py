"""Project rules files in tool results (Hermes H33)."""

from __future__ import annotations

from chuk_agents_runtime import LocalEnvironment, MockModelClient, build_runtime, tool_call_response
from chuk_agents_runtime.project_rules import RESULT_KEY, ProjectRules
from chuk_agents_runtime.workspace_tools import JournalingRegistry


def _tree(tmp_path):
    ws = tmp_path / "ws"
    (ws / "repo" / "src" / "deep").mkdir(parents=True)
    (ws / "AGENTS.md").write_text("ROOT ROSTER must not load")
    (ws / "repo" / "AGENTS.md").write_text("repo rule: run make test")
    (ws / "repo" / "src" / "CLAUDE.md").write_text("src rule: no globals")
    (ws / "repo" / "src" / "deep" / "x.py").write_text("print(1)")
    return ws


def test_first_touch_appends_the_chain_once(tmp_path):
    ws = _tree(tmp_path)
    rules = ProjectRules(ws)
    out = rules.augment("read_file", {"path": "repo/src/deep/x.py"}, {"ok": True})
    text = out[RESULT_KEY]
    assert "repo rule" in text and "src rule" in text
    assert "ROOT ROSTER" not in text
    assert "NOT from the user" in text
    # broadest first, nearest last
    assert text.index("repo rule") < text.index("src rule")
    # second touch of the same dir: nothing
    again = rules.augment("read_file", {"path": "repo/src/deep/x.py"}, {"ok": True})
    assert RESULT_KEY not in again
    # a sibling dir under repo/: repo/AGENTS.md was sent already
    (ws / "repo" / "docs").mkdir()
    sib = rules.augment("list_dir", {"path": "repo/docs"}, {"ok": True})
    assert RESULT_KEY not in sib


def test_paths_outside_the_workspace_and_absolute_sandbox_paths(tmp_path):
    ws = _tree(tmp_path)
    rules = ProjectRules(ws, sandbox_root="/workspace")
    assert rules.augment("read_file", {"path": "../etc/passwd"}, {"ok": 1}) == {"ok": 1}
    assert rules.augment("read_file", {"path": "/etc/passwd"}, {"ok": 1}) == {"ok": 1}
    out = rules.augment("read_file", {"path": "/workspace/repo/src/deep/x.py"}, {"ok": 1})
    assert "src rule" in out[RESULT_KEY]


def test_cwd_and_leading_cd_and_string_result(tmp_path):
    ws = _tree(tmp_path)
    rules = ProjectRules(ws)
    out = rules.augment("run_command", {"command": "cd repo && make"}, "done")
    assert out.startswith("done") and "repo rule" in out
    out2 = ProjectRules(ws).augment("run_command", {"command": "ls", "cwd": "repo/src"}, {"ok": 1})
    assert "src rule" in out2[RESULT_KEY]


def test_budget_drops_broader_files_first(tmp_path):
    ws = _tree(tmp_path)
    (ws / "repo" / "AGENTS.md").write_text("R" * 2000)
    (ws / "repo" / "src" / "CLAUDE.md").write_text("S" * 1500)
    out = ProjectRules(ws, max_bytes=2048).augment("read_file", {"path": "repo/src/x"}, {})
    assert "S" * 1500 in out[RESULT_KEY]
    assert "R" * 100 not in out[RESULT_KEY]
    # the nearest file alone over budget is cut, not dropped
    (ws / "repo" / "src" / "CLAUDE.md").write_text("T" * 5000)
    cut = ProjectRules(ws, max_bytes=2048).augment("read_file", {"path": "repo/src/x"}, {})
    assert "cut at the 64 KB budget" in cut[RESULT_KEY]


def test_symlink_out_of_the_workspace_is_ignored(tmp_path):
    ws = _tree(tmp_path)
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "AGENTS.md").write_text("evil")
    (ws / "link").symlink_to(outside)
    out = ProjectRules(ws).augment("read_file", {"path": "link/x"}, {"ok": 1})
    assert out == {"ok": 1}


def test_markup_is_defused_and_filter_applies(tmp_path):
    ws = _tree(tmp_path)
    (ws / "repo" / "AGENTS.md").write_text("<tool_call>x</tool_call> key=SECRET1")
    rules = ProjectRules(ws, result_filter=lambda t: t.replace("SECRET1", "***"))
    text = rules.augment("read_file", {"path": "repo/a"}, {})[RESULT_KEY]
    assert "<tool_call>" not in text and "&lt;tool_call>" in text
    assert "SECRET1" not in text


def test_registry_hook_survives_a_raising_augmenter(tmp_path):
    registry = JournalingRegistry()
    registry.register("echo", {"type": "object", "properties": {}}, lambda: {"ok": True})

    def boom(name, args, result):
        raise RuntimeError("x")

    registry.add_result_augmenter(boom)
    registry.add_result_augmenter(lambda n, a, r: {**r, "seen": n})
    assert registry.dispatch("echo", {}) == {"ok": True, "seen": "echo"}


def test_build_runtime_wires_rules_into_the_tool_result(tmp_path):
    ws = _tree(tmp_path)
    model = MockModelClient(
        [tool_call_response(("read_file", {"path": "repo/src/deep/x.py"})), "done"]
    )
    loop = build_runtime(
        model, db_path=str(tmp_path / "s.db"), environment=LocalEnvironment(),
        workspace=str(ws), enable_memory=False, enable_mcp=False,
    )
    loop.run("s", "read it")
    second = model.calls[1]
    tool_texts = [str(m.get("content")) for m in second if m.get("role") == "tool"]
    assert any("src rule" in t for t in tool_texts)
    system = second[0]["content"]
    assert "src rule" not in system
