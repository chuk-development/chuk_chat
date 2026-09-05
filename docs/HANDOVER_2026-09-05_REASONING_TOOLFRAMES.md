# Handover 2026-09-05 — reasoning streaming, tool frames, run timestamps

Session `cowork-reasoning` (coordinator: cowork-b7, then cowork-76). Beads
`cowork-0ia` (reasoning), `cowork-b45` / `cowork-al2` (tool frames + "Worked
for 0s", Python part), `cowork-3hk` (thinking default `medium`, Dart, open).
Everything below is UNCOMMITTED on branch `cowork`; commit release is the
user's call (cowork-47 is the Python committer). No worktree, no branch switch.

## What was wrong (three causes, all proved)

1. **The host never streamed the model's thinking.** `agent/backend.py`
   `_chat_once` received the backend's `kind: "reasoning"` frames, appended them
   to `raw["reasoning"]` and dropped them. The executor's `StreamingModelClient`
   only had `on_delta`; `protocol.py` had no reasoning payload. The Dart chain
   (relay `case 'reasoning'` → `CoworkRelayReasoning` → adapter `ReasoningEvent`
   → chuk `StreamingManager.reasoningBuffer` → `MessageBubble.reasoning`) was
   already complete and waiting.
2. **The thinking block was hidden behind the verbose toggle.**
   `cowork_thread_view.dart` passed `showReasoningTokens: _verbose` (default
   false). chuk_chat binds it to the user's own "show reasoning" setting
   (`AppThemeService.showReasoningTokens`, default true). Coordinator decision:
   chuk semantics; tool calls / tps stay on verbose.
3. **The Thinking mode sends `reasoning_effort: medium`, which the default
   models do not accept — and the backend then sends NO reasoning at all,
   silently.** Live probe: glm-5.3-flash @ fireworks/serverless with `medium`
   → 0 reasoning frames (twice, also on novita); with `high` → 11 frames.
   Catalogue (`/v1/models_info`, 2026-09-05): glm-5.3-flash
   `supported_efforts` [low, high, max] (reasoning mandatory), glm-5.3
   [low, high, max], deepseek-v4-pro-0813 (the app's Thinking default)
   [none, low, high, max], deepseek-v4-flash-0731 [none, low, high, max],
   deepseek-v4-pro [none, high, xhigh], glm-5.2 [none, high, xhigh]. The app
   clamps only when `ModelCapabilitiesService` has the list; its cold-cache
   fallback ladder contains `medium`.

## What was built

### Python (agent / executor) — all suites green, ruff F/E9 clean

- `agent/src/cowork_agent/backend.py`
  - `BackendModelClient.on_reasoning` seam next to `on_delta`; fired per
    `reasoning` frame; a raising sink never aborts the turn; not inherited by
    `cheap_clone` (housekeeping must not narrate into the thread).
  - `reasoning_effort` read-only property.
  - `REASONING_LADDER`, `supported_efforts(models, model_id)`,
    `clamp_reasoning_effort(models, model_id, effort)` (see WIRE_CONTRACT
    `reasoning` section for the rules).
- `executor/src/cowork_executor/executor.py`
  - `StreamingModelClient(inner, on_delta=, on_reasoning=)`; fallback for a
    non-streaming inner emits reasoning once, then text.
  - `_run_task`: `on_reasoning=lambda t: self._event(rid, reasoning_payload(t))`;
    `_env_shim.on_run = None` (the shell hook emits no tool frames any more);
    `build_runtime(..., tool_event_observer=lambda f: self._event(rid, tool_payload(**f)))`;
    after the selector built the model, a clamped effort is logged and written
    to the runs row (`_record_run_effort`), and `run.reasoning_effort` updated.
  - `_record_run` returns the closed row's stamps; the live `done` carries
    `started_at / finished_at / first_mid / last_mid` (`run_stamps=`).
- `executor/src/cowork_executor/protocol.py`: `reasoning_payload(text)`;
  `tool_payload(**fields)` (the shared shape); `done_payload(run_stamps=)`.
- `executor/src/cowork_executor/backend.py`: `make_backend_model_select` clamps
  the effort against the catalogue it already holds, warns once per
  (model, level), builds the client with the effective level.
- `agent/src/cowork_agent/tool_events.py` (NEW): `tool_event_fields`,
  `tool_status`, `result_text` — ONE shape for live and replayed tool events
  (name, arguments, call_id, command only for run_command/run_python, result,
  projected exit_code/stdout/stderr/timed_out, status, started_at,
  completed_at, duration_ms).
- `agent/src/cowork_agent/loop.py`: `AgentLoop(tool_event_observer=)`; one event
  per native tool call after its result (`_emit_tool`); `_persist_assistant`
  stores `content["reasoning"]` from `response.raw`.
- `agent/src/cowork_agent/runtime.py`: `build_runtime(tool_event_observer=)`
  threaded to the loop (distinct from the pre-existing `tool_observer`, the
  journaling registry's subagent summary hook — a duplicate name broke the host
  import once; both packages are import-tested before every save now).
- `agent/src/cowork_agent/state.py`: `replay_events` emits a `reasoning` event
  before a turn's `delta` / `tool` events (same `mid`); tool events rebuilt via
  `tool_event_fields` with `started_at` = assistant row `created_at`,
  `completed_at` = tool row `created_at`; result rows matched per turn by
  `tool_call_id`, else by position (`_tool_rows_after`, `_match_tool_row`);
  `run_stamp_fields(row)`; `run_terminals` carries the four stamps;
  `update_run_reasoning_effort(run_id, effort)`.
- `agent/src/cowork_agent/__init__.py`: exports `run_stamp_fields`,
  `tool_event_fields`, `tool_status`, `result_text`, `clamp_reasoning_effort`,
  `supported_efforts`.

Tests added: `agent/tests/test_tool_events.py` (6), `test_backend.py` (+3
reasoning seam, +5 clamp), `test_loop.py` (+3 reasoning persistence, +4 tool
events), `test_state.py` (+3); `executor/tests/test_reasoning_stream.py` (8),
`test_tool_frames.py` (2), `test_model_select.py` (+2). Updated to the new
tool shape: `agent/tests/test_state.py` (replay), `executor/tests/test_replay.py`.

Suites at the last full run (before the clamp; clamp runs are in the log
files `_scratch_pytest_*.log` at the repo root): agent 765 passed / 3 skipped,
executor 123, host 118, ruff clean. Re-run: `cd agent && uv run pytest tests/
-p no:cacheprovider --ignore=tests/test_live_model.py`, same in `executor`
and `host`, plus `uv run ruff check --select F,E9 src tests`.

### Dart (app) — owner boundaries respected

- `app/lib/services/websocket_chat_service.dart` (my inbound mapping spot):
  `_isReplay` treats `CoworkRelayReasoning(replay: true)` as history, so a
  replayed thinking never enters a live run. Tests +2 in
  `test/services/websocket_chat_service_test.dart` (18 green).
- `app/lib/widgets/cowork_thread_view.dart`: `showReasoningTokens:
  AppThemeService.instance.showReasoningTokens` on both `ChukChatUI*` calls;
  listener `_onThemeChanged` so the setting reflows live. Test file: the
  quiet-default assertion now expects the thinking block visible; new test
  "the thinking block follows the 'show reasoning' setting, not verbose"
  (flips the persisted preference through the service's cached prefs instance
  — the setter debounces a Supabase sync on a timer the harness rejects).
  `cowork_thread_view_test.dart` 23/23, scoped `flutter analyze` 0.
- Built by cowork-47 on my diff proposal: `CoworkRelayReasoning(replay, mid)` in
  `cowork_relay_client.dart`; replay loader writes replayed reasoning into the
  restored answer row (`aiReasoning` → `row['reasoning']`).

### Docs

- `docs/WIRE_CONTRACT.md`: new `reasoning` section (live + replay, clamp
  rule); `mid` now also on replayed `reasoning`; "Tool events and timestamps"
  section (by cowork-84) marked implemented with the two details (no `mid` on
  live tool frames; per-turn result matching).

## Live proof (no UI) — `executor/tests/live_reasoning_probe.py`

Not pytest-collected. Runs an in-process `Executor` with a real
`BackendModelClient` (session from the app's own storage, token-rotation guard
like `live_native_probe.py`: never refreshes, needs >15 min token headroom).
Costs cents. `cd executor && uv run python tests/live_reasoning_probe.py`
(env: `COWORK_LIVE_MODEL`, `COWORK_LIVE_PROVIDER`, `COWORK_LIVE_REASONING`).

Run 2026-09-05 ~04:35, glm-5.3-flash @ fireworks/serverless, effort `high`:

```
sequence: reasoning ×11  tool delta tool done
reasoning frames: 11  chars: 43
  joined: 'Simple: run the command, then reply "done."'
delta frames    : 1  text: 'done'
tool frame      : {"name": "run_command", "arguments": {"command": "echo hello > probe.txt"},
                   "command": "echo hello > probe.txt", "status": "completed", "exit_code": 0,
                   "started_at": 1788574076.987802, "completed_at": 1788574077.0016656,
                   "duration_ms": 14}
tool frame      : {"name": "finish", "arguments": {"summary": "done"}, "status": "completed",
                   "started_at": 1788574086.4009135, "completed_at": 1788574086.4036481, "duration_ms": 3}
done            : {"type": "done", "reason": "finished", "started_at": 1788574070.5993595,
                   "finished_at": 1788574086.4554918, "first_mid": 0, "last_mid": 6,
                   "run_id": "9ca7bc49…", "iterations": 2}
probe.txt written: True
```

Same model, effort `medium` (novita/fp8 and fireworks/serverless): `sequence:
tool delta done`, 0 reasoning frames. That run is what the user saw.

The probe's checks (after the check fix): reasoning arrives, precedes the
first delta, is its own channel; one tool frame per native call with
arguments/status/clocks and a plain command line; done stamped; command ran.
The clamp has NOT been probed live yet (it needs a token with >15 min
headroom; the result must equal the `high` run when `COWORK_LIVE_REASONING=medium`).

## Host restarts

- #2 (04:20, this session): old 4125726 stopped, import probe, started from
  `host/` with the `.hostlive` env (47's one-liner, see COORDINATION). New pid
  61136; app reconnected and re-provisioned without a click (5c confirmed).
  This build streams reasoning and the new tool frames, done stamps.
- #3 (~04:55, this session): clamp + cowork-9e's persisted subagent/file/
  approval events. Old 61136 stopped, import probe green, new pid 201476;
  reconnected + "token provisioned" in ~15 s, no warnings in `.hostlive`.
- #4 (~05:25, this session): cowork-9e's F9 (`session_key` on
  `approval_request`). Old 201476 stopped, import probe green, new pid 1589404;
  app 441086 (cowork-c6) reconnected in ~10 s, no warnings.

## Verification tasks from the coordinator (2026-09-05, ~05:10)

- **cowork-jqi (host-side OAuth for catalogue connectors): CLOSED, superseded
  by P5 device OAuth.** Verified in `agent/src/cowork_agent/mcp_client.py`: an
  `oauth` entry without `access_token` stays a configured server; with
  `oauth.refresh_token` + `token_endpoint` the first request mints a token
  (`_http_headers` → `refresh_token`), on 401 the manager forces a refresh and
  redials; with no material at all only that server's handshake fails and is
  recorded in `MCPManager.errors` — the batch and the run continue. apiKey
  entries (no `auth`, key in the URL query) pass the else branch untouched;
  transport errors are redacted. New test
  `test_a_tokenless_oauth_entry_and_an_apikey_entry_are_both_kept` (green).
- **cowork-fqm (mcp_oauth_connect offered only for the exchange form):
  VERIFIED in code and test.** `runtime.py` builds `exchange_configs` only from
  configs whose `oauth` carries `token_url`, registers the tool only when that
  map is non-empty AND a session exists; `config_token_exchange` additionally
  requires `client_id` per server. Test `agent/tests/test_mcp_runtime.py`
  ("offered only for a server that declares that form", ~line 150): plain
  server → no tool, device-forwarded block (token_endpoint/refresh_token) →
  no tool, exchange form + session → tool, exchange form without session →
  no tool. Residual nit, not a bug: a `token_url` without `client_id` still
  registers the tool and that server's exchange returns "no token exchange
  configured" — the same message the fix was for, but only for a misconfigured
  mcp.json, never for a device-forwarded block.

## Open

- **UI screenshot proof** (user asked for it): send a task in Thinking mode
  after restart #3 with a supported effort (or any effort — the clamp fixes
  `medium`), capture `flutter-hot shot docs/screenshots/cowork-reasoning/<time>.png`
  showing the streamed thinking block, before/after. Blocked on "screen free"
  from the user; the app instance belongs to cowork-5c.
- `cowork-3hk` (Dart): Thinking default `medium` — fix in chuk_chat master
  first (clamp after catalogue load, before the first send), then re-import.
- `cowork-266` (cowork-9e): subagent/file/approval events persisted + replayed.
- Dart side of the tool-frame contract (`ToolCall.startedAt/completedAt`,
  `arguments`, `result`, `generationMs` from `done`, cursor to `last_mid` on a
  live done): cowork-84 (rendering) / cowork-47 (ledger, loader, relay).
- `live_reasoning_probe.py` assumes the model may add a `finish` call; if a
  model answers in prose without calling `run_command` the probe reports FAIL
  on the tool checks — that is the model, not the wire.
