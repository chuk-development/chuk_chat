"""search_tools ranks by relevance only (CHAT-40)."""

from types import SimpleNamespace

from chuk_agents_runtime.tool_search import relevance_search


def _tool(name: str, description: str = "") -> SimpleNamespace:
    return SimpleNamespace(name=name, description=description)


def test_best_match_wins_over_weaker_matches():
    tools = [_tool(f"mcp__GitHub__search_{n}", "Search GitHub") for n in range(12)]
    tools.append(_tool("mcp__Fastmail__search_email", "Search email in the mailbox"))
    names = relevance_search(None, ["search_email"], tools)
    assert names[0] == "mcp__Fastmail__search_email"


def test_name_match_counts_more_than_description():
    tools = [
        _tool("notes_add", "Add an email address to a note"),
        _tool("mcp__Fastmail__update_email", "Change folder or flag"),
    ]
    assert relevance_search(None, ["email"], tools)[0] == "mcp__Fastmail__update_email"


def test_no_terms_and_no_hits_return_empty():
    tools = [_tool("a_tool", "does a thing")]
    assert relevance_search(None, ["  "], tools) == []
    assert relevance_search(None, ["fastmail"], tools) == []
