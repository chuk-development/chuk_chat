"""Self-naming (docs/WIRE_CONTRACT.md, "Agent names"): ``rename_self`` checks
the name, renames only through the bound backend, and the prompt tells the
agent to ask the user before it renames itself."""

from __future__ import annotations

from chuk_agents_runtime import MockModelClient, build_runtime, tool_call_response
from chuk_agents_runtime.agent_naming import (
    MAX_NAME_LEN,
    RecordingNamingBackend,
    clean_name,
    is_placeholder_name,
    make_rename_self_handler,
    naming_prompt_section,
    register_naming_tools,
)
from chuk_agents_runtime.registry import ToolRegistry


def test_clean_name_folds_whitespace_and_checks_length():
    assert clean_name("  Price \n Watch ") == "Price Watch"
    assert clean_name("") is None
    assert clean_name("   ") is None
    assert clean_name(42) is None
    assert clean_name("x" * MAX_NAME_LEN) == "x" * MAX_NAME_LEN
    assert clean_name("x" * (MAX_NAME_LEN + 1)) is None


def test_placeholder_names():
    assert is_placeholder_name(None)
    assert is_placeholder_name("saffron-osprey")
    assert is_placeholder_name("Your computer")
    assert not is_placeholder_name("Mail")
    assert not is_placeholder_name("Price Watch")


def test_rename_self_stores_through_the_backend():
    backend = RecordingNamingBackend("saffron-osprey")
    rename = make_rename_self_handler(backend)
    out = rename("  Shopping  ")
    assert out == {"ok": True, "name": "Shopping", "previous": "saffron-osprey"}
    assert backend.renames == ["Shopping"]
    # The same name again is a no-op, not a second write.
    assert rename("Shopping")["unchanged"] is True
    assert backend.renames == ["Shopping"]


def test_rename_self_refuses_a_bad_name_and_reports_a_failed_store():
    backend = RecordingNamingBackend("Mail")
    assert make_rename_self_handler(backend)("")["ok"] is False
    assert backend.renames == []
    failing = RecordingNamingBackend("Mail", fail="no host")
    out = make_rename_self_handler(failing)("Inbox")
    assert out == {"ok": False, "error": "no host"}


def test_register_only_with_a_backend():
    registry = ToolRegistry()
    register_naming_tools(registry, None)
    assert not registry.has("rename_self")
    register_naming_tools(registry, RecordingNamingBackend())
    assert registry.has("rename_self")


def test_prompt_asks_first_and_proposes_only_for_a_placeholder():
    fresh = naming_prompt_section("saffron-osprey")
    assert '"saffron-osprey"' in fresh
    assert "propose one short name" in fresh
    assert "Never rename yourself silently" in fresh
    named = naming_prompt_section("Mail")
    assert "propose one short name" not in named
    assert "ask first" in named


def test_runtime_registers_the_tool_and_the_prompt_section(tmp_path):
    backend = RecordingNamingBackend("brisk-kestrel")
    model = MockModelClient([tool_call_response(("rename_self", {"name": "Solstice"})), "done"])
    loop = build_runtime(
        model,
        db_path=str(tmp_path / "state.db"),
        workspace=str(tmp_path / "ws"),
        agent_naming=backend,
        enable_memory=False,
        enable_mcp=False,
        enable_browser=False,
    )
    loop.run("local:brisk-kestrel:3:1", "you may call yourself Solstice")
    assert backend.renames == ["Solstice"]
    system = model.calls[0][0]
    assert system["role"] == "system"
    assert "# Your name" in system["content"]
    assert '"brisk-kestrel"' in system["content"]


def test_runtime_without_a_backend_has_no_tool(tmp_path):
    model = MockModelClient(["done"])
    loop = build_runtime(
        model,
        db_path=str(tmp_path / "state.db"),
        workspace=str(tmp_path / "ws"),
        enable_memory=False,
        enable_mcp=False,
        enable_browser=False,
    )
    assert "rename_self" not in loop.registry.names()
