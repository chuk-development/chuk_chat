"""Paginated read, literal edit and the read-before-edit guard (research
items 32, 34, 35)."""

from __future__ import annotations

import pytest

from chuk_agents_runtime import LocalEnvironment, ToolRegistry, register_builtin_tools
from chuk_agents_runtime.file_edit import EditGuard


@pytest.fixture()
def env_reg(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    env = LocalEnvironment()
    guard = EditGuard(env)
    reg = ToolRegistry()
    register_builtin_tools(reg, env, guard=guard)
    return env, reg, guard, tmp_path


# -- read_file pagination ------------------------------------------------------


def test_read_file_returns_a_window_and_a_continue_footer(env_reg):
    env, reg, guard, tmp_path = env_reg
    (tmp_path / "big.txt").write_text("".join(f"line {i}\n" for i in range(1, 11)))
    out = reg.dispatch("read_file", {"path": "big.txt", "offset": 1, "limit": 4})
    assert out["ok"] is True
    assert out["start_line"] == 1 and out["end_line"] == 4
    assert out["total_lines"] == 10
    assert "Showing lines 1-4 of 10" in out["footer"]
    assert "offset=5" in out["footer"]
    assert out["content"].splitlines()[:4] == ["line 1", "line 2", "line 3", "line 4"]


def test_read_file_end_footer_on_the_last_window(env_reg):
    env, reg, guard, tmp_path = env_reg
    (tmp_path / "f.txt").write_text("a\nb\nc\n")
    out = reg.dispatch("read_file", {"path": "f.txt", "offset": 1, "limit": 100})
    assert out["footer"] == "(End of file - total 3 lines)"
    assert out["truncated"] is False


def test_read_file_offset_past_end_is_a_clear_error(env_reg):
    env, reg, guard, tmp_path = env_reg
    (tmp_path / "f.txt").write_text("a\nb\n")
    out = reg.dispatch("read_file", {"path": "f.txt", "offset": 9})
    assert out["ok"] is False
    assert "past the end" in out["error"] and out["total_lines"] == 2


def test_read_file_empty_file(env_reg):
    env, reg, guard, tmp_path = env_reg
    (tmp_path / "e.txt").write_text("")
    out = reg.dispatch("read_file", {"path": "e.txt"})
    assert out["ok"] is True and out["total_lines"] == 0
    assert "total 0 lines" in out["footer"]


# -- edit_file -----------------------------------------------------------------


def test_edit_file_needs_a_prior_read(env_reg):
    env, reg, guard, tmp_path = env_reg
    (tmp_path / "f.txt").write_text("hello world\n")
    out = reg.dispatch("edit_file", {"path": "f.txt", "old_string": "world", "new_string": "there"})
    assert out["ok"] is False
    assert "has not been read" in out["error"]


def test_edit_file_after_read_replaces_once(env_reg):
    env, reg, guard, tmp_path = env_reg
    (tmp_path / "f.txt").write_text("hello world\n")
    reg.dispatch("read_file", {"path": "f.txt"})
    out = reg.dispatch("edit_file", {"path": "f.txt", "old_string": "world", "new_string": "there"})
    assert out["ok"] is True and out["replacements"] == 1
    assert (tmp_path / "f.txt").read_text() == "hello there\n"


def test_edit_file_rejects_empty_old_string_and_noop(env_reg):
    env, reg, guard, tmp_path = env_reg
    (tmp_path / "f.txt").write_text("x\n")
    reg.dispatch("read_file", {"path": "f.txt"})
    assert reg.dispatch("edit_file", {"path": "f.txt", "old_string": "", "new_string": "y"})["error"]
    assert "differ" in reg.dispatch(
        "edit_file", {"path": "f.txt", "old_string": "x", "new_string": "x"}
    )["error"]


def test_edit_file_reports_multiple_matches(env_reg):
    env, reg, guard, tmp_path = env_reg
    (tmp_path / "f.txt").write_text("a a a\n")
    reg.dispatch("read_file", {"path": "f.txt"})
    out = reg.dispatch("edit_file", {"path": "f.txt", "old_string": "a", "new_string": "b"})
    assert out["ok"] is False
    assert "matched 3 times" in out["error"]
    out2 = reg.dispatch(
        "edit_file", {"path": "f.txt", "old_string": "a", "new_string": "b", "replace_all": True}
    )
    assert out2["ok"] is True and out2["replacements"] == 3
    assert (tmp_path / "f.txt").read_text() == "b b b\n"


def test_edit_file_not_found_message(env_reg):
    env, reg, guard, tmp_path = env_reg
    (tmp_path / "f.txt").write_text("hello\n")
    reg.dispatch("read_file", {"path": "f.txt"})
    out = reg.dispatch("edit_file", {"path": "f.txt", "old_string": "zzz", "new_string": "y"})
    assert "was not found in f.txt" in out["error"]


def test_edit_file_refuses_a_file_changed_since_read(env_reg):
    env, reg, guard, tmp_path = env_reg
    (tmp_path / "f.txt").write_text("one\n")
    reg.dispatch("read_file", {"path": "f.txt"})
    (tmp_path / "f.txt").write_text("one changed on disk\n")
    out = reg.dispatch("edit_file", {"path": "f.txt", "old_string": "one", "new_string": "two"})
    assert out["ok"] is False and "changed since it was read" in out["error"]


def test_edit_file_preserves_crlf(env_reg):
    env, reg, guard, tmp_path = env_reg
    (tmp_path / "f.txt").write_bytes(b"a\r\nworld\r\n")
    reg.dispatch("read_file", {"path": "f.txt"})
    out = reg.dispatch("edit_file", {"path": "f.txt", "old_string": "world", "new_string": "there"})
    assert out["ok"] is True
    assert (tmp_path / "f.txt").read_bytes() == b"a\r\nthere\r\n"


# -- write guard ---------------------------------------------------------------


def test_write_file_create_is_free_but_overwrite_needs_a_read(env_reg):
    env, reg, guard, tmp_path = env_reg
    assert reg.dispatch("write_file", {"path": "new.txt", "content": "hi\n"})["ok"] is True
    # Own write counts as an observation: a second write is allowed.
    assert reg.dispatch("write_file", {"path": "new.txt", "content": "hi2\n"})["ok"] is True
    (tmp_path / "other.txt").write_text("external\n")
    refused = reg.dispatch("write_file", {"path": "other.txt", "content": "x\n"})
    assert refused["ok"] is False and "has not been read" in refused["error"]
    reg.dispatch("read_file", {"path": "other.txt"})
    assert reg.dispatch("write_file", {"path": "other.txt", "content": "x\n"})["ok"] is True
