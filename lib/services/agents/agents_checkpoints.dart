/// Checkpoints, rewind and fork of an Agents thread (docs/WIRE_CONTRACT.md,
/// "Checkpoints, rewind and fork").
///
/// Before the first file-changing call of a run the host pins the agent's
/// workspace. The app lists those pins per thread (`checkpoints_list`),
/// rewinds the files to one (`checkpoint_rewind`) and forks a thread from a
/// message (`thread_fork`). Every request has one terminal reply, which the
/// relay client hands to [AgentsReplyFrames].
///
/// The workspace belongs to the AGENT, not to the thread: a rewind changes
/// the files for every thread of that agent, and the host refuses it while a
/// task of the agent runs (`busy: ...`).
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/services/agents/agents_reply_frames.dart';

/// The key of the host's row id (`mid`) on a stored Agents message. The
/// replay loader writes it on user rows; "Fork from here" reads it.
const String kAgentsHostMidKey = 'hostMid';

/// The rewind modes the host takes.
abstract final class AgentsRewindMode {
  /// Nothing changes when a file changed outside the agent (default).
  static const String safe = 'safe';

  /// Restore the agent's files, leave the user's edits.
  static const String keepUserEdits = 'keep_user_edits';

  /// Like [keepUserEdits], plus a 3-way merge of text files.
  static const String merge = 'merge';

  /// Restore every file, the user's edits too.
  static const String force = 'force';

  static const List<String> all = <String>[safe, keepUserEdits, merge, force];
}

/// One pinned state of the workspace.
@immutable
class AgentsCheckpoint {
  const AgentsCheckpoint({
    required this.id,
    this.commit = '',
    this.createdAt,
    this.runId,
    this.userMid,
    this.prompt = '',
  });

  /// 16 hex.
  final String id;
  final String commit;

  /// When the host pinned it.
  final DateTime? createdAt;
  final String? runId;

  /// The `mid` of the user message whose run made it.
  final int? userMid;

  /// The first 160 characters of that user message.
  final String prompt;

  static AgentsCheckpoint? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? id = raw['id'];
    if (id is! String || id.isEmpty) return null;
    final Object? created = raw['created_at'];
    final Object? commit = raw['commit'];
    final Object? runId = raw['run_id'];
    final Object? mid = raw['user_mid'];
    final Object? prompt = raw['prompt'];
    return AgentsCheckpoint(
      id: id,
      commit: commit is String ? commit : '',
      createdAt: created is num
          ? DateTime.fromMillisecondsSinceEpoch((created * 1000).round())
          : null,
      runId: runId is String && runId.isNotEmpty ? runId : null,
      userMid: mid is num ? mid.toInt() : null,
      prompt: prompt is String ? prompt.trim() : '',
    );
  }
}

/// The answer to `checkpoints_list`.
@immutable
class AgentsCheckpointList {
  const AgentsCheckpointList({
    this.items = const <AgentsCheckpoint>[],
    this.error,
  });

  /// Newest first.
  final List<AgentsCheckpoint> items;

  /// The host's refusal, or [AgentsCheckpoints.errNotConnected] /
  /// [AgentsCheckpoints.errTimeout].
  final String? error;

  bool get ok => error == null;

  static AgentsCheckpointList fromReply(Map<String, dynamic> reply) {
    if (reply['ok'] == false) {
      return AgentsCheckpointList(error: _errorOf(reply));
    }
    final Object? raw = reply['items'];
    final List<AgentsCheckpoint> items = <AgentsCheckpoint>[
      if (raw is List)
        for (final Object? row in raw)
          if (AgentsCheckpoint.fromJson(row) case final AgentsCheckpoint c) c,
    ];
    // The host sends them newest first; sorted again so a reply in another
    // order still reads newest first.
    items.sort((AgentsCheckpoint a, AgentsCheckpoint b) {
      final DateTime? x = a.createdAt;
      final DateTime? y = b.createdAt;
      if (x == null || y == null) return 0;
      return y.compareTo(x);
    });
    return AgentsCheckpointList(
      items: List<AgentsCheckpoint>.unmodifiable(items),
    );
  }
}

/// The answer to `checkpoint_rewind` (also the `workspace` of a fork).
@immutable
class AgentsRewindResult {
  const AgentsRewindResult({
    required this.ok,
    this.checkpointId = '',
    this.mode = AgentsRewindMode.safe,
    this.restored = const <String>[],
    this.merged = const <String>[],
    this.kept = const <String>[],
    this.refused = const <String>[],
    this.conflicts = const <String>[],
    this.restorable,
    this.commit,
    this.note,
    this.error,
  });

  final bool ok;
  final String checkpointId;
  final String mode;
  final List<String> restored;
  final List<String> merged;
  final List<String> kept;

  /// Paths not restored because a parent is a symlink (or not a directory).
  final List<String> refused;

  /// Files changed outside the agent, on a refused `safe` rewind.
  final List<String> conflicts;

  /// How many files the refused rewind would have restored.
  final int? restorable;
  final String? commit;

  /// The host's note (outside effects stay).
  final String? note;
  final String? error;

  /// A refusal that the user can solve by picking another mode.
  bool get hasConflicts => !ok && conflicts.isNotEmpty;

  /// The host refused because a task of the agent runs.
  bool get isBusy => !ok && (error?.startsWith('busy') ?? false);

  static AgentsRewindResult fromReply(Map<String, dynamic> reply) {
    final Object? id = reply['checkpoint_id'];
    final Object? mode = reply['mode'];
    final Object? restorable = reply['restorable'];
    final Object? commit = reply['commit'];
    final Object? note = reply['note'];
    final bool ok = reply['ok'] == true;
    return AgentsRewindResult(
      ok: ok,
      checkpointId: id is String ? id : '',
      mode: mode is String && mode.isNotEmpty ? mode : AgentsRewindMode.safe,
      restored: _paths(reply['restored']),
      merged: _paths(reply['merged']),
      kept: _paths(reply['kept']),
      refused: _paths(reply['refused']),
      conflicts: _paths(reply['conflicts']),
      restorable: restorable is num ? restorable.toInt() : null,
      commit: commit is String && commit.isNotEmpty ? commit : null,
      note: note is String && note.trim().isNotEmpty ? note.trim() : null,
      error: ok ? null : _errorOf(reply),
    );
  }

  static AgentsRewindResult failed(String error) =>
      AgentsRewindResult(ok: false, error: error);
}

/// The answer to `thread_fork`.
@immutable
class AgentsForkResult {
  const AgentsForkResult({
    required this.ok,
    this.newSessionKey,
    this.mid,
    this.copied,
    this.checkpointId,
    this.workspace,
    this.error,
  });

  final bool ok;

  /// The new thread's key.
  final String? newSessionKey;
  final int? mid;

  /// How many rows the host copied.
  final int? copied;

  /// The checkpoint the host rewound to, when one was later than [mid].
  final String? checkpointId;

  /// The rewind the fork ran, when it ran one.
  final AgentsRewindResult? workspace;
  final String? error;

  /// The thread exists, but its files were not restored: the user picks a
  /// mode and the app rewinds to [checkpointId].
  bool get needsWorkspaceChoice =>
      ok && checkpointId != null && (workspace?.hasConflicts ?? false);

  static AgentsForkResult fromReply(Map<String, dynamic> reply) {
    final bool ok = reply['ok'] == true;
    final Object? key = reply['new_session_key'];
    final Object? mid = reply['mid'];
    final Object? copied = reply['copied'];
    final Object? checkpoint = reply['checkpoint_id'];
    final Object? workspace = reply['workspace'];
    return AgentsForkResult(
      ok: ok,
      newSessionKey: key is String && key.isNotEmpty ? key : null,
      mid: mid is num ? mid.toInt() : null,
      copied: copied is num ? copied.toInt() : null,
      checkpointId: checkpoint is String && checkpoint.isNotEmpty
          ? checkpoint
          : null,
      workspace: workspace is Map
          ? AgentsRewindResult.fromReply(
              workspace.map((Object? k, Object? v) => MapEntry('$k', v)),
            )
          : null,
      error: ok ? null : _errorOf(reply),
    );
  }
}

List<String> _paths(Object? raw) => List<String>.unmodifiable(<String>[
  if (raw is List)
    for (final Object? p in raw)
      if (p is String && p.isNotEmpty) p,
]);

String _errorOf(Map<String, dynamic> reply) {
  final Object? error = reply['error'];
  return error is String && error.trim().isNotEmpty
      ? error.trim()
      : 'The host refused it.';
}

/// Sends the three requests and reads their replies.
class AgentsCheckpoints {
  AgentsCheckpoints({
    AgentsFrameSender? send,
    AgentsReplyFrames? replies,
    this.timeout = const Duration(seconds: 30),
  }) : _send = send,
       _replies = replies ?? AgentsReplyFrames.instance;

  static AgentsCheckpoints instance = AgentsCheckpoints();

  /// The error of a request that could not be sent.
  static const String errNotConnected = 'not_connected';

  /// The error of a request the host did not answer in time.
  static const String errTimeout = 'timeout';

  final AgentsFrameSender? _send;
  final AgentsReplyFrames _replies;
  final Duration timeout;

  /// A fork asks the app to open its new thread: the shell listens.
  static final StreamController<String> _openRequests =
      StreamController<String>.broadcast();

  /// Thread keys the user forked into, for the shell to select.
  static Stream<String> get openRequests => _openRequests.stream;

  /// Asks the shell to open [sessionKey].
  static void requestOpen(String sessionKey) {
    if (!_openRequests.isClosed) _openRequests.add(sessionKey);
  }

  Future<Map<String, dynamic>?> _ask(
    Map<String, dynamic> frame,
    String replyType,
    bool Function(Map<String, dynamic>) matches,
    void Function(String error) onError,
  ) async {
    try {
      return await _replies.request(
        frame,
        replyType: replyType,
        send: _send,
        matches: matches,
        timeout: timeout,
      );
    } on AgentsReplyTimeout {
      onError(errTimeout);
    } catch (error) {
      if (kDebugMode) {
        debugPrint(
          '[checkpoints] ${frame['type']} failed: ${error.runtimeType}',
        );
      }
      onError(errNotConnected);
    }
    return null;
  }

  static bool _sameSession(Map<String, dynamic> reply, String sessionKey) {
    final Object? key = reply['session_key'];
    return key == null || key == sessionKey;
  }

  /// `checkpoints_list` for [sessionKey].
  Future<AgentsCheckpointList> list(String sessionKey) async {
    String? failure;
    final Map<String, dynamic>? reply = await _ask(
      <String, dynamic>{'type': 'checkpoints_list', 'session_key': sessionKey},
      'checkpoints',
      (Map<String, dynamic> r) => _sameSession(r, sessionKey),
      (String e) => failure = e,
    );
    if (reply == null) {
      return AgentsCheckpointList(error: failure ?? errNotConnected);
    }
    return AgentsCheckpointList.fromReply(reply);
  }

  /// `checkpoint_rewind` of [sessionKey] to [checkpointId] with [mode].
  Future<AgentsRewindResult> rewind(
    String sessionKey,
    String checkpointId, {
    String mode = AgentsRewindMode.safe,
  }) async {
    if (!AgentsRewindMode.all.contains(mode)) {
      throw ArgumentError.value(mode, 'mode');
    }
    String? failure;
    final Map<String, dynamic>? reply = await _ask(
      <String, dynamic>{
        'type': 'checkpoint_rewind',
        'session_key': sessionKey,
        'checkpoint_id': checkpointId,
        'mode': mode,
      },
      'checkpoint_rewound',
      (Map<String, dynamic> r) {
        if (!_sameSession(r, sessionKey)) return false;
        final Object? id = r['checkpoint_id'];
        return id == null || id == checkpointId;
      },
      (String e) => failure = e,
    );
    if (reply == null) {
      return AgentsRewindResult.failed(failure ?? errNotConnected);
    }
    return AgentsRewindResult.fromReply(reply);
  }

  /// `thread_fork` of [sessionKey] at [mid]. The host makes the new key.
  Future<AgentsForkResult> fork(
    String sessionKey,
    int mid, {
    bool restoreWorkspace = true,
    String mode = AgentsRewindMode.safe,
  }) async {
    String? failure;
    final Map<String, dynamic>? reply = await _ask(
      <String, dynamic>{
        'type': 'thread_fork',
        'session_key': sessionKey,
        'mid': mid,
        if (!restoreWorkspace) 'restore_workspace': false,
        if (mode != AgentsRewindMode.safe) 'mode': mode,
      },
      'thread_forked',
      (Map<String, dynamic> r) {
        if (!_sameSession(r, sessionKey)) return false;
        final Object? m = r['mid'];
        return m == null || (m is num && m.toInt() == mid);
      },
      (String e) => failure = e,
    );
    if (reply == null) {
      return AgentsForkResult(ok: false, error: failure ?? errNotConnected);
    }
    return AgentsForkResult.fromReply(reply);
  }
}
