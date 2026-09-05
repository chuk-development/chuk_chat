# Handover 2026-09-05 — tool cards + "Worked for" live vs. replay (cowork-84)

Session cowork-84 ("cowork-toolcards"). Beads: cowork-b45 (P1), cowork-al2 (P2),
cowork-266 (new, P2). Coordinator: cowork-b7. Nothing committed (rule).

## Findings (verified in code, 2026-09-05 03:10–03:50)

### cowork-b45 — tool cards differ after replay: the frames come from two sources

| | live | replay |
|---|---|---|
| source | `executor.py` `_env_shim.on_run` (~L1515): one `tool` frame per shell command `env.run_bash` runs | `state.py` `replay_events`: one `tool` frame per native tool call on a stored assistant row |
| tools shown | `run_command` only — but also the internal shell of `write_file` / `read_file` / `list_dir` / `run_python` (`tools.py`), as `printf … base64 -d …` command cards | every native tool (`run_command`, `write_file`, `web_search`, MCP tools, `finish`, …) |
| `command` | the shell line | the native arguments as one JSON string |
| `exit_code` / failure | real | always `0`, never failed |
| timestamps | none | none |

App side, both paths map a frame the same way (`name`, `arguments.command`,
`arguments.exit_code`, `status`, `result`), and the row shape is the same
(`toolCalls` flat + `reasoning` + `text`; `contentBlocks` only with a file).
`agent_activity_model.dart` / `agent_activity_timeline.dart` are byte-equal to
chuk master. So the renderer is not the cause; the host is.

### cowork-al2 — "Worked for 0s"

`AgentActivityTimeline` takes, in order of trust: `finalDuration`
(`row.generationMs`), a running clock from `row.startedAt`, else first-start →
last-completion of the tool calls. Replayed rows carry neither `startedAt`
nor `generationMs` (loader writes only sender/text/reasoning/toolCalls), and
the loader stamps every replayed `ToolCall` with fold time (`completedAt =
DateTime.now()`, `startedAt` = ctor default) → span 0 s. Live rows are stamped
by chuk (`startedAt` on the placeholder in `desktop_send_logic.dart` L284 /
`chat_ui_mobile.dart` L2425, `generationMs` in
`ChatPersistenceHandler.stampWorkedFor`) and are right.

### New: duplicate turn after a reconnect (part of cowork-bkw)

Live frames carry no `mid`, so the replay cursor never moves during a live
run. The next replay (reconnect, host restart) sends the live run's rows above
the old cursor; `_commit` sees `honouredCursor` and APPENDS them behind the
copy the imported screen already saved. The user sees the turn twice, the
second with replay-style cards. Fix: `done.last_mid` on the live terminal →
`advanceCursor`.

### New: cowork-266 — `subagent` / `file` / `approval_request` not persisted

They exist only live; a replay cannot carry them, so their cards vanish.

### Blocking regression found on the way (not mine)

`chat_storage_crud.dart` `_doSaveChat` (untracked, changed 03:38, storage
session) now requires a signed-in Supabase user and a loaded encryption key.
The replay loader writes its rows through that `saveChat` and only logs the
failure → `cowork_replay_loader_test` 10/12 red, my parity test red at the
same line, and in the app a missing key (cowork-6v5) means a replay lands
nothing in the cache. Reported to cowork-b7 for the storage session.

## Built (2026-09-05 ~04:30, after the coordinator handed 47's files to me)

All four app files carry the contract now; Python (cowork-b5) sends the frames
(`agent/src/cowork_agent/tool_events.py`, `protocol.tool_payload` /
`done_payload(run_stamps)`).

- `lib/services/cowork/cowork_relay_client.dart` — `CoworkRelayTool.argumentMap`
  / `callId` / `startedAt` / `completedAt`; `fromPayload` reads `arguments`
  (object), `result`, `status` (the host's `error` verdict wins), `call_id`,
  `started_at`, `completed_at`; old frames (`command` + `stdout`) decode as
  before. `CoworkRelayDone.startedAt` / `finishedAt` / `firstMid` / `lastMid`
  + `workedFor`. Top-level `epochSecondsToDateTime`.
- `lib/services/cowork/cowork_run_ledger.dart` — `toolCallFromRelay(event,
  {now})`: THE one mapping for both paths (object args, host clock, fallback
  clock). `recordTool(sessionKey, event)`: appends, or fills an open line with
  the same call id / name. `CoworkRun.finishedAt` / `hostStamped` / `firstMid`
  / `lastMid` / `workedFor`; `finish(...)` takes the stamps; `adoptRunning`
  marks a host clock.
- `lib/services/cowork/cowork_replay_loader.dart` — tool frames go through
  `toolCallFromRelay`; a replayed run terminal writes `generationMs` on the
  answer row (never `startedAt`); `run_state.started_at` reaches the ledger.
- `lib/services/websocket_chat_service.dart` — completed tool frames →
  `recordTool`; a live `done` with `last_mid` → `advanceCursor`, else 47's
  `invalidateCursor`; the run stamps go to `ledger.finish`.

Green (each file alone, `--timeout 60s`): `dart analyze` on the six files 0
issues; `tool_events_contract_test` 8/8 (new), `tool_card_parity_test` 5/5
(timestamps, `generationMs`, cursor), `cowork_run_ledger_test` 14/14,
`cowork_replay_loader_test` 16/16, `websocket_chat_service_test` 18/18.

P8 review F11 (recordTool could fill an open line of the same name that
carried another host id): fixed in the ledger — a known, differing `call_id`
is never filled; `openTool` takes an optional `callId` so a host that grows
`running` frames closes the right line. Verified: analyze 0,
`tool_events_contract_test` 10/10 (two new cases), `cowork_run_ledger_test`
17/17, parity 5/5 against f7's in-flight loader/relay/adapter edits.

Still open: the before/after screenshots (screen locked, host restart #2
pending) and `bd close cowork-b45 cowork-al2` after the live check.

## What I wrote (first pass, before the files were handed over)

- `docs/WIRE_CONTRACT.md` — section "Tool events and timestamps (beads
  cowork-b45, cowork-al2)": one `tool` frame per native tool call on both
  paths with `arguments` (object), `result`, `status`, `started_at`,
  `completed_at`; `done` with `started_at`, `finished_at`, `first_mid`,
  `last_mid`. Python: cowork-b5. App: cowork-47.
- `docs/PROPOSAL_2026-09-05_TOOLCARDS_cowork-84.md` — the concrete Dart diffs
  for cowork-47's files (relay client, ledger `toolCallFromRelay`, loader
  `generationMs` without `startedAt`, `advanceCursor` on a live `done`).
- `app/test/services/cowork/tool_card_parity_test.dart` — the same scripted
  run through adapter → ledger → fold and through loader → cached rows; asserts
  count, order, name, arguments, status, result are equal. Timestamps join the
  comparison once the frames carry them. Red today only because of the storage
  regression above (fails before any assertion of mine).

## Open / next

1. Storage session: `saveChat` must fill the in-memory cache before Supabase /
   encryption (it was the "instant-paint cache") or the loader gets its own
   local sink. Then `cowork_replay_loader_test` and the parity test run again.
2. cowork-b5 lands the frames (contract section), cowork-47 the app mapping
   (proposal file). Then extend `_visible()` in the parity test with
   `startedAt` / `completedAt`.
3. (DONE except screenshots) Screenshots before/after: blocked twice — the screen was locked
   (`loginctl … LockedHint=yes`) and the host was down. Method for Wayland (from
   cowork-b7): `gnome-screenshot -f <tmp-in-repo>.png`, crop with `convert` to
   `docs/screenshots/84/`, delete the full-screen shot. `flutter-hot shot` does
   not work under Wayland (no X window for the Flutter app).
4. Rendering-side nice-to-have, not needed for parity: chuk's
   `agent_activity_model._subjectKeys` has no `command` / `code`, so a
   `run_command` step reads "Ran run command" with no command line. If wanted:
   fix in chuk master first, then re-import (verbatim-file rule).
