# Agents runtime loop on Pydantic AI

Status: 2026-09-30. **Done and live.** The agent loop is Pydantic AI. The
native loop, the WebSocket model client, the connection pool and the tool
search bridge are deleted. All model calls go to
`POST https://api.chuk.chat/v1/chat/completions` (api_server
`docs/openai_chat_completions.md`). The spike gates pass with fakes and live
(deepseek-v4-flash, kimi-k2.6). Runtime, executor, host and config suites are
green. Owner decision 2026-09-30: adopt Pydantic AI as the agent loop.

Pinned: `pydantic-ai-slim[openai,mcp]==2.51.0` in `agents/runtime/pyproject.toml`
(pulls `openai 3.22.0`, `httpx2 2.13.1`, `fastmcp-slim 4.0.10`; `mcp 2.0.0`
stays). `websockets` is no longer a runtime dependency. `pydantic-ai-harness`
is not a dependency (section 11).

## 1. Goal

* Maintain less of our own loop code.
* Get the standard features: a streaming model client, tool execution,
  approvals (deferred tools), tool search, cancellation, usage limits,
  OpenTelemetry, later MCP transports and compaction.
* Keep what is ours: the executor, the relay, sealed frames, the approvals UI,
  the secrets vault, the Docker sandbox, the `StateStore` and the app wire
  contract (`docs/WIRE_CONTRACT.md` does not change).

Permission policy (owner): everything is allowed by default. Only clearly
dangerous or outward actions ask. Today: here.now publish (in `ask` mode).
Later: payments, SMS or mail sent for the user. No prompts for normal tools.

## 2. What existed

| Module | Lines before | Job |
|---|---|---|
| `loop.py` | 856 | `AgentLoop` + `KillSwitch`, `IterationBudget`, `StopReason`, `LoopResult`, `RunTimings`, `TurnRecord` |
| `backend.py` | 1438 | `SupabaseSession`, the WebSocket `BackendModelClient` (`/v2/ws`), the model catalogue |
| `connection_pool.py` | 70 | idle WebSocket pool |
| `tool_search.py` | 399 | threshold decision + `tool_search` / `tool_describe` / `tool_call` bridge |
| `model.py` | 181 | `ModelClient` protocol, mock, an unused OpenAI HTTP client |
| `registry.py`, `context.py`, `trace*.py` | 296, 895, 876 | tools, context ladder, JSONL trace (unchanged) |

Facts that shaped the design: the loop was synchronous; the model client, not
the loop, streamed deltas; the store was the source of truth and was re-read
every round; tools ran one at a time; approvals lived inside the here.now tool;
`[SILENT]` is read by the manager, not the loop.

## 3. Architecture

```
executor ──run(session_key, prompt)──▶ AgentLoop (loop.py, same facade as before)
                                         │ asyncio.run, one task per run
                                         ▼
                             Agent.iter(message_history = stored rows)
                                         │ node by node
        ┌────────────────────────────────┼───────────────────────────────┐
        ▼                                ▼                               ▼
 ModelRequestNode                  CallToolsNode                  (End: unused; the
  ProcessHistory: store rows →      RegistryToolset.call_tool       loop stops on the
  upgrade → ContextLadder →         → registry.dispatch (thread)    text turn itself)
  messages; stream → StreamMapper   HandleDeferredToolCalls →
  → on_delta / on_reasoning;        ApprovalPolicy → executor gate
  persist the assistant row         FunctionToolResultEvent →
                                    tool row + tool frame
```

Files: `loop.py` (shared types + `AgentLoop`), `pai/model.py` (the account
model, `SupabaseJwtAuth`, the legacy adapter), `pai/convert.py` (rows <->
messages), `pai/tools.py` (`RegistryToolset`), `pai/approvals.py`,
`pai/events.py` (`StreamMapper`), `pai/wiring.py` (what `build_runtime` adds).

## 4. Module mapping (final)

| Module / behaviour | Pydantic AI feature | Result |
|---|---|---|
| `AgentLoop.run` | `Agent.iter()` driven node by node | **Replaced** (same constructor, `run()`, `LoopResult`) |
| structural finish, `finish` tool | `CallToolsNode` | kept as a rule in the driver |
| `KillSwitch`, ESTOP | `CancellationToken`, `RunCancelled` | **kept**; the switch fires the token |
| iteration / token budgets | (`UsageLimits`) | **kept**, same `StopReason` values |
| WebSocket client, pool | `OpenAIChatModel` + `OpenAIProvider` | **deleted** |
| `BackendModelClient` | `pydantic_ai.direct.model_request` | **kept as a spec holder**; its blocking `complete()` uses the same Pydantic AI model |
| `SupabaseSession` refresh | `httpx2.Auth` on the provider client | kept; `SupabaseJwtAuth` sets the bearer per request |
| `registry.py`, scrubber | toolset interface | kept; `RegistryToolset` wraps it |
| here.now gate in the tool | `kind="unapproved"` + `HandleDeferredToolCalls` | **moved** to `pai/approvals.py` |
| tool search bridge | `ToolSearch` + `defer_loading` | **deleted**; threshold decision kept |
| `ContextLadder` | `ProcessHistory` | kept as the history processor |
| `trace.py`, `trace_report.py` | `Instrumentation` (OTel) | kept (host `cli.py` imports them); OTel beside it |
| `subagents.py` | harness `SubAgents` | kept (section 12) |
| `mcp_client.py`, `oauth_bridge.py` | `MCPToolset` | kept; tools reach Pydantic AI via the registry |
| memory hooks, context providers | – | kept as loop hooks |

## 5. Model access

* Every model call is Pydantic AI's `OpenAIChatModel` on
  `https://api.chuk.chat/v1/chat/completions` (`pai/model.py`
  `chuk_chat_model`). There is one wire implementation.
* The agent loop streams (`stream: true`, `stream_options.include_usage`).
  `build_runtime` builds the model from the executor's `BackendModelClient`
  (`chat_spec()`: session, model, provider pin, effort) and takes over the
  executor's `on_delta` / `on_reasoning` sinks
  (`pai/wiring.py` `openai_model_from_client`).
* The housekeeping calls (context summary, memory extraction, browser steps,
  subagent children) use `BackendModelClient.complete()`, non-streaming,
  through `pydantic_ai.direct.model_request` on the same model. `cancel()`
  cancels the request task from the Stop thread.
* Auth: `SupabaseJwtAuth` refreshes an expired token before a request and
  refreshes once after a `401` (the existing single-flight
  `SupabaseSession.refresh()`, app re-provision rule, on a worker thread),
  then sends the request again. A token the route keeps rejecting is a
  `SupabaseAuthError`.
* Request: `model`, `messages`, `tools`, `reasoning_effort`, and the route's
  `provider` extension (the old `provider_slug`). `max_tokens` and
  `temperature` are not sent for the main loop. That is the old behaviour:
  `/v2/ws` never forwarded them (api_server `routers/ai/multiplex.py`, the
  `_max_tokens_unused` comment), so every turn always had the provider default.
  Sending the old client's 2048 now would cap thinking plus answer at 2048
  tokens for the first time. The cheap clone sends `max_tokens=512`.
* Thinking: `delta.reasoning_content` becomes `ThinkingPart` deltas. It is not
  sent back (the route drops it anyway).
* `LegacyClientModel` runs any blocking `ModelClient` behind the Pydantic AI
  model interface: the test `MockModelClient` and a subagent child's wrapper.

## 6. Tools

* `RegistryToolset` lists each available registry tool as a `ToolDefinition`
  (the same split as `registry.openai_tool`, `strict=False`).
* Pydantic AI does not validate arguments (any-schema validator); the registry
  coerces them, as before.
* `call_tool` runs `registry.dispatch` on a worker thread with
  `abandon_on_cancel`. The result is the registry result (scrubbed, error
  envelope on failure), and the loop stores that exact object.
* A call that starts after Stop is not run (`INTERRUPTED_TOOL_RESULT`).
* Tools run in `sequential` mode (no journal races).
* An unknown tool name stores the registry envelope (with the browser hint). A
  known tool that Pydantic AI refused (a deferred tool not yet searched for)
  stores its reason as an error.

## 7. Approvals

* `ApprovalPolicy` names the tools that ask; empty by default.
* `herenow_publish` in `ask` mode is the one entry
  (`herenow_rule(env, config, gate)`). The toolset declares it with
  `kind="unapproved"`; `HandleDeferredToolCalls(policy.handler)` resolves it in
  the same run: scan (honest prompt) → the executor's existing gate
  (`approval_request` / `approval_decision`, 600 s, Stop ends the wait) →
  `ToolApproved` or `ToolDenied`. A denial stores the old tool result
  (`declined: true`).
* In `ask` mode the here.now tool is registered with an always-yes gate,
  because the approval already happened.
* `request_secrets` is an input dialog, not an approval; it stays in its tool.
* Payments, SMS and mail get one `ApprovalRule` each when they exist.

## 8. Wire events (unchanged contract)

| Pydantic AI event | Frame |
|---|---|
| `PartStartEvent(TextPart)`, `PartDeltaEvent(TextPartDelta)` | `delta{text}` |
| `PartStartEvent(ThinkingPart)`, `PartDeltaEvent(ThinkingPartDelta)` | `reasoning{text}` |
| `ToolCallPartDelta` | none (traced only) |
| `FunctionToolResultEvent` | `tool{...}` via `tool_event_fields` |
| deferred approval | `approval_request` from the executor gate |
| request settled | `debug_context` (only with `debug`) |

## 9. History and storage

* The `messages` table keeps the old OpenAI-style rows; there is no migration.
* `pai/convert.py`: `rows_to_messages` / `messages_to_rows`. Old sessions
  convert on read, every round.
* The `ProcessHistory` hook ignores Pydantic AI's in-run list and sends what
  the store holds (rows → `system_prompt_upgrade` → `ContextLadder` →
  messages). The model sees what was stored, scrubbed.
* Rows are written through `persist_filter` (the scrubber): the assistant row
  when the request settles, one tool row per call, context rows after a tool
  round.
* `search_tools` rows convert back to `ToolSearchCallPart` /
  `ToolSearchReturnPart`, so a discovered tool stays discovered next task.
* Old stored prompts that name `tool_search` are rewritten to `search_tools`
  on the way out (`upgrade_research_instructions`).

## 10. Context and compaction

The `ContextLadder` runs inside the history processor, unchanged (tier 1
dedup/truncate, tier 2/3 aux summary on the cheap clone, `on_summary` to
memory). Next: compare with harness `TieredCompaction`; adopt only if it
deletes ladder code and leaves the stored rows untouched.

## 11. pydantic-ai-harness

0.36.0, alpha, 41 releases in five months, imports private core modules; being
moved into the Pydantic AI monorepo as its own package. Not a dependency.
Candidates later, pinned with core: `TieredCompaction`, `ReportContextUsage`,
`ToolOutputLimits`. Avoid: `Shell` / `FileSystem` (local only), `SpendLimits`
(credits are billed server-side), `SubAgents`, regex-only secret guards.

## 12. Subagents

The supervisor stays (a container and a git branch per child, a gate per
level, steer rows, one Stop for the tree). Children are built by
`build_runtime`, so they run on the same `AgentLoop`, behind the legacy adapter
over `BackendModelClient.complete()` (one `delta` per child turn, as before).

## 13. MCP

`MCPManager` keeps our config, the OAuth bridge, the token exchange, the
forwarded-token refresh and rotation frames, the 20k cap and the browser GUI
start. The transport and the tool plumbing are Pydantic AI's `MCPToolset`
(FastMCP client: stdio, SSE, streamable HTTP), kept entered on one thread per
server so a session lives across tasks. The bearer is resolved per request
(`_BearerAuth`): a lapsed or refused token is renewed in place, with no
reconnect. Tools stay registry tools named `mcp__<server>__<tool>` (the app's
cards and the replay depend on the names), so the scrubber, the journal and
tool search apply to them.

## 14. Tool search

* The threshold decision stays (deferrable MCP schemas above 10 % of the input
  budget are deferred; core tools never).
* A deferred tool has `defer_loading=True`; Pydantic AI's `ToolSearch` gives
  the model `search_tools(queries)`; a found tool joins `tools` on the next
  request and is called by its own name.
* `OpenAIChatModel` has no native deferral: this is the local fallback, and a
  discovery changes the tools array once (one prompt-cache miss).

## 15. Memory hooks

`recall_provider` (once per task, after the user row) and `turn_observer`
(once per task, after the outcome) are unchanged and best effort. Hindsight
plugs in through `memory.py`.

## 16. Stop, ESTOP, limits, empty replies

* The kill switch fires the run's `CancellationToken`: a stream closes at once,
  a running tool is abandoned; the executor's listener kills the sandbox
  process group. Every call gets a row, and the row never denies a side effect:
  - a call that never started is `INTERRUPTED_TOOL_RESULT` ("not run") and is
    closed so it can never start later;
  - a call that started is waited for up to 10 s (`STOP_SETTLE_S`) and keeps
    its real result; past that its row is `STOPPED_TOOL_RESULT` ("outcome
    unknown, verify before you retry").
* Workspace-journal commits take one lock per repository per process, so a
  tool thread a Stop abandoned cannot race the next task's commits.
* A reply the provider cut off (`finish_reason` `length` / `content_filter`)
  ends the run as finished with no answer and `LoopResult.note`; it is not
  retried. Model errors the user can act on reach the app as a message
  (`ModelServiceError`: 402 "no credits left", 429 "rate limited, try again
  shortly", a stream with no event for 90 s).
* SDK retries: at most 1 (`max_retries=1`); every extra request is counted
  into the run row's `retries` / `retry_ms`.
* A turn the model finished while Stop landed is kept; a streamed turn keeps
  the text the user saw.
* Checks before each request, in the old order: interrupt, ESTOP,
  `max_iterations`, `IterationBudget`, token budget. `UsageLimits` has no
  request limit; `cost_limit` would need prices for our models.
* **New:** a reply with neither text nor a tool call (a thinking-only turn,
  seen live on kimi-k2.6) gets one nudge (a `context` row, not replayed) and
  one more request. The old loop ended with no answer.

## 17. Tracing

The run trace is OpenTelemetry (`telemetry.py`): one `agent_run` span per run,
every phase (`task_received` … `run_finished`, `tool_end`, `model_call`,
`retry`) a child span exported at once, and Pydantic AI's `invoke_agent` /
`chat` / `execute_tool` spans (content off) in the same trace. The local sink is
a rolling JSON-lines span exporter; `telemetry_report.py` reads it (and old
flat traces) for `agents-host trace`. `trace.py` / `trace_report.py` are gone.

## 18. Migration (done)

1. Spike: `pai/` package, gates with fakes.
2. Wire: `build_runtime` builds the new loop; approval policy, tool search, OTel.
3. Flip + delete: the native `AgentLoop`, the bridge, the loop switch.
4. HTTP route live: live gates passed; the WebSocket client, the pool and the
   transport switch are deleted. No `native` fallback is kept.

## 19. Gates

| Gate | Fake (no network) | Live (api.chuk.chat) |
|---|---|---|
| 1. token + reasoning deltas → frames; JWT expiry and 401 | `test_pai_gates.py::test_gate1_*` | `test_pai_live.py::test_live_gate1` (deepseek 6 s, kimi 3–10 s; 4–13 text chunks, 10–101 thinking chunks) |
| 2. approval pauses and resumes in the same run | `test_gate2_*` (approve, deny, nobody to ask, normal tools never ask) | `test_live_gate2` |
| 3. secret never in model messages, rows, tool events | `test_gate3_*` | `test_live_gate3` (request bodies recorded) |
| 4. Stop mid `run_command` → row < 2 s, process killed; Stop mid stream | `test_gate4_*` | `test_live_gate4` |
| 5. tool search over 60 deferred tools | `test_gate5_*`, `test_mcp_runtime.py::test_search_then_call_reaches_the_live_server` (real stdio MCP server) | `test_live_gate5` (deepseek and kimi: `search_tools` → `mcp__crm__create_invoice`) |
| housekeeping path | `test_backend.py` | `test_live_housekeeping_complete_on_the_same_route` |
| parity | `test_loop.py` (all 45) runs on the new loop | – |

Live runs: `AGENTS_LIVE=1 uv run pytest tests/test_pai_live.py -s` (reads the
desktop app's token from its SharedPreferences, never prints or refreshes it).

## 20. Risks

* **Pydantic AI churn.** 2.x moves fast. Mitigation: exact pin; the loop,
  gate and live suites run on every upgrade.
* **Code size.** The loop driver and the adapters are larger than the old loop
  (source +~780 lines after the deletions, much of it docstrings). The large
  deletions left are the JSONL trace (~880, after the host `trace` command
  moves to OTel), the MCP transport (~800 if `MCPToolset` fits) and the ladder
  (~500 if harness compaction fits).
* **Rate limit.** The route shares the 60/min `websocket` bucket with the app.
* **Thread per sync tool.** A tool that ignores Stop keeps its thread; the run
  itself stops at once.

## 21. Open questions for the owner

Answered 2026-09-30: MCP on `MCPToolset` (done); trace on OTel (done, the
`cli.py` import switch follows its owner's push); harness compaction not now
(bead chuk_chat-qe5l); thinking round-trip not now (api_server bead).
