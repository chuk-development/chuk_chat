import 'package:flutter/foundation.dart' show immutable, mapEquals;

import 'package:chuk_chat/l10n/app_localizations.dart';

/// One automation of a coworker: a schedule (cron / every / at) or a watcher
/// (a script that runs 24/7 in the sandbox and wakes the agent through
/// `agents_hooks.trigger()`). docs/WIRE_CONTRACT.md, section "Automations".
///
/// This is the app's view of the host's `automations` row. It is built from
/// an `automation` event or an `automation_list` entry; the two carry the
/// same fields. Nothing here is guessed: a field the host did not send is
/// null.
@immutable
class AgentsAutomation {
  const AgentsAutomation({
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
    this.notify = 'always',
    this.lastSummary,
    this.lastResultAt,
    this.unchangedCount = 0,
  });

  /// The host's short handle (`ab12cd34`).
  final String id;

  /// The conversation that owns it. An agent only ever sees its own.
  final String sessionKey;

  /// `schedule`, `watcher`, `watch_url` or `mail`.
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

  /// Workspace-relative log of a watcher (`.agents/automations/<id>.log`).
  final String? logPath;

  final DateTime? createdAt;

  /// `always` (every run notifies) or `on_change` (only a run that reports a
  /// change does). docs/WIRE_CONTRACT.md, "Event triggers".
  final String notify;

  /// The facts the last `on_change` run reported, in its own short words.
  final String? lastSummary;

  /// When that last result came.
  final DateTime? lastResultAt;

  /// How many runs in a row reported no change.
  final int unchangedCount;

  /// True when only a run that reports a change tells the user.
  bool get notifiesOnChange => notify == 'on_change';

  /// A page the host checks (`{url, every}`).
  bool get isWatchUrl => kind == 'watch_url';

  /// An incoming agent mail that matches a filter (`{from?, subject?}`).
  bool get isMail => kind == 'mail';

  /// What sets it off, in the user's words: `clock` (a schedule), `page` (a
  /// watched page), `mail` (a mail filter) or `script` (a watcher script).
  String get trigger => switch (kind) {
    'watcher' => 'script',
    'watch_url' => 'page',
    'mail' => 'mail',
    _ => 'clock',
  };

  /// The URL a page watch checks, or null.
  String? get watchedUrl {
    final url = spec['url'];
    return url is String && url.isNotEmpty ? url : null;
  }

  /// The check interval of a page watch, or the interval of an `every`
  /// schedule, in seconds.
  int? get everySeconds {
    final every = spec['every'];
    return every is num ? every.toInt() : null;
  }

  /// The sender filter of a mail trigger, or null.
  String? get mailFrom {
    final from = spec['from'];
    return from is String && from.isNotEmpty ? from : null;
  }

  /// The subject filter of a mail trigger, or null.
  String? get mailSubject {
    final subject = spec['subject'];
    return subject is String && subject.isNotEmpty ? subject : null;
  }

  /// The schedule as the host's spec grammar writes it (`0 9 * * 1-5`,
  /// `every 30m`, `at 2026-10-06T09:00`), so the edit sheet can show and send
  /// it back unchanged. Null for a kind that is not a schedule.
  String? get scheduleText {
    if (!isSchedule) return null;
    final cron = spec['cron'];
    if (cron is String) return cron;
    final every = everySeconds;
    if (every != null) return 'every ${_duration(every)}';
    final at = spec['at'];
    if (at is String) return 'at $at';
    return null;
  }

  bool get isSchedule => kind == 'schedule';
  bool get isWatcher => kind == 'watcher';
  bool get isActive => state == 'active';
  bool get isPaused => state == 'paused';

  /// `done` or `failed`: nothing more will happen.
  bool get isOver => state == 'done' || state == 'failed';

  /// The words of the state chip, localised and in sentence case ("Active",
  /// "Pausiert"). English without [l10n]. A state this app does not know is
  /// shown as the host sent it, with a capital first letter.
  String stateLabel([AppLocalizations? l10n]) =>
      automationStateLabel(state, l10n);

  /// A short human reading of the spec (`every 5m`, `cron 0 9 * * 1-5`,
  /// `at 2026-09-06 09:00`, `watch poll.py`).
  String get specLabel {
    if (isWatchUrl || isMail) return _eventSpecLabel;
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

  String get _eventSpecLabel {
    if (isWatchUrl) {
      final url = watchedUrl;
      final host = url == null ? null : Uri.tryParse(url)?.host;
      final every = everySeconds;
      final where = (host == null || host.isEmpty) ? (url ?? 'page') : host;
      return every == null ? where : '$where · every ${_duration(every)}';
    }
    if (isMail) {
      final parts = <String>[
        if (mailFrom != null) 'from $mailFrom',
        if (mailSubject != null) 'subject "$mailSubject"',
      ];
      return parts.isEmpty ? 'mail' : parts.join(' · ');
    }
    return kind;
  }

  /// `30m`, `2h`, `1d`, `45s`: the largest whole unit.
  static String _duration(int seconds) {
    if (seconds > 0 && seconds % 86400 == 0) return '${seconds ~/ 86400}d';
    if (seconds > 0 && seconds % 3600 == 0) return '${seconds ~/ 3600}h';
    if (seconds > 0 && seconds % 60 == 0) return '${seconds ~/ 60}m';
    return '${seconds}s';
  }

  /// Reads an `automation` event or an `automation_list` entry. Null when
  /// the id or the session is missing (nothing to show, nothing to control).
  static AgentsAutomation? fromPayload(Map<String, dynamic> payload) {
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
    return AgentsAutomation(
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
      notify: payload['notify'] == 'on_change' ? 'on_change' : 'always',
      lastSummary: _text(payload['last_summary']),
      lastResultAt: _epoch(payload['last_result_at']),
      unchangedCount: _int(payload['unchanged_count']) ?? 0,
    );
  }

  static String? _text(Object? value) =>
      value is String && value.trim().isNotEmpty ? value : null;

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
    'notify': notify,
    if (lastSummary != null) 'last_summary': lastSummary,
    if (lastResultAt != null)
      'last_result_at': lastResultAt!.millisecondsSinceEpoch / 1000,
    if (unchangedCount > 0) 'unchanged_count': unchangedCount,
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
      other is AgentsAutomation &&
      other.id == id &&
      other.sessionKey == sessionKey &&
      other.state == state &&
      other.fireCount == fireCount &&
      other.nextFireAt == nextFireAt &&
      other.lastFiredAt == lastFiredAt &&
      other.lastError == lastError &&
      other.name == name &&
      other.prompt == prompt &&
      other.notify == notify &&
      other.lastSummary == lastSummary &&
      other.unchangedCount == unchangedCount &&
      mapEquals(other.spec, spec);

  @override
  int get hashCode => Object.hash(id, sessionKey, state, fireCount, nextFireAt);
}

/// The two frames the app sends about automations. Kept apart from
/// `AgentsRelayController` so the existing test doubles keep compiling; the
/// real relay client implements both, and a view checks `is
/// AgentsAutomationControl` before it sends.
abstract interface class AgentsAutomationControl {
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

/// The words for an automation [state] (`active`, `paused`, `done`,
/// `failed`), localised when [l10n] is given. See
/// [AgentsAutomation.stateLabel].
String automationStateLabel(String state, [AppLocalizations? l10n]) {
  switch (state) {
    case 'active':
      return l10n?.agentsAutomationStateActive ?? 'Active';
    case 'paused':
      return l10n?.agentsAutomationStatePaused ?? 'Paused';
    case 'done':
      return l10n?.agentsAutomationStateDone ?? 'Done';
    case 'failed':
      return l10n?.agentsAutomationStateFailed ?? 'Failed';
    default:
      final String raw = state.trim();
      if (raw.isEmpty) return raw;
      return raw[0].toUpperCase() + raw.substring(1);
  }
}

// ── F2: automations + cost totals ──
// The create and edit frames (docs/WIRE_CONTRACT.md, "Event triggers and
// notify only on change"). Their own interface, like
// [AgentsAutomationControl]: the existing test doubles keep compiling, and a
// view checks `is AgentsAutomationEditControl` before it sends.

/// The page watch's floor: the host checks a page at most every 15 minutes.
const int kWatchUrlMinSeconds = 900;

/// The page watch's default interval when the user gives none.
const int kWatchUrlDefaultSeconds = 3600;

/// The longest mail filter the host accepts, per field.
const int kMailFilterMaxLength = 200;

/// The kinds the app can create. A `watcher` needs a script in the workspace,
/// so only the model makes one.
const List<String> kCreatableAutomationKinds = <String>[
  'schedule',
  'watch_url',
  'mail',
];

abstract interface class AgentsAutomationEditControl {
  /// `automation_create`. The host answers with one `automation_saved`.
  Future<void> sendAutomationCreate(Map<String, dynamic> frame);

  /// `automation_update`. The host answers with one `automation_saved`.
  Future<void> sendAutomationUpdate(Map<String, dynamic> frame);
}

/// The host's answer to a create or an update: the saved row, or why not.
@immutable
class AutomationSaveResult {
  const AutomationSaveResult.saved(this.automation) : error = null;
  const AutomationSaveResult.failed(this.error) : automation = null;

  final AgentsAutomation? automation;

  /// The host's own words, shown as they are.
  final String? error;

  bool get ok => automation != null;

  /// Reads an `automation_saved` frame. A frame that says `ok` without a row
  /// it can read is a failure: nothing would show the saved state.
  static AutomationSaveResult fromPayload(Map<String, dynamic> payload) {
    if (payload['ok'] == true) {
      final raw = payload['automation'];
      if (raw is Map) {
        final automation = AgentsAutomation.fromPayload(
          raw.map((k, v) => MapEntry('$k', v)),
        );
        if (automation != null) return AutomationSaveResult.saved(automation);
      }
      return const AutomationSaveResult.failed(
        'The host saved it but sent no readable row.',
      );
    }
    final error = payload['error'];
    return AutomationSaveResult.failed(
      error is String && error.trim().isNotEmpty
          ? error.trim()
          : 'The host did not save it.',
    );
  }
}

/// The spec a create or an update carries for [kind]: the schedule text as
/// typed (`every 30m`, `0 9 * * 1-5`, `at …`, `in 2h`), `{url, every}` for a
/// page watch, `{from?, subject?}` for a mail filter. Empty fields are left
/// out.
Object automationSpecFor(
  String kind, {
  String schedule = '',
  String url = '',
  int? everySeconds,
  String mailFrom = '',
  String mailSubject = '',
}) {
  switch (kind) {
    case 'watch_url':
      return <String, dynamic>{
        'url': url.trim(),
        'every': everySeconds ?? kWatchUrlDefaultSeconds,
      };
    case 'mail':
      return <String, dynamic>{
        if (mailFrom.trim().isNotEmpty) 'from': mailFrom.trim(),
        if (mailSubject.trim().isNotEmpty) 'subject': mailSubject.trim(),
      };
    default:
      return schedule.trim();
  }
}

/// `automation_create` for [sessionKey].
Map<String, dynamic> automationCreateFrame({
  required String sessionKey,
  required String kind,
  required Object spec,
  required String prompt,
  String? name,
  bool notifyOnChange = false,
}) => <String, dynamic>{
  'type': 'automation_create',
  'session_key': sessionKey,
  'kind': kind,
  'spec': spec,
  'prompt': prompt.trim(),
  if (name != null && name.trim().isNotEmpty) 'name': name.trim(),
  'notify': notifyOnChange ? 'on_change' : 'always',
};

/// `automation_update` for [before]: only the keys whose value differs from
/// the row as the host last sent it. Null when nothing changed.
Map<String, dynamic>? automationUpdateFrame({
  required AgentsAutomation before,
  required Object spec,
  required String prompt,
  required String name,
  required bool notifyOnChange,
}) {
  final frame = <String, dynamic>{'type': 'automation_update', 'id': before.id};
  final trimmedName = name.trim();
  if (trimmedName.isNotEmpty && trimmedName != before.name) {
    frame['name'] = trimmedName;
  }
  final trimmedPrompt = prompt.trim();
  if (trimmedPrompt != before.prompt.trim()) frame['prompt'] = trimmedPrompt;
  final bool specChanged = spec is String
      ? spec != (before.scheduleText ?? '')
      : !(spec is Map && mapEquals(spec, before.spec));
  if (specChanged) frame['spec'] = spec;
  final notify = notifyOnChange ? 'on_change' : 'always';
  if (notify != before.notify) frame['notify'] = notify;
  return frame.length <= 2 ? null : frame;
}
// ── end F2 ──
