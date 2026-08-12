"""The system prompt must document the tools and the wire format.

The first live run failed because it did not: the host seeded a one-line
persona, and the model answered with a Python file in a code fence instead of
calling a tool. These tests pin the contract that prevents that regression.
"""

from __future__ import annotations

from cowork_agent import (
    LocalEnvironment,
    MockModelClient,
    ToolRegistry,
    build_runtime,
    build_system_prompt,
    register_builtin_tools,
    render_tool_docs,
)
from cowork_agent.model import extract_tool_calls


def _registry() -> ToolRegistry:
    registry = ToolRegistry()
    register_builtin_tools(registry, LocalEnvironment())
    return registry


def test_tool_docs_list_every_available_tool_with_its_arguments():
    docs = render_tool_docs(_registry())
    for name in ("run_command", "write_file", "read_file", "list_dir"):
        assert f"## {name}" in docs
    # arguments come from the schema, so a schema change cannot drift from the docs
    assert "`command` (string, required)" in docs
    assert "`content` (string, required)" in docs
    assert "`append` (boolean, optional)" in docs


def test_tool_docs_skip_unavailable_tools():
    registry = ToolRegistry()
    registry.register("offline", {"type": "object"}, lambda: None, check_fn=lambda: False)
    registry.register("online", {"type": "object"}, lambda: None)
    docs = render_tool_docs(registry)
    assert "## online" in docs
    assert "## offline" not in docs


def test_system_prompt_carries_protocol_tools_workspace_and_persona():
    prompt = build_system_prompt(
        _registry(), persona="Be terse.", workspace="/home/u/ws"
    )
    assert "<tool_call>" in prompt  # the wire format
    assert "write_file" in prompt  # the tool that writes files
    assert "/home/u/ws" in prompt
    # the persona comes last so it wins on a conflict
    assert prompt.index("Be terse.") > prompt.index("<tool_call>")


def test_prompt_example_parses_with_the_runtime_tool_parser():
    """The example in the prompt must be a call the runtime can actually parse —
    a wrong example teaches the model a format the loop then drops."""
    prompt = build_system_prompt(_registry())
    _, calls = extract_tool_calls(prompt)
    # calls[0] is the format template itself; the worked example follows.
    assert [c.name for c in calls[-2:]] == ["write_file", "run_command"]
    example = calls[-2]
    assert example.arguments["path"] == "show_date.py"
    assert example.arguments["content"].endswith("\n")


def test_build_runtime_seeds_the_full_prompt_into_the_first_turn(tmp_path):
    model = MockModelClient(["done"])
    loop = build_runtime(
        model,
        db_path=str(tmp_path / "state.db"),
        environment=LocalEnvironment(),
        system_prompt="Be terse.",
    )
    loop.run("s1", "hi")
    system = model.calls[0][0]
    assert system["role"] == "system"
    assert "write_file" in system["content"]
    assert "<tool_call>" in system["content"]


def test_build_runtime_can_use_a_verbatim_prompt(tmp_path):
    model = MockModelClient(["done"])
    loop = build_runtime(
        model,
        db_path=str(tmp_path / "state.db"),
        environment=LocalEnvironment(),
        system_prompt="only this",
        include_tool_docs=False,
    )
    loop.run("s1", "hi")
    assert model.calls[0][0]["content"] == "only this"
