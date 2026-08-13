"""End-to-end wiring: model + registry + environment + state -> a runnable loop.

``build_runtime`` assembles the core into one :class:`AgentLoop`. With a mock
model it runs fully offline; swap in ``OpenAICompatModelClient`` and the real
sandbox ``Environment`` for production.

Memory (§12) and skills (§11) are workspace-relative: ``<workspace>/memory``
holds ``MEMORY.md`` + ``USER.md``, ``<workspace>/skills`` holds
``<name>/SKILL.md``. Both are read when a session is seeded, not when this
function runs — see ``_prompt_factory`` — so a long-lived process still gives
each new session the current state, while a running session keeps the prompt it
started with.
"""

from __future__ import annotations

from pathlib import Path

from .context import AuxSummarizer, ContextLadder, LadderConfig
from .environment import Environment, LocalEnvironment
from .files_out import FileSink
from .loop import AgentLoop, IterationBudget, KillSwitch
from .media import WorkspaceMount
from .memory import MemoryStore, register_memory_tool
from .model import ModelClient
from .prompt import build_system_prompt
from .registry import ToolRegistry
from .search import register_search_tool
from .skills import SkillLibrary, load_skills, register_skill_tool
from .state import StateStore
from .tools import register_builtin_tools
from .web_search import DEFAULT_BASE_URL, TokenSession

MEMORY_DIRNAME = "memory"
SKILLS_DIRNAME = "skills"


def build_runtime(
    model: ModelClient,
    *,
    db_path: str,
    environment: Environment | None = None,
    max_iterations: int = 50,
    budget: int | None = None,
    estop_path: str | None = None,
    system_prompt: str | None = None,
    workspace: str | None = None,
    include_tool_docs: bool = True,
    session: TokenSession | None = None,
    base_url: str = DEFAULT_BASE_URL,
    memory_root: str | None = None,
    skills_root: str | None = None,
    enable_memory: bool = True,
    enable_skills: bool = True,
    enable_chat_search: bool = True,
    context_ladder: bool = True,
    context_config: LadderConfig | None = None,
    aux_model: ModelClient | None = None,
    file_sink: FileSink | None = None,
    media_mount: WorkspaceMount | None = None,
) -> AgentLoop:
    """Assemble the loop. ``system_prompt`` is the operator *persona*: the
    behaviour contract, the ``<tool_call>`` wire format and the live tool list
    are prepended from :mod:`cowork_agent.prompt`, so a tool can never be
    registered without being documented to the model. Pass
    ``include_tool_docs=False`` to use ``system_prompt`` verbatim (tests).

    ``session`` is the account session. Pass it and ``web_search`` joins the
    tool set (it bills the account through our backend); leave it out and only
    the local tools — including ``web_fetch`` — are registered.

    The context ladder (§7.3) is **on by default**. Without ``aux_model`` it runs
    tier 1 only — deterministic dedup/truncation, no LLM call, no spend — which
    is the tier that reclaims most of the waste anyway. Pass a cheap
    ``aux_model`` to enable the tier-2/3 summary of the middle, or
    ``context_ladder=False`` to send the raw history.

    ``file_sink`` and ``media_mount`` are the two channels the runtime cannot
    invent for itself: where a file sent to the user goes (the executor's sealed
    event stream) and which host directory the sandbox workspace really is (for
    the host-side ffmpeg, §9). Each unset tool stays out of the prompt.
    """
    env = environment or LocalEnvironment()
    registry = ToolRegistry()
    register_builtin_tools(
        registry,
        env,
        session=session,
        base_url=base_url,
        file_sink=file_sink,
        media_mount=media_mount,
    )

    ladder: ContextLadder | None = None
    if context_ladder:
        ladder = ContextLadder(
            config=context_config or LadderConfig(),
            summarizer=AuxSummarizer(aux_model) if aux_model is not None else None,
        )

    store = StateStore(db_path)
    if enable_chat_search:
        register_search_tool(registry, store)

    memory: MemoryStore | None = None
    if enable_memory:
        root = memory_root or (
            str(Path(workspace) / MEMORY_DIRNAME) if workspace else None
        )
        if root:
            memory = MemoryStore(root)
            register_memory_tool(registry, memory)

    library = SkillLibrary()
    if enable_skills:
        root = skills_root or (
            str(Path(workspace) / SKILLS_DIRNAME) if workspace else None
        )
        library = load_skills(root)
        # Registered even when empty: `check_fn` keeps it out of the prompt
        # until a skill exists, and a skill dropped into the workspace between
        # sessions then needs no re-wiring.
        register_skill_tool(registry, library)

    def _prompt_factory() -> str:
        """Resolved once, when a session is seeded (see ``AgentLoop.run``).
        Reading memory here and not at build time is what makes the snapshot
        per-session instead of per-process."""
        library.reload()
        return build_system_prompt(
            registry,
            persona=system_prompt,
            workspace=workspace,
            skills=library.catalog(),
            memory=memory.snapshot() if memory else None,
        )

    prompt = _prompt_factory if include_tool_docs else system_prompt

    return AgentLoop(
        model,
        registry,
        store,
        max_iterations=max_iterations,
        budget=IterationBudget(budget if budget is not None else max_iterations),
        kill_switch=KillSwitch(estop_path),
        system_prompt=prompt,
        context_providers=[library.pending_context],
        context_ladder=ladder,
    )
