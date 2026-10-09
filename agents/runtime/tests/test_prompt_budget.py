"""The baseline request budget (bead chuk_chat-b3g4).

A plain "hi" to a coworker used to cost ~33k input tokens. For a fresh
coworker the fixed part was ~12.7k: a 2.7k system prompt plus 64 declared tool
schemas (~10k) — the browser's Playwright tools and the rarely used built-ins
(shell, jobs, workspace undo, documents, ffmpeg) rode on every round of every
task. Now the deferrable tools are behind ``search_tools`` from the first
round, the persona files and the task-start recall are capped, and the skill
catalogue has a total budget.

These tests pin that budget, so it cannot silently grow back: a new tool must
either join ``CORE_TOOLS`` on purpose or register ``deferrable=True``, and a longer prompt section has to fit the
numbers below. The token figure is the
runtime's own estimate (4 characters per token), the one tool search and the
context ladder decide on; real tokenizers count about 5-10 % less.

The numbers measured when this was written (fresh default coworker, built-in
skills, seeded memory files, one MCP server):

    system prompt   ~2,940   (was ~2,720; +160 for the deferred-tools section)
    declared tools  ~2,250   (was ~10,000: 16 tools instead of 64)

The automations, call and secrets tools were declared at first too (~1.3k
tokens). A direct call to a deferred tool by its exact name is now honoured,
so they are deferred like the rest; :data:`ALWAYS_DEFERRED` pins that.
"""

from __future__ import annotations

import json
import shutil
from pathlib import Path

import pytest

from chuk_agents_runtime.context import estimate_tokens
from chuk_agents_runtime.mcp_client import MCPManager, MCPServerConfig, MCPToolInfo
from chuk_agents_runtime.media import WorkspaceMount
from chuk_agents_runtime.memory import (
    MAX_FILE_CHARS,
    RECALL_MAX_CHARS,
    RECALL_PREFIX,
    MemoryStore,
    recall_block,
)
from chuk_agents_runtime.model import MockModelClient, ModelResponse
from chuk_agents_runtime.prompt import BASE_INSTRUCTIONS, upgrade_research_instructions
from chuk_agents_runtime.runtime import SubagentConfig, build_runtime
from chuk_agents_runtime.skills import MAX_CATALOG_CHARS, SkillLibrary, parse_skill
from chuk_agents_runtime.tool_search import CORE_TOOLS

BUILTIN_SKILLS = Path(__file__).resolve().parents[2] / "skills" / "builtin"
DEFAULT_PERSONA = "You are a Agents coworker running on the user's own machine."

#: Ceilings, in estimated tokens. Raise one only on purpose, with the reason in
#: the commit: every token here is paid on every round of every session.
#: 3,300 -> 3,700 (live test 2026-10-09, compared with Grok Bot): the rules for
#: thorough research, the `[clock]` note, no unasked routines, one language per
#: answer and fewer rounds (~450), plus the `research` and `web-images` skills
#: in the catalogue (~140). Fewer rounds per task pay this back many times.
SYSTEM_PROMPT_BUDGET = 3_700
DECLARED_TOOLS_BUDGET = 3_000
DECLARED_TOOLS_MAX = 20

#: Deferrable tools that must never be declared up front again. They were
#: declared while a call to a deferred tool needed a search first.
ALWAYS_DEFERRED = frozenset(
    {
        "schedule_task", "start_watcher", "list_automations", "pause_automation",
        "resume_automation", "cancel_automation", "call_user", "call_status",
        "request_secrets", "list_secrets",
    }
)


# -- a default coworker, wired like the executor wires one ------------------


class _Session:
    access_token = "stub"

    def refresh(self) -> None:  # pragma: no cover - never called
        pass


class _Secrets:
    def names(self) -> list[str]:
        return []

    def env(self) -> dict[str, str]:
        return {}

    def request(self, names, purpose):  # pragma: no cover - never called
        return {}


class _Backend:
    """Automations / calls stand-in: registration is all that matters."""

    def __getattr__(self, name):
        return lambda *a, **k: {}


def _mcp_tool(index: int) -> MCPToolInfo:
    return MCPToolInfo(
        f"browser_action_{index}",
        "Act on the open page: click, type or read an element by its reference.",
        {
            "type": "object",
            "properties": {
                "ref": {"type": "string", "description": "Element reference."},
                "text": {"type": "string", "description": "Text to type."},
            },
            "required": ["ref"],
        },
    )


class _FakeConnection:
    def __init__(self, config: MCPServerConfig) -> None:
        self.tools = [_mcp_tool(i) for i in range(24)]
        self.error = None
        self.connected_once = True

    def start(self) -> bool:
        return True

    def alive(self) -> bool:
        return True

    def call(self, tool, arguments):
        return {"ok": False}

    def close(self) -> None:
        pass


def _model() -> MockModelClient:
    return MockModelClient([ModelResponse(text="hi")] * 4)


@pytest.fixture
def coworker(tmp_path, monkeypatch):
    monkeypatch.setenv("AGENTS_MEM_BACKEND", "mem0")
    workspace = tmp_path / "ws"
    (workspace / "skills").mkdir(parents=True)
    for skill in BUILTIN_SKILLS.iterdir():
        if (skill / "SKILL.md").is_file():
            shutil.copytree(skill, workspace / "skills" / skill.name)
    mcp = MCPManager(
        [MCPServerConfig(name="playwright", command="true")],
        connection_factory=_FakeConnection,
    )
    loop = build_runtime(
        _model(),
        db_path=str(tmp_path / "state.db"),
        workspace=str(workspace),
        system_prompt=DEFAULT_PERSONA,
        session=_Session(),
        aux_model=_model(),
        browser_model=_model(),
        automations=_Backend(),
        calls=_Backend(),
        secrets=_Secrets(),
        subagents=SubagentConfig(model_factory=_model, runner=lambda *a, **k: None),
        file_sink=lambda sent: None,
        media_mount=WorkspaceMount("/workspace", str(workspace)),
        shell_session_key="local:budget",
        mcp=mcp,
    )
    try:
        yield loop
    finally:
        mcp.close()


def _declared(loop) -> dict[str, int]:
    registry = loop.registry
    return {
        name: estimate_tokens(json.dumps(registry.openai_tool(name), separators=(",", ":")))
        for name in registry.names()
        if registry.available(name) and not registry.is_deferred(name)
    }


def _system_prompt(loop) -> str:
    prompt = loop._system_prompt  # noqa: SLF001 - the seeded prompt factory
    return prompt() if callable(prompt) else prompt


# -- the budget ------------------------------------------------------------


def test_only_core_tools_are_declared_for_a_default_coworker(coworker):
    declared = _declared(coworker)
    stray = sorted(set(declared) - CORE_TOOLS)
    assert not stray, (
        f"{stray} are declared on every round. Register them deferrable=True "
        "(found with search_tools) or add them to CORE_TOOLS on purpose."
    )
    deferred = coworker.registry.deferred_names()
    # The MCP server and the rarely used built-ins are all behind search_tools.
    assert all(f"mcp__playwright__browser_action_{i}" in deferred for i in range(24))
    for name in (
        "shell_start", "job_output", "workspace_undo", "chat_document", "run_ffmpeg", "memory",
    ):
        assert name in deferred, name
    for name in sorted(ALWAYS_DEFERRED):
        assert name in deferred, name
        assert name not in declared, name


def test_declared_tool_schemas_stay_under_budget(coworker):
    declared = _declared(coworker)
    assert len(declared) <= DECLARED_TOOLS_MAX, sorted(declared)
    total = sum(declared.values())
    assert total <= DECLARED_TOOLS_BUDGET, (total, sorted(declared.items(), key=lambda i: -i[1]))


def test_system_prompt_stays_under_budget(coworker):
    prompt = _system_prompt(coworker)
    assert "# Deferred tools" in prompt
    assert "# Skills" in prompt
    assert estimate_tokens(prompt) <= SYSTEM_PROMPT_BUDGET, estimate_tokens(prompt)


def test_baseline_request_for_hi_stays_under_budget(coworker):
    total = estimate_tokens(_system_prompt(coworker)) + sum(_declared(coworker).values())
    assert total <= SYSTEM_PROMPT_BUDGET + DECLARED_TOOLS_BUDGET
    # The measured value was ~5.2k; the old baseline was ~12.7k.
    assert total < 6_500


def test_the_prompt_head_is_stable_across_seeds(coworker):
    """The prefix cache needs the same bytes every time: no clock, no per-turn
    data anywhere in the composed prompt."""
    first = _system_prompt(coworker)
    second = _system_prompt(coworker)
    assert first == second
    assert first.startswith(BASE_INSTRUCTIONS.split("\n", 1)[0])


# -- the caps that keep it there -------------------------------------------


def test_a_huge_persona_file_is_capped_in_the_snapshot(tmp_path):
    store = MemoryStore(tmp_path / "memory", seed_defaults=False)
    store.path("soul").parent.mkdir(parents=True, exist_ok=True)
    store.path("soul").write_text("persona line. " * 5_000, encoding="utf-8")
    store.path("agents").write_text("roster line. " * 5_000, encoding="utf-8")
    snapshot = store.snapshot()
    # Two files at the cap, the headings and the two cut notes.
    assert len(snapshot) <= 2 * MAX_FILE_CHARS + 1_000
    assert "memory/soul.md" in snapshot and "memory/agents.md" in snapshot
    # The file itself is untouched.
    assert len(store.read("soul")) == len("persona line. " * 5_000)


def test_the_task_start_recall_is_capped():
    notes = [f"note {i}: " + "detail " * 200 for i in range(20)]
    [message] = recall_block(notes)
    body = message["content"][len(RECALL_PREFIX):]
    assert len(body) <= RECALL_MAX_CHARS
    assert body.startswith("- note 0")
    assert recall_block([]) == []


def test_a_large_skill_library_keeps_the_catalogue_bounded():
    library = SkillLibrary()
    for i in range(100):
        skill = parse_skill(
            f"---\nname: skill-{i:03d}\ndescription: {'Does a thing. ' * 30}\n---\nbody\n"
        )
        library.skills[skill.name] = skill
    catalog = library.catalog()
    # Header + the description budget + one names-only line for the rest.
    assert len(catalog) <= MAX_CATALOG_CHARS + 1_600
    assert "`skill-099`" in catalog  # still listed, still loadable
    assert "Also available" in catalog


def test_an_old_session_prompt_learns_about_deferred_tools_once():
    old = BASE_INSTRUCTIONS.replace(
        "# Deferred tools\n"
        + BASE_INSTRUCTIONS.split("# Deferred tools\n", 1)[1].split("# Online research\n", 1)[0],
        "",
    )
    assert "# Deferred tools" not in old
    upgraded = upgrade_research_instructions(old)
    assert upgraded.count("# Deferred tools") == 1
    assert upgraded.index("# Deferred tools") < upgraded.index("# Online research")
    # Same input, same bytes: the upgrade keeps the cached prefix stable.
    assert upgrade_research_instructions(old) == upgraded
    assert upgrade_research_instructions(upgraded) == upgraded
