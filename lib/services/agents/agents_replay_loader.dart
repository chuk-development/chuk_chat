/// History is the server's. This is the client's side of getting it back.
///
/// The Agents host keeps the authoritative transcript of every thread (see
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

import 'package:chuk_chat/models/content_block.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/agents/media_index.dart';
import 'package:chuk_chat/services/agents/thread_preview_store.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/services/automations/automation_ledger.dart';
import 'package:chuk_chat/services/agents/agents_run_ledger.dart';
import 'package:chuk_chat/services/image_storage_service.dart';

/// Prefix of the per-session replay cursor key in SharedPreferences.
const String kReplayCursorPrefix = 'cowork.replay_cursor.';
const String kReplayTimestampCursorPrefix = 'cowork.replay_timestamp_cursor.';

/// One-time repair flag (bead cowork-4rpt). Caches written before the repeat
/// guard existed already hold turns twice, and no later delta can heal a
/// duplicate that sits in the middle of the history. Dropping every cursor
/// once makes the next replay a full one, and a full replay REPLACES the
/// cache with the host's transcript — which has each turn exactly once.
const String kReplayRepeatRepairKey = 'cowork.replay_repeat_repair.v1';

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

  /// Replay paging (docs/WIRE_CONTRACT.md, Bead cowork-axx): the `before_id`
  /// this page was asked with (0 = the newest page or an unpaged replay), and
  /// what its history-end `done` said about older rows.
  int beforeId = 0;
  bool hasMore = false;
  int? oldestMid;

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
class AgentsReplayLoader extends ChangeNotifier {
  AgentsReplayLoader._();

  static final AgentsReplayLoader instance = AgentsReplayLoader._();

  StreamSubscription<AgentsRelayInbound>? _sub;

  final Map<String, _Draft> _drafts = <String, _Draft>{};
  final Map<String, int> _cursors = <String, int>{};
  final Map<String, int> _revisions = <String, int>{};
  final Map<String, bool> _answerReady = <String, bool>{};
  final Map<String, String?> _answerReadyRun = <String, String?>{};
  final Set<String> _replayWanted = <String>{};
  // Replay paging: the lowest `before_id` already asked per session.
  final Map<String, int> _pagingFloor = <String, int>{};
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
  final List<AgentsRelayInbound> _queue = <AgentsRelayInbound>[];
  bool _draining = false;

  /// Subscribes to the link's long-lived inbound stream. Idempotent.
  void attach() {
    if (_sub != null) return;
    _sub = AgentsRelayLink.instance.inbound.listen(
      _enqueue,
      onError: (Object error, StackTrace _) {
        if (kDebugMode) debugPrint('[agents-replay] inbound error: $error');
      },
      cancelOnError: false,
    );
  }

  void _enqueue(AgentsRelayInbound event) {
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
              debugPrint('[agents-replay] dropped a frame: $error\n$stack');
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
      if (prefs.getBool(kReplayRepeatRepairKey) != true) {
        // Keep no cursor this once: every thread replays whole and the host's
        // copy replaces a cache that may show turns twice. The flag is written
        // first, so a crash mid-replay costs one extra full replay, never a
        // repair loop.
        await prefs.setBool(kReplayRepeatRepairKey, true);
        if (kDebugMode) {
          debugPrint('[agents-replay] repeat repair: replaying every thread');
        }
        return;
      }
      for (final key in prefs.getKeys()) {
        if (!key.startsWith(kReplayCursorPrefix)) continue;
        final session = key.substring(kReplayCursorPrefix.length);
        // Old caches predate message clocks. Re-fetch once without deleting
        // their visible history; only the completed replay replaces the cache.
        if (prefs.getBool('$kReplayTimestampCursorPrefix$session') != true) {
          continue;
        }
        final value = prefs.getInt(key);
        if (value != null && value > 0) {
          _cursors[key.substring(kReplayCursorPrefix.length)] = value;
        }
      }
    } catch (error) {
      // No prefs (a test without a mock store): every replay is a full one.
      if (kDebugMode) debugPrint('[agents-replay] cursor load failed: $error');
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
  void expect(String sessionKey, {int afterId = 0, int beforeId = 0}) {
    final fresh = _Draft(sessionKey)
      ..afterId = afterId
      ..beforeId = beforeId;
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
    _pagingFloor.clear();
    _hostRunning.clear();
    _hostPrompts.clear();
    _activeSession = null;
    _queue.clear();
    _draining = false;
  }

  // --- the fold ---------------------------------------------------------------

  Future<void> _handle(AgentsRelayInbound event) async {
    switch (event) {
      case AgentsRelayRunState():
        _activeSession = event.sessionKey;
        if (event.isRunning) {
          _hostRunning.add(event.sessionKey);
          _hostPrompts[event.sessionKey] = event.prompt;
          // A run that belongs to the host process, not to this socket. The
          // ledger is what the thread view reads its run phase from.
          AgentsRunLedger.instance.adoptRunning(
            event.sessionKey,
            runId: event.runId,
            prompt: event.prompt,
            startedAt: epochSecondsToDateTime(event.startedAt),
          );
        } else {
          _hostRunning.remove(event.sessionKey);
          _hostPrompts.remove(event.sessionKey);
          AgentsRunLedger.instance.reconcileIdle(event.sessionKey);
        }
        notifyListeners();

      case AgentsRelayUser(:final replay, :final text, :final mid):
        // Always true today (a user turn only exists in a replay); checked, not
        // assumed, like every other case (review F13).
        if (!replay) return;
        final draft = _draftFor();
        _closeAiRow(draft);
        draft.rows.add(<String, String>{
          'sender': 'user',
          'text': text,
          'reasoning': '',
          if (event.sentAt != null) 'sentAt': event.sentAt!.toIso8601String(),
        });
        _noteMid(draft, mid);

      case AgentsRelayDelta(:final replay, :final text, :final mid):
        if (!replay) return;
        final draft = _draftFor();
        _openAiRow(draft).aiText.write(text);
        if (event.sentAt != null) {
          draft.aiRow!['sentAt'] = event.sentAt!.toIso8601String();
        }
        _noteMid(draft, mid);

      case AgentsRelayReasoning(:final replay, :final text, :final mid):
        if (!replay) return;
        final draft = _draftFor();
        _openAiRow(draft).aiReasoning.write(text);
        if (event.sentAt != null) {
          draft.aiRow!.putIfAbsent(
            'sentAt',
            () => event.sentAt!.toIso8601String(),
          );
        }
        _noteMid(draft, mid);

      case AgentsRelayTool(:final replay):
        if (!replay) return;
        final draft = _draftFor();
        // The SAME mapping the live ledger uses, so the replayed card is the
        // live card (bead cowork-b45).
        _openAiRow(draft).aiToolCalls.add(toolCallFromRelay(event));
        _noteMid(draft, event.mid);

      case AgentsRelaySubagent(:final replay):
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

      case AgentsRelayFile(:final replay):
        if (!replay) return;
        final draft = _draftFor();
        final block = await _blockForFile(event);
        if (block != null) _openAiRow(draft).aiBlocks.add(block);
        _noteMid(draft, event.mid);

      case AgentsRelayApprovalRequest(:final replay):
        if (!replay) return;
        // A decided request (or one whose run is over) is information: the
        // card shows the outcome and offers nothing to press. An open one on a
        // run still in flight is drawn exactly as live; the thread view
        // prompts for it as it does live.
        final draft = _draftFor();
        final decided = event.isDecided || !hostRunning(draft.sessionKey);
        _openAiRow(
          draft,
        ).aiToolCalls.add(approvalCallFromRelay(event, decided: decided));
        _noteMid(draft, event.mid);

      case AgentsRelayAutomation(:final replay):
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

      case AgentsRelayAutomationList():
      case AgentsRelayDocuments():
      case AgentsRelaySkillsList():
      case AgentsRelayAgentList():
        // Owned by the automations source / the shell's roster; never part
        // of a transcript.
        break;

      case AgentsRelayDone():
        if (!event.isReplay) return;
        final draft = _draftFor();
        if (event.isHistoryEnd) {
          // Replay paging: what the host says about rows below this page.
          draft.hasMore = event.hasMore;
          draft.oldestMid = event.oldestMid;
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
        // A run that was stopped or that failed wrote nothing, so without this
        // it comes back from the host as an empty gap in the thread — the
        // reader cannot tell it from a run that is still thinking (bead
        // cowork-gnr8). The SAME wording the live thread uses, and the same
        // `interrupted` status, so the bubble offers to ask again.
        final notice = agentsRunEndNotice(
          agentsRunOutcomeFor(
            reason: event.reason,
            finalAnswer: event.finalAnswer,
          ),
        );
        // A turn the host reports as STILL RUNNING is not a dead turn. The
        // `run_state` header that opened this replay says so, and its word
        // beats the absence of a terminal: marking it `interrupted` puts a
        // "Continue generation" button on a run that is still writing its
        // answer, and the answer then arrives underneath the button.
        final stillRunning = _hostRunning.contains(draft.sessionKey);
        if (notice != null &&
            !stillRunning &&
            draft.aiText.toString().trim().isEmpty) {
          _openAiRow(draft);
          draft.aiText.write(notice);
          draft.aiRow!['status'] = 'interrupted';
        }
        _closeAiRow(draft);
        if (event.whileAway) {
          _answerReady[draft.sessionKey] = true;
          _answerReadyRun[draft.sessionKey] = event.runId;
          notifyListeners();
        }

      case AgentsRelayTaskAck():
      case AgentsRelayHeartbeat():
      case AgentsRelayRunError():
      case AgentsRelaySecretRequest():
      case AgentsRelayDebugContext():
      case AgentsRelayRoomTurn():
      case AgentsRelayRoomDone():
      case AgentsRelayRoomHistory():
      case AgentsRelayBrowserData():
      case AgentsRelayBrowserView():
        // Live-only, or owned elsewhere. A replay never carries them.
        break;
    }
  }

  _Draft _draftFor() {
    final key = _activeSession ?? AgentsRelayLink.instance.sessionKey.value;
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
      row['toolCalls'] = jsonEncode(
        draft.aiToolCalls.map((c) => c.toJson()).toList(),
      );
    }
    if (draft.aiBlocks.isNotEmpty) {
      // A row that carries blocks renders as blocks, so the answer text has to
      // be one of them or it disappears.
      final blocks = <ContentBlock>[
        if (text.trim().isNotEmpty) ContentBlock.text(text),
        ...draft.aiBlocks,
      ];
      row['contentBlocks'] = jsonEncode(blocks.map((b) => b.toJson()).toList());
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

  /// How far back a repeat is looked for. A delta only ever carries turns the
  /// app may have painted itself since the last replay, so the window is about
  /// "recent", not about the whole thread.
  @visibleForTesting
  static const int repeatWindow = 60;

  /// The host's delta appended to the cache, with the turns the app already
  /// painted itself removed.
  ///
  /// The app paints an outgoing message the moment it is sent, and the answer
  /// as it streams; neither row carries a `mid`, because the host had not
  /// stored them yet. The host stores the same turn, and on the next replay it
  /// sends it back above the cursor. A plain append therefore shows the turn
  /// twice — the bug the reader sees as "the same message, twice" (bead
  /// cowork-4rpt).
  ///
  /// The overlap is found by content, and the host's copy wins: it carries the
  /// tool calls, the reasoning and the server clock the local copy never had.
  /// Two guards keep this from eating history:
  ///
  ///  * only the last [repeatWindow] cached rows are searched, and
  ///  * the delta must be at least as long as the tail it replaces, so a short
  ///    delta can never shrink the thread.
  @visibleForTesting
  static List<Map<String, String>> appendWithoutRepeats(
    List<Map<String, String>> existing,
    List<Map<String, String>> delta,
  ) {
    if (existing.isEmpty || delta.isEmpty) {
      return <Map<String, String>>[...existing, ...delta];
    }
    // 1. The clean case: a tail of the cache IS the head of the delta.
    //
    // Found in linear time, not by trying every length. The obvious loop —
    // longest candidate first, compare row by row — is O(k²) in the size of
    // the delta, and it reaches its worst case on real data: a thread of
    // repeated identical turns ("ok", "ok", "ok") makes every candidate match
    // on all but its last row, so every one is paid for in full. Measured at
    // 97 ms on the UI thread for a 2000-row replay on a desktop, and a replay
    // that large is exactly the reconnect-after-a-long-absence path (bead
    // cowork-6i0m).
    final int overlap = _longestOverlap(existing, delta);
    if (overlap > 0) {
      return <Map<String, String>>[
        ...existing.take(existing.length - overlap),
        ...delta,
      ];
    }
    // 2. The streamed case: the answer the app painted is not byte-identical
    //    to the stored one (it was cut off, or a tool card is missing), so the
    //    tails do not line up. Align on the first row of the delta instead —
    //    it is the start of the repeated turn.
    final int floor = existing.length - repeatWindow < 0
        ? 0
        : existing.length - repeatWindow;
    for (int j = existing.length - 1; j >= floor; j--) {
      if (!_sameRow(existing[j], delta.first)) continue;
      // A delta shorter than the tail it would replace must not shrink the
      // thread: that is a coincidence, not the same turn.
      if (existing.length - j > delta.length) {
        break;
      }
      return <Map<String, String>>[...existing.take(j), ...delta];
    }
    return <Map<String, String>>[...existing, ...delta];
  }

  /// The length of the longest tail of [existing] that is also a head of
  /// [delta], in O(n + m).
  ///
  /// This is "the longest prefix of B that is a suffix of A", which the KMP
  /// prefix function answers directly: run it over `B + separator + A`, and the
  /// last value is the answer. The separator is a key no row can produce, so a
  /// match can never straddle the join.
  static int _longestOverlap(
    List<Map<String, String>> existing,
    List<Map<String, String>> delta,
  ) {
    final int longest = existing.length < delta.length
        ? existing.length
        : delta.length;
    if (longest == 0) return 0;
    // Only the last `longest` rows of the cache can take part.
    final List<int> keys = <int>[
      for (int i = 0; i < longest; i++) _rowKey(delta[i]),
      _separatorKey,
      for (int i = existing.length - longest; i < existing.length; i++)
        _rowKey(existing[i]),
    ];
    final List<int> failure = List<int>.filled(keys.length, 0);
    for (int i = 1; i < keys.length; i++) {
      int len = failure[i - 1];
      while (len > 0 && keys[i] != keys[len]) {
        len = failure[len - 1];
      }
      if (keys[i] == keys[len]) len++;
      failure[i] = len;
    }
    final int match = failure[keys.length - 1];
    // A hash collision would claim an overlap that is not there, and this
    // decides what gets written over the thread. Confirm the answer against
    // the rows themselves — once, over `match` rows, not once per candidate.
    if (match == 0) return 0;
    for (int i = 0; i < match; i++) {
      if (!_sameRow(existing[existing.length - match + i], delta[i])) return 0;
    }
    return match;
  }

  /// A value no row can produce, so the two halves cannot match across it.
  static const int _separatorKey = -1;

  /// The identity [_sameRow] compares, as one integer.
  static int _rowKey(Map<String, String> row) =>
      Object.hash(row['sender'], (row['text'] ?? '').trim()) & 0x3fffffff;

  /// Two cache rows that stand for the same turn: same side, same words. The
  /// clocks differ by design (the app stamps its own send, the host stamps the
  /// store), so they are not compared.
  static bool _sameRow(Map<String, String> a, Map<String, String> b) {
    if (a['sender'] != b['sender']) return false;
    return (a['text'] ?? '').trim() == (b['text'] ?? '').trim();
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
        draft.afterId > 0 &&
        (draft.minMid == null || draft.minMid! > draft.afterId);

    if (draft.rows.isEmpty && honouredCursor) {
      // "Nothing new" is only good news when there is something to be new
      // ABOVE. A cursor outlives the rows it was earned on — it lives in
      // preferences, the transcript lives in the store — so a store that lost
      // its threads (the JSON to SQLite move) leaves a cursor pointing at rows
      // nobody has. The host then answers "nothing after 106", the thread stays
      // empty, and because the cursor keeps advancing it is never asked for
      // again: the reader's history is gone for good although the host still
      // has every word of it (bead cowork-izh). The check is cheap — a row
      // count, no payload decode, no cloud.
      if (!await ChatStorageService.hasLocalThread(session)) {
        if (kDebugMode) {
          debugPrint(
            '[agents-replay] $session: cursor ${draft.afterId} with no '
            'local thread, replaying from zero',
          );
        }
        invalidateCursor(session);
        _replayWanted.add(session);
        notifyListeners();
        return;
      }
      // Nothing new: the cache is already current.
      _advanceCursor(session, draft.maxMid);
      return;
    }

    var rows = draft.rows;
    if (draft.beforeId > 0) {
      // An OLDER page (replay paging): it goes in front of what the newer
      // pages already put in the cache. Nothing there yet (the cache was lost
      // between pages) is not an error — the page is then simply the thread.
      final existing = await _cachedRows(session);
      // Same repeat guard as the append below, read the other way round: the
      // older page comes first, and whatever of it the cache already holds is
      // dropped from the cache side (bead cowork-4rpt).
      rows = appendWithoutRepeats(draft.rows, existing);
    } else if (honouredCursor) {
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
          debugPrint(
            '[agents-replay] $session: local rows unreadable, '
            'dropping the delta and replaying from zero',
          );
        }
        invalidateCursor(session);
        _replayWanted.add(session);
        notifyListeners();
        return;
      }
      rows = appendWithoutRepeats(existing, draft.rows);
    }

    // `saveChat` updates the in-memory cache synchronously and only then goes
    // to disk, so the rows are readable the moment this returns a future. The
    // repaint must not wait on that disk write (nor on the cursor's
    // preferences write): both are about the NEXT launch, not this frame.
    final List<Map<String, dynamic>> committed = rows
        .map<Map<String, dynamic>>(Map<String, dynamic>.from)
        .toList();
    // The roster has no messages of its own (see ThreadPreviewStore). This is
    // the one place the rows are already decrypted and in hand, so the last
    // line is taken here and nowhere else.
    ThreadPreviewStore.instance.noteRows(session, committed);
    // The same rows carry every picture and every file the coworker handed
    // over. The Media tab has no other way to find them (MediaIndex).
    MediaIndex.instance.noteRows(session, committed);
    final saved = ChatStorageService.saveChat(committed, chatId: session);
    unawaited(
      saved.then(
        (_) {},
        onError: (Object error) {
          if (kDebugMode) {
            debugPrint('[agents-replay] cache write failed: $error');
          }
        },
      ),
    );
    _advanceCursor(session, draft.maxMid);
    _revisions[session] = (_revisions[session] ?? 0) + 1;
    notifyListeners();
    _requestOlderPage(draft);
  }

  /// Replay paging (docs/WIRE_CONTRACT.md, Bead cowork-axx): the page just
  /// committed said older rows exist — ask for the next one, below its first
  /// row. Only ever downwards (a page that does not move the floor is not asked
  /// again), and only while the transport is paired; a page that cannot be
  /// asked for now is asked for by the next full replay.
  void _requestOlderPage(_Draft draft) {
    final int? oldest = draft.oldestMid;
    if (!draft.hasMore || oldest == null || oldest <= 1) return;
    final session = draft.sessionKey;
    final int? floor = _pagingFloor[session];
    if (floor != null && oldest >= floor) return;
    final controller = AgentsRelayLink.instance.controller.value;
    if (controller == null || !controller.state.value.isPaired) return;
    _pagingFloor[session] = oldest;
    expect(session, beforeId: oldest);
    unawaited(
      controller
          .requestReplay(
            sessionKey: session,
            beforeId: oldest,
            limit: kReplayPageSize,
          )
          .catchError((Object _) {}),
    );
  }

  /// Writes one quiet line into [session]'s transcript and repaints it.
  ///
  /// The live path's half of [agentsRunEndNotice]. A run that ended with
  /// nothing — a stop the app only heard about through a terminal, a run the
  /// host no longer has, a run that went silent — has no answer row of its
  /// own, so the thread would simply stop animating and show nothing. The row
  /// carries `status: interrupted`, which is what makes the bubble offer to
  /// ask again.
  ///
  /// Idempotent per line: the same notice is never written twice in a row, so
  /// a reconnect that reconciles the same dead run again adds nothing.
  Future<void> appendNotice(String session, String notice) async {
    if (session.isEmpty || notice.isEmpty) return;
    // The host says this thread has a run in flight. Whatever made the local
    // ledger close its own run — a dropped socket, a view that was rebuilt —
    // the turn is not dead, so it gets neither the line nor the `interrupted`
    // status that turns it into a "Continue generation" button.
    if (_hostRunning.contains(session)) return;
    final existing = await _cachedRows(session);
    if (existing.isNotEmpty &&
        (existing.last['text'] ?? '').trim() == notice.trim()) {
      return;
    }
    final rows = <Map<String, String>>[
      ...existing,
      <String, String>{
        'sender': 'ai',
        'text': notice,
        'reasoning': '',
        'status': 'interrupted',
        'sentAt': DateTime.now().toIso8601String(),
      },
    ];
    final committed = rows
        .map<Map<String, dynamic>>(Map<String, dynamic>.from)
        .toList();
    ThreadPreviewStore.instance.noteRows(session, committed);
    unawaited(
      ChatStorageService.saveChat(committed, chatId: session).then(
        (_) {},
        onError: (Object error) {
          if (kDebugMode) {
            debugPrint('[agents-replay] notice write failed: $error');
          }
        },
      ),
    );
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
      await prefs.setBool('$kReplayTimestampCursorPrefix$session', true);
    } catch (error) {
      // A cursor that cannot be persisted only costs a full replay next time.
      if (kDebugMode) debugPrint('[agents-replay] cursor save failed: $error');
    }
  }

  /// Bytes into the blob store FIRST, then the block that points at them.
  Future<ContentBlock?> _blockForFile(AgentsRelayFile file) async {
    final bytes = file.bytes;
    if (bytes == null || !file.isValid) return null;
    try {
      // Local blob store, like the live ledger: a relayed host file never
      // goes to the Supabase bucket.
      final storagePath = await ImageStorageService.uploadLocalBlob(bytes);
      // The SAME block the live ledger builds (bead cowork-266).
      return artifactBlockFromFile(storagePath, file);
    } catch (error) {
      if (kDebugMode) debugPrint('[agents-replay] blob write failed: $error');
      return null;
    }
  }
}
