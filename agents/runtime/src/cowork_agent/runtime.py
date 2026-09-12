"""End-to-end wiring: model + registry + environment + state -> a runnable loop.

``build_runtime`` assembles the core into one :class:`AgentLoop`. With a mock
model it runs fully offline; swap in ``OpenAICompatModelClient`` and the real
sandbox ``Environment`` for production.

Memory (§12) and skills (§11) are workspace-relative: ``<workspace>/memory``
holds the Mem0 vector store plus the static ``soul.md`` + ``agents.md`` persona
files, ``<workspace>/skills`` holds ``<name>/SKILL.md``. The persona snapshot and
the skill catalog are read when a session is seeded, not when this function runs
— see ``_prompt_factory`` — so a long-lived process still gives each new session
the current state, while a running session keeps the prompt it started with.
"""

from __future__ import annotations

import sqlite3
import threading
from collections.abc import Callable, Sequence
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import httpx

from .browser import BrowserRunner, register_browser_task
from .context import AuxSummarizer, ContextLadder, LadderConfig
from .environment import Environment, LocalEnvironment
from .chat_documents import DocumentStore, register_document_tool
from .files_out import FileSink
from .herenow import ApprovalGate, HereNowConfig, register_herenow_tools
from .loop import AgentLoop, IterationBudget, KillSwitch, LoopResult
from .mcp_client import MCPManager, open_browser_gui_async, register_mcp_tools
from .media import WorkspaceMount
from .memory import MemoryStore, register_memory_tool
from .model import ModelClient, ModelResponse
from .oauth_bridge import (
    BackendOAuthClient,
    CredentialStash,
    LinkNotifier,
    OAuthBridge,
    config_token_exchange,
    register_oauth_tool,
)
from .prompt import build_system_prompt, upgrade_research_instructions
from .search import register_search_tool
from .secrets import SecretsAccess
from .automations import AutomationBackend, register_automation_tools
from .skills import SkillLibrary, SkillSettingsStore, load_skills, register_skill_tool
from .state import StateStore
from .subagents import (
    ActivityMonitor,
    ChildContext,
    ChildRunner,
    SubagentLimits,
    SubagentSupervisor,
    register_subagent_tools,
)
from .shell_tools import JobManager, register_job_tools, register_shell_tools
from .terminal import TerminalManager
from .tool_search import DEFAULT_THRESHOLD, ToolSearchDecision, apply_tool_search
from .tools import register_builtin_tools
from .web_search import DEFAULT_BASE_URL, TokenSession
from .workspace_git import JOURNAL_PATH, GitWorkspace, summarize_result
from .workspace_tools import JournalingRegistry, register_workspace_tools

MEMORY_DIRNAME = "memory"
SKILLS_DIRNAME = "skills"
SUBAGENT_DIRNAME = "subagents"


@dataclass
class SubagentConfig:
    """How this runtime spawns children (§7.6).

    Passed to :func:`build_runtime` to add ``delegate_task`` /
    ``subagent_control``. Everything a child needs that this process cannot
    invent is a field here: a **fresh model client** per child (a scripted or
    streaming client is single-use), and an **environment factory keyed by the
    child's task id** — that factory is the whole isolation story. Hand it
    ``cowork_sandbox.make_environment`` and each child gets its own container;
    leave it out and children get their own local stand-in, so the same code path
    is exercised in tests and in production.
    """

    model_factory: Callable[[], ModelClient]
    env_factory: Callable[[str], Environment] | None = None
    limits: SubagentLimits = field(default_factory=SubagentLimits)
    #: Depth of the agent this config belongs to. The root is 0; a child's own
    #: config is derived with ``depth = ctx.depth``.
    depth: int = 0
    task_id: str = "task"
    #: Where child state (db, per-child scratch) lives. Defaults to a
    #: ``subagents/`` directory next to the parent's database.
    root: str | None = None
    #: Shared across the whole tree so the concurrency ceiling is per level, not
    #: per node. Left unset at the root and threaded down from there.
    gates: dict[int, threading.BoundedSemaphore] | None = None
    on_event: Callable[[dict], None] | None = None
    activity: ActivityMonitor | None = None
    #: Override the default child runner (tests use a fake).
    runner: ChildRunner | None = None
    system_prompt: str | None = None
    max_iterations: int = 30
    version_workspace: bool = True
    #: Extra keyword arguments forwarded verbatim to the child's
    #: ``build_runtime`` (``session``, ``aux_model``, ``media_mount``, ...).
    runtime_kwargs: dict[str, Any] = field(default_factory=dict)
    #: Set by :func:`build_runtime` so the caller can shut the tree down.
    supervisor: SubagentSupervisor | None = None


class _ChildStreamingModel:
    """Reports each child turn's assistant text upward as it happens (§7.6 live
    streaming). Mirrors the executor's wrapper, one level down."""

    def __init__(self, inner: ModelClient, emit: Callable[[dict], None]) -> None:
        self._inner = inner
        self._emit = emit

    def set_tools(self, tools: list[dict] | None) -> None:
        """Forward native tools to the child's inner client, so a subagent gets
        the same native tool calling as its parent (§ native tool calls)."""
        if hasattr(self._inner, "set_tools"):
            self._inner.set_tools(tools)  # type: ignore[attr-defined]

    def complete(self, messages: list[dict]) -> ModelResponse:
        response = self._inner.complete(messages)
        if response.text:
            self._emit({"type": "delta", "text": response.text})
        return response


def make_child_runner(config: SubagentConfig) -> ChildRunner:
    """The default :class:`~cowork_agent.subagents.ChildRunner`: a full runtime.

    One child = one environment built from its own task id, one database, one
    loop. The environment is released in a ``finally`` — a leaked child container
    outlives the run that made it.
    """

    def run(ctx: ChildContext) -> LoopResult:
        factory = config.env_factory or (lambda task_id: LocalEnvironment())
        env = factory(ctx.task_id)
        try:
            child_config = SubagentConfig(
                model_factory=config.model_factory,
                env_factory=config.env_factory,
                limits=config.limits,
                depth=ctx.depth,
                task_id=ctx.task_id,
                root=ctx.root,
                gates=ctx.gates,
                on_event=ctx.emit,
                runner=config.runner,
                system_prompt=config.system_prompt,
                max_iterations=config.max_iterations,
                version_workspace=config.version_workspace,
                runtime_kwargs=config.runtime_kwargs,
            )
            loop = build_runtime(
                _ChildStreamingModel(config.model_factory(), ctx.emit),
                db_path=ctx.db_path,
                environment=env,
                workspace=ctx.workspace,
                max_iterations=config.max_iterations,
                # Per-child spend cap (§7.6): a child stops at its token budget
                # so a wedged or looping subagent cannot burn credits unwatched.
                token_budget=config.limits.max_child_tokens,
                system_prompt=config.system_prompt,
                kill_switch=ctx.kill_switch,
                version_workspace=config.version_workspace and ctx.branch is not None,
                # One journal file per agent, or two children merging back would
                # collide on every line of it.
                git_journal_path=f".cowork/journal-{ctx.subagent_id}.jsonl",
                terminal_task_id=ctx.task_id,
                # Summarised, not verbatim: the child's raw tool output can be
                # megabytes, and this event exists to show the parent (and the
                # phone) that something happened, not to move the payload.
                tool_observer=lambda name, args, result: ctx.emit(
                    {
                        "type": "tool",
                        "name": name,
                        "summary": summarize_result(result),
                    }
                ),
                subagents=child_config,
                **config.runtime_kwargs,
            )
            ctx.on_loop(loop)
            try:
                return loop.run(ctx.session_key, ctx.prompt)
            finally:
                nested = child_config.supervisor
                if nested is not None:
                    nested.shutdown()
                # A child reads the same workspace, so it started its own MCP
                # servers (§9). Close them with the child, or a run with four
                # subagents leaves four sets of subprocesses behind. An executor
                # that wants one shared manager passes ``mcp=`` in
                # ``runtime_kwargs`` and then owns the lifetime itself.
                child_mcp = getattr(loop, "mcp", None)
                if child_mcp is not None and "mcp" not in config.runtime_kwargs:
                    try:
                        child_mcp.close()
                    except Exception:  # noqa: BLE001 — cleanup never fails a result
                        pass
        finally:
            cleanup = getattr(env, "cleanup", None)
            if callable(cleanup):
                try:
                    cleanup()
                except Exception:  # noqa: BLE001 — cleanup must not mask a result
                    pass

    return run


def build_runtime(
    model: ModelClient,
    *,
    db_path: str,
    environment: Environment | None = None,
    max_iterations: int = 50,
    budget: int | None = None,
    token_budget: int | None = None,
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
    enable_terminal: bool = True,
    terminal_task_id: str = "task",
    enable_browser: bool = True,
    browser_model: ModelClient | None = None,
    browser_runner: BrowserRunner | None = None,
    version_workspace: bool = True,
    git_journal_path: str = JOURNAL_PATH,
    file_sink: FileSink | None = None,
    media_mount: WorkspaceMount | None = None,
    kill_switch: KillSwitch | None = None,
    tool_observer: Callable[[str, dict | None, Any], None] | None = None,
    subagents: SubagentConfig | None = None,
    enable_mcp: bool = True,
    mcp: MCPManager | None = None,
    herenow_config: HereNowConfig | None = None,
    herenow_gate: ApprovalGate | None = None,
    enable_tool_search: bool = True,
    tool_search_threshold: float = DEFAULT_THRESHOLD,
    oauth_link_notifier: LinkNotifier | None = None,
    oauth_http_client: httpx.Client | None = None,
    debug_observer: Callable[[dict], None] | None = None,
    tool_event_observer: Callable[[dict], None] | None = None,
    secrets: SecretsAccess | None = None,
    automations: AutomationBackend | None = None,
    shell_session_key: str | None = None,
    context_providers: Sequence[Callable[[], list[dict]]] | None = None,
) -> AgentLoop:
    """Assemble the loop. ``system_prompt`` is the operator *persona*: the
    behaviour contract is prepended from :mod:`cowork_agent.prompt` and the live
    tool schemas are handed to the model natively (``set_tools`` below), so a
    tool can never be registered without being offered to the model. Pass
    ``include_tool_docs=False`` to use ``system_prompt`` verbatim and declare no
    tools (tests).

    ``session`` is the account session. Pass it and ``web_search`` joins the
    tool set (it bills the account through our backend); leave it out and only
    the local tools — including ``web_fetch`` — are registered.

    The context ladder (§7.3) is **on by default**. Without ``aux_model`` it runs
    tier 1 only — deterministic dedup/truncation, no LLM call, no spend — which
    is the tier that reclaims most of the waste anyway. Pass a cheap
    ``aux_model`` to enable the tier-2/3 summary of the middle, or
    ``context_ladder=False`` to send the raw history.

    ``version_workspace`` (§7.7) makes the workspace a git repo, journals every
    tool call into it and registers the undo/history tools. It needs a
    ``workspace``; without one, or without git, it silently does nothing.

    ``file_sink`` and ``media_mount`` are the two channels the runtime cannot
    invent for itself: where a file sent to the user goes (the executor's sealed
    event stream) and which host directory the sandbox workspace really is (for
    the host-side ffmpeg, §9). Each unset tool stays out of the prompt.

    ``browser_model`` is the client the browser fallback (§8) may spend rounds
    on. It is a separate parameter because the loop's own client is wrapped to
    stream deltas to the user, and a browser session's per-step JSON has no
    business in the chat thread. Unset, the cheap ``aux_model`` is used; with
    neither, ``browser_task`` is not registered at all.

    ``subagents`` (§7.6) adds ``delegate_task`` / ``subagent_control``. It needs
    the state store (children are recorded in it) and, for branch-per-child, a
    versioned workspace; without git the children share this workspace.
    ``kill_switch`` lets a caller own the Stop switch — that is how a parent
    interrupts one child, since a child's loop is built by this same function.

    ``enable_mcp`` (§9) reads ``mcp.json`` from the workspace and connects the
    servers listed there — the fallback protocol, off the critical path: no file
    means no servers, and a server that does not answer only costs its own tools.
    Pass ``mcp=`` to supply a prepared :class:`~cowork_agent.mcp_client.MCPManager`
    (tests, or an executor that owns the lifetime). The returned loop carries it
    as ``loop.mcp``; **close it when the run ends** or the transport threads and
    their subprocesses outlive the task.

    ``herenow_config`` turns on the here.now publish connector (off by default).
    The tool is registered only when the config is enabled; ``herenow_gate`` is
    the approval round-trip the executor binds, so a public publish waits on the
    user in ``ask`` mode and refuses when no one can approve.

    ``enable_tool_search`` (§7.2) hides the MCP tools behind ``tool_search`` /
    ``tool_describe`` / ``tool_call`` once their schemas pass
    ``tool_search_threshold`` of the effective input budget. Core tools are never
    hidden. The measured decision is on the loop as ``loop.tool_search``.

    ``debug_observer`` is the backend half of a debug "copy raw context" feature:
    a callback fired once per model round with the EXACT message list sent to the
    model that round and the context ladder's stats. Off by default — pass no
    observer and nothing is built or called, so a normal run pays nothing for it.

    ``secrets`` (docs/WIRE_CONTRACT.md, "Secrets") is the user's secret set:
    the values go into the child environment of ``run_command`` / ``python``,
    ``request_secrets`` / ``list_secrets`` are registered, and the registry's
    result filter masks every value in every dispatch result. Unset, nothing
    of it exists.

    ``shell_session_key`` (docs/WIRE_CONTRACT.md, "Interactive shell and
    background commands") is the conversation a background job's end is
    routed to; the executor passes the task's session key. ``None`` still runs
    jobs, but nobody is woken. ``context_providers`` are extra message
    providers drained after every tool round, next to the skill bodies — the
    seam the executor uses to hand a finished job's output to a running turn.
    """
    env = environment or LocalEnvironment()
    ladder_config = context_config or LadderConfig()
    # The one place a third-party MCP token may live in this process (§10). Empty
    # until an OAuth flow completes; memory only, redacted repr, never journaled.
    stash = CredentialStash()
    # The workspace is a git repo and every dispatch is journaled into it (§7.7).
    # No workspace, no git binary, or an unwritable directory -> the registry is
    # a plain one and the run continues unversioned.
    git_workspace = (
        GitWorkspace.open(workspace, journal_path=git_journal_path)
        if version_workspace
        else None
    )
    registry = JournalingRegistry(git_workspace, observer=tool_observer)
    # Background jobs (docs/WIRE_CONTRACT.md, "Interactive shell and background
    # commands"): ``run_command(background=true)`` + ``job_*``. Needs no tmux,
    # only the environment; the wake-up is the host's job.
    jobs = JobManager(
        env,
        session_key=shell_session_key,
        workspace=workspace,
        secrets_env=secrets.env if secrets is not None else None,
    )
    register_builtin_tools(
        registry,
        env,
        session=session,
        base_url=base_url,
        file_sink=file_sink,
        media_mount=media_mount,
        secrets=secrets,
        jobs=jobs,
    )
    register_job_tools(registry, jobs)
    register_workspace_tools(registry, git_workspace)

    # here.now publishing (a first-class connector, off unless the user enabled
    # it in settings). Registered only when ``herenow_config.enabled``; the gate
    # is the executor's approval round-trip, so a public publish waits on the
    # user in ``ask`` mode. Not deferrable — a publish is a real, user-visible
    # action, kept in the prompt like the other core tools.
    register_herenow_tools(registry, env, herenow_config, herenow_gate)

    # Automations (docs/WIRE_CONTRACT.md, "Automations"): schedule_task /
    # start_watcher / list / pause / resume / cancel, bound to ONE session by
    # the executor. ``None`` (no host, no clock) registers nothing.
    register_automation_tools(registry, automations)

    if enable_terminal:
        # The interactive shell (docs/WIRE_CONTRACT.md, "Interactive shell and
        # background commands"): ``shell_start`` / ``shell_read`` /
        # ``shell_send`` / ``shell_list`` / ``shell_kill`` over the tmux driver
        # (§7.8). The task id is part of every tmux session name; a live
        # session of an earlier task in the same sandbox is attached, not
        # killed. Registered even without tmux — `check_fn` keeps it out of the
        # prompt. The secrets ride into the tmux server's environment when it
        # starts, the same values ``run_command`` gets.
        register_shell_tools(
            registry,
            TerminalManager(
                env,
                task_id=terminal_task_id,
                env_provider=secrets.env if secrets is not None else None,
            ),
        )

    if enable_browser:
        # The browser fallback (§8/§9). It needs a model client of its own: the
        # loop's client is wrapped for streaming, and every browser step's JSON
        # would land in the user's chat. `browser_model` first, else the cheap
        # `aux_model`; with neither, the tool is simply not registered. Chromium
        # or a CDP endpoint gates the rest, through `check_fn`.
        register_browser_task(
            registry,
            browser_model or aux_model,
            runner=browser_runner,
            file_sink=file_sink,
        )

    ladder: ContextLadder | None = None
    if context_ladder:
        ladder = ContextLadder(
            config=ladder_config,
            summarizer=AuxSummarizer(aux_model) if aux_model is not None else None,
        )

    store = StateStore(db_path)
    if file_sink is not None and shell_session_key:
        register_document_tool(registry, DocumentStore(db_path, shell_session_key), file_sink)
    if enable_chat_search:
        register_search_tool(registry, store)

    kill = kill_switch or KillSwitch(estop_path)

    if subagents is not None:
        supervisor = SubagentSupervisor(
            parent_key=f"agent:{subagents.task_id}",
            store=store,
            runner=subagents.runner or make_child_runner(subagents),
            root=subagents.root or str(Path(db_path).parent / SUBAGENT_DIRNAME),
            depth=subagents.depth,
            task_id=subagents.task_id,
            limits=subagents.limits,
            workspace=workspace,
            git=git_workspace,
            gates=subagents.gates,
            on_event=subagents.on_event,
            activity=subagents.activity,
            # The parent's own Stop reaches the children: stopping a run must
            # stop the sandboxes it opened, not orphan them.
            parent_kill=kill,
        )
        subagents.supervisor = supervisor
        register_subagent_tools(registry, supervisor)

    memory: MemoryStore | None = None
    if enable_memory:
        root = memory_root or (
            str(Path(workspace) / MEMORY_DIRNAME) if workspace else None
        )
        if root:
            # Mem0's fact-extraction writer runs on our own backend via the
            # `chukbackend` provider; the cheap aux client is preferred, falling
            # back to the loop's own model. `snapshot()` (soul.md/agents.md) needs
            # no client, so memory still injects the persona without a backend.
            memory = MemoryStore(root, llm_client=aux_model or model)
            register_memory_tool(registry, memory)
            # Nothing a compaction summarized away is lost: every new tier-2/3
            # summary is handed to memory as facts (§12).
            if ladder is not None and memory.automatic:
                ladder.on_summary = memory.remember_summary

    library = SkillLibrary()
    if enable_skills:
        root = skills_root or (
            str(Path(workspace) / SKILLS_DIRNAME) if workspace else None
        )
        # The user's switches (docs/WIRE_CONTRACT.md, "Skills") live in the
        # same state database; a skill switched off in the app never reaches
        # the catalogue. An unreadable store means "all on" (see load_skills).
        try:
            settings: SkillSettingsStore | None = SkillSettingsStore(db_path)
        except sqlite3.Error:
            settings = None
        library = load_skills(root, settings=settings)
        # Registered even when empty: `check_fn` keeps it out of the prompt
        # until a skill exists, and a skill dropped into the workspace between
        # sessions then needs no re-wiring.
        register_skill_tool(registry, library)

    # MCP last, after every core tool is in (§9): the tool-search threshold is
    # measured on the deferrable surface, and a core tool registered afterwards
    # would not be counted in the baseline.
    manager = mcp
    if manager is None and enable_mcp:
        manager = MCPManager.from_workspace(workspace, token_provider=stash.get)
    if manager is not None:
        register_mcp_tools(registry, manager)
        # Open the browser's GUI now, not on the first tool call (bead
        # cowork-bxvh). The Playwright MCP server in the sandbox launches
        # Chromium lazily, so until the agent browses, the display the app's
        # live view streams is empty — a black rectangle with nothing to
        # explain it. One ``browser_navigate about:blank`` on a daemon thread
        # puts a real window there for the rest of the session and costs the
        # first model round nothing. No browser server, no thread.
        open_browser_gui_async(manager)
        # One tool, for the servers that carry a §10 token EXCHANGE
        # (``oauth.token_url`` + ``client_id``: the bridge form
        # ``config_token_exchange`` reads). A device-forwarded oauth block
        # (``token_endpoint`` + ``refresh_token``, docs/WIRE_CONTRACT.md) is a
        # different thing — the host refreshes those itself in mcp_client — and
        # offering ``mcp_oauth_connect`` for it only led the model into "no token
        # exchange configured". No exchange-form server -> no tool. Needs the
        # account session: the backend holds the pending flow and pays for it.
        exchange_configs = {
            c.name: c.oauth
            for c in manager.configs
            if c.oauth and c.oauth.get("token_url")
        }
        if session is not None and exchange_configs:
            register_oauth_tool(
                registry,
                OAuthBridge(),
                BackendOAuthClient(
                    session, base_url=base_url, http_client=oauth_http_client
                ),
                stash=stash,
                exchange=config_token_exchange(
                    exchange_configs,
                    base_url=base_url,
                    http_client=oauth_http_client,
                ),
                notify=oauth_link_notifier,
                # A fresh handshake is what picks the new token out of the stash.
                on_authorized=manager.reconnect,
                # Stop reaches into the wait: the tool can park for minutes, and
                # the loop only polls the kill switch between tool calls.
                cancel=lambda: kill.interrupted() or kill.estop_engaged(),
            )

    decision = ToolSearchDecision(
        active=False,
        effective_budget=0,
        threshold_tokens=0,
        deferrable_tokens=0,
    )
    if enable_tool_search:
        decision = apply_tool_search(
            registry,
            context_window=ladder_config.context_length,
            reserved_output=ladder_config.reserved_output,
            threshold=tool_search_threshold,
        )

    # Native tool calling (§ native tool calls): hand the model the OpenAI `tools`
    # array built from the registry AFTER deferral, so deferred tools (which stay
    # reachable through the tool_search bridge) are not double-declared. The seam
    # is a settable `set_tools`, mirroring `on_delta`; the backend client and the
    # streaming wrappers forward it, and a client without it (the mock, which is
    # scripted anyway) simply ignores it. Gated on `include_tool_docs`: a bare
    # run that was told to use its persona verbatim declares no tools either.
    if include_tool_docs and hasattr(model, "set_tools"):
        model.set_tools(registry.openai_tools())  # type: ignore[attr-defined]

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
            # Names only (§9): lets the model answer "what integrations do you
            # have" truthfully now that tool schemas no longer live in the prompt.
            # Only servers that actually connected: a configured-but-dead server
            # presented as "wired up" is exactly the invented integration the
            # inventory exists to prevent. The manager was started by
            # register_mcp_tools above, so liveness is known by the time a
            # session is seeded.
            mcp_servers=(
                [c.name for c in manager.configs if manager.is_alive(c.name)]
                if manager is not None
                else None
            ),
        )

    prompt = _prompt_factory if include_tool_docs else system_prompt

    loop = AgentLoop(
        model,
        registry,
        store,
        max_iterations=max_iterations,
        budget=IterationBudget(budget if budget is not None else max_iterations),
        token_budget=token_budget,
        kill_switch=kill,
        system_prompt=prompt,
        system_prompt_upgrade=(
            lambda saved: library.upgrade_catalog(upgrade_research_instructions(saved))
        ) if include_tool_docs else None,
        context_providers=[library.pending_context, *(context_providers or [])],
        context_ladder=ladder,
        # The debug "copy raw context" tap (off by default): fired each round with
        # the exact outbound payload and the ladder's stats. Unset -> not wired.
        debug_observer=debug_observer,
        # The one source of live ``tool`` frames (one per native tool call, with
        # its result and clocks; docs/WIRE_CONTRACT.md). Unset -> not wired.
        # Distinct from ``tool_observer`` above, the journaling registry's
        # per-dispatch summary hook a parent uses to watch its subagents.
        tool_event_observer=tool_event_observer,
        # Store writes pass the secret scrubber too (docs/WIRE_CONTRACT.md,
        # "Secrets"): a key the USER typed into the prompt, or one a model
        # echoes, is masked before it becomes a row. The same filter the
        # registry installed on its dispatch result.
        persist_filter=registry.result_filter if secrets is not None else None,
        # Memory both ways (§12): the top-k memories relevant to the prompt are
        # injected once per task; the finished turn's facts are extracted in
        # the background. The model still has memory_search / memory_add for
        # anything explicit.
        recall_provider=(
            memory.recall_messages_bounded if memory is not None and memory.automatic else None
        ),
        turn_observer=(
            (
                lambda record: memory.observe_turn(
                    record.user_message,
                    record.final_answer,
                    tool_names=record.tool_names,
                )
            )
            if memory is not None and memory.automatic
            else None
        ),
    )
    # Two handles the caller needs and the loop itself does not: the MCP manager,
    # whose transport threads and subprocesses must be closed when the run ends,
    # and the tool-search decision, which is what the executor logs.
    loop.mcp = manager
    loop.tool_search = decision
    return loop
