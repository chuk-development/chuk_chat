"""apply_patch (Codex format, all-or-nothing, 4-pass fuzzy seek; research
item 33)."""

from __future__ import annotations

import pytest

from chuk_agents_runtime import LocalEnvironment, ToolRegistry, register_builtin_tools
from chuk_agents_runtime.file_edit import EditGuard
from chuk_agents_runtime.file_patch import apply_hunks, parse_patch


@pytest.fixture()
def env_reg(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    env = LocalEnvironment()
    guard = EditGuard(env)
    reg = ToolRegistry()
    register_builtin_tools(reg, env, guard=guard)
    return env, reg, guard, tmp_path


def test_add_file(env_reg):
    env, reg, guard, tmp_path = env_reg
    patch = "*** Begin Patch\n*** Add File: new.txt\n+hello\n+world\n*** End Patch\n"
    out = reg.dispatch("apply_patch", {"patch": patch})
    assert out["ok"] is True
    assert (tmp_path / "new.txt").read_text() == "hello\nworld\n"


def test_add_file_refuses_existing(env_reg):
    env, reg, guard, tmp_path = env_reg
    (tmp_path / "there.txt").write_text("x\n")
    patch = "*** Begin Patch\n*** Add File: there.txt\n+y\n*** End Patch\n"
    out = reg.dispatch("apply_patch", {"patch": patch})
    assert out["ok"] is False and "already exists" in out["error"]


def test_update_needs_a_read_then_applies(env_reg):
    env, reg, guard, tmp_path = env_reg
    (tmp_path / "f.txt").write_text("a\nb\nc\n")
    patch = "*** Begin Patch\n*** Update File: f.txt\n@@\n a\n-b\n+B\n c\n*** End Patch\n"
    # Without a prior read: refused.
    assert reg.dispatch("apply_patch", {"patch": patch})["ok"] is False
    reg.dispatch("read_file", {"path": "f.txt"})
    out = reg.dispatch("apply_patch", {"patch": patch})
    assert out["ok"] is True
    assert (tmp_path / "f.txt").read_text() == "a\nB\nc\n"


def test_delete_file(env_reg):
    env, reg, guard, tmp_path = env_reg
    (tmp_path / "gone.txt").write_text("bye\n")
    reg.dispatch("read_file", {"path": "gone.txt"})
    patch = "*** Begin Patch\n*** Delete File: gone.txt\n*** End Patch\n"
    out = reg.dispatch("apply_patch", {"patch": patch})
    assert out["ok"] is True
    assert not (tmp_path / "gone.txt").exists()


def test_move_file(env_reg):
    env, reg, guard, tmp_path = env_reg
    (tmp_path / "old.txt").write_text("one\ntwo\n")
    reg.dispatch("read_file", {"path": "old.txt"})
    patch = (
        "*** Begin Patch\n*** Update File: old.txt\n*** Move to: new.txt\n"
        "@@\n one\n-two\n+TWO\n*** End Patch\n"
    )
    out = reg.dispatch("apply_patch", {"patch": patch})
    assert out["ok"] is True
    assert not (tmp_path / "old.txt").exists()
    assert (tmp_path / "new.txt").read_text() == "one\nTWO\n"


def test_all_or_nothing_rejects_before_any_change(env_reg):
    env, reg, guard, tmp_path = env_reg
    (tmp_path / "a.txt").write_text("hello\n")
    reg.dispatch("read_file", {"path": "a.txt"})
    # The second op fails (b.txt not read); nothing is applied.
    patch = (
        "*** Begin Patch\n"
        "*** Update File: a.txt\n@@\n-hello\n+HELLO\n"
        "*** Update File: b.txt\n@@\n-x\n+y\n"
        "*** End Patch\n"
    )
    out = reg.dispatch("apply_patch", {"patch": patch})
    assert out["ok"] is False
    assert "Patch rejected before any change" in out["error"]
    assert (tmp_path / "a.txt").read_text() == "hello\n"  # untouched


def test_fuzzy_match_normalizes_unicode_punctuation(env_reg):
    env, reg, guard, tmp_path = env_reg
    # File uses a curly quote; the patch uses a straight one.
    (tmp_path / "f.txt").write_text("say “hi” now\n")
    reg.dispatch("read_file", {"path": "f.txt"})
    patch = '*** Begin Patch\n*** Update File: f.txt\n@@\n-say "hi" now\n+done\n*** End Patch\n'
    out = reg.dispatch("apply_patch", {"patch": patch})
    assert out["ok"] is True
    assert (tmp_path / "f.txt").read_text() == "done\n"


def test_parse_error_is_a_message_not_a_crash(env_reg):
    env, reg, guard, tmp_path = env_reg
    out = reg.dispatch("apply_patch", {"patch": "not a patch"})
    assert out["ok"] is False and "Begin Patch" in out["error"]


def test_apply_hunks_pure():
    after, failure = apply_hunks("a\nb\nc\n", parse_patch(
        "*** Begin Patch\n*** Update File: x\n@@\n a\n-b\n+B\n c\n*** End Patch\n"
    )[0].hunks)
    assert failure is None and after == "a\nB\nc\n"
