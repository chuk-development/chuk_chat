"""The system prompt must push the model to act, and must NOT re-state schemas.

The first live run failed on the first half: the host seeded a one-line persona,
and the model answered with a Python file in a code fence instead of calling a
tool. The second half is the native-tool-calling contract — the schemas travel
in the request's ``tools`` array, so a copy in the prompt would be paid for twice
and could drift. These tests pin both.
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


def test_system_prompt_carries_behaviour_workspace_and_persona():
    prompt = build_system_prompt(
        _registry(), persona="Be terse.", workspace="/home/u/ws"
    )
    # The behaviour contract: call the tool, do not print the file.
    assert "write_file" in prompt
    assert "/home/u/ws" in prompt
    # the persona comes last so it wins on a conflict
    assert prompt.index("Be terse.") > prompt.index("write_file")


def test_system_prompt_omits_the_tool_definitions():
    """Native tool calling: the schemas are the request's `tools` array, so the
    prompt must not carry a second copy of them."""
    registry = _registry()
    prompt = build_system_prompt(registry)
    docs = render_tool_docs(registry)
    # No rendered tool block, no argument lines, no tool-list heading.
    assert docs not in prompt
    assert "## run_command" not in prompt
    assert "`command` (string, required)" not in prompt
    assert "Tools you can call" not in prompt
    # And no in-band call format of any kind.
    assert "tool_call" not in prompt


def test_system_prompt_tells_the_model_to_report_skills_and_mcp_not_languages():
    """Asked what it can do, the model must name its SKILLS and connected MCP
    servers/tools, not list programming languages."""
    prompt = build_system_prompt(_registry())
    lowered = prompt.lower()
    assert "what you can do" in lowered
    # It must point at the real inventory: skills and MCP servers/tools.
    assert "skill" in lowered
    assert "mcp" in lowered
    # And it must warn off the wrong answer (listing languages / "write Python").
    assert "python" in lowered
    assert "languages" in lowered


def test_system_prompt_enforces_quiet_result_only_behaviour():
    """Quiet by default (§ product philosophy): the result, not the process.

    The prompt must tell the model to retry silently, to skip step-reports and
    apologies, and to ask the user only for a genuine fork it cannot settle."""
    prompt = build_system_prompt(_registry())
    lowered = prompt.lower()
    # Retry silently, do not narrate failed commands.
    assert "retry" in lowered or "try again" in lowered
    assert "never narrate problems" in lowered
    # No apologies / status updates / meta.
    assert "no apologies" in lowered
    # Ideally one final message with the result.
    assert "as few messages" in lowered
    # Ask only for a real fork: missing credential or irreversible money action.
    assert "credential" in lowered
    assert "irreversible" in lowered
    # The old step-report instruction must be gone.
    assert "report what you did" not in lowered


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
    # The behaviour contract is seeded; the schemas are not (they go native).
    assert "write_file" in system["content"]
    assert "Be terse." in system["content"]
    assert "## write_file" not in system["content"]


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


def test_system_prompt_states_the_workspace_hygiene_transcript_and_memory_rules():
    prompt = build_system_prompt(_registry(), workspace="/home/u/ws")
    # Hygiene: notes/, tmp/, nothing loose in the root.
    assert "`notes/`" in prompt and "`tmp/`" in prompt
    assert "workspace root" in prompt
    # The transcript folder is the long-term search and read-only.
    assert "`transcript/` is read-only" in prompt
    assert "long-term search" in prompt
    # Memory: recall block + the explicit tools.
    assert "[memory recall]" in prompt
    assert "`memory_search`" in prompt and "`memory_add`" in prompt
