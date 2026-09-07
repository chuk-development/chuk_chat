/// The in-UI control surface (§16, §17: this GUI is the moat).
///
/// What a coworker runs on, what it has spent, how long it has worked, which
/// box it works in and which skills it may load — all of it read from the host,
/// none of it invented here.
///
/// [ControlValue] is what keeps that honest: a block is either
/// [ControlAvailable] with a measured value, [ControlLoading], or
/// [ControlUnavailable] with a reason. The host sends a block only for a figure
/// it measured (docs/WIRE_CONTRACT.md, "Agent status"), so there is no "0
/// tokens" a reader could mistake for a measurement.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:cowork/services/cowork/cowork_relay_client.dart';
import 'package:cowork/services/cowork/cowork_relay_link.dart';
import 'package:cowork/services/skills/skills_source.dart';

/// One block of the control surface: known, loading, or not connected.
@immutable
sealed class ControlValue<T> {
  const ControlValue();

  /// The value when it is really known, else null.
  T? get valueOrNull => switch (this) {
        ControlAvailable<T>(:final value) => value,
        _ => null,
      };
}

/// The host reported a real value.
@immutable
class ControlAvailable<T> extends ControlValue<T> {
  const ControlAvailable(this.value);
  final T value;
}

/// A request is in flight.
@immutable
class ControlLoading<T> extends ControlValue<T> {
  const ControlLoading();
}

/// Nothing on the other side reports this yet. [reason] is shown to the user.
@immutable
class ControlUnavailable<T> extends ControlValue<T> {
  const ControlUnavailable([this.reason = 'Not connected yet.']);
  final String reason;
}

/// One skill the agent can load on demand (§11).
@immutable
class AgentSkill {
  const AgentSkill({
    required this.name,
    required this.description,
    required this.enabled,
  });

  final String name;
  final String description;
  final bool enabled;

  AgentSkill copyWith({bool? enabled}) => AgentSkill(
        name: name,
        description: description,
        enabled: enabled ?? this.enabled,
      );
}

/// The model this coworker's last run really used.
@immutable
class AgentModelChoice {
  const AgentModelChoice({
    required this.id,
    this.provider,
    this.reasoningEffort,
  });

  /// The model id, as the account's catalogue names it.
  final String id;

  /// Which provider served it, when the host says.
  final String? provider;

  /// How hard it thought — Fast mode is this turned down.
  final String? reasoningEffort;

  /// `anthropic · low`, or null when the host named neither.
  String? get detail {
    final parts = <String>[
      if (provider != null && provider!.isNotEmpty) provider!,
      if (reasoningEffort != null && reasoningEffort!.isNotEmpty)
        reasoningEffort!,
    ];
    return parts.isEmpty ? null : parts.join(' · ');
  }

  static AgentModelChoice? fromPayload(Map<String, dynamic>? payload) {
    if (payload == null) return null;
    final id = payload['id'];
    if (id is! String || id.isEmpty) return null;
    String? text(Object? value) =>
        (value is String && value.isNotEmpty) ? value : null;
    return AgentModelChoice(
      id: id,
      provider: text(payload['provider']),
      reasoningEffort: text(payload['reasoning_effort']),
    );
  }
}

/// What this coworker has spent, summed over the runs it really made.
///
/// The host stores a run's total only, so there is no prompt/completion split
/// to show — and inventing one would be worse than leaving it out.
@immutable
class AgentTokenUsage {
  const AgentTokenUsage({
    required this.total,
    required this.runs,
    required this.lastRun,
  });

  final int total;
  final int runs;
  final int lastRun;

  static AgentTokenUsage? fromPayload(Map<String, dynamic>? payload) {
    if (payload == null) return null;
    int number(Object? value) => value is num ? value.toInt() : 0;
    return AgentTokenUsage(
      total: number(payload['total']),
      runs: number(payload['runs']),
      lastRun: number(payload['last_run']),
    );
  }
}

/// The coworker's clock: when it first ran, and how long it has been working.
@immutable
class AgentSessionRuntime {
  const AgentSessionRuntime({
    required this.active,
    required this.runs,
    required this.running,
    this.startedAt,
    this.current,
  });

  /// Time the agent was actually running, summed over its runs. Not wall clock
  /// since the thread was opened — that would measure the user, not the agent.
  final Duration active;

  /// How many runs that time is spread over.
  final int runs;

  /// True while a run is in flight right now.
  final bool running;

  /// When this coworker first ran.
  final DateTime? startedAt;

  /// How long the run in flight has been going, when one is.
  final Duration? current;

  static Duration _seconds(Object? value) => Duration(
        milliseconds: value is num ? (value * 1000).round() : 0,
      );

  static AgentSessionRuntime? fromPayload(Map<String, dynamic>? payload) {
    if (payload == null) return null;
    final startedAt = payload['started_at'];
    return AgentSessionRuntime(
      active: _seconds(payload['active_seconds']),
      runs: payload['runs'] is num ? (payload['runs'] as num).toInt() : 0,
      running: payload['running'] == true,
      startedAt: startedAt is num
          ? DateTime.fromMillisecondsSinceEpoch(
              (startedAt * 1000).round(),
              isUtc: true,
            ).toLocal()
          : null,
      current: payload['current_seconds'] == null
          ? null
          : _seconds(payload['current_seconds']),
    );
  }
}

/// The box this coworker works in (§6, bead cowork-jo2).
///
/// Every coworker gets its own container; this is what makes that visible in
/// the app instead of merely claimed in a design document.
@immutable
class AgentSandbox {
  const AgentSandbox({
    required this.kind,
    this.container,
    this.containerId,
    this.workspace,
  });

  /// `docker` or `local`.
  final String kind;

  /// The container's name, with the docker backend.
  final String? container;

  /// Its short id, when the container is already up.
  final String? containerId;

  /// The host directory the agent works in.
  final String? workspace;

  bool get isContainer => kind == 'docker';

  static AgentSandbox? fromPayload(Map<String, dynamic>? payload) {
    if (payload == null) return null;
    final kind = payload['kind'];
    if (kind is! String || kind.isEmpty) return null;
    String? text(Object? value) =>
        (value is String && value.isNotEmpty) ? value : null;
    return AgentSandbox(
      kind: kind,
      container: text(payload['container']),
      containerId: text(payload['container_id']),
      workspace: text(payload['workspace']),
    );
  }
}

/// Everything the control surface shows, one [ControlValue] per block.
@immutable
class AgentControlSnapshot {
  const AgentControlSnapshot({
    this.model = const ControlUnavailable<AgentModelChoice>(),
    this.tokens = const ControlUnavailable<AgentTokenUsage>(),
    this.runtime = const ControlUnavailable<AgentSessionRuntime>(),
    this.sandbox = const ControlUnavailable<AgentSandbox>(),
    this.skills = const ControlUnavailable<List<AgentSkill>>(),
  });

  final ControlValue<AgentModelChoice> model;
  final ControlValue<AgentTokenUsage> tokens;
  final ControlValue<AgentSessionRuntime> runtime;
  final ControlValue<AgentSandbox> sandbox;
  final ControlValue<List<AgentSkill>> skills;

  AgentControlSnapshot copyWith({
    ControlValue<AgentModelChoice>? model,
    ControlValue<AgentTokenUsage>? tokens,
    ControlValue<AgentSessionRuntime>? runtime,
    ControlValue<AgentSandbox>? sandbox,
    ControlValue<List<AgentSkill>>? skills,
  }) =>
      AgentControlSnapshot(
        model: model ?? this.model,
        tokens: tokens ?? this.tokens,
        runtime: runtime ?? this.runtime,
        sandbox: sandbox ?? this.sandbox,
        skills: skills ?? this.skills,
      );
}

/// The control surface's data source. One instance for the app; every call
/// names the coworker it is about, because one panel serves them all.
abstract interface class AgentControlSource {
  /// The live snapshot of one coworker. Stable for the life of the source, so
  /// a widget may listen to it.
  ValueListenable<AgentControlSnapshot> snapshotFor(String sessionKey);

  /// Re-reads everything for one coworker. Safe to call on every panel open.
  Future<void> refresh(String sessionKey);

  /// Switch one skill on or off on the host.
  Future<void> setSkillEnabled(String skillName, {required bool enabled});

  void dispose();
}

/// The production source: the host's own figures, over the relay.
///
/// Status comes back as [CoworkRelayAgentStatus] — as the answer to a request,
/// and again by itself whenever a run of that coworker ends, so the panel moves
/// with the work. Skills come from [SkillsSource], which already owns the
/// host's skill list and its switches.
class RelayAgentControlSource implements AgentControlSource {
  RelayAgentControlSource({SkillsSource? skills})
      : _skills = skills ?? SkillsSource.instance {
    // The transport is rebuilt on every reconnect, so follow it rather than
    // hold one subscription that dies with the first socket.
    CoworkRelayLink.instance.controller.addListener(_onController);
    _onController();
    _skills.addListener(_onSkills);
  }

  final SkillsSource _skills;
  StreamSubscription<CoworkRelayAgentStatus>? _sub;
  final Map<String, ValueNotifier<AgentControlSnapshot>> _snapshots =
      <String, ValueNotifier<AgentControlSnapshot>>{};
  bool _disposed = false;

  @override
  ValueListenable<AgentControlSnapshot> snapshotFor(String sessionKey) =>
      _notifier(sessionKey);

  ValueNotifier<AgentControlSnapshot> _notifier(String sessionKey) =>
      _snapshots.putIfAbsent(
        sessionKey,
        () => ValueNotifier<AgentControlSnapshot>(
          const AgentControlSnapshot(),
        ),
      );

  @override
  Future<void> refresh(String sessionKey) async {
    if (_disposed) return;
    final notifier = _notifier(sessionKey);
    final Object? controller = CoworkRelayLink.instance.controller.value;
    if (controller is! CoworkAgentStatusControl) {
      notifier.value = _unavailable('Not paired with a host.');
      return;
    }
    notifier.value = notifier.value.copyWith(
      model: const ControlLoading<AgentModelChoice>(),
      tokens: const ControlLoading<AgentTokenUsage>(),
      runtime: const ControlLoading<AgentSessionRuntime>(),
      sandbox: const ControlLoading<AgentSandbox>(),
      skills: const ControlLoading<List<AgentSkill>>(),
    );
    _skills.attach();
    // Two independent requests; a failure of either leaves that block saying
    // why, never a plausible-looking zero.
    unawaited(_skills.refresh().then((_) => _onSkills()));
    try {
      await controller.requestAgentStatus(sessionKey);
    } catch (error) {
      notifier.value = notifier.value.copyWith(
        model: ControlUnavailable<AgentModelChoice>('$error'),
        tokens: ControlUnavailable<AgentTokenUsage>('$error'),
        runtime: ControlUnavailable<AgentSessionRuntime>('$error'),
        sandbox: ControlUnavailable<AgentSandbox>('$error'),
      );
    }
  }

  @override
  Future<void> setSkillEnabled(String skillName, {required bool enabled}) async {
    final ok = await _skills.setEnabled(skillName, enabled);
    if (!ok) throw StateError('The host did not take that skill switch.');
  }

  @override
  void dispose() {
    _disposed = true;
    CoworkRelayLink.instance.controller.removeListener(_onController);
    _sub?.cancel();
    _sub = null;
    _skills.removeListener(_onSkills);
    for (final notifier in _snapshots.values) {
      notifier.dispose();
    }
    _snapshots.clear();
  }

  AgentControlSnapshot _unavailable(String reason) => AgentControlSnapshot(
        model: ControlUnavailable<AgentModelChoice>(reason),
        tokens: ControlUnavailable<AgentTokenUsage>(reason),
        runtime: ControlUnavailable<AgentSessionRuntime>(reason),
        sandbox: ControlUnavailable<AgentSandbox>(reason),
        skills: ControlUnavailable<List<AgentSkill>>(reason),
      );

  void _onController() {
    if (_disposed) return;
    _sub?.cancel();
    _sub = null;
    final Object? controller = CoworkRelayLink.instance.controller.value;
    if (controller is CoworkAgentStatusControl) {
      _sub = controller.agentStatus.listen(_onStatus);
    }
  }

  void _onStatus(CoworkRelayAgentStatus event) {
    if (_disposed) return;
    final notifier = _notifier(event.sessionKey);
    const nothingYet = 'The host has nothing to report for this coworker yet.';
    final model = AgentModelChoice.fromPayload(event.model);
    final tokens = AgentTokenUsage.fromPayload(event.tokens);
    final runtime = AgentSessionRuntime.fromPayload(event.runtime);
    final sandbox = AgentSandbox.fromPayload(event.sandbox);
    notifier.value = notifier.value.copyWith(
      model: model == null
          ? const ControlUnavailable<AgentModelChoice>(nothingYet)
          : ControlAvailable<AgentModelChoice>(model),
      tokens: tokens == null
          ? const ControlUnavailable<AgentTokenUsage>(nothingYet)
          : ControlAvailable<AgentTokenUsage>(tokens),
      runtime: runtime == null
          ? const ControlUnavailable<AgentSessionRuntime>(nothingYet)
          : ControlAvailable<AgentSessionRuntime>(runtime),
      sandbox: sandbox == null
          ? const ControlUnavailable<AgentSandbox>(nothingYet)
          : ControlAvailable<AgentSandbox>(sandbox),
    );
  }

  void _onSkills() {
    if (_disposed || !_skills.listed) return;
    final skills = <AgentSkill>[
      for (final skill in _skills.all)
        AgentSkill(
          name: skill.name,
          description: skill.description,
          enabled: skill.enabled,
        ),
    ];
    // Skills are the host's, not one coworker's: the same list belongs in
    // every open panel.
    for (final notifier in _snapshots.values) {
      notifier.value = notifier.value.copyWith(
        skills: ControlAvailable<List<AgentSkill>>(skills),
      );
    }
  }
}

/// The name the shell constructs. It **is** [RelayAgentControlSource].
///
/// The old class of this name reported every block as "not connected", which is
/// what the panel used to draw. Nothing is unavailable by default any more, but
/// the constructor call lives in `cowork_shell_state.dart`, which another
/// session owns right now; the name goes when that file is next edited.
class HostUnavailableControlSource extends RelayAgentControlSource {
  HostUnavailableControlSource({super.skills});
}

/// A stand-in source with values in it.
///
/// **For tests and local UI work only.** Nothing here comes from a host, which
/// is exactly why it must never be wired into the app.
@visibleForTesting
class FakeAgentControlSource implements AgentControlSource {
  FakeAgentControlSource({AgentControlSnapshot? initial})
      : _initial = initial ?? const AgentControlSnapshot();

  final AgentControlSnapshot _initial;
  final Map<String, ValueNotifier<AgentControlSnapshot>> _snapshots =
      <String, ValueNotifier<AgentControlSnapshot>>{};

  final List<String> refreshed = <String>[];
  final List<String> skillSwitches = <String>[];

  @override
  ValueListenable<AgentControlSnapshot> snapshotFor(String sessionKey) =>
      _notifier(sessionKey);

  ValueNotifier<AgentControlSnapshot> _notifier(String sessionKey) =>
      _snapshots.putIfAbsent(
        sessionKey,
        () => ValueNotifier<AgentControlSnapshot>(_initial),
      );

  @override
  Future<void> refresh(String sessionKey) async => refreshed.add(sessionKey);

  @override
  Future<void> setSkillEnabled(String skillName, {required bool enabled}) async {
    skillSwitches.add('$skillName=$enabled');
    for (final notifier in _snapshots.values) {
      final skills = notifier.value.skills.valueOrNull;
      if (skills == null) continue;
      notifier.value = notifier.value.copyWith(
        skills: ControlAvailable<List<AgentSkill>>(<AgentSkill>[
          for (final skill in skills)
            skill.name == skillName ? skill.copyWith(enabled: enabled) : skill,
        ]),
      );
    }
  }

  @override
  void dispose() {
    for (final notifier in _snapshots.values) {
      notifier.dispose();
    }
    _snapshots.clear();
  }
}
