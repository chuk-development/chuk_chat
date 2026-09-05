/// History is the server's. This is the client's side of getting it back.
///
/// The CoWork host keeps the authoritative transcript of every thread (see
/// docs/PRODUCT_PHILOSOPHY.md: "Full history comes back from the server"). When
/// the app pairs, switches agent, or reconnects, it asks for a `replay`; the
/// host answers with a `run_state` header, then the stored `user` / `delta` /
/// `tool` / `subagent` / `file` events marked `replay: true`, then a closing
/// `done` with `reason: "replay"`.
///
/// This loader is the ONLY consumer of those frames. A replayed frame must
/// never enter a live run's stream — that is what would append yesterday's
/// answer to today's turn — so the adapter drops everything this file handles,
/// and this file handles nothing live.
///
/// What it produces is the local instant-paint cache: the same
/// `List<Map<String, String>>` row shape the imported chat screen writes, saved
/// through [ChatStorageService] under the thread's session key. On the
/// history-end marker the cache for that session is replaced and
/// `ChatStorageService.changes` fires.
///
/// ## The cursor
///
/// Every replayed event carries `mid`, the host's message-store row id. The
/// highest one seen per session is persisted under
/// `cowork.replay_cursor.<sessionKey>` and sent back as `after_id`, so a
/// reconnect re-streams only what the app is missing instead of the whole
/// thread. A host that honours the cursor sends a delta, which is appended; a
/// host that does not (or a fresh install, cursor `0`) sends everything, which
/// replaces. The two are told apart by the lowest `mid` in the answer, not by
/// hope.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cowork/models/content_block.dart';
import 'package:cowork/models/tool_call.dart';
import 'package:cowork/services/chat_storage_service.dart';
import 'package:cowork/services/cowork/cowork_relay_client.dart';
import 'package:cowork/services/cowork/cowork_relay_link.dart';
import 'package:cowork/services/automations/automation_ledger.dart';
import 'package:cowork/services/cowork/cowork_run_ledger.dart';
import 'package:cowork/services/image_storage_service.dart';

/// Prefix of the per-session replay cursor key in SharedPreferences.
const String kReplayCursorPrefix = 'cowork.replay_cursor.';

/// One session's in-progress replay fold.
class _Draft {
  _Draft(this.sessionKey);

  final String sessionKey;

  /// The rows built so far, in the imported screen's raw-map shape.
  final List<Map<String, String>> rows = <Map<String, String>>[];

  /// The open assistant row, if a delta has arrived since the last user turn.
  Map<String, String>? aiRow;
  final StringBuffer aiText = StringBuffer();

  /// What the model thought before it answered, when the host stored it. The
  /// bubble renders it as the collapsible thinking block, so a replayed answer
  /// looks like the live one it replaces.
  final StringBuffer aiReasoning = StringBuffer();
  List<ToolCall> aiToolCalls = <ToolCall>[];
  List<ContentBlock> aiBlocks = <ContentBlock>[];

  /// The `after_id` this replay was asked with.
  int afterId = 0;

  /// True once a frame has folded into this draft: the host is answering the
  /// request it was made for, and a later `expect` must not move it.
  bool started = false;

  /// A second request for the same thread made while this one is still being
  /// answered. The host answers in order, so it takes over at [_commit].
  _Draft? next;

  /// The lowest and highest `mid` this replay carried.
  int? minMid;
  int maxMid = 0;
}

/// Folds the host's replay stream into the local instant-paint cache.
class CoworkReplayLoader extends ChangeNotifier {
  CoworkReplayLoader._();

  static final CoworkReplayLoader instance = CoworkReplayLoader._();

  StreamSubscription<CoworkRelayInbound>? _sub;

  final Map<String, _Draft> _drafts = <String, _Draft>{};
  final Map<String, int> _cursors = <String, int>{};
  final Map<String, int> _revisions = <String, int>{};
  final Map<String, bool> _answerReady = <String, bool>{};
  final Map<String, String?> _answerReadyRun = <String, String?>{};
  final Set<String> _replayWanted = <String>{};
  final Map<String, String?> _hostPrompts = <String, String?>{};
  final Set<String> _hostRunning = <String>{};

  /// The session the current replay belongs to. Replayed events carry no
  /// session key of their own (only the `run_state` header does), so the
  /// caller names its target with [expect] before it asks.
  String? _activeSession;

  /// Frames waiting to be folded, and whether a drain is already running.
  ///
  /// The handlers must run strictly in order and one at a time: a file's bytes
  /// have to land in the blob store before the block that points at them joins
  /// a row, and the history-end write has to see every row that came before it.
  /// A plain queue drained by a microtask does that, and — unlike chaining onto
  /// a long-lived `Future` — it never inherits the zone that future was made in,
  /// so the fold runs in whichever zone the frame arrived in.
  final List<CoworkRelayInbound> _queue = <CoworkRelayInbound>[];
  bool _draining = false;

  /// Subscribes to the link's long-lived inbound stream. Idempotent.
  void attach() {
    if (_sub != null) return;
    _sub = CoworkRelayLink.instance.inbound.listen(
      _enqueue,
      onError: (Object error, StackTrace _) {
        if (kDebugMode) debugPrint('[cowork-replay] inbound error: $error');
      },
      cancelOnError: false,
    );
  }

  void _enqueue(CoworkRelayInbound event) {
    _queue.add(event);
    if (_draining) return;
    _draining = true;
    scheduleMicrotask(() async {
      try {
        while (_queue.isNotEmpty) {
          final next = _queue.removeAt(0);
          // Each frame swallows its own failure: one bad frame must never stop
          // the loader folding history for the rest of the session.
          try {
            await _handle(next);
          } catch (error, stack) {
            if (kDebugMode) {
              debugPrint('[cowork-replay] dropped a frame: $error\n$stack');
            }
          }
        }
      } finally {
        _draining = false;
      }
    });
  }

  void detach() {
    _sub?.cancel();
    _sub = null;
  }

  /// Reads the persisted cursors so [cursorFor] answers before any replay.
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final key in prefs.getKeys()) {
        if (!key.startsWith(kReplayCursorPrefix)) continue;
        final value = prefs.getInt(key);
        if (value != null && value > 0) {
          _cursors[key.substring(kReplayCursorPrefix.length)] = value;
        }
      }
    } catch (error) {
      // No prefs (a test without a mock store): every replay is a full one.
      if (kDebugMode) debugPrint('[cowork-replay] cursor load failed: $error');
    }
  }

  /// Names the thread the next replay answer belongs to. Call it immediately
  /// before `requestReplay`, with the same [afterId].
  ///
  /// Requests may overlap: the first pairing asks for `default` and, one frame
  /// later, for the host agent's thread; the user may pick another coworker
  /// while a replay is still streaming. The host answers them in order, each
  /// answer headed by its `run_state`, so the session a frame belongs to is
  /// decided by that header (or, for a header-less host, by the order of the
  /// requests) — never by the most recent `expect`, which would fold the tail
  /// of one thread's answer into the next thread's draft (review F1).
  void expect(String sessionKey, {int afterId = 0}) {
    final fresh = _Draft(sessionKey)..afterId = afterId;
    final inFlight = _drafts[sessionKey];
    if (inFlight != null && inFlight.started) {
      // The same thread again while its answer is still arriving: the answer
      // to THIS request comes after the current one ends, so it queues up.
      inFlight.next = fresh;
      return;
    }
    _drafts[sessionKey] = fresh;
    // Only when no answer is streaming right now is this the next one the
    // host sends. Otherwise the current answer's `done` (or the next
    // `run_state` header) moves the pointer when the time comes.
    if (!_drafts.values.any((d) => d.started)) _activeSession = sessionKey;
  }

  /// The replay cursor for [sessionKey]: the highest `mid` already stored.
  /// `0` means "replay everything", which is always safe to ask for.
  int cursorFor(String sessionKey) => _cursors[sessionKey] ?? 0;

  /// Bumped every time the cache for [sessionKey] is replaced. The thread view
  /// keys the imported screen on it, so a repaint is a remount off fresh rows.
  int revisionFor(String sessionKey) => _revisions[sessionKey] ?? 0;

  /// True when a replayed run finished with no app attached — the host never
  /// got a `run_ack` for it, so the user has an answer waiting.
  bool answerReadyFor(String sessionKey) => _answerReady[sessionKey] ?? false;

  /// The run the waiting answer belongs to, when the host stamped it. Lets the
  /// notification bookkeeping tell a second answer from a re-replay of the
  /// first (review F7).
  String? answerReadyRunFor(String sessionKey) => _answerReadyRun[sessionKey];

  void clearAnswerReady(String sessionKey) {
    _answerReadyRun.remove(sessionKey);
    if (_answerReady.remove(sessionKey) != null) notifyListeners();
  }

  /// True once, when a delta replay could not be applied because the local
  /// copy of the thread was unreadable (review F2): the cursor was forgotten
  /// and the caller should ask for the whole thread again.
  bool takeReplayWanted(String sessionKey) => _replayWanted.remove(sessionKey);

  /// True when the host says a run for [sessionKey] is in flight right now,
  /// including one that started before this app attached.
  bool hostRunning(String sessionKey) => _hostRunning.contains(sessionKey);

  /// The prompt an already-in-flight run is working on, when the host said.
  String? hostPrompt(String sessionKey) => _hostPrompts[sessionKey];

  /// Test seam.
  @visibleForTesting
  void reset() {
    detach();
    _drafts.clear();
    _cursors.clear();
    _revisions.clear();
    _answerReady.clear();
    _answerReadyRun.clear();
    _replayWanted.clear();
    _hostRunning.clear();
    _hostPrompts.clear();
    _activeSession = null;
    _queue.clear();
    _draining = false;
  }

  // --- the fold ---------------------------------------------------------------

  Future<void> _handle(CoworkRelayInbound event) async {
    switch (event) {
      case CoworkRelayRunState():
        _activeSession = event.sessionKey;
        if (event.isRunning) {
          _hostRunning.add(event.sessionKey);
          _hostPrompts[event.sessionKey] = event.prompt;
          // A run that belongs to the host process, not to this socket. The
          // ledger is what the thread view reads its run phase from.
          CoworkRunLedger.instance.adoptRunning(
            event.sessionKey,
            runId: event.runId,
            prompt: event.prompt,
            startedAt: epochSecondsToDateTime(event.startedAt),
          );
        } else {
          _hostRunning.remove(event.sessionKey);
          _hostPrompts.remove(event.sessionKey);
        }
        notifyListeners();

      case CoworkRelayUser(:final replay, :final text, :final mid):
        // Always true today (a user turn only exists in a replay); checked, not
        // assumed, like every other case (review F13).
        if (!replay) return;
        final draft = _draftFor();
        _closeAiRow(draft);
        draft.rows.add(<String, String>{
          'sender': 'user',
          'text': text,
          'reasoning': '',
        });
        _noteMid(draft, mid);

      case CoworkRelayDelta(:final replay, :final text, :final mid):
        if (!replay) return;
        final draft = _draftFor();
        _openAiRow(draft).aiText.write(text);
        _noteMid(draft, mid);

      case CoworkRelayReasoning(:final replay, :final text, :final mid):
        if (!replay) return;
        final draft = _draftFor();
        _openAiRow(draft).aiReasoning.write(text);
        _noteMid(draft, mid);

      case CoworkRelayTool(:final replay):
        if (!replay) return;
        final draft = _draftFor();
        // The SAME mapping the live ledger uses, so the replayed card is the
        // live card (bead cowork-b45).
        _openAiRow(draft).aiToolCalls.add(toolCallFromRelay(event));
        _noteMid(draft, event.mid);

      case CoworkRelaySubagent(:final replay):
        if (!replay) return;
        // One card per child, as live: the host stores one row per state
        // change and the last state wins (docs/WIRE_CONTRACT.md, "Persisted
        // subagent / file / approval events"). The SAME mapping the live
        // ledger uses (bead cowork-266).
        final draft = _draftFor();
        final row = _openAiRow(draft);
        ToolCall? existing;
        for (final call in row.aiToolCalls) {
          if (call.name == 'subagent' &&
              call.arguments['subagent_id'] == event.subagentId) {
            existing = call;
            break;
          }
        }
        final call = subagentCallFromRelay(
          existing,
          subagentId: event.subagentId,
          title: event.title,
          state: event.state,
          result: event.result,
          error: event.error,
        );
        if (existing == null) row.aiToolCalls.add(call);
        _noteMid(draft, event.mid);

      case CoworkRelayFile(:final replay):
        if (!replay) return;
        final draft = _draftFor();
        final block = await _blockForFile(event);
        if (block != null) _openAiRow(draft).aiBlocks.add(block);
        _noteMid(draft, event.mid);

      case CoworkRelayApprovalRequest(:final replay):
        if (!replay) return;
        // A decided request (or one whose run is over) is information: the
        // card shows the outcome and offers nothing to press. An open one on a
        // run still in flight is drawn exactly as live; the thread view
        // prompts for it as it does live.
        final draft = _draftFor();
        final decided = event.isDecided || !hostRunning(draft.sessionKey);
        _openAiRow(draft)
            .aiToolCalls
            .add(approvalCallFromRelay(event, decided: decided));
        _noteMid(draft, event.mid);

      case CoworkRelayAutomation(:final replay):
        if (!replay) return;
        // One line per automation id, last event wins — the SAME mapping the
        // live ledger uses (docs/WIRE_CONTRACT.md, "Automations").
        final draft = _draftFor();
        final row = _openAiRow(draft);
        ToolCall? existing;
        for (final call in row.aiToolCalls) {
          if (call.name == 'automation' &&
              call.arguments['id'] == event.automation.id) {
            existing = call;
            break;
          }
        }
        final call = automationCallFromRelay(existing, event);
        if (existing == null) row.aiToolCalls.add(call);
        _noteMid(draft, event.mid);

      case CoworkRelayAutomationList():
        // Owned by the automations source; never part of a transcript.
        break;

      case CoworkRelayDone():
        if (!event.isReplay) return;
        final draft = _draftFor();
        if (event.isHistoryEnd) {
          await _commit(draft);
          return;
        }
        // A persisted run terminal, replayed in message order: it closes the
        // answer it belongs to. `while_away` means nobody was watching when it
        // landed, so the thread offers an "Answer ready" affordance.
        //
        // The run's length goes on the answer row as `generationMs`, the field
        // the imported timeline shows as "Worked for" (bead cowork-al2). NOT
        // `startedAt`: the imported persistence handler re-stamps the newest
        // row from `startedAt` on every save, and a host time there would
        // turn the number into the age of the thread.
        final worked = event.workedFor;
        final aiRow = draft.aiRow;
        if (worked != null && aiRow != null) {
          aiRow['generationMs'] = '${worked.inMilliseconds}';
        }
        _closeAiRow(draft);
        if (event.whileAway) {
          _answerReady[draft.sessionKey] = true;
          _answerReadyRun[draft.sessionKey] = event.runId;
          notifyListeners();
        }

      case CoworkRelayRunError():
      case CoworkRelaySecretRequest():
      case CoworkRelayDebugContext():
      case CoworkRelayRoomTurn():
      case CoworkRelayRoomDone():
      case CoworkRelayRoomHistory():
      case CoworkRelayBrowserData():
      case CoworkRelayBrowserView():
        // Live-only, or owned elsewhere. A replay never carries them.
        break;
    }
  }

  _Draft _draftFor() {
    final key = _activeSession ?? CoworkRelayLink.instance.sessionKey.value;
    final draft = _drafts[key] ??= _Draft(key);
    draft.started = true;
    return draft;
  }

  _Draft _openAiRow(_Draft draft) {
    if (draft.aiRow != null) return draft;
    final row = <String, String>{'sender': 'ai', 'text': '', 'reasoning': ''};
    draft.rows.add(row);
    draft.aiRow = row;
    draft.aiText.clear();
    draft.aiReasoning.clear();
    draft.aiToolCalls = <ToolCall>[];
    draft.aiBlocks = <ContentBlock>[];
    return draft;
  }

  void _closeAiRow(_Draft draft) {
    final row = draft.aiRow;
    if (row == null) return;
    final text = draft.aiText.toString();
    row['text'] = text;
    final reasoning = draft.aiReasoning.toString();
    if (reasoning.isNotEmpty) row['reasoning'] = reasoning;
    if (draft.aiToolCalls.isNotEmpty) {
      row['toolCalls'] =
          jsonEncode(draft.aiToolCalls.map((c) => c.toJson()).toList());
    }
    if (draft.aiBlocks.isNotEmpty) {
      // A row that carries blocks renders as blocks, so the answer text has to
      // be one of them or it disappears.
      final blocks = <ContentBlock>[
        if (text.trim().isNotEmpty) ContentBlock.text(text),
        ...draft.aiBlocks,
      ];
      row['contentBlocks'] =
          jsonEncode(blocks.map((b) => b.toJson()).toList());
    }
    draft.aiRow = null;
    draft.aiText.clear();
    draft.aiReasoning.clear();
    draft.aiToolCalls = <ToolCall>[];
    draft.aiBlocks = <ContentBlock>[];
  }

  void _noteMid(_Draft draft, int? mid) {
    if (mid == null) return;
    if (mid > draft.maxMid) draft.maxMid = mid;
    final min = draft.minMid;
    if (min == null || mid < min) draft.minMid = mid;
  }

  /// Writes the replayed rows into the local cache and tells the UI.
  Future<void> _commit(_Draft draft) async {
    _closeAiRow(draft);
    final session = draft.sessionKey;
    _drafts.remove(session);
    // A request for the same thread that queued up behind this answer takes
    // the slot; the host answers it next.
    final queued = draft.next;
    if (queued != null) _drafts[session] = queued;
    // This answer is over. The next one the host sends belongs to the oldest
    // request still waiting — its `run_state` header will say so too, but a
    // header-less host must land right as well.
    if (_activeSession == session) {
      for (final pending in _drafts.values) {
        if (!pending.started) {
          _activeSession = pending.sessionKey;
          break;
        }
      }
    }

    // Did the host honour the cursor? A delta answer starts above the cursor;
    // a full re-send starts at or below it. Reading it off the data is the only
    // way that is right against both an old host and a new one.
    final honouredCursor =
        draft.afterId > 0 && (draft.minMid == null || draft.minMid! > draft.afterId);

    if (draft.rows.isEmpty && honouredCursor) {
      // Nothing new: the cache is already current.
      _advanceCursor(session, draft.maxMid);
      return;
    }

    var rows = draft.rows;
    if (honouredCursor) {
      final existing = await _cachedRows(session);
      if (existing.isEmpty) {
        // A delta with nothing to append it to. That is a cache MISS, not an
        // empty thread: a cursor only ever advances after rows were saved, so
        // the local read failed (SQLite threw, the cloud table is not migrated
        // yet, the memory entry is a title only). Writing the delta over the
        // thread would lose the history for good — the host never re-sends
        // below the cursor. Forget the cursor instead and ask for the whole
        // thread again (review F2).
        if (kDebugMode) {
          debugPrint('[cowork-replay] $session: local rows unreadable, '
              'dropping the delta and replaying from zero');
        }
        invalidateCursor(session);
        _replayWanted.add(session);
        notifyListeners();
        return;
      }
      rows = <Map<String, String>>[...existing, ...draft.rows];
    }

    // `saveChat` updates the in-memory cache synchronously and only then goes
    // to disk, so the rows are readable the moment this returns a future. The
    // repaint must not wait on that disk write (nor on the cursor's
    // preferences write): both are about the NEXT launch, not this frame.
    final saved = ChatStorageService.saveChat(
      rows.map<Map<String, dynamic>>(Map<String, dynamic>.from).toList(),
      chatId: session,
    );
    unawaited(saved.then((_) {}, onError: (Object error) {
      if (kDebugMode) debugPrint('[cowork-replay] cache write failed: $error');
    }));
    _advanceCursor(session, draft.maxMid);
    _revisions[session] = (_revisions[session] ?? 0) + 1;
    notifyListeners();
  }

  Future<List<Map<String, String>>> _cachedRows(String session) async {
    final chat = await ChatStorageService.loadFullChat(session);
    final messages = chat?.messagesOrNull;
    if (messages == null) return const <Map<String, String>>[];
    return <Map<String, String>>[
      for (final message in messages)
        <String, String>{
          for (final entry in message.toJson().entries)
            entry.key: '${entry.value}',
        },
    ];
  }

  /// Forget the replay cursor for [session], so the next replay asks for the
  /// whole thread and REPLACES the local rows instead of appending to them.
  ///
  /// This is what a live run has to do when it ends. The cursor only ever moves
  /// on a replay, so after a live turn it still points at the last replayed
  /// row — below the turns the UI has just written locally. The next reconnect
  /// then asks from there, the host honours the cursor, and `_commit` appends
  /// the host's copy of those same turns underneath the local ones: the answer
  /// and the question appear twice (bead cowork-bkw). Asking for the whole
  /// thread instead costs one replay and is always right, because a full
  /// replay replaces rather than appends. When the host starts stamping live
  /// events with their row id, [advanceCursor] is the cheaper path and this
  /// becomes the fallback.
  void invalidateCursor(String session) {
    if (_cursors.remove(session) == null) return;
    unawaited(_persistCursor(session, 0));
  }

  /// Moves the in-memory cursor and persists it in the background. Synchronous
  /// on purpose: nothing the user sees may block on a preferences write.
  ///
  /// Public because a live run ends outside this class: the adapter moves the
  /// cursor when the host tells it which row the run finished on.
  void advanceCursor(String session, int mid) => _advanceCursor(session, mid);

  void _advanceCursor(String session, int mid) {
    if (mid <= (_cursors[session] ?? 0)) return;
    _cursors[session] = mid;
    unawaited(_persistCursor(session, mid));
  }

  Future<void> _persistCursor(String session, int mid) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('$kReplayCursorPrefix$session', mid);
    } catch (error) {
      // A cursor that cannot be persisted only costs a full replay next time.
      if (kDebugMode) debugPrint('[cowork-replay] cursor save failed: $error');
    }
  }

  /// Bytes into the blob store FIRST, then the block that points at them.
  Future<ContentBlock?> _blockForFile(CoworkRelayFile file) async {
    final bytes = file.bytes;
    if (bytes == null || !file.isValid) return null;
    try {
      final storagePath =
          await ImageStorageService.uploadEncryptedImage(bytes);
      // The SAME block the live ledger builds (bead cowork-266).
      return artifactBlockFromFile(storagePath, file);
    } catch (error) {
      if (kDebugMode) debugPrint('[cowork-replay] blob write failed: $error');
      return null;
    }
  }
}
