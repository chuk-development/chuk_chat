# CoWork — Overnight Integration Plan (2026-08-28)

Orchestrated build to land a **fully working CoWork mode** in ONE repo. This doc
is the source of truth for the overnight run; subagents read it.

## Ground truth (verified by recon)

- **Base branch = `cowork`, branched off `master`.** `master` already ships the
  whole platform (87 commits ahead of the old `agent/pairing-persist`): agent
  loop, MCP client (`mcp_client.py`, official SDK, tool-search), context ladder
  (`context.py`), per-agent Docker containers (`sandbox/docker/*`,
  `manager/containers.py`, `sandbox/lifecycle.py`), scheduler/cron, subagents +
  group rooms (`subagents.py`, `manager/room_*`, `group_room.py`), browser-use,
  skills, oauth_bridge, terminal, workspace_git. All tested green.
- **Reference (do NOT build on, copy FROM):** `agent/pairing-persist @ 307b1c4`
  holds this session's work (Mem0 memory config, mcp_bridge, compaction,
  python/finish tools) — most is superseded by master; salvage the useful bits.
  The external `chuk_chat`/`chuk_chat-cowork` repos are porting references for
  Flutter UI patterns ONLY and get **trashed later** — never a build target,
  never commit there.
- **All commits go to the `cowork` branch in `/home/user/git/cowork`. Nowhere
  else. One repo, one branch.**

## Locked decisions (owner, 2026-08-28)

1. **Memory = Mem0 (main)** — semantic, via our own `BackendModelClient`
   (WebSocket, `wss://api.chuk.chat/v2/ws`) as the LLM and `/v1/embeddings`
   (live, qwen3-embedding-8b @ 1024, deepinfra→fireworks) as the embedder.
   **Rip out master's markdown+FTS5 `MemoryStore`.** PLUS a light markdown-file
   memory the agent can read — `soul.md` (persona) + `agents.md` (agent roster/
   definitions) — static files, injected/readable, NOT the old FTS5 search.
2. **No OpenAI-compatible route on the proxy.** Mem0's writer LLM uses a custom
   provider (`ChukBackendLLM(LLMBase)`, one method `generate_response` →
   `BackendModelClient.complete`). Only `/v1/embeddings` is used server-side.
3. **Keep master's MCP server implementation** (`mcp_client.py`) — the correct
   one. Wire the credential-forwarding flow into it.
4. **Flutter = unify** the two diverged lines into the full CoWork mode:
   master's agent **roster/rooms + control panel** + `agent/pairing-persist`'s
   **per-task composer model-picker** + a **new settings menu** (greenfield) +
   **MCP config UI** (ported from chuk_chat) + a **new embedding-model picker**.
5. **The product vision:** many Python agents on one self-hosted server (install
   by one short command → pulls Docker, or Podman if no Docker → sets up →
   prints a pairing code → enter in the Flutter client → E2E-encrypted, paired
   once forever). Each agent = its own Python runtime + **its own Docker
   container** (browser/MCP/ffmpeg tool execution happens in that container).
   Agents talk to each other in **group rooms like a human messenger**,
   coordinate, run their tasks, message back. Managed from the Flutter UI /
   settings. (Rooms/containers exist on master; the gap is going live + UI.)

## Workstreams

Each runs in an **isolated git worktree** off `cowork`; the orchestrator merges
each back into `cowork` and keeps the suite green. Module ownership is disjoint
to avoid clobbering.

### Phase 1 — foundation (parallel)
- **WS-A · Memory → Mem0 + markdown files** (owns `agent/src/cowork_agent/memory.py`,
  new `mem0_provider.py`, `agent/src/cowork_agent/runtime.py` memory wiring,
  `agent/pyproject.toml` deps, `soul.md`/`agents.md` seed). Rip `MemoryStore` +
  FTS5; install Mem0 as main memory (custom WS LLM provider + proxy embedder +
  local Qdrant); add the static soul.md/agents.md reader; keep the agent-facing
  `memory` tool, backed by Mem0. Salvage config from `pairing-persist @ 307b1c4`.
  Tests: Mem0 write/recall with a stub, markdown injection, no-network default.
- **WS-B · `python` + `finish` tools** (owns `agent/src/cowork_agent/tools.py`,
  `loop.py`, `agent/tests/test_loop.py`). Port the CodeAct `python` tool + the
  explicit `finish` terminator onto master's files (net-new; recon recipe).

### Phase 2 — integration (after Phase 1 merges)
- **WS-C · Flutter unify + settings + CoWork mode** (owns `app/`). Reconcile
  master's roster/rooms/control-panel with pairing-persist's composer
  model-picker; build the new settings menu (tiles → sub-pages, chuk_chat
  pattern); port the MCP config UI + storage (SharedPreferences config +
  FlutterSecureStorage secrets); add the embedding-model picker. UI direction:
  clean messenger, roster of agents, per-agent control surface, group rooms.
- **WS-D · MCP credential forwarding** (owns `executor/protocol.py`,
  `agent/mcp_client.py` auth field, `manager` + host wiring). Extend
  `task_payload` with `mcp_servers: [{name,url,auth,access_token?}]` inside the
  sealed frame; the Flutter host resolves each connection's live bearer at
  task-launch; the executor builds an `MCPManager` per session with auth
  headers. appSession connectors (GitHub) use the account token server-side;
  oauth connectors forward the device token.

### Phase 3 — go-live wiring + gaps (after Phase 2)
- Rooms live (per-member `TaskSender` registration in host `RoomBinding`).
- MCP OAuth **backend** routes (client done; backend absent — see
  `docs/MCP_OAUTH_BACKEND_ROUTE.md`).
- Embedding-picker host/manager capability to feed the UI.
- Install/pair smoke pass. (Prod relay-crossreplica deploy stays owner-gated.)

## Orchestration rules
- Worktree isolation per agent; orchestrator merges sequentially, runs `uv run
  pytest` (Python) / `flutter test` (app) per merge, never lands red.
- `uv.lock` conflicts → regenerate with `uv lock`, never hand-merge.
- Discard stray `session.txt` / `_scratch` junk; do not carry over.
- Commit author = chukfinley; no session/tool trailers in messages.
