/// The per-thread mode state of an agent (docs/WIRE_CONTRACT.md, "Agent
/// modes: goal, plan, todo list, questions, typed sources"), and what the
/// inbox needs to know about a thread that waits on the user.
///
/// The host is the truth. Every frame here is persisted on the host and comes
/// back in a replay, so this store keeps the LAST frame per thread and never
/// guesses a value:
///
///  * `goal` / `run_state.goal` / `done.goal`: the goal card;
///  * `plan_mode` / `run_state.plan_mode`: the "Plan mode" chip;
///  * `todo` / `run_state.todos`: the sticky todo card;
///  * `question_request`: the question card in the composer seat;
///  * `approval_request`: the inbox label "Approval" / "Plan review".
///
/// It also keeps the host-wide sandbox block (`agent_permissions.sandbox`,
/// `agent_status.sandbox`, "Sandbox fallback"), so a thread can say that its
/// agent works without a container.
///
/// The relay client feeds it from its frame switch ([ingest]); it is not a
/// transcript event, so it never enters the sealed inbound stream.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';

// ── models ──────────────────────────────────────────────────────────────────

/// One goal view (`goal` frame, `run_state.goal`, `done.goal`).
@immutable
class AgentsGoal {
  const AgentsGoal({
    required this.id,
    required this.revision,
    required this.objective,
    required this.phase,
    this.activation = 'disarmed',
    this.roundsStarted = 0,
    this.maxRounds = 0,
    this.blockedCode,
    this.blockedMessage,
    this.needsUser = false,
    this.continues = false,
    this.waiting = false,
  });

  static const String phaseActive = 'active';
  static const String phasePaused = 'paused';
  static const String phaseBlocked = 'blocked';
  static const String phaseComplete = 'complete';

  final String id;
  final int revision;
  final String objective;

  /// `active`, `paused`, `blocked` or `complete`.
  final String phase;

  /// `armed` or `disarmed`. A goal comes back disarmed after a host restart.
  final String activation;
  final int roundsStarted;
  final int maxRounds;

  /// `model-reported` or `round-limit` while [phase] is `blocked`.
  final String? blockedCode;
  final String? blockedMessage;

  /// The goal is blocked and waits on the user: "Needs you" in the inbox.
  final bool needsUser;

  /// Only on `done.goal`: the next round is already queued.
  final bool continues;

  /// Only on `done.goal`: a queued user run goes first.
  final bool waiting;

  bool get isActive => phase == phaseActive;
  bool get isPaused => phase == phasePaused;
  bool get isBlocked => phase == phaseBlocked;
  bool get isComplete => phase == phaseComplete;
  bool get isArmed => activation == 'armed';

  /// "Resume" is offered when the goal does not continue on its own.
  bool get canResume => !isComplete && (!isArmed || isPaused || isBlocked);

  /// "Pause" is offered while the goal runs on its own.
  bool get canPause => isActive && isArmed;

  /// Reads a goal view, or null when it names no goal (a cleared goal is
  /// `"goal": null`).
  static AgentsGoal? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? id = raw['id'];
    final Object? objective = raw['objective'];
    if (id is! String || id.isEmpty) return null;
    final Object? blocked = raw['blocked_reason'];
    String? blockedText(String key) {
      if (blocked is! Map) return null;
      final Object? v = blocked[key];
      return v is String && v.trim().isNotEmpty ? v.trim() : null;
    }

    final Object? phase = raw['phase'];
    final Object? activation = raw['activation'];
    return AgentsGoal(
      id: id,
      revision: _int(raw['revision']) ?? 0,
      objective: objective is String ? objective.trim() : '',
      phase: phase is String && phase.isNotEmpty ? phase : phaseActive,
      activation: activation is String && activation.isNotEmpty
          ? activation
          : 'disarmed',
      roundsStarted: _int(raw['rounds_started']) ?? 0,
      maxRounds: _int(raw['max_rounds']) ?? 0,
      blockedCode: blockedText('code'),
      blockedMessage: blockedText('message'),
      needsUser: raw['needs_user'] == true,
      continues: raw['continues'] == true,
      waiting: raw['waiting'] == true,
    );
  }
}

/// One item of the agent's todo list.
@immutable
class AgentsTodo {
  const AgentsTodo({required this.content, required this.status});

  static const String pending = 'pending';
  static const String inProgress = 'in_progress';
  static const String completed = 'completed';

  final String content;

  /// `pending`, `in_progress` or `completed`.
  final String status;

  bool get isPending => status == pending;
  bool get isInProgress => status == inProgress;
  bool get isCompleted => status == completed;

  static List<AgentsTodo> listFrom(Object? raw) {
    if (raw is! List) return const <AgentsTodo>[];
    return List<AgentsTodo>.unmodifiable(<AgentsTodo>[
      for (final Object? entry in raw)
        if (entry is Map &&
            entry['content'] is String &&
            (entry['content'] as String).trim().isNotEmpty)
          AgentsTodo(
            content: (entry['content'] as String).trim(),
            status: switch (entry['status']) {
              inProgress => inProgress,
              completed => completed,
              _ => pending,
            },
          ),
    ]);
  }

  @override
  bool operator ==(Object other) =>
      other is AgentsTodo && other.content == content && other.status == status;

  @override
  int get hashCode => Object.hash(content, status);
}

/// One option of a question.
@immutable
class AgentsQuestionOption {
  const AgentsQuestionOption({required this.label, this.description});

  /// The suffix the tool puts on the recommended option (first only).
  static const String recommendedSuffix = '(Recommended)';

  /// The label as the model wrote it. This is what an answer sends back.
  final String label;
  final String? description;

  bool get recommended => label.trimRight().endsWith(recommendedSuffix);

  /// The label without "(Recommended)": the card shows a tag instead.
  String get displayLabel {
    if (!recommended) return label;
    final String trimmed = label.trimRight();
    return trimmed
        .substring(0, trimmed.length - recommendedSuffix.length)
        .trimRight();
  }
}

/// One question of an `ask_user` call.
@immutable
class AgentsQuestion {
  const AgentsQuestion({
    required this.id,
    required this.question,
    this.header,
    this.options = const <AgentsQuestionOption>[],
    this.multiSelect = false,
  });

  final String id;
  final String question;
  final String? header;
  final List<AgentsQuestionOption> options;
  final bool multiSelect;

  /// The labels preselected when the card opens: the recommended option.
  List<String> get preselected => <String>[
    for (final AgentsQuestionOption o in options)
      if (o.recommended) o.label,
  ].take(1).toList();

  static AgentsQuestion? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? id = raw['id'];
    final Object? question = raw['question'];
    if (id is! String || id.isEmpty || question is! String) return null;
    final Object? header = raw['header'];
    final Object? options = raw['options'];
    return AgentsQuestion(
      id: id,
      question: question.trim(),
      header: header is String && header.trim().isNotEmpty
          ? header.trim()
          : null,
      options: List<AgentsQuestionOption>.unmodifiable(<AgentsQuestionOption>[
        if (options is List)
          for (final Object? o in options)
            if (o is Map &&
                o['label'] is String &&
                (o['label'] as String).trim().isNotEmpty)
              AgentsQuestionOption(
                label: (o['label'] as String).trim(),
                description:
                    o['description'] is String &&
                        (o['description'] as String).trim().isNotEmpty
                    ? (o['description'] as String).trim()
                    : null,
              ),
      ]),
      multiSelect: raw['multi_select'] == true,
    );
  }
}

/// The user's answer to one question. Empty [selected] and no [custom] is a
/// skip.
@immutable
class AgentsQuestionAnswer {
  const AgentsQuestionAnswer({
    required this.id,
    this.selected = const <String>[],
    this.custom,
  });

  final String id;
  final List<String> selected;
  final String? custom;

  bool get isSkip =>
      selected.isEmpty && (custom == null || custom!.trim().isEmpty);

  Map<String, dynamic> toJson() => <String, dynamic>{
    'id': id,
    'selected': selected,
    if (custom != null && custom!.trim().isNotEmpty) 'custom': custom!.trim(),
  };

  static AgentsQuestionAnswer? fromJson(Object? raw) {
    if (raw is! Map || raw['id'] is! String) return null;
    final Object? selected = raw['selected'];
    final Object? custom = raw['custom'];
    return AgentsQuestionAnswer(
      id: raw['id'] as String,
      selected: <String>[
        if (selected is List)
          for (final Object? s in selected)
            if (s is String) s,
      ],
      custom: custom is String && custom.trim().isNotEmpty ? custom : null,
    );
  }
}

/// The last `question_request` of a thread.
@immutable
class AgentsQuestionRequest {
  const AgentsQuestionRequest({
    required this.questionId,
    required this.sessionKey,
    required this.questions,
    required this.status,
    this.timeoutSeconds,
    this.answers = const <AgentsQuestionAnswer>[],
  });

  static const String statusOpen = 'open';
  static const String statusAnswered = 'answered';
  static const String statusPending = 'pending';
  static const String statusStopped = 'stopped';

  final String questionId;
  final String sessionKey;
  final List<AgentsQuestion> questions;

  /// `open`, `answered`, `pending` or `stopped`.
  final String status;
  final int? timeoutSeconds;
  final List<AgentsQuestionAnswer> answers;

  /// Open, or timed out and still answerable (`pending`).
  bool get isAnswerable => status == statusOpen || status == statusPending;
  bool get isPending => status == statusPending;
  bool get isAnswered => status == statusAnswered;

  AgentsQuestionRequest copyWith({
    String? status,
    List<AgentsQuestionAnswer>? answers,
  }) => AgentsQuestionRequest(
    questionId: questionId,
    sessionKey: sessionKey,
    questions: questions,
    status: status ?? this.status,
    timeoutSeconds: timeoutSeconds,
    answers: answers ?? this.answers,
  );

  static AgentsQuestionRequest? fromPayload(Map<String, dynamic> payload) {
    final Object? id = payload['question_id'];
    final Object? key = payload['session_key'];
    if (id is! String || id.isEmpty || key is! String || key.isEmpty) {
      return null;
    }
    final Object? raw = payload['questions'];
    final List<AgentsQuestion> questions = <AgentsQuestion>[
      if (raw is List)
        for (final Object? q in raw) ?AgentsQuestion.fromJson(q),
    ];
    if (questions.isEmpty) return null;
    final Object? status = payload['status'];
    final Object? answers = payload['answers'];
    return AgentsQuestionRequest(
      questionId: id,
      sessionKey: key,
      questions: List<AgentsQuestion>.unmodifiable(questions),
      status: status is String && status.isNotEmpty ? status : statusOpen,
      timeoutSeconds: _int(payload['timeout_seconds']),
      answers: List<AgentsQuestionAnswer>.unmodifiable(<AgentsQuestionAnswer>[
        if (answers is List)
          for (final Object? a in answers) ?AgentsQuestionAnswer.fromJson(a),
      ]),
    );
  }

  /// The answer as one line per question, for the user-style bubble.
  String summary() {
    final List<String> lines = <String>[];
    for (final AgentsQuestion q in questions) {
      AgentsQuestionAnswer? a;
      for (final AgentsQuestionAnswer x in answers) {
        if (x.id == q.id) a = x;
      }
      final List<String> parts = <String>[
        if (a != null)
          for (final String s in a.selected)
            AgentsQuestionOption(label: s).displayLabel,
        if (a?.custom != null) a!.custom!.trim(),
      ];
      lines.add(parts.isEmpty ? '-' : parts.join(', '));
    }
    return lines.join('\n');
  }
}

/// What a thread waits on the user for, in the inbox's words.
enum AgentsWaitKind {
  /// A plan from plan mode waits for Approve / Keep planning.
  planReview,

  /// An action (or a publish, a takeover, a secret) waits for an answer.
  approval,

  /// A question from `ask_user` waits for an answer.
  answer,

  /// The goal is blocked and needs the user.
  needsYou,
}

/// The host's sandbox block (docs/WIRE_CONTRACT.md, "Sandbox fallback").
@immutable
class AgentsSandboxInfo {
  const AgentsSandboxInfo({
    required this.kind,
    this.fallback = false,
    this.requested,
    this.isolation,
  });

  /// `docker`, `local` or `local-bwrap`.
  final String kind;

  /// The user asked for `auto` and the host found no docker.
  final bool fallback;
  final String? requested;

  /// `bwrap` when local commands run in bubblewrap.
  final String? isolation;

  static AgentsSandboxInfo? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? kind = raw['kind'];
    if (kind is! String || kind.isEmpty) return null;
    final Object? requested = raw['requested'];
    final Object? isolation = raw['isolation'];
    return AgentsSandboxInfo(
      kind: kind,
      fallback: raw['fallback'] == true,
      requested: requested is String && requested.isNotEmpty ? requested : null,
      isolation: isolation is String && isolation.isNotEmpty ? isolation : null,
    );
  }
}

/// The user's picks from a late answer's prompt (the
/// `answer_to_pending_question` wrapper around `{callId, questions,
/// answers}`), one line per question. Null when the text is not that
/// wrapper.
String? pendingAnswerSummary(String prompt) {
  final int open = prompt.indexOf('>');
  final int close = prompt.lastIndexOf('</answer_to_pending_question>');
  if (!prompt.trimLeft().startsWith('<answer_to_pending_question') ||
      open < 0 ||
      close <= open) {
    return null;
  }
  try {
    final Object? body = jsonDecode(prompt.substring(open + 1, close));
    if (body is! Map) return null;
    final AgentsQuestionRequest? request = AgentsQuestionRequest.fromPayload(
      <String, dynamic>{
        'question_id': '${body['callId'] ?? 'answer'}',
        'session_key': 'answer',
        'questions': body['questions'],
        'answers': body['answers'],
        'status': AgentsQuestionRequest.statusAnswered,
      },
    );
    return request?.summary();
  } catch (_) {
    return null;
  }
}

int? _int(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

// ── the store ───────────────────────────────────────────────────────────────

/// Sends one sealed control frame; throws when nothing is connected.
typedef AgentsModesFrameSender =
    Future<void> Function(Map<String, dynamic> payload);

Future<void> _sendOverRelay(Map<String, dynamic> payload) async {
  final Object? controller = AgentsRelayLink.instance.controller.value;
  if (controller is! AgentsRelayClient) {
    throw StateError('Not connected to the host');
  }
  await controller.sendControlFrame(payload);
}

class AgentsThreadModes extends ChangeNotifier {
  AgentsThreadModes({AgentsModesFrameSender? send})
    : _send = send ?? _sendOverRelay;

  /// The one instance the app uses.
  static AgentsThreadModes instance = AgentsThreadModes();

  AgentsModesFrameSender _send;

  /// Test seam: where the control frames go.
  @visibleForTesting
  set sender(AgentsModesFrameSender send) => _send = send;

  final Map<String, AgentsGoal> _goals = <String, AgentsGoal>{};
  final Map<String, bool> _planMode = <String, bool>{};
  final Map<String, bool> _planWanted = <String, bool>{};
  final Map<String, List<AgentsTodo>> _todos = <String, List<AgentsTodo>>{};
  final Map<String, AgentsQuestionRequest> _questions =
      <String, AgentsQuestionRequest>{};
  final Map<String, String> _runSource = <String, String>{};

  /// Open approvals per thread: approval id → is a plan review.
  final Map<String, Map<String, bool>> _openApprovals =
      <String, Map<String, bool>>{};

  /// `ask_visible` already sent per question id, so a rebuild sends nothing.
  final Map<String, bool> _askVisibleSent = <String, bool>{};

  AgentsSandboxInfo? _sandbox;

  /// The wait labels the inbox showed before the app closed, per thread
  /// ([loadWaits]). Only the label is kept, nothing the user wrote. A thread
  /// the host has spoken about since ([_liveKeys]) reads its live state
  /// instead, so a stale label goes the moment the replay or a frame lands.
  final Map<String, AgentsWaitKind> _storedWaits = <String, AgentsWaitKind>{};

  /// Threads with at least one mode frame in this app session.
  final Set<String> _liveKeys = <String>{};

  bool _waitsLoaded = false;

  /// Where [_storedWaits] lives. Labels only; a few bytes per thread.
  static const String waitsPrefsKey = 'agents_thread_waits_v1';

  AgentsGoal? goalOf(String key) => _goals[key];

  /// What the host says about plan mode in [key].
  bool planModeOf(String key) => _planMode[key] ?? false;

  /// What the composer's toggle shows: the user's pending choice, else the
  /// host's state.
  bool planToggleOf(String key) => _planWanted[key] ?? planModeOf(key);

  List<AgentsTodo> todosOf(String key) => _todos[key] ?? const <AgentsTodo>[];

  AgentsQuestionRequest? questionOf(String key) => _questions[key];

  /// The origin of the run in flight when nobody typed its prompt.
  String? runSourceOf(String key) => _runSource[key];

  /// The host's sandbox, host-wide. Null before a host said.
  AgentsSandboxInfo? get sandbox => _sandbox;

  /// The agent works on the user's computer without a container.
  bool get sandboxFallback => _sandbox?.fallback ?? false;

  /// The plan-mode toggle in the composer. The next task of [key] carries
  /// `plan: on` (see [takePlanFlag]); until the host confirms, the chip
  /// shows the choice.
  void setPlanWanted(String key, bool on) {
    if (key.isEmpty) return;
    if (on == planModeOf(key)) {
      if (_planWanted.remove(key) == null) return;
    } else {
      if (_planWanted[key] == on) return;
      _planWanted[key] = on;
    }
    notifyListeners();
  }

  /// The `plan` value the next task of [key] carries, or null to leave the
  /// key off (no change). Read once per send.
  bool? takePlanFlag(String key) => _planWanted.remove(key);

  /// What [key] waits on the user for, or null. A plan review beats an
  /// approval, an approval beats a question, a question beats a blocked goal.
  AgentsWaitKind? waitKindOf(String key) {
    final AgentsWaitKind? live = _liveWaitKindOf(key);
    if (live != null || _liveKeys.contains(key)) return live;
    return _storedWaits[key];
  }

  AgentsWaitKind? _liveWaitKindOf(String key) {
    final Map<String, bool>? approvals = _openApprovals[key];
    if (approvals != null && approvals.isNotEmpty) {
      return approvals.values.any((bool plan) => plan)
          ? AgentsWaitKind.planReview
          : AgentsWaitKind.approval;
    }
    if (_questions[key]?.isAnswerable ?? false) return AgentsWaitKind.answer;
    if (_goals[key]?.needsUser ?? false) return AgentsWaitKind.needsYou;
    return null;
  }

  /// The most urgent wait over several threads (an agent's threads).
  AgentsWaitKind? waitKindOfAny(Iterable<String> keys) {
    AgentsWaitKind? best;
    for (final String key in keys) {
      final AgentsWaitKind? kind = waitKindOf(key);
      if (kind != null && (best == null || kind.index < best.index)) {
        best = kind;
      }
    }
    return best;
  }

  // ── frames in ──

  /// Takes one decoded frame. Types this store does not read are ignored.
  void ingest(Map<String, dynamic> payload) {
    final Object? type = payload['type'];
    final Object? rawKey = payload['session_key'];
    final String? key = rawKey is String && rawKey.isNotEmpty ? rawKey : null;
    bool changed = false;
    switch (type) {
      case 'goal':
        if (key != null && payload.containsKey('goal')) {
          changed = _setGoal(key, payload['goal']);
        }
      case 'plan_mode':
        if (key != null && payload['active'] is bool) {
          changed = _setPlanMode(key, payload['active'] as bool);
        }
      case 'todo':
        if (key != null) changed = _setTodos(key, payload['todos']);
      case 'question_request':
        final AgentsQuestionRequest? request =
            AgentsQuestionRequest.fromPayload(payload);
        if (request != null) changed = _setQuestion(request);
      case 'run_state':
        if (key != null) changed = _runState(key, payload);
      case 'approval_request':
        if (key != null) changed = _approval(key, payload);
      case 'done':
        if (key != null && payload['reason'] != 'replay') {
          changed = _done(key, payload);
        }
      case 'agent_permissions':
      case 'agent_status':
        final AgentsSandboxInfo? box = AgentsSandboxInfo.fromJson(
          payload['sandbox'],
        );
        if (box != null) changed = _setSandbox(box);
      default:
        return;
    }
    if (key != null) _liveKeys.add(key);
    if (changed) {
      notifyListeners();
      _saveWaits();
    }
  }

  // ── wait labels across restarts ──

  /// Reads the labels stored at the last change. Safe to call often.
  Future<void> loadWaits() async {
    if (_waitsLoaded) return;
    _waitsLoaded = true;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final Map<String, AgentsWaitKind> stored = decodeWaits(
        prefs.getString(waitsPrefsKey),
      );
      if (stored.isEmpty) return;
      stored.removeWhere((String key, _) => _liveKeys.contains(key));
      _storedWaits.addAll(stored);
      notifyListeners();
    } catch (_) {
      // No preferences (a widget test): the labels start empty.
    }
  }

  /// Every thread that waits now: the live state where the host has spoken,
  /// the stored label elsewhere.
  @visibleForTesting
  Map<String, AgentsWaitKind> currentWaits() {
    final Set<String> keys = <String>{
      ..._openApprovals.keys,
      ..._questions.keys,
      ..._goals.keys,
      ..._storedWaits.keys,
    };
    return <String, AgentsWaitKind>{
      for (final String key in keys)
        if (waitKindOf(key) case final AgentsWaitKind kind) key: kind,
    };
  }

  void _saveWaits() {
    if (!_waitsLoaded) return; // Never overwrite labels not read yet.
    final String encoded = encodeWaits(currentWaits());
    unawaited(() async {
      try {
        final SharedPreferences prefs = await SharedPreferences.getInstance();
        await prefs.setString(waitsPrefsKey, encoded);
      } catch (_) {
        // Kept in memory; the next change writes again.
      }
    }());
  }

  /// `{"<thread key>": "<kind name>"}`.
  @visibleForTesting
  static String encodeWaits(Map<String, AgentsWaitKind> waits) =>
      jsonEncode(<String, String>{
        for (final MapEntry<String, AgentsWaitKind> e in waits.entries)
          e.key: e.value.name,
      });

  /// [encodeWaits]'s output back; unknown kinds and broken input are dropped.
  @visibleForTesting
  static Map<String, AgentsWaitKind> decodeWaits(String? raw) {
    if (raw == null || raw.isEmpty) return <String, AgentsWaitKind>{};
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, AgentsWaitKind>{};
      return <String, AgentsWaitKind>{
        for (final MapEntry<dynamic, dynamic> e in decoded.entries)
          if (e.key is String && (e.key as String).isNotEmpty)
            for (final AgentsWaitKind kind in AgentsWaitKind.values)
              if (kind.name == e.value) e.key as String: kind,
      };
    } catch (_) {
      return <String, AgentsWaitKind>{};
    }
  }

  bool _setGoal(String key, Object? raw) {
    final AgentsGoal? goal = AgentsGoal.fromJson(raw);
    if (goal == null) return _goals.remove(key) != null;
    _goals[key] = goal;
    return true;
  }

  bool _setPlanMode(String key, bool active) {
    final bool? before = _planMode[key];
    _planMode[key] = active;
    // The host now says what the user asked for: the choice is applied.
    final bool applied = _planWanted[key] == active;
    if (applied) _planWanted.remove(key);
    return before != active || applied;
  }

  bool _setTodos(String key, Object? raw) {
    final List<AgentsTodo> next = AgentsTodo.listFrom(raw);
    if (listEquals(next, _todos[key])) return false;
    if (next.isEmpty) {
      _todos.remove(key);
    } else {
      _todos[key] = next;
    }
    return true;
  }

  bool _setQuestion(AgentsQuestionRequest request) {
    final AgentsQuestionRequest? current = _questions[request.sessionKey];
    // A replay of an older question never replaces a newer open one.
    if (current != null &&
        current.questionId != request.questionId &&
        current.isAnswerable &&
        !request.isAnswerable) {
      return false;
    }
    _questions[request.sessionKey] = request;
    if (!request.isAnswerable) _askVisibleSent.remove(request.questionId);
    return true;
  }

  bool _runState(String key, Map<String, dynamic> payload) {
    // The replay header is the whole mode state of the thread: each field
    // rides only when it applies, so an absent one means "none" (an older
    // host never had any to clear).
    bool changed = _setGoal(key, payload['goal']);
    if (_setPlanMode(key, payload['plan_mode'] == true)) changed = true;
    if (_setTodos(key, payload['todos'])) changed = true;
    final Object? source = payload['source'];
    final bool running = payload['state'] == 'running';
    if (running && source is String && source.isNotEmpty) {
      if (_runSource[key] != source) {
        _runSource[key] = source;
        changed = true;
      }
    } else if (_runSource.remove(key) != null) {
      changed = true;
    }
    if (!running) {
      // Nothing runs: no approval can still be waiting.
      if (_openApprovals.remove(key) != null) changed = true;
    }
    return changed;
  }

  bool _approval(String key, Map<String, dynamic> payload) {
    final Object? id = payload['approval_id'];
    if (id is! String || id.isEmpty) return false;
    final Object? decision = payload['decision'];
    final bool decided = decision is String && decision.isNotEmpty;
    final Map<String, bool> open = _openApprovals.putIfAbsent(
      key,
      () => <String, bool>{},
    );
    if (decided) {
      final bool removed = open.remove(id) != null;
      if (open.isEmpty) _openApprovals.remove(key);
      return removed;
    }
    if (open.containsKey(id)) return false;
    open[id] =
        payload['action'] == 'plan_review' || payload['kind'] == 'plan_review';
    return true;
  }

  bool _done(String key, Map<String, dynamic> payload) {
    bool changed = _openApprovals.remove(key) != null;
    if (_runSource.remove(key) != null) changed = true;
    if (payload.containsKey('goal')) {
      changed = _setGoal(key, payload['goal']) || changed;
    }
    // A question that was still `open` when the run ended is over; a
    // `pending` one stays answerable (it starts a new turn).
    final AgentsQuestionRequest? q = _questions[key];
    if (q != null && q.status == AgentsQuestionRequest.statusOpen) {
      _questions[key] = q.copyWith(status: AgentsQuestionRequest.statusStopped);
      changed = true;
    }
    return changed;
  }

  bool _setSandbox(AgentsSandboxInfo box) {
    final AgentsSandboxInfo? before = _sandbox;
    _sandbox = box;
    return before == null ||
        before.kind != box.kind ||
        before.fallback != box.fallback ||
        before.isolation != box.isolation;
  }

  /// The app answered [approvalId] of [key] on a card: the inbox label goes
  /// at once, before the host echoes the outcome.
  void approvalAnswered(String key, String approvalId) {
    final Map<String, bool>? open = _openApprovals[key];
    if (open == null || open.remove(approvalId) == null) return;
    if (open.isEmpty) _openApprovals.remove(key);
    notifyListeners();
    _saveWaits();
  }

  // ── frames out ──

  /// `goal_control` pause / resume / clear. False when it could not be sent.
  Future<bool> goalControl(String key, String action) async {
    try {
      await _send(<String, dynamic>{
        'type': 'goal_control',
        'session_key': key,
        'action': action,
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  /// One `approval_decision` with the fields the typed controller method
  /// does not carry: the "Keep planning" [feedback] of a plan review (at most
  /// 4,000 characters) and the [rememberPrefix] of "Always allow `git push`"
  /// (scope `always_this_prefix`). False when it could not be sent.
  Future<bool> sendApprovalDecision({
    required String approvalId,
    required bool approved,
    String? scope,
    String? rememberPrefix,
    String? feedback,
  }) async {
    final String? note = feedback?.trim();
    try {
      await _send(<String, dynamic>{
        'type': 'approval_decision',
        'approval_id': approvalId,
        'approved': approved,
        if (scope != null && scope.isNotEmpty) 'scope': scope,
        if (rememberPrefix != null && rememberPrefix.trim().isNotEmpty)
          'remember_prefix': rememberPrefix.trim(),
        if (note != null && note.isNotEmpty)
          'feedback': note.length > 4000 ? note.substring(0, 4000) : note,
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  /// `question_answer` for [request]. The card shows the answer at once as
  /// answered; the host's next `question_request` confirms it. False when it
  /// could not be sent (the card stays answerable).
  Future<bool> answerQuestion(
    AgentsQuestionRequest request,
    List<AgentsQuestionAnswer> answers,
  ) async {
    try {
      await _send(<String, dynamic>{
        'type': 'question_answer',
        'question_id': request.questionId,
        'session_key': request.sessionKey,
        'answers': <Map<String, dynamic>>[
          for (final AgentsQuestionAnswer a in answers) a.toJson(),
        ],
      });
    } catch (_) {
      return false;
    }
    _questions[request.sessionKey] = request.copyWith(
      status: AgentsQuestionRequest.statusAnswered,
      answers: List<AgentsQuestionAnswer>.unmodifiable(answers),
    );
    _askVisibleSent.remove(request.questionId);
    _liveKeys.add(request.sessionKey);
    notifyListeners();
    _saveWaits();
    return true;
  }

  /// `ask_visible`: the card is on screen (the wait stops counting down) or
  /// not. Sent once per change per question.
  Future<void> setAskVisible(String questionId, bool visible) async {
    if (_askVisibleSent[questionId] == visible) return;
    _askVisibleSent[questionId] = visible;
    try {
      await _send(<String, dynamic>{
        'type': 'ask_visible',
        'question_id': questionId,
        'visible': visible,
      });
    } catch (_) {
      // Not connected: the next show sends it again.
      _askVisibleSent.remove(questionId);
    }
  }

  /// Test seam.
  @visibleForTesting
  void reset() {
    _goals.clear();
    _planMode.clear();
    _planWanted.clear();
    _todos.clear();
    _questions.clear();
    _runSource.clear();
    _openApprovals.clear();
    _askVisibleSent.clear();
    _storedWaits.clear();
    _liveKeys.clear();
    _waitsLoaded = false;
    _sandbox = null;
    _send = _sendOverRelay;
    notifyListeners();
  }
}
