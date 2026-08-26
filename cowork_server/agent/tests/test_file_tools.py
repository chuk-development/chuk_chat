"""File tools go through the sandbox shell, so the content must survive the
shell verbatim — quotes, ``$``, backticks, newlines and all. That is why the
payload travels as base64 instead of a heredoc."""

from __future__ import annotations

import pytest

from cowork_agent import LocalEnvironment, ToolRegistry, register_builtin_tools

TRICKY = (
    "print('it\\'s $HOME')\n"
    "# `backticks` and \"quotes\" and $(whoami)\n"
    'x = """triple"""\n'
)


@pytest.fixture()
def registry(tmp_path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    reg = ToolRegistry()
    register_builtin_tools(reg, LocalEnvironment())
    return reg


def test_write_file_creates_parent_dirs_and_keeps_content_byte_exact(registry, tmp_path):
    result = registry.dispatch(
        "write_file", {"path": "a/b/script.py", "content": TRICKY}
    )
    assert result["ok"] is True
    assert result["bytes_written"] == len(TRICKY.encode())
    assert (tmp_path / "a" / "b" / "script.py").read_text() == TRICKY


def test_write_file_replaces_by_default_and_appends_on_request(registry, tmp_path):
    registry.dispatch("write_file", {"path": "f.txt", "content": "one\n"})
    registry.dispatch("write_file", {"path": "f.txt", "content": "two\n"})
    assert (tmp_path / "f.txt").read_text() == "two\n"
    registry.dispatch(
        "write_file", {"path": "f.txt", "content": "three\n", "append": True}
    )
    assert (tmp_path / "f.txt").read_text() == "two\nthree\n"


def test_write_file_accepts_the_stringy_append_a_model_sends(registry, tmp_path):
    registry.dispatch("write_file", {"path": "f.txt", "content": "one\n"})
    registry.dispatch(
        "write_file", {"path": "f.txt", "content": "two\n", "append": "true"}
    )
    assert (tmp_path / "f.txt").read_text() == "one\ntwo\n"


def test_read_file_round_trips_and_reports_truncation(registry):
    registry.dispatch("write_file", {"path": "f.txt", "content": TRICKY})
    full = registry.dispatch("read_file", {"path": "f.txt"})
    assert full["ok"] is True
    assert full["content"] == TRICKY
    assert full["truncated"] is False

    cut = registry.dispatch("read_file", {"path": "f.txt", "max_bytes": 5})
    assert cut["truncated"] is True
    assert len(cut["content"]) == 5


def test_read_file_reports_a_missing_file_instead_of_raising(registry):
    result = registry.dispatch("read_file", {"path": "nope.txt"})
    assert result["ok"] is False
    assert result["error"]


def test_list_dir_lists_the_workspace(registry):
    registry.dispatch("write_file", {"path": "marker.txt", "content": "x"})
    result = registry.dispatch("list_dir", {})
    assert result["ok"] is True
    assert "marker.txt" in result["listing"]


def test_list_dir_reports_a_missing_directory(registry):
    result = registry.dispatch("list_dir", {"path": "missing_dir"})
    assert result["ok"] is False


def test_a_write_file_call_from_the_model_lands_on_disk(tmp_path, monkeypatch):
    """The whole point: a model turn that emits a write_file block creates the
    file. This is the path that silently did nothing before — the model printed
    the script and the loop had no file tool to call."""
    from cowork_agent import LocalEnvironment, MockModelClient, build_runtime

    monkeypatch.chdir(tmp_path)
    model = MockModelClient(
        [
            '<tool_call>{"name":"write_file","arguments":'
            '{"path":"hello.py","content":"print(\'hi\')\\n"}}</tool_call>',
            "Wrote `hello.py`.",
        ]
    )
    loop = build_runtime(
        model,
        db_path=str(tmp_path / "state.db"),
        environment=LocalEnvironment(),
        system_prompt="Be terse.",
    )
    result = loop.run("s1", "write a python script that prints hi")

    assert (tmp_path / "hello.py").read_text() == "print('hi')\n"
    assert result.final_answer == "Wrote `hello.py`."
