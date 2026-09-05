# Handover — Python side (agent / executor / host), 2026-09-05

Written by the session that held the Python-committer role (cowork-49) on
handing it to cowork-13. Everything below is on branch `cowork`, single
worktree `/home/user/git/cowork`, branches `cowork` + `master` only.

## 1. What lives where

| Area | Path | Notes |
|---|---|---|
| Agent runtime | `agent/src/cowork_agent/` | `loop.py` (tool loop), `runtime.py` (`build_runtime` wiring), `context.py` (context ladder / compaction), `memory.py` + `mem0_provider.py` (mem0), `backend.py` (`SupabaseSession`, `BackendModelClient`, `/v2/ws`), `model.py` (`ModelResponse`, `MockModelClient`, `tool_call_response`), `mcp_client.py` (MCP + OAuth refresh, owner: cowork-47), `prompt.py`, `registry.py`, `tool_search.py`, `state.py` (SQLite: sessions, messages, runs). |
| Executor | `executor/src/cowork_executor/` | `executor.py` (task worker, per-task model select, MCP manager cache, credential back-channels, debug tap), `protocol.py` (frame builders), `backend.py` (model factory/select), `controller.py`. |
| Host | `host/src/cowork_host/` | `host.py` (`LocalHost`: provisioning, session policy, notifier), `party.py` (relay session; drops frames while detached), `notify.py`/`desktop_notify.py` (owner: cowork-98). |
| Contracts | `docs/WIRE_CONTRACT.md` | The wire truth. Frames below are documented there. |
| Design | `docs/context-compaction-design.md` | Compaction / memory design + live validation log (§10a). |
| Live probes | `agent/tests/live_*.py` | Not pytest-collected; run directly (see §5). |

Tool calls are **native only** (OpenAI `tools[]` → server `tool_calls` frame).
There is no `<tool_call>` text protocol anywhere in Python; do not reintroduce it.

## 2. How to commit (rules that applied, keep them)

- Commit **directly on `cowork`**. No worktrees left behind; delete any you make.
- Identity: `chukfinley <77645077+chukfinley@users.noreply.github.com>` via the
  global git config. **No** `-c user.*` overrides, **no** `Claude-Session:`
  links, **no** `Co-Authored-By` trailers.
- Stage **by explicit path**. Never `git add -A`: the tree carries other
  sessions' uncommitted work (Flutter under `app/lib`, VNC files, docs). Before
  committing run `git diff --cached --name-only | grep -E '^app/lib|third_party|vnc-up|COORDINATION'`
  and expect nothing.
- A commit may carry other sessions' hunks **only** when the coordinator
  (cowork-b7) says they are finished and green; name the author session in the
  message body.
- Run the affected suites first, **one at a time** (RAM):
  `cd agent && uv run pytest tests/ -q -p no:cacheprovider`,
  `cd executor && uv run pytest tests/ -q -p no:cacheprovider`,
  `cd host && uv run pytest tests/ -q -p no:cacheprovider`;
  plus `uv run ruff check --select F,E9 src tests` in agent and executor
  (both clean at handover). Baseline at handover: agent all green (3 env-gated
  skips), executor 110, host 118.
- The live tests are env-gated / not collected; do not add them to CI.
- Beads: `bd` is the tracker. Close what you finish (`bd close <id> --reason=…`),
  file what you find (`bd create …`). Do not use TodoWrite or markdown TODOs.

## 3. Frames introduced or changed (all in `docs/WIRE_CONTRACT.md`)

### `reprovision_request` (host → app) — bead cowork-c91
`{"type":"reprovision_request","reason":"token_expired"|"refresh_failed"}`.
Sent by the host when a model call is rejected for auth **while a controller is
attached**. The app answers with its normal `account_authentication` frame.
Python: `SupabaseSession.refresh()` (`agent/backend.py`) — with
`may_self_refresh()` False it calls `request_reprovision(reason)` and waits on a
Condition (`reprovision_timeout`, 20 s) for `mark_reprovisioned()`, which
`LocalHost._on_reprovision` calls after writing the fresh pair in place. Only
after the deadline does it raise `SupabaseAuthError` → error terminal.
Detached (no controller) the host refreshes via GoTrue itself (single-flight).

### `account_session_rotated` (host → app) — bead cowork-c91
`{"type":"account_session_rotated","access_token","refresh_token","expires_at"?,"rotated_at"}`.
Sent after a **host-side** GoTrue refresh (which rotated the pair and killed the
app's copy): immediately if a controller is attached, else kept pending
(`LocalHost._pending_session_rotation`) and re-sent on the next provision until
the app acks by sending an `account_authentication` whose `refresh_token`
equals the rotated one (`_note_incoming_token`). App side: 98.

### `mcp_credentials` (executor → app) — beads cowork-lwc + 47's review
`{"type":"mcp_credentials","session_key","id"?,"name","url","access_token"?,"oauth":{…no client_secret},"rotated_at"}`.
Fired from `mcp_client.refresh_token()` via `on_credentials_rotated` (owner 47)
**only when the provider rotated the refresh token**. Executor:
`_mcp_rotation_listener` builds the frame (with the device's `id` echoed
verbatim from `_mcp_entry_meta`), sends it on the active task's stream, parks
it in `_mcp_pending_credentials`; `_flush_pending_mcp_credentials` re-sends at
every task start and in `_handle_replay` until the device forwards the rotated
token back (ack) or re-signs-in.

### Cache key + merge for forwarded `mcp_servers`
`_mcp_signature` hashes a redacted projection (drops `access_token`,
`oauth.refresh_token`, `oauth.expires_at`) so a token rotation does not rebuild
the session's MCPManager. On a hit, `_adopt_rotating_credentials` **merges**:
identity fields always from the device; `refresh_token`/`expires_at`/bearer
only for a refresh token the device has **never sent before**
(`_mcp_refresh_seen`) — a re-sign-in or the host's own rotated token handed
back — never for a stale replay, and never over a host-rotated token.

### Others from this session
- `debug_context` (executor → app, opt-in via task `debug: true`): the exact
  per-round outbound message list + ladder stats. `AgentLoop(debug_observer=…)`.
- Task fields `model` / `provider` / `reasoning_effort` (not `model_id`):
  `_Run` → `ModelSelect` → `BackendModelClient(reasoning_effort=…)`; recorded in
  the `runs` table (nullable columns, `RUNS_MIGRATIONS` backfills old DBs) and
  logged once per task by `_accept_task` (never the prompt).

## 4. Other behaviour worth knowing

- **Hero compaction is default-on**: the executor builds
  `BackendModelClient.cheap_clone()` (same model, `reasoning_effort="none"`,
  512 tokens, no tools) and passes it as `aux_model`; tier-2/3 context summary
  and mem0 fact extraction run on it. Measured: reasoning **off** summarizes
  better here (reasoning "low" over-applied the redaction rule).
- **mem0**: one `Memory` handle per workspace root, process-wide
  (`memory._MEM_BY_ROOT`), because embedded Qdrant refuses a second client on the
  same folder; `close_cached_memories()` runs from `Executor.stop()`. Provider is
  registered under the allowlisted alias `lmstudio` (mem0 2.0.x validates
  provider names before the factory). Embedder falls back to local fastembed
  when no proxy key is set.
- **Worker survival**: `_work` turns any exception from `_run_task` (model
  select / runtime build) into an error terminal + failed `runs` row; the worker
  thread lives on. `_accept_task` refuses a non-string prompt up front.
- **Per-task clients** (main, hero, browser) are closed in `_run_task`'s finally.
- `mcp_oauth_connect` is offered only for exchange-form servers
  (`oauth.token_url` + `client_id`), not for device-forwarded oauth blocks.
- `mcp_client.tool_name` caps names at 64 chars (contract regex) with a
  deterministic hash suffix; nothing re-derives server/tool from the string.

## 5. Live probes (real backend, use the app's stored session; cost: cents)

All read the signed-in app session from
`~/.local/share/dev.chuk.cowork/shared_preferences.json` (or `.env.live`).
Run from `agent/`; set `MEMGUARD_ALLOW_MB=8192` for the fastembed-heavy ones.

| Probe | Proves | Last result |
|---|---|---|
| `uv run python tests/live_native_probe.py` | server returns a native `tool_calls` frame for declared `tools[]` | PASS |
| `MEMGUARD_ALLOW_MB=20480 uv run python tests/live_long_context.py` | tier-2/3 compaction fires on a long single session and the early fact is recalled exactly | PASS (2×) |
| `MEMGUARD_ALLOW_MB=8192 uv run python tests/live_memory_two_tasks.py` | mem0 still works on the second task of a workspace | PASS |
| `uv run python tests/live_reprovision_probe.py` | stale token → `reprovision_request` → re-provision → same request retried; GoTrue untouched | PASS |
| `uv run pytest tests/test_live_model.py -v -s` | the model writes a file instead of printing it | env-gated |

**Do not** rotate the user's real token from a probe: it logs the running app out.
The c91 Definition of Done (app rotates its token mid-task, host task continues)
is run with the real app once 98's `tokenRefreshed → provisionAccount` and the
`reprovision_request` / `account_session_rotated` handling are in.

## 6. Open beads touching Python (at handover)

- `cowork-c91` (P1) — host side DONE (this handover); needs app side (98) and
  the live DoD run. Note in the bead.
- `cowork-jqi` (P1) host-side OAuth for catalogue connectors — owner 47.
- `cowork-sls` (P1) hand test MCP OAuth with a real provider.
- `cowork-95i.*` (P3) service API tools — not started.
- `cowork-kjl.5/.6` (P3) here.now follow-ups.
- Model probe (deepseek-v4-flash-0731 via fireworks; newest Gemini 3) was
  reassigned to cowork-13 — `tests/live_native_probe.py` takes
  `COWORK_LIVE_MODEL` to pick a model.

## 7. Known limitations / next steps

- Host-side refresh while detached still rotates the shared pair; the
  `account_session_rotated` frame is the mitigation. The clean end state is an
  independent host credential (HANDOFF_2026-09-04 §5) — not built.
- `mcp_credentials` and `account_session_rotated` have no durable outbox; they
  are re-sent until acked, which is why the ack is defined as "the device sends
  the token back".
- A rotation while the host process dies before the app reconnects is lost
  (in-memory only).
