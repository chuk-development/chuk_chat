# deepseek-harness ideas: check against our code (2026-11-04)

Item numbers refer to `docs/research/DEEPSEEK_HARNESS_IDEAS.md`.
Status: HAVE / PART (partial) / MISS / N/A. Size: S / M / L.
C = Flutter client (`lib/`), API = `/home/user/git/api_server`, AG = `agents/`.
`RT` = `agents/runtime/src/chuk_agents_runtime`, `EX` = `agents/executor/src/chuk_agents_executor`.

Totals: 92 items. HAVE 3, PART 50, MISS 36, N/A 3.

## A. Real bugs found during the check

| Bug | Where | Fix | Size |
|-----|-------|-----|------|
| B1. Server drops a history user turn when its content is a list (image + text). The text is lost too. | API `routers/ai/multiplex.py:1274` | Accept list content, keep `text` and `image_url` blocks | S |
| B2. Upstream closes without `[DONE]`: server logs a warning and sends `done`. Client saves a cut answer as complete. | API `multiplex.py:2518-2526` | Emit `error` `upstream_interrupted` (as `openai_compat.py:479` does) | S |
| B3. Idle timer with partial content calls `onComplete`. Stream closed without `done` also calls `onComplete`. | C `streaming_manager_io.dart:118-123`, `streaming_manager_base.dart:427-458` | Call `onError(idleTimeout)`, keep partial text via the salvage path | S |
| B4. `finish_reason` never reaches the client (only in the `timing` frame, which the client drops). Truncation and tool-use signals never fire on the hosted path. | API `multiplex.py:2381`, C `multiplex_connection.dart:714-778` | Send `finish_reason` in a `meta` frame before `done` | S |
| B5. Reply cut at `length` still runs its tool calls. `openai_compat` reports `tool_calls` instead of `length`. | API `multiplex.py:2350`, `openai_compat.py:515-523`; C `tool_call_handler.dart:987` | Check `length` first; drop calls and send "continue" | S |
| B6. Out-of-credits arrives as code `billing`; client only maps HTTP 402. Upgrade dialog never shows. | C `streaming_manager_base.dart:183`, API `multiplex.py:1038` | Map `billing` to `__PAYMENT_REQUIRED__` | S |
| B7. History caps (100 msgs / 500k chars) and malformed-call removal leave orphan tool results. Upstream answers 400. | API `multiplex.py:1225-1237`, `746-775` | Cut at unit boundaries; drop results without a matching call | S |
| B8. Two calls with the same id in one round overwrite each other; fallback id `call_{pos}` repeats every round. | C `tool_call_handler.dart:1431,1469,1500`; API `multiplex.py:857` | Make ids unique per turn | S |
| B9. Agents local backend: every shell/python/job inherits the full host env (account token, API keys). | AG `sandbox/.../local.py:89`, `RT/environment.py:89` | Env allowlist, drop `KEY/TOKEN/SECRET/PASSWORD`, add `NO_COLOR TERM=dumb PAGER=cat` | S |
| B10. `--sandbox auto` falls back to local without isolation and without a warning in the app. | AG `host/.../cli.py:449-466` | Show the fallback in the app; refuse risky toggles | S |
| B11. Approval card stays after timeout/stop; user can tap Allow on a dead request. | EX `executor.py` `_close_approval` | Re-send `approval_request` with `decision`; app removes the card | S |
| B12. Diff widget runs O(m*n) LCS on every `build()` with no cap. Large diff freezes the UI. | C `lib/widgets/diff_widget.dart:86-99,262` | Memoise; plain +/- over 256 changed lines | S-M |
| B13. Flutter MCP tool names cut to 64 chars without hash; names can collide. | C `lib/services/mcp/mcp_connection.dart:223-227` | Hash suffix like `RT/mcp_client.py:137` | S |
| B14. Agents workspace git commits into the user's own repo and index. | AG `RT/workspace_git.py:356` | Private `GIT_DIR` / `GIT_INDEX_FILE` | M |
| B15. Native round with mixed valid/rejected calls: rejected calls are not reported to the model. | C `tool_call_handler.dart:1313-1326` vs `1554` | Add each rejected call with a `Rejected: <reason>` result | S |
| B16. Client forced final pass removes `tools[]` (cache miss); server keeps tools with `tool_choice:none`. | C `tool_call_handler.dart:705-709` | Keep tools, set `tool_choice: none` | S |
| B17. Anthropic tool loop: no history cache breakpoint (last assistant has `content: None`). | API `chat/prompt_cache.py:124-134` | Mark last message incl. `tool` / `tool_calls` messages | S |
| B18. Agents ladder always uses default 128k context, not the model's real size. | AG `RT/runtime.py:441` | `LadderConfig(context_length=model.context_length)` | S |
| B19. api_server tests (51 entries) never run in CI. | API `.github/workflows/` | Add a pytest workflow | S |
| B20. Repo has `agents.md -> CLAUDE.md` and a separate `AGENTS.md`; on macOS the names collide. | chuk_chat root | Merge into one file + one symlink | S |
| B21. Not verified: voice assistant may send the first user turn twice. | C `lib/assistant/assistant_session.dart:231`, API `multiplex.py:1294` | Check, then fix | S |

## B. Cache: what breaks the prefix today (client)

Everything below sits in system message 0 and changes during a chat. Each
change makes the full history a cache miss.

1. Date line, once per day (`tool_prompt_builder.dart:72-99`).
2. `CONTINUATION` block added on tool-result passes (`tool_prompt_builder.dart:286-301`). Pass 1 and pass 2+ differ.
3. Soul / user / memory text, re-read every message (`tool_prompt_builder.dart:103`).
4. Connected MCP server list (`tool_call_handler.dart:1907-1912`).
5. Active skill body under `## ACTIVE SKILL` (`tool_executor.dart:1060-1095`).
6. `tools[]` order = map insertion order; MCP reconnect re-registers (`mcp/mcp_tool_bridge.dart:17-37`).
7. Server history cap and the 10-turn image window move every turn (`multiplex.py:1225`, `chat_history_builder.dart:33`).

Fix: freeze system message 0 per chat. Send each change as an appended,
tagged user note (as `RT/clock.py` does). Sort `tools[]`. Agents already do
this correctly (frozen system prompt, appended `[clock]` row).

## C. Status per item

### LLM, cache, context (1-17)

| # | Status | Note / improvement | Size |
|---|--------|--------------------|------|
| 1 | N/A | All upstreams are OpenAI-compatible; no direct DeepSeek provider | L |
| 2 | MISS | Store `reasoning_details` per round with model id; replay to same model only | S-M |
| 3 | MISS | Sort `tools[]`; keep MCP tools behind `find_tools` in native mode | S/M |
| 4 | MISS | Freeze system prompt; changes as appended notes (section B) | S |
| 5 | MISS (C) | No chat compaction; AG summarizer uses a fresh prompt (OK) | M |
| 6 | PART | AG correct; C date in system prompt | S |
| 7 | MISS (C) / PART (AG) | C only "Too much context"; AG ladder exists, add "summary must be smaller" check | M / S |
| 8 | PART | C + API keep head only (3000 of 4000); change to head 4096 + tail 1024, code points; cap newest round too | S |
| 9 | MISS (C) / PART (AG) | Spill to file + `read` notice; C `read_tool_result(id, offset)` | M |
| 10 | PART | Images dropped silently, newest dropped first, sent to text-only models | S-M |
| 11 | PART | Flat 1000 tokens per image; per-model formula | S |
| 12 | N/A | No direct DeepSeek | - |
| 13 | PART | Unknown cache value becomes 0; live usage event ignored | S |
| 14 | MISS (C) / PART (AG) | Anchor on last real usage + delta | S |
| 15 | HAVE | Catalog with capability flags; cache 24 h, could be 10 min SWR | S |
| 16 | MISS | `x_chuk: {purpose, chat_id_hash, pass}`; per-chat `user` for OpenRouter affinity | S |
| 17 | MISS (C) / PART (AG) | See B18; C compact before switch to smaller model | S |

### Reliability (18-26)

| # | C | API | AG | Improvement |
|---|---|-----|----|-------------|
| 18 | PART | PART | PART | API `classify_upstream()`: auth, quota, rate_limit, context_window_exceeded, invalid, server; mid-stream errors = `upstream_interrupted`; AG compact + retry on context overflow. B6 |
| 19 | PART | PART | PART (OK) | Jitter ±10 %, honour upstream `retry-after` up to 10 s |
| 20 | PART | PART | HAVE | B2, B3 |
| 21 | PART | MISS | PART | B4, B5 |
| 22 | PART | MISS | PART | B7, B8; `validateToolPairing()` before send |
| 23 | PART | N/A | MISS | C: count all tools, note at 3/5/8; AG: same in `loop.py` |
| 24 | PART | N/A | PART | C `.timeout()` around `execute()` and `multiplex_connection.tool()`; AG `anyio.fail_after` |
| 25 | HAVE | N/A | PART | AG all sequential; add `concurrency_safe` flag |
| 26 | PART | N/A | HAVE | B15 |

### Tools and safety, Agents (27-40)

| # | Status | Improvement | Size |
|---|--------|-------------|------|
| 27 | PART | `stopped: user_stop/timeout`, `exit_code` last key | S |
| 28 | MISS | `sandbox_escalation` approval class with justification | M |
| 29 | PART | B11 | S |
| 30 | MISS | Presets Full / Careful / Locked, mismatch = Custom | S |
| 31 | MISS | Cheap-model review for shell/python/write; reviewer sees args only | M |
| 32 | MISS | `edit_file(path, old, new, replace_all)` | S |
| 33 | MISS | `apply_patch` port | M |
| 34 | MISS | `read_file` returns mtime+sha; required for edit/write | S-M |
| 35 | PART | `offset/limit` + footer in `read_file` | S |
| 36 | MISS | B9; SIGTERM then SIGKILL after 3 s | S |
| 37 | PART | bwrap for local (`--unshare-net`), docker `--cap-drop ALL --pids-limit`; B10 | M |
| 38 | PART | Foreground timeout moves to background job | M |
| 39 | PART | Untrusted prefix in `web_fetch.py` and `web_tools.dart`; pin resolved IP (DNS rebinding) | S |
| 40 | MISS | Required `description` arg on `run_command` / `python` | S |

Other safety notes: network is ON by default in the sandbox; docker can reach
the LAN and 169.254.169.254 via `curl`; shell/python/write never ask.

### Agent features (41-58)

| # | Status | Improvement | Size |
|---|--------|-------------|------|
| 41 | MISS | Goal mode (`RT/goal.py`) | L |
| 42 | PART | Core done (`EX/shell.py` `JobWakeRouter`); add `maxConsecutiveWakes` | S |
| 43 | PART | Add `target: this_session/new_once/new`; spec help in tool error | M / S |
| 44 | PART | `fork=true` (same model, parent history); settled notice after `wait=false` | M / S |
| 45 | PART | Agent `ask_user` with pending timeout and late answer by callId | M |
| 46 | MISS | Plan mode: prompt-only flag, `exit_plan_mode` approval | M |
| 47 | PART | C: skill body as user message, hashed catalog; parse `disable-model-invocation` | S |
| 48 | PART | B13; feed server instructions (32 KB, as data); mask secrets in errors; background reconnect | S / M |
| 49 | PART | Up to 4 files per call; link rule `<path>#L24-L30` | S |
| 50 | PART | B14; show `changed_files` per turn in the app | M |
| 51 | MISS | `todo_write` (chat + agents), sticky card | S |
| 52 | PART | `source` field on context/user rows, chips in UI | M |
| 53 | PART | Title input as JSON array, first line only | S |
| 54 | PART | Composer chat picker, snapshot as untrusted, `<` escaped | M |
| 55 | PART | Workspace `complete` + `includeRuntimeContext` flags | S |
| 56 | MISS | Feedback sheet, 7 categories, sent to backend | S |
| 57 | MISS | ACP `ChildRunner` for claude / codex | M |
| 58 | HAVE | Crash gap: `sweep_orphan_runs` should write "unknown outcome" tool rows | S |

### UI (59-78)

| # | Status | Improvement | Size |
|---|--------|-------------|------|
| 59 | PART | Group calls by category, max 3, 150 ms min title | M |
| 60 | PART | Failed turns must not fold (`_isExpanded` ignores `hasError`); detail modes | S / M |
| 61 | MISS | Text shimmer while running; tabular figures on timer | S |
| 62 | PART | "Preparing: Edit x 1KB"; `+a -r` on collapsed row | S-M |
| 63 | PART | Terminal block: no wrap, h-scroll, head/tail 8+8, ANSI SGR, exit capsule on failure | M |
| 64 | PART | B12; 3 context lines, fold after 9 rows | M |
| 65 | PART | Card in composer slot, Enter/Esc shortcuts (lock already HAVE) | S |
| 66 | PART | `recommended` preselected, composer seat | M |
| 67 | PART | Steer (Ctrl+Enter), double Esc stop, keep draft until ack | M |
| 68 | MISS | `/` and `@` menu with atomic chips | L |
| 69 | PART | Stats row under composer: tok/s, cache hit %, context ring | S |
| 70 | PART | No autofocus on all phone chats; 16 px composer font on web | S |
| 71 | MISS | Turn rail, hidden under 900 px | M |
| 72 | PART | Show "Approval / Answer" instead of time when `waitingForUser` | M |
| 73 | PART | Like/dislike with 7 reason chips; token usage in normal chat | S |
| 74 | MISS | xlsx preview in isolate; docx/pptx to PDF on server | L |
| 75 | PART | Clamp single image aspect 1:4..4:1 | S |
| 76 | PART | Mask pasted keys in user bubbles (first 8 chars, eye toggle) | S |
| 77 | PART | ~15 literal radii in code; `radiusForHeight()` helper | S |
| 78 | PART | Shortcut registry + Ctrl+/ dialog | M |

### Repo and process (79-92)

| # | Status | Improvement | Size |
|---|--------|-------------|------|
| 79 | PART | B20; one root file + symlink; `lib/`, `agents/`, `test/` AGENTS.md | M |
| 80 | PART | `docs/AGENTS.md` tier table | S |
| 81 | MISS | Word budgets (CLAUDE.md 5,716 words, AGENTS.md 2,662, 44 % duplicate lines) | S |
| 82 | MISS | `trim-cot-leakage` skill | S |
| 83 | MISS | `tool/change_scope.dart` + pre-push skill | S-M |
| 84 | PART | ~60 of 127 `docs/*.md` are dated session files; move to `.agents/notes/<status>/` | M |
| 85 | PART | l10n key-parity test (`test/verify_languages.dart` asserts nothing); hugeicons freshness | M |
| 86 | PART | Cache DB v6 has no migration test; schema fingerprint test | M |
| 87 | MISS | Record/replay SSE cassettes (api_server + stream parser tests) | M |
| 88 | MISS | Ratchet for `!` (~1,500), `// ignore` (44) | M |
| 89 | MISS | jscpd for Dart, advisory first | S |
| 90 | MISS | Doc-ref checker (`AGENTS.md:287` says api_server has no tests; it has 51) | S |
| 91 | PART | `dart format` on staged files in `.beads/hooks/pre-commit` | S |
| 92 | PART | Strong already; add memory ceiling and `docs/perf_budgets.json` | M |
