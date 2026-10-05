/// The round trips behind "What did it do" (docs/WIRE_CONTRACT.md, "What did
/// it do: run changes and undo", bead chuk_chat-4qry).
///
/// The changes sheet asks the host for one run's files (`run_changes_get`)
/// and undoes some or all of them (`run_undo`). Each request is answered by
/// one terminal frame that names the run, so a request waits on a completer
/// keyed by the run id. A host that predates the frames answers with an
/// `error` that names no run, so a timeout is what ends that wait.
///
/// The service also keeps the newest `changes` block per run for this app
/// session: the line under an answer reads it, so after an undo it says
/// "1 undone" at once. The cached answer keeps its old block, so a successful
/// undo drops the thread's replay cursor: the next replay is a full one and
/// REPLACES the cached rows with the host's copy, which the host updated.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/services/agents/agents_permissions_service.dart'
    show AgentsControlFrameSender;
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/services/agents/agents_replay_loader.dart';
import 'package:chuk_chat/services/agents/agents_run_changes.dart';

/// Set once the user saw the host's note on what an undo does not bring back.
const String kRunUndoNoteSeenKey = 'agents.run_undo_note_seen';

Future<void> _sendOverRelay(Map<String, dynamic> payload) async {
  final Object? controller = AgentsRelayLink.instance.controller.value;
  if (controller is! AgentsRelayClient) {
    throw StateError('Not connected to the host');
  }
  await controller.sendControlFrame(payload);
}

void _invalidateReplayCursor(String sessionKey) =>
    AgentsReplayLoader.instance.invalidateCursor(sessionKey);

class AgentsRunChangesService extends ChangeNotifier {
  AgentsRunChangesService({
    AgentsControlFrameSender? send,
    void Function(String sessionKey)? onUndone,
    this.timeout = const Duration(seconds: 30),
  }) : _send = send ?? _sendOverRelay,
       _onUndone = onUndone ?? _invalidateReplayCursor;

  /// The one instance the app uses.
  static AgentsRunChangesService instance = AgentsRunChangesService();

  final AgentsControlFrameSender _send;
  final void Function(String sessionKey) _onUndone;

  /// How long a request waits for its answer.
  final Duration timeout;

  final Map<String, Completer<AgentsRunChangesReport>> _fetches =
      <String, Completer<AgentsRunChangesReport>>{};
  final Map<String, Completer<AgentsRunUndoResult>> _undos =
      <String, Completer<AgentsRunUndoResult>>{};
  final Map<String, AgentsRunChangesSummary> _summaries =
      <String, AgentsRunChangesSummary>{};
  bool _noteSeen = false;

  /// Routes the relay's `run_changes` / `run_undo_result` frames here.
  /// Idempotent; every request calls it.
  void attach() {
    AgentsRelayClient.runChangesSink = handleFrame;
  }

  /// The newest block this session knows for [runId], or null.
  AgentsRunChangesSummary? summaryOf(String runId) => _summaries[runId];

  /// Asks the host for [runId]'s files and commits.
  Future<AgentsRunChangesReport> fetch(String runId) {
    final Completer<AgentsRunChangesReport>? running = _fetches[runId];
    if (running != null) return running.future;
    final completer = Completer<AgentsRunChangesReport>();
    _fetches[runId] = completer;
    return _request(
      completer,
      <String, dynamic>{'type': 'run_changes_get', 'run_id': runId},
      onFail: (String code) =>
          _settleFetch(runId, AgentsRunChangesReport.failed(runId, code)),
    );
  }

  /// Undoes [paths] of [runId] (all of its files when null). [force] goes
  /// over conflicts; the wire wants the JSON `true` or nothing.
  Future<AgentsRunUndoResult> undo(
    String runId, {
    List<String>? paths,
    bool force = false,
  }) {
    final Completer<AgentsRunUndoResult>? running = _undos[runId];
    if (running != null) return running.future;
    final completer = Completer<AgentsRunUndoResult>();
    _undos[runId] = completer;
    return _request(
      completer,
      <String, dynamic>{
        'type': 'run_undo',
        'run_id': runId,
        'paths': ?paths,
        if (force) 'force': true,
      },
      onFail: (String code) =>
          _settleUndo(runId, AgentsRunUndoResult.failed(runId, code)),
    );
  }

  Future<T> _request<T>(
    Completer<T> completer,
    Map<String, dynamic> payload, {
    required void Function(String code) onFail,
  }) async {
    attach();
    try {
      await _send(payload);
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[agents-run-changes] ${payload['type']} not sent: $error');
      }
      onFail('not_sent');
      return completer.future;
    }
    return completer.future.timeout(
      timeout,
      onTimeout: () {
        onFail('no_answer');
        return completer.future;
      },
    );
  }

  /// One `run_changes` or `run_undo_result` frame.
  void handleFrame(Map<String, dynamic> payload) {
    switch (payload['type']) {
      case 'run_changes':
        final report = AgentsRunChangesReport.fromPayload(payload);
        if (report == null) return;
        final summary = report.summary;
        if (summary != null) _remember(report.runId, summary);
        _settleFetch(report.runId, report);
      case 'run_undo_result':
        final result = AgentsRunUndoResult.fromPayload(payload);
        if (result == null) return;
        final changes = result.changes;
        if (changes != null) _remember(result.runId, changes);
        if (result.ok) {
          final String? sessionKey = result.sessionKey;
          if (sessionKey != null) _onUndone(sessionKey);
        }
        _settleUndo(result.runId, result);
    }
  }

  void _remember(String runId, AgentsRunChangesSummary summary) {
    if (_summaries[runId] == summary) return;
    _summaries[runId] = summary;
    notifyListeners();
  }

  void _settleFetch(String runId, AgentsRunChangesReport report) {
    final completer = _fetches.remove(runId);
    if (completer != null && !completer.isCompleted) completer.complete(report);
  }

  void _settleUndo(String runId, AgentsRunUndoResult result) {
    final completer = _undos.remove(runId);
    if (completer != null && !completer.isCompleted) completer.complete(result);
  }

  /// True the first time an undo's note should show, then false for good.
  Future<bool> claimUndoNote() async {
    if (_noteSeen) return false;
    _noteSeen = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(kRunUndoNoteSeenKey) == true) return false;
      await prefs.setBool(kRunUndoNoteSeenKey, true);
    } catch (error) {
      // No preferences: the note still shows once in this app session.
      if (kDebugMode) debugPrint('[agents-run-changes] note flag: $error');
    }
    return true;
  }
}
