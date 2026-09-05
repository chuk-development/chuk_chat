import 'package:flutter/foundation.dart' show immutable;

/// One automation of a coworker: a schedule (cron / every / at) or a watcher
/// (a script that runs 24/7 in the sandbox and wakes the agent through
/// `cowork_hooks.trigger()`). docs/WIRE_CONTRACT.md, section "Automations".
///
/// This is the app's view of the host's `automations` row. It is built from
/// an `automation` event or an `automation_list` entry; the two carry the
/// same fields. Nothing here is guessed: a field the host did not send is
/// null.
@immutable
class CoworkAutomation {
  const CoworkAutomation({
    required this.id,
    required this.sessionKey,
    required this.kind,
    required this.name,
    required this.state,
    this.spec = const <String, dynamic>{},
    this.prompt = '',
    this.nextFireAt,
    this.lastFiredAt,
    this.fireCount = 0,
    this.suppressedCount = 0,
    this.lastError,
    this.logPath,
    this.createdAt,
  });

  /// The host's short handle (`ab12cd34`).
  final String id;

  /// The conversation that owns it. An agent only ever sees its own.
  final String sessionKey;

  /// `schedule` or `watcher`.
  final String kind;

  /// The label the model gave, or the host's default from the spec.
  final String name;

  /// `active`, `paused`, `done` or `failed`.
  final String state;

  /// `{cron}` / `{every}` / `{at}` for a schedule, `{script_path, restart}`
  /// for a watcher.
  final Map<String, dynamic> spec;

  /// What a fired task says to the model (may be empty for a watcher).
  final String prompt;

  final DateTime? nextFireAt;
  final DateTime? lastFiredAt;
  final int fireCount;

  /// Triggers folded by the rate limit (watcher).
  final int suppressedCount;

  /// Why it failed, or the last non-fatal problem.
  final String? lastError;

  /// Workspace-relative log of a watcher (`.cowork/automations/<id>.log`).
  final String? logPath;

  final DateTime? createdAt;

  bool get isSchedule => kind == 'schedule';
  bool get isWatcher => kind == 'watcher';
  bool get isActive => state == 'active';
  bool get isPaused => state == 'paused';

  /// `done` or `failed`: nothing more will happen.
  bool get isOver => state == 'done' || state == 'failed';

  /// A short human reading of the spec (`every 5m`, `cron 0 9 * * 1-5`,
  /// `at 2026-09-06 09:00`, `watch poll.py`).
  String get specLabel {
    final cron = spec['cron'];
    if (cron is String) return 'cron $cron';
    final every = spec['every'];
    if (every is num) {
      final seconds = every.toInt();
      if (seconds % 86400 == 0) return 'every ${seconds ~/ 86400}d';
      if (seconds % 3600 == 0) return 'every ${seconds ~/ 3600}h';
      if (seconds % 60 == 0) return 'every ${seconds ~/ 60}m';
      return 'every ${seconds}s';
    }
    final at = spec['at'];
    if (at is String) {
      final when = DateTime.tryParse(at)?.toLocal();
      return when == null ? 'at $at' : 'at ${_stamp(when)}';
    }
    final script = spec['script_path'];
    if (script is String) return 'watch $script';
    return kind;
  }

  /// Reads an `automation` event or an `automation_list` entry. Null when
  /// the id or the session is missing (nothing to show, nothing to control).
  static CoworkAutomation? fromPayload(Map<String, dynamic> payload) {
    final id = payload['id'];
    final session = payload['session_key'];
    if (id is! String || id.isEmpty || session is! String) return null;
    final rawSpec = payload['spec'];
    final rawKind = payload['kind'];
    final rawName = payload['name'];
    final rawState = payload['state'];
    final rawPrompt = payload['prompt'];
    final rawError = payload['last_error'];
    final rawLog = payload['log_path'];
    return CoworkAutomation(
      id: id,
      sessionKey: session,
      kind: rawKind is String ? rawKind : 'schedule',
      name: rawName is String && rawName.isNotEmpty ? rawName : id,
      state: rawState is String ? rawState : 'active',
      spec: rawSpec is Map
          ? rawSpec.map((k, v) => MapEntry('$k', v))
          : const <String, dynamic>{},
      prompt: rawPrompt is String ? rawPrompt : '',
      nextFireAt: _epoch(payload['next_fire_at']),
      lastFiredAt: _epoch(payload['last_fired_at']),
      fireCount: _int(payload['fire_count']) ?? 0,
      suppressedCount: _int(payload['suppressed_count']) ?? 0,
      lastError: rawError is String && rawError.isNotEmpty ? rawError : null,
      logPath: rawLog is String && rawLog.isNotEmpty ? rawLog : null,
      createdAt: _epoch(payload['created_at']),
    );
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
        'id': id,
        'session_key': sessionKey,
        'kind': kind,
        'name': name,
        'state': state,
        'spec': spec,
        'prompt': prompt,
        if (nextFireAt != null)
          'next_fire_at': nextFireAt!.millisecondsSinceEpoch / 1000,
        if (lastFiredAt != null)
          'last_fired_at': lastFiredAt!.millisecondsSinceEpoch / 1000,
        'fire_count': fireCount,
        'suppressed_count': suppressedCount,
        if (lastError != null) 'last_error': lastError,
        if (logPath != null) 'log_path': logPath,
        if (createdAt != null)
          'created_at': createdAt!.millisecondsSinceEpoch / 1000,
      };

  static int? _int(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  static DateTime? _epoch(Object? value) {
    if (value is num) {
      return DateTime.fromMillisecondsSinceEpoch((value * 1000).round());
    }
    return null;
  }

  static String _stamp(DateTime when) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${when.year}-${two(when.month)}-${two(when.day)} '
        '${two(when.hour)}:${two(when.minute)}';
  }

  @override
  bool operator ==(Object other) =>
      other is CoworkAutomation &&
      other.id == id &&
      other.sessionKey == sessionKey &&
      other.state == state &&
      other.fireCount == fireCount &&
      other.nextFireAt == nextFireAt &&
      other.lastFiredAt == lastFiredAt &&
      other.lastError == lastError;

  @override
  int get hashCode => Object.hash(id, sessionKey, state, fireCount, nextFireAt);
}

/// The two frames the app sends about automations. Kept apart from
/// `CoworkRelayController` so the existing test doubles keep compiling; the
/// real relay client implements both, and a view checks `is
/// CoworkAutomationControl` before it sends.
abstract interface class CoworkAutomationControl {
  /// `automation_control`: pause / resume / cancel one automation. The host
  /// answers with the `automation` event the action caused.
  Future<void> sendAutomationControl({
    required String id,
    required String action,
  });

  /// `automation_list`: ask for every automation of one session, or of the
  /// whole host when [sessionKey] is null. The host answers with an
  /// `automation_list` frame.
  Future<void> requestAutomationList({String? sessionKey});
}
