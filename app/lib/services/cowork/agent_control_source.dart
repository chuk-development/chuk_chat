/// The in-UI control surface (§16, §17: this GUI is the moat).
///
/// Skills, integrations, the model, live token use, session runtime and the cron
/// schedule all belong in the app, not in a CLI. None of them cross the relay
/// yet: the in-frame protocol today is `task`/`stop` out and
/// `delta`/`reasoning`/`tool`/`file`/`done`/`error` back. So this file defines
/// the seam and ships the honest default — [HostUnavailableControlSource], which
/// reports every block as **not connected**.
///
/// [ControlValue] is what keeps that honest: a block is either
/// [ControlAvailable] with a real value, [ControlLoading], or
/// [ControlUnavailable] with a reason. There is no "0 tokens" or "no schedule"
/// state that a reader could mistake for a measurement.
library;

import 'package:flutter/foundation.dart';

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

/// One third-party door the agent can be given (§10). The raw secret never
/// enters the sandbox, so all the UI ever handles is the connected flag.
@immutable
class AgentIntegration {
  const AgentIntegration({
    required this.name,
    required this.connected,
    this.account,
  });

  final String name;
  final bool connected;

  /// Which account it is connected as, when the host says.
  final String? account;

  AgentIntegration copyWith({bool? connected, String? account}) =>
      AgentIntegration(
        name: name,
        connected: connected ?? this.connected,
        account: account ?? this.account,
      );
}

/// The model the agent runs on, and what else it could run on.
@immutable
class AgentModelChoice {
  const AgentModelChoice({required this.selectedId, this.available = const []});

  final String selectedId;
  final List<String> available;
}

/// Live token use for the current session (§7.3 counts prompt tokens only for
/// context pressure; this is the user-facing total).
@immutable
class AgentTokenUsage {
  const AgentTokenUsage({
    required this.promptTokens,
    required this.completionTokens,
  });

  final int promptTokens;
  final int completionTokens;

  int get total => promptTokens + completionTokens;
}

/// The agent's schedule and when it fires next (§13).
@immutable
class AgentSchedule {
  const AgentSchedule({
    required this.source,
    required this.description,
    this.nextRuns = const <DateTime>[],
    this.installedOnHost = true,
  });

  /// The schedule string exactly as it was set.
  final String source;

  /// A short human reading of [source].
  final String description;

  /// The next fire times. Empty means "none within the search window", which is
  /// different from unknown — an unknown schedule is a [ControlUnavailable].
  final List<DateTime> nextRuns;

  /// False when the schedule was set in the app but the host does not run it
  /// yet. The panel says so instead of implying the agent will wake up.
  final bool installedOnHost;
}

/// Everything the control surface shows, one [ControlValue] per block.
@immutable
class AgentControlSnapshot {
  const AgentControlSnapshot({
    this.skills = const ControlUnavailable<List<AgentSkill>>(),
    this.integrations = const ControlUnavailable<List<AgentIntegration>>(),
    this.model = const ControlUnavailable<AgentModelChoice>(),
    this.tokens = const ControlUnavailable<AgentTokenUsage>(),
    this.sessionRuntime = const ControlUnavailable<Duration>(),
    this.schedule = const ControlUnavailable<AgentSchedule>(),
  });

  final ControlValue<List<AgentSkill>> skills;
  final ControlValue<List<AgentIntegration>> integrations;
  final ControlValue<AgentModelChoice> model;
  final ControlValue<AgentTokenUsage> tokens;
  final ControlValue<Duration> sessionRuntime;
  final ControlValue<AgentSchedule> schedule;

  AgentControlSnapshot copyWith({
    ControlValue<List<AgentSkill>>? skills,
    ControlValue<List<AgentIntegration>>? integrations,
    ControlValue<AgentModelChoice>? model,
    ControlValue<AgentTokenUsage>? tokens,
    ControlValue<Duration>? sessionRuntime,
    ControlValue<AgentSchedule>? schedule,
  }) =>
      AgentControlSnapshot(
        skills: skills ?? this.skills,
        integrations: integrations ?? this.integrations,
        model: model ?? this.model,
        tokens: tokens ?? this.tokens,
        sessionRuntime: sessionRuntime ?? this.sessionRuntime,
        schedule: schedule ?? this.schedule,
      );
}

/// The control surface's data source. One instance per agent.
abstract interface class AgentControlSource {
  ValueListenable<AgentControlSnapshot> get snapshot;

  /// Re-reads everything. Safe to call on every panel open.
  Future<void> refresh();

  Future<void> setSkillEnabled(String skillName, {required bool enabled});

  Future<void> setIntegrationConnected(String name, {required bool connected});

  Future<void> selectModel(String modelId);

  /// Sets the cron/interval schedule from the string the user typed (§13).
  Future<void> setSchedule(String source);

  void dispose();
}

/// The production default: the host reports none of this yet.
///
/// Every block is [ControlUnavailable] and every mutation is refused, so the
/// panel can only ever show "not connected" — never a plausible-looking zero.
class HostUnavailableControlSource implements AgentControlSource {
  HostUnavailableControlSource({
    String reason = 'The host does not report this yet.',
  }) : _snapshot = ValueNotifier<AgentControlSnapshot>(
          AgentControlSnapshot(
            skills: ControlUnavailable<List<AgentSkill>>(reason),
            integrations: ControlUnavailable<List<AgentIntegration>>(reason),
            model: ControlUnavailable<AgentModelChoice>(reason),
            tokens: ControlUnavailable<AgentTokenUsage>(reason),
            sessionRuntime: ControlUnavailable<Duration>(reason),
            schedule: ControlUnavailable<AgentSchedule>(reason),
          ),
        );

  final ValueNotifier<AgentControlSnapshot> _snapshot;

  @override
  ValueListenable<AgentControlSnapshot> get snapshot => _snapshot;

  @override
  Future<void> refresh() async {}

  @override
  Future<void> setSkillEnabled(String skillName, {required bool enabled}) async {
    throw UnsupportedError('The host cannot change skills yet.');
  }

  @override
  Future<void> setIntegrationConnected(String name, {required bool connected}) async {
    throw UnsupportedError('The host cannot change integrations yet.');
  }

  @override
  Future<void> selectModel(String modelId) async {
    throw UnsupportedError('The host cannot change the model yet.');
  }

  @override
  Future<void> setSchedule(String source) async {
    throw UnsupportedError('The host cannot change the schedule yet.');
  }

  @override
  void dispose() => _snapshot.dispose();
}

/// A stand-in source with values in it.
///
/// **For tests and local UI work only.** It is never wired into the app: the
/// production default is [HostUnavailableControlSource], because showing made-up
/// skills or a made-up token count would be worse than showing nothing.
@visibleForTesting
class FakeAgentControlSource implements AgentControlSource {
  FakeAgentControlSource({AgentControlSnapshot? initial})
      : _snapshot = ValueNotifier<AgentControlSnapshot>(
          initial ?? const AgentControlSnapshot(),
        );

  final ValueNotifier<AgentControlSnapshot> _snapshot;

  int refreshCalls = 0;
  final List<String> selectedModels = <String>[];
  final List<String> schedules = <String>[];

  @override
  ValueListenable<AgentControlSnapshot> get snapshot => _snapshot;

  @override
  Future<void> refresh() async => refreshCalls++;

  @override
  Future<void> setSkillEnabled(String skillName, {required bool enabled}) async {
    final skills = _snapshot.value.skills.valueOrNull;
    if (skills == null) return;
    _snapshot.value = _snapshot.value.copyWith(
      skills: ControlAvailable<List<AgentSkill>>(<AgentSkill>[
        for (final skill in skills)
          skill.name == skillName ? skill.copyWith(enabled: enabled) : skill,
      ]),
    );
  }

  @override
  Future<void> setIntegrationConnected(String name, {required bool connected}) async {
    final integrations = _snapshot.value.integrations.valueOrNull;
    if (integrations == null) return;
    _snapshot.value = _snapshot.value.copyWith(
      integrations: ControlAvailable<List<AgentIntegration>>(<AgentIntegration>[
        for (final integration in integrations)
          integration.name == name
              ? integration.copyWith(connected: connected)
              : integration,
      ]),
    );
  }

  @override
  Future<void> selectModel(String modelId) async {
    selectedModels.add(modelId);
    _snapshot.value = _snapshot.value.copyWith(
      model: ControlAvailable<AgentModelChoice>(
        AgentModelChoice(
          selectedId: modelId,
          available: _snapshot.value.model.valueOrNull?.available ?? <String>[],
        ),
      ),
    );
  }

  @override
  Future<void> setSchedule(String source) async => schedules.add(source);

  @override
  void dispose() => _snapshot.dispose();
}
