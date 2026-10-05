/// What a coworker's run changed in its workspace, and the undo of it
/// (docs/WIRE_CONTRACT.md, "What did it do: run changes and undo", bead
/// chuk_chat-4qry).
///
/// Three shapes come from the host:
///
/// - [AgentsRunChangesSummary]: the `changes` block of a `done` (live and
///   replayed) and of a `run_undo_result`. It rides on the answer inside the
///   hidden run meta call (`agents_run_cost.dart`, [runMetaCall]), next to
///   the cost.
/// - [AgentsRunChangesReport]: the `run_changes` answer to `run_changes_get`,
///   one row per file and the run's commits.
/// - [AgentsRunUndoResult]: the `run_undo_result` answer to `run_undo`.
///
/// Pure data, no relay: the relay client parses `done` with it, and the
/// service (`agents_run_changes_service.dart`) does the round trips.
library;

import 'package:flutter/foundation.dart';

/// The `changes` block: how many workspace files the run changed, the line
/// counts, and how many of those files are back to their state before it.
@immutable
class AgentsRunChangesSummary {
  const AgentsRunChangesSummary({
    required this.files,
    this.additions = 0,
    this.deletions = 0,
    this.undone = 0,
  });

  final int files;
  final int additions;
  final int deletions;
  final int undone;

  /// Every changed file is back: nothing left to undo.
  bool get allUndone => undone >= files;

  /// Some files are back and some are not.
  bool get partlyUndone => undone > 0 && undone < files;

  /// Null for anything that is not a block, and for a block that names no
  /// changed file (the host leaves the block out then; an empty one draws
  /// nothing either).
  static AgentsRunChangesSummary? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final int? files = _count(raw['files']);
    if (files == null || files <= 0) return null;
    final int undone = _count(raw['undone']) ?? 0;
    return AgentsRunChangesSummary(
      files: files,
      additions: _count(raw['additions']) ?? 0,
      deletions: _count(raw['deletions']) ?? 0,
      undone: undone > files ? files : undone,
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    'files': files,
    'additions': additions,
    'deletions': deletions,
    'undone': undone,
  };

  @override
  bool operator ==(Object other) =>
      other is AgentsRunChangesSummary &&
      other.files == files &&
      other.additions == additions &&
      other.deletions == deletions &&
      other.undone == undone;

  @override
  int get hashCode => Object.hash(files, additions, deletions, undone);
}

/// Why a file cannot be undone without `force`.
enum AgentsRunConflictReason {
  /// A later run changed the file.
  changedLaterByRun,

  /// A change outside any run changed the file (the user's own edit).
  changedOutside,

  /// The file has edits on disk that are not committed yet.
  uncommitted,
}

/// One conflicting file, from `conflict` on a row or from `conflicts`.
@immutable
class AgentsRunConflict {
  const AgentsRunConflict({
    required this.path,
    required this.reason,
    this.runs = const <String>[],
  });

  final String path;
  final AgentsRunConflictReason reason;

  /// The later runs that changed the file, when the host named them.
  final List<String> runs;

  static AgentsRunConflict? fromJson(Object? raw, {String? path}) {
    if (raw is! Map) return null;
    final String? at = _text(raw['path']) ?? path;
    if (at == null) return null;
    final Object? reason = raw['reason'];
    final List<String> runs = <String>[
      if (raw['runs'] is List)
        for (final Object? run in raw['runs'] as List)
          if (run is String && run.isNotEmpty) run,
    ];
    final AgentsRunConflictReason kind;
    if (reason == 'uncommitted') {
      kind = AgentsRunConflictReason.uncommitted;
    } else if (raw['outside'] == true && runs.isEmpty) {
      // `outside` with no later run: only the user (or another tool) touched
      // it. With a later run as well, the run is the clearer thing to name.
      kind = AgentsRunConflictReason.changedOutside;
    } else {
      kind = AgentsRunConflictReason.changedLaterByRun;
    }
    return AgentsRunConflict(path: at, reason: kind, runs: runs);
  }

  static List<AgentsRunConflict> listFrom(Object? raw) => <AgentsRunConflict>[
    if (raw is List)
      for (final Object? item in raw) ?AgentsRunConflict.fromJson(item),
  ];
}

/// What the run did to one file.
enum AgentsRunFileChange { added, modified, deleted }

/// One row of `run_changes.files`.
@immutable
class AgentsRunFile {
  const AgentsRunFile({
    required this.path,
    required this.change,
    this.additions = 0,
    this.deletions = 0,
    this.undoable = false,
    this.undone = false,
    this.binary = false,
    this.conflict,
  });

  final String path;
  final AgentsRunFileChange change;
  final int additions;
  final int deletions;

  /// Can be undone without `force`.
  final bool undoable;

  /// Already back to its state before the run.
  final bool undone;

  /// No line counts.
  final bool binary;
  final AgentsRunConflict? conflict;

  static AgentsRunFile? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final String? path = _text(raw['path']);
    if (path == null) return null;
    final AgentsRunFileChange change = switch (raw['change']) {
      'added' => AgentsRunFileChange.added,
      'deleted' => AgentsRunFileChange.deleted,
      _ => AgentsRunFileChange.modified,
    };
    return AgentsRunFile(
      path: path,
      change: change,
      additions: _count(raw['additions']) ?? 0,
      deletions: _count(raw['deletions']) ?? 0,
      undoable: raw['undoable'] == true,
      undone: raw['undone'] == true,
      binary: raw['binary'] == true,
      conflict: AgentsRunConflict.fromJson(raw['conflict'], path: path),
    );
  }
}

/// One commit of the run that changed a file.
@immutable
class AgentsRunCommit {
  const AgentsRunCommit({
    required this.commit,
    required this.subject,
    this.short,
    this.time,
    this.files,
  });

  final String commit;
  final String subject;
  final String? short;
  final DateTime? time;
  final int? files;

  static AgentsRunCommit? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final String? commit = _text(raw['commit']);
    if (commit == null) return null;
    final Object? time = raw['time'];
    return AgentsRunCommit(
      commit: commit,
      short: _text(raw['short']),
      subject: _text(raw['subject']) ?? '',
      time: time is String ? DateTime.tryParse(time)?.toLocal() : null,
      files: _count(raw['files']),
    );
  }
}

/// The `run_changes` answer. [failure] is set when no answer came at all
/// (not connected, no answer in time); then the lists are empty.
@immutable
class AgentsRunChangesReport {
  const AgentsRunChangesReport({
    required this.runId,
    this.sessionKey,
    this.files = const <AgentsRunFile>[],
    this.filesTotal,
    this.commits = const <AgentsRunCommit>[],
    this.commitsTotal,
    this.actions,
    this.summary,
    this.undoable = false,
    this.reason,
    this.conflicts = const <AgentsRunConflict>[],
    this.failure,
  });

  /// No answer: [code] is `not_sent` or `no_answer`.
  const AgentsRunChangesReport.failed(this.runId, String code)
    : sessionKey = null,
      files = const <AgentsRunFile>[],
      filesTotal = null,
      commits = const <AgentsRunCommit>[],
      commitsTotal = null,
      actions = null,
      summary = null,
      undoable = false,
      reason = null,
      conflicts = const <AgentsRunConflict>[],
      failure = code;

  final String runId;
  final String? sessionKey;
  final List<AgentsRunFile> files;

  /// The real count when the host capped [files] (at 500).
  final int? filesTotal;
  final List<AgentsRunCommit> commits;

  /// The real count when the host capped [commits] (at 200).
  final int? commitsTotal;

  /// All the run's commits, journal-only ones included.
  final int? actions;
  final AgentsRunChangesSummary? summary;

  /// At least one file can be undone without `force`.
  final bool undoable;

  /// Why nothing can be undone: `no_history`, `not_found`, `no_changes`,
  /// `already_undone`, `conflicts`, `run_active`, `failed`.
  final String? reason;
  final List<AgentsRunConflict> conflicts;
  final String? failure;

  /// A run works in this workspace right now.
  bool get runActive => reason == 'run_active';

  /// The files [files] does not list because of the cap.
  int get hiddenFiles {
    final int? total = filesTotal;
    if (total == null || total <= files.length) return 0;
    return total - files.length;
  }

  static AgentsRunChangesReport? fromPayload(Map<String, dynamic> payload) {
    final Object? runId = payload['run_id'];
    if (runId is! String) return null;
    return AgentsRunChangesReport(
      runId: runId,
      sessionKey: _text(payload['session_key']),
      files: List<AgentsRunFile>.unmodifiable(<AgentsRunFile>[
        if (payload['files'] is List)
          for (final Object? f in payload['files'] as List)
            ?AgentsRunFile.fromJson(f),
      ]),
      filesTotal: _count(payload['files_total']),
      commits: List<AgentsRunCommit>.unmodifiable(<AgentsRunCommit>[
        if (payload['commits'] is List)
          for (final Object? c in payload['commits'] as List)
            ?AgentsRunCommit.fromJson(c),
      ]),
      commitsTotal: _count(payload['commits_total']),
      actions: _count(payload['actions']),
      summary: AgentsRunChangesSummary.fromJson(payload['summary']),
      undoable: payload['undoable'] == true,
      reason: _text(payload['reason']),
      conflicts: List<AgentsRunConflict>.unmodifiable(
        AgentsRunConflict.listFrom(payload['conflicts']),
      ),
    );
  }
}

/// The `run_undo_result` answer, or a failure with no answer.
@immutable
class AgentsRunUndoResult {
  const AgentsRunUndoResult({
    required this.runId,
    required this.ok,
    this.sessionKey,
    this.reverted = const <String>[],
    this.conflicts = const <AgentsRunConflict>[],
    this.forced = false,
    this.changes,
    this.note,
    this.code,
    this.error,
  });

  /// No answer: [code] is `not_sent` or `no_answer`.
  const AgentsRunUndoResult.failed(this.runId, String this.code)
    : ok = false,
      sessionKey = null,
      reverted = const <String>[],
      conflicts = const <AgentsRunConflict>[],
      forced = false,
      changes = null,
      note = null,
      error = null;

  final String runId;
  final bool ok;
  final String? sessionKey;
  final List<String> reverted;
  final List<AgentsRunConflict> conflicts;
  final bool forced;

  /// The updated `done` block.
  final AgentsRunChangesSummary? changes;

  /// What the undo did not bring back (mail, API calls). Shown once.
  final String? note;

  /// `no_history`, `not_found`, `no_changes`, `already_undone`, `conflicts`,
  /// `run_active`, `failed`, or the app's own `not_sent` / `no_answer`.
  final String? code;

  /// A sentence the host wrote for the user.
  final String? error;

  bool get isConflicts => !ok && code == 'conflicts';
  bool get isRunActive => !ok && code == 'run_active';

  static AgentsRunUndoResult? fromPayload(Map<String, dynamic> payload) {
    final Object? runId = payload['run_id'];
    if (runId is! String) return null;
    return AgentsRunUndoResult(
      runId: runId,
      ok: payload['ok'] == true,
      sessionKey: _text(payload['session_key']),
      reverted: List<String>.unmodifiable(<String>[
        if (payload['reverted'] is List)
          for (final Object? p in payload['reverted'] as List)
            if (p is String && p.isNotEmpty) p,
      ]),
      conflicts: List<AgentsRunConflict>.unmodifiable(
        AgentsRunConflict.listFrom(payload['conflicts']),
      ),
      forced: payload['forced'] == true,
      changes: AgentsRunChangesSummary.fromJson(payload['changes']),
      note: _text(payload['note']),
      code: _text(payload['code']),
      error: _text(payload['error']),
    );
  }
}

String? _text(Object? value) =>
    value is String && value.trim().isNotEmpty ? value.trim() : null;

int? _count(Object? value) {
  if (value is bool) return null;
  if (value is int) return value < 0 ? null : value;
  if (value is num && value.isFinite && value >= 0) return value.toInt();
  return null;
}
