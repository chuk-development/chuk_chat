# Proposal: tool cards and "Worked for" the same live and replayed (cowork-84)

Beads: cowork-b45 (tool cards differ after replay), cowork-al2 ("Worked for 0s"),
cowork-266 (subagent/file/approval not persisted, separate).
Contract: docs/WIRE_CONTRACT.md, section "Tool events and timestamps".
Owner of the files below: cowork-47. This file is the diff proposal; cowork-84
does not edit them. Python (frames, persistence, replay): cowork-b5.

## What is already equal (verified 2026-09-05)

- The row shape the imported screen renders is the same on both paths:
  `sender: ai`, `text`, `reasoning`, `toolCalls` (flat JSON list), and
  `contentBlocks` only when a file block exists. The bubble takes the classic
  layout (`_buildActivityTimeline(widget.toolCalls!, live: true)` +
  `_buildInfoStatusBar`) for both.
- `agent_activity_model.dart` and `agent_activity_timeline.dart` are byte-equal
  to chuk_chat master. Nothing to change in the renderer.
- The app-side mapping of one `tool` frame is the same on both paths for
  `name`, `arguments.command`, `arguments.exit_code`, `status`, `result`.
  The parity test `app/test/services/cowork/tool_card_parity_test.dart`
  (cowork-84) pins that and stays green today.

What differs comes from the host (two different frame sources, no timestamps)
and from three small gaps on the app side, below.

## 1. `cowork_relay_client.dart` — `CoworkRelayTool.fromPayload`

Read the new fields. `arguments` is an object now; `_asText` returns null for
it today, so every card would lose its arguments once b5 ships.

```dart
class CoworkRelayTool extends CoworkRelayInbound {
  const CoworkRelayTool(
    this.name, {
    this.status,
    this.arguments,
    this.argumentMap,        // NEW
    this.result,
    this.detail,
    this.exitCode,
    this.timedOut = false,
    this.duration,
    this.failed = false,
    this.replay = false,
    this.mid,
    this.callId,             // NEW
    this.startedAt,          // NEW
    this.completedAt,        // NEW
    this.raw = const {},
  });

  factory CoworkRelayTool.fromPayload(Map<String, dynamic> payload) {
    ...
    final rawArgs = payload['arguments'];
    final argumentMap = rawArgs is Map
        ? Map<String, dynamic>.from(rawArgs)
        : null;
    final arguments = _asText(payload['command']) ??
        (rawArgs is String ? rawArgs : null);
    // The host's own verdict wins; the old derivation stays for old hosts.
    final status = payload['status'];
    final failed = status == 'error' ||
        timedOut ||
        (exitCode != null && exitCode != 0) ||
        payload['error'] != null;
    // `result` is the text the model got; stdout/stderr are its projection.
    final result = _asText(payload['result']) ??
        _asText(payload['error']) ??
        (stderr != null && stderr.isNotEmpty && failed ? stderr : stdout);
    ...
    return CoworkRelayTool(
      name,
      ...
      argumentMap: argumentMap,
      callId: _asText(payload['call_id']),
      startedAt: _asEpoch(payload['started_at']),
      completedAt: _asEpoch(payload['completed_at']),
      ...
    );
  }

  /// The native arguments, when the host sent them as an object.
  final Map<String, dynamic>? argumentMap;
  final String? callId;
  final DateTime? startedAt;
  final DateTime? completedAt;

  static DateTime? _asEpoch(Object? value) {
    if (value is! num) return null;
    return DateTime.fromMillisecondsSinceEpoch((value * 1000).round(), isUtc: true)
        .toLocal();
  }
}
```

`CoworkRelayDone`: add `startedAt`, `finishedAt` (DateTime?, same `_asEpoch`),
`firstMid`, `lastMid` (int?, `_asInt`). Decode in the `case 'done'` branch.

`CoworkRelayRunState` already has `startedAt` (double). Keep it.

## 2. `cowork_run_ledger.dart` — one mapping, both paths

Today the ledger (`openTool` + `closeTool`) and the loader each build their
own `ToolCall`. Put the mapping in ONE place and let both call it:

```dart
/// The renderer's shape of one host tool frame. Used by the live path
/// (ledger) and the replay path (loader) so both draw the same card.
ToolCall toolCallFromRelay(CoworkRelayTool event, {DateTime? now}) {
  final clock = now ?? DateTime.now();
  final args = <String, dynamic>{
    if (event.argumentMap != null)
      ...event.argumentMap!
    else if (event.arguments != null && event.arguments!.isNotEmpty)
      'command': event.arguments,
    if (event.exitCode != null) 'exit_code': event.exitCode,
  };
  final startedAt = event.startedAt ?? clock;
  final completedAt = event.completedAt ??
      (event.duration != null ? startedAt.add(event.duration!) : clock);
  return ToolCall(
    id: event.callId,
    name: event.name,
    arguments: args,
    status: event.failed ? ToolCallStatus.error : ToolCallStatus.completed,
    result: event.detail ?? event.result,
    startedAt: startedAt,
  )..completedAt = completedAt;
}
```

`closeTool` keeps its open/close matching but fills the call from this
function (name, args, result, status, timestamps). `openTool` sets
`startedAt` from the frame when present.

`CoworkRun`: add `finishedAt`, `firstMid`, `lastMid`; `finish(...)` takes
them from the live `done`. `adoptRunning` already takes `startedAt`.

## 3. `cowork_replay_loader.dart`

a) `case CoworkRelayTool`: replace the inline `ToolCall(...)` with
   `toolCallFromRelay(event)`.

b) `case CoworkRelayDone` (persisted run terminal, not history end): before
   `_closeAiRow(draft)`, stamp the run length on the open answer row:

```dart
final started = event.startedAt;
final finished = event.finishedAt;
if (started != null && finished != null && draft.aiRow != null) {
  final ms = finished.difference(started).inMilliseconds;
  if (ms >= 0) draft.aiRow!['generationMs'] = '$ms';
}
```

   Do NOT write `startedAt` on a replayed row. chuk's
   `ChatPersistenceHandler.stampWorkedFor` re-stamps the NEWEST row from
   `startedAt` on every save; a host time there turns "Worked for 26s" into
   the age of the thread on the next save. With `generationMs` only, the
   timeline uses it as `finalDuration` and the handler skips the row.

c) `case CoworkRelayRunState`: pass the host clock through:
   `adoptRunning(..., startedAt: event.startedAt == null ? null : DateTime.fromMillisecondsSinceEpoch((event.startedAt! * 1000).round()))`.

d) Cursor after a LIVE run. Make `_advanceCursor` public
   (`advanceCursor(String session, int mid)`). Today the cursor moves only on
   a replay commit; live events carry no `mid`, so after a live run the next
   replay (reconnect, host restart, thread switch back) sends that run's
   rows again above the old cursor, `honouredCursor` is true, and `_commit`
   appends them behind the copy the imported screen already saved. That is
   the duplicate turn with differently drawn cards (bead cowork-bkw shares
   this cause).

## 4. `websocket_chat_service.dart` — live `done`

```dart
case CoworkRelayDone():
  final lastMid = event.lastMid;
  if (lastMid != null) {
    CoworkReplayLoader.instance.advanceCursor(sessionKey, lastMid);
  }
  endRun(...);   // unchanged; ledger.finish also gets startedAt/finishedAt
```

## 5. Tests to add (47's files; cowork-84 wrote the parity test)

- relay client: a `tool` payload with `arguments: {}` object, `status`,
  `started_at`/`completed_at`, `result` decodes into the new fields; an old
  payload (`command` + `stdout`) still decodes as before.
- ledger test: `toolCallFromRelay` uses host timestamps when present and the
  clock otherwise.
- loader test: a replayed run terminal with `started_at`/`finished_at` writes
  `generationMs` and no `startedAt` on the answer row.
- adapter test: a live `done` with `last_mid` moves the cursor.
- `tool_card_parity_test.dart` (cowork-84): extend the "same on both paths"
  assertion to `startedAt`/`completedAt` once the frames carry them.
