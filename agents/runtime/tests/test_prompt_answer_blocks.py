"""The answer-block rules in the agent prompt (bead chuk_chat-vxo0).

The app draws ``:::`` blocks in an Agents thread with the same
``MarkdownMessage`` as in a chat. Without the rule the Mail agent wrote a list
of invoices as plain bullets. These tests check that the rule is in the built
prompt, that it stays small, and that its ``::: status`` example parses with
the grammar of ``lib/utils/answer_blocks_parser.dart`` (ported below; the
Dart code is not run here).
"""

from __future__ import annotations

import re

from chuk_agents_runtime.context import estimate_tokens
from chuk_agents_runtime.prompt import (
    BASE_INSTRUCTIONS,
    _base_section,
    build_system_prompt,
    upgrade_research_instructions,
)
from chuk_agents_runtime.registry import ToolRegistry

# -- a port of the Dart grammar (answer_blocks_parser.dart) ---------------

_OPEN_RE = re.compile(r"^ {0,3}:::\s*([A-Za-z][\w-]*)[ \t]*(.*)$")
_CLOSE_RE = re.compile(r"^ {0,3}:::\s*$")
_BLOCK_NAMES = {
    "steps", "timeline", "scale", "bars", "kpi", "tiles", "cards", "ask",
    "source", "status",
}
_STATUS_WORDS = {
    "failed", "fail", "error", "declined", "fehlgeschlagen", "abgelehnt",
    "overdue", "late", "delayed", "überfällig", "ueberfaellig", "verspätet",
    "due", "pending", "open", "offen", "fällig", "soon", "warning",
    "ok", "paid", "done", "delivered", "bezahlt", "erledigt", "geliefert",
}
_HOST_RE = re.compile(r"^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,24}$")
_URL_TOKEN_RE = re.compile(r"https?://\S+", re.IGNORECASE)


def _blocks(text: str) -> list[tuple[str, str, list[str]]]:
    """``(name, arg, lines)`` of every closed block, outside code fences."""
    out: list[tuple[str, str, list[str]]] = []
    lines = text.split("\n")
    in_fence = False
    i = 0
    while i < len(lines):
        line = lines[i]
        if line.lstrip().startswith(("```", "~~~")):
            in_fence = not in_fence
        elif not in_fence:
            opened = _OPEN_RE.match(line)
            if opened and opened.group(1).lower() in _BLOCK_NAMES:
                body: list[str] = []
                j = i + 1
                while j < len(lines) and not _CLOSE_RE.match(lines[j]):
                    body.append(lines[j])
                    j += 1
                assert j < len(lines), f"block {opened.group(1)} is not closed"
                out.append((opened.group(1).lower(), opened.group(2), body))
                i = j
        i += 1
    return out


def _status_row(line: str) -> dict:
    parts = [p.strip() for p in line.split("|")]
    at = lambda k: parts[k] if k < len(parts) else ""  # noqa: E731
    status = at(3)
    word = re.match(r"^([^\s:]+)\s*:?\s*(.*)$", status)
    action = " | ".join(parts[6:]) if len(parts) > 6 else ""
    url = _URL_TOKEN_RE.search(action)
    return {
        "title": at(0),
        "amount": at(2),
        "kind": word.group(1).lower() if word else "",
        "label": word.group(2).strip() if word else "",
        "date": at(4),
        "domain": at(5),
        "action_url": url.group(0) if url else "",
        "action_label": action[: url.start()].strip() if url else "",
    }


def _section() -> str:
    return "# Answer blocks\n" + _base_section("Answer blocks", "What you can do")


# -- the tests ------------------------------------------------------------


def test_the_built_prompt_carries_the_rule():
    prompt = build_system_prompt(ToolRegistry(), persona="Mail agent.")
    assert "\n# Answer blocks\n" in prompt
    assert "always `::: status`" in prompt
    assert "never bullets" in prompt
    for name in ("::: steps", "::: timeline", "::: source"):
        assert name in prompt


def test_the_rule_sits_in_the_static_part_and_stays_small():
    # In BASE_INSTRUCTIONS, so it is part of the cached prefix of every round.
    assert _section() in BASE_INSTRUCTIONS
    assert estimate_tokens(_section()) < 300


def test_the_status_example_parses_like_the_app_parser():
    blocks = [b for b in _blocks(_section()) if b[0] == "status"]
    assert len(blocks) == 1
    _, arg, lines = blocks[0]
    title, _, summary = arg.partition(" · ")
    assert title.strip() and summary.strip()
    rows = [_status_row(line.strip()) for line in lines if line.strip()]
    assert len(rows) >= 2
    for row in rows:
        assert row["title"]
        assert row["kind"] in _STATUS_WORDS, row
        assert _HOST_RE.match(row["domain"]), row
    assert rows[0]["kind"] == "failed" and rows[0]["amount"]
    assert rows[0]["action_url"].startswith("https://") and rows[0]["action_label"]
    assert rows[1]["kind"] == "due" and rows[1]["label"] == "Last chance"


def test_an_old_session_prompt_gets_the_section_once():
    old = BASE_INSTRUCTIONS.replace(_section(), "")
    assert "\n# Answer blocks\n" not in old
    upgraded = upgrade_research_instructions(old)
    assert upgraded.count("\n# Answer blocks\n") == 1
    assert _section() in upgraded
    assert upgrade_research_instructions(upgraded) == upgraded
    assert upgrade_research_instructions(BASE_INSTRUCTIONS) == BASE_INSTRUCTIONS
