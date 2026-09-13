import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/services/skills/agents_skill.dart';
import 'package:chuk_chat/services/skills/skill_settings_sync.dart';

/// The app's copy of the host's skill list, kept current from the relay.
///
/// One instance for the app (like [AutomationsSource]): it listens to
/// [AgentsRelayLink.inbound], takes every `skills_list` reply as the whole
/// truth, and notifies. The Skills page reads [all] and flips switches through
/// [setEnabled]; both need the bound controller to be a [AgentsSkillsControl]
/// (the real relay client is; a test double may not be).
///
/// The Supabase mirror rides along: the first reply after a start is compared
/// with the account's stored switches, and a skill the account has OFF but the
/// host reports ON is switched off on the host (a reinstalled app, a reset
/// host database). After that every reply is written back to the mirror, so
/// the account always holds what the host holds.
class SkillsSource extends ChangeNotifier {
  SkillsSource._({SkillSettingsMirror mirror = const SkillSettingsSync()})
    : _mirror = mirror;

  static SkillsSource instance = SkillsSource._();

  SkillSettingsMirror _mirror;
  List<AgentsSkill> _skills = const <AgentsSkill>[];
  List<String> _errors = const <String>[];
  StreamSubscription<AgentsRelayInbound>? _sub;
  bool _listed = false;
  bool _mirrorApplied = false;
  Map<String, bool> _mirrored = const <String, bool>{};

  /// Starts listening. Idempotent.
  void attach() {
    _sub ??= AgentsRelayLink.instance.inbound.listen(_onInbound);
  }

  /// Every skill the host listed, in the host's order (built-ins first).
  List<AgentsSkill> get all => List.unmodifiable(_skills);

  List<AgentsSkill> get builtin =>
      _skills.where((s) => s.isBuiltin).toList(growable: false);

  List<AgentsSkill> get workspace =>
      _skills.where((s) => !s.isBuiltin).toList(growable: false);

  /// What the host could not load (a broken SKILL.md) or refused (an unknown
  /// name in a control). Shown, never swallowed.
  List<String> get errors => List.unmodifiable(_errors);

  /// True once the host answered a list request. Before that an empty list
  /// means "not asked yet".
  bool get listed => _listed;

  AgentsSkill? byName(String name) {
    for (final skill in _skills) {
      if (skill.name == name) return skill;
    }
    return null;
  }

  /// Ask the host for the current list. Returns false when nothing is
  /// connected or the transport cannot send it.
  Future<bool> refresh() async {
    final Object? controller = AgentsRelayLink.instance.controller.value;
    if (controller is! AgentsSkillsControl) return false;
    try {
      await controller.requestSkillsList();
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Switch one skill on or off. The row flips at once so the switch does not
  /// bounce; the host's reply (the truth) then overwrites it — and puts it
  /// back if the host refused. Returns false when nothing is connected.
  Future<bool> setEnabled(String name, bool enabled) async {
    final Object? controller = AgentsRelayLink.instance.controller.value;
    if (controller is! AgentsSkillsControl) return false;
    final before = _skills;
    _skills = [
      for (final skill in _skills)
        skill.name == name ? skill.copyWith(enabled: enabled) : skill,
    ];
    notifyListeners();
    try {
      await controller.sendSkillControl(
        name: name,
        action: enabled ? 'enable' : 'disable',
      );
      return true;
    } catch (_) {
      _skills = before;
      notifyListeners();
      return false;
    }
  }

  void _onInbound(AgentsRelayInbound event) {
    if (event is! AgentsRelaySkillsList) return;
    _skills = List.unmodifiable(event.skills);
    _errors = List.unmodifiable(event.errors);
    _listed = true;
    notifyListeners();
    unawaited(_reconcileMirror(event.skills));
  }

  /// First reply: push the account's OFF switches to a host that has them ON.
  /// Every reply: write the host's truth back to the account.
  Future<void> _reconcileMirror(List<AgentsSkill> skills) async {
    // What this pass pushed to the host: its reply, not this stale list,
    // is what the mirror learns about those.
    final pushed = <String>{};
    if (!_mirrorApplied) {
      _mirrorApplied = true;
      final stored = await _mirror.load();
      if (stored != null) {
        _mirrored = Map<String, bool>.of(stored);
        for (final skill in skills) {
          if (skill.enabled && stored[skill.name] == false) {
            if (await setEnabled(skill.name, false)) pushed.add(skill.name);
          }
        }
      }
    }
    for (final skill in skills) {
      if (pushed.contains(skill.name)) continue;
      if (_mirrored[skill.name] == skill.enabled) continue;
      _mirrored = {..._mirrored, skill.name: skill.enabled};
      await _mirror.save(skill.name, skill.enabled);
    }
  }

  /// Test seam: forget everything, stop listening, swap the mirror.
  @visibleForTesting
  void reset({SkillSettingsMirror? mirror}) {
    _sub?.cancel();
    _sub = null;
    _skills = const <AgentsSkill>[];
    _errors = const <String>[];
    _listed = false;
    _mirrorApplied = false;
    _mirrored = const <String, bool>{};
    if (mirror != null) _mirror = mirror;
  }
}
