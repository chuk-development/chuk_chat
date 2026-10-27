"""``agents-bench prompt-breakdown`` on a synthetic database built with the
runtime's own StateStore. No model, no network."""

from __future__ import annotations

import pytest

from chuk_agents_bench import cli, prompt_breakdown as pb
from chuk_agents_runtime.state import StateStore

KEY = "local:test-agent:1:42"


def _make_session(path, *, turns=6):
    store = StateStore(str(path))
    sid = store.route(KEY)
    store.append_message(sid, "system", {"role": "system", "content": "# Intro\n\nYou are a test agent.\n"})
    for i in range(turns):
        store.append_message(sid, "user", {"role": "user", "content": f"question {i}"})
        store.append_message(sid, "assistant", {"role": "assistant", "content": f"answer {i}"})
    close = getattr(store, "close", None)
    if callable(close):
        close()


def _tool(name: str, description: str) -> dict:
    return {
        "type": "function",
        "function": {"name": name, "description": description, "parameters": {"type": "object"}},
    }


def test_common_prefix_names_the_first_different_segment():
    tools = [_tool("a", "x" * 400), _tool("b", "y")]
    first = {"tools": tools, "messages": [{"role": "system", "content": "S"}, {"role": "user", "content": "hi"}]}
    second = {
        "tools": tools,
        "messages": [
            {"role": "system", "content": "S"},
            {"role": "user", "content": "hi"},
            {"role": "assistant", "content": "ok"},
        ],
    }
    same = pb.common_prefix(first, first)
    assert same.diverges_at is None
    assert same.prefix_tokens == same.second_tokens

    grown = pb.common_prefix(first, second)
    assert grown.diverges_at == "message 2 (assistant)"
    assert grown.prefix_tokens == grown.first_tokens

    changed = pb.common_prefix(first, {**second, "tools": list(reversed(tools))})
    assert changed.diverges_at == "tools"
    # Only the JSON head that every tool shares is left.
    assert changed.prefix_tokens < 20


def test_system_sections_split_on_top_level_headings():
    sections = pb.system_sections("intro text\n# One\n\nbody\n## sub\n# Two\nmore\n")
    assert [title for title, _ in sections] == ["(intro)", "One", "Two"]


def test_analyse_compares_the_last_call_with_the_next_first_call():
    tools = [_tool("big", "z" * 800), _tool("small", "s")]
    base = [{"role": "system", "content": "# A\n\nrules\n"}, {"role": "user", "content": "hi"}]
    task1 = [
        {"tools": tools, "messages": base},
        {"tools": tools, "messages": [*base, {"role": "assistant", "content": None, "tool_calls": [{"id": "c"}]}]},
    ]
    task2 = [{"tools": tools, "messages": [*base, {"role": "assistant", "content": "ok"}]}]
    result = pb.analyse([task1, task2], session_key=KEY, seeded_rows=2)
    assert [name for name, _ in result.tools] == ["big", "small"]
    assert result.base_tokens == result.system_tokens + result.tools_tokens
    assert result.history_messages == 1
    (prefix,) = result.prefixes
    assert prefix.diverges_at == "message 2 (assistant)"
    data = result.as_dict()
    assert data["base_tokens"] == result.base_tokens
    assert prefix.first_side != prefix.second_side


def test_run_records_consecutive_tasks_with_a_stable_prefix(tmp_path):
    db = tmp_path / "copy.db"
    _make_session(db)
    result = pb.run(db, KEY, turns=3, work_dir=tmp_path / "work", tool_turns=True)
    assert result.seeded_rows == 13
    assert result.turns == 3
    assert result.tools_tokens > 0 and result.system_tokens > 0
    names = [name for name, _ in result.tools]
    assert "run_command" in names and "write_file" in names
    assert len(result.prefixes) == 2
    for prefix in result.prefixes:
        # Tools and the system prompt never change between two tasks.
        assert prefix.diverges_at is None or prefix.diverges_at.startswith("message")
        assert prefix.prefix_tokens >= result.base_tokens
    text = pb.render_text(result)
    assert "tool definitions" in text and "identical prefix" in text


def test_cli_prompt_breakdown_prints_json(tmp_path, capsys, monkeypatch):
    db = tmp_path / "copy.db"
    _make_session(db)
    monkeypatch.setattr(pb, "default_scratch_dir", lambda: tmp_path / "scratch")
    code = cli.main(
        ["prompt-breakdown", "--db", str(db), "--session", KEY, "--no-skills", "--json"]
    )
    assert code == 0
    out = capsys.readouterr().out
    assert '"base_tokens"' in out and '"prefixes"' in out


def test_unknown_session_is_an_error(tmp_path):
    db = tmp_path / "copy.db"
    _make_session(db)
    with pytest.raises(LookupError):
        pb.run(db, "local:nope:1:1", work_dir=tmp_path / "work")
