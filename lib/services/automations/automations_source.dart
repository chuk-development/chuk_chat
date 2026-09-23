import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/services/automations/agents_automation.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';

/// The app's copy of the host's automations, kept current from the relay.
///
/// One instance for the app (like the replay loader): it listens to
/// [AgentsRelayLink.inbound], folds every `automation` event (live or
/// replayed) and every `automation_list` reply into one map by id, and
/// notifies. The thread view reads [forSession] for its strip; the
/// Automations page reads [all]. Both send through [control] and [refresh],
/// which need the bound controller to be a [AgentsAutomationControl] (the
/// real relay client is; a test double may not be).
class AutomationsSource extends ChangeNotifier {
  AutomationsSource._();

  static final AutomationsSource instance = AutomationsSource._();

  final Map<String, AgentsAutomation> _byId = <String, AgentsAutomation>{};

  /// The host's coworker names, by session key (`agent_list`).
  final Map<String, String> _names = <String, String>{};
  StreamSubscription<AgentsRelayInbound>? _sub;

  /// Sessions whose list the host has answered at least once.
  final Set<String> _listed = <String>{};
  bool _listedAll = false;

  /// Starts listening. Idempotent.
  void attach() {
    _sub ??= AgentsRelayLink.instance.inbound.listen(_onInbound);
  }

  /// Every automation known to this app, newest first.
  List<AgentsAutomation> get all {
    final list = _byId.values.toList();
    list.sort(_newestFirst);
    return list;
  }

  /// Every automation, one row per automation, newest first.
  ///
  /// The host never deletes a row, so restarting a watcher leaves the old row
  /// behind: the same name, the same script, one `done` and one `active`. Two
  /// rows for one thing is not two automations — it is one automation and its
  /// history. The live row wins; among rows of one state the newest wins.
  List<AgentsAutomation> get distinct {
    final best = <String, AgentsAutomation>{};
    for (final a in all) {
      final key = identityOf(a);
      final held = best[key];
      if (held == null || _better(a, held)) best[key] = a;
    }
    final list = best.values.toList();
    list.sort(_newestFirst);
    return list;
  }

  /// What makes two rows the same automation: the same thread, the same kind,
  /// the same name and the same spec. The host's id is NOT part of it — a new
  /// id is exactly what a restart produces.
  static String identityOf(AgentsAutomation a) =>
      '${a.sessionKey}|${a.kind}|${a.name}|${a.specLabel}';

  static bool _better(AgentsAutomation a, AgentsAutomation b) {
    if (a.isOver != b.isOver) return b.isOver;
    return _newestFirst(a, b) < 0;
  }

  /// The automations of one conversation, newest first.
  List<AgentsAutomation> forSession(String sessionKey) =>
      all.where((a) => a.sessionKey == sessionKey).toList();

  /// The name to put over a group of rows: what the rest of the app calls that
  /// coworker, never the raw session key.
  ///
  /// The host sends its roster as `agent_list`; a key it has not named is read
  /// the way the app itself built it (`local:<name>:<n>:<random>`,
  /// `host:<device>`), and only a key that is neither shows as it is.
  String coworkerName(String sessionKey) {
    final named = _names[sessionKey];
    if (named != null && named.isNotEmpty) return named;
    if (sessionKey == 'default') return 'Default coworker';
    if (sessionKey.startsWith('local:')) {
      final parts = sessionKey.split(':');
      if (parts.length >= 2 && parts[1].trim().isNotEmpty)
        return parts[1].trim();
    }
    if (sessionKey.startsWith('host:')) {
      final device = sessionKey.substring('host:'.length).trim();
      if (device.isNotEmpty) return device;
    }
    return sessionKey;
  }

  /// The active and paused ones of one conversation: what a thread's strip
  /// shows. A done or failed automation is history (its card is in the
  /// transcript).
  List<AgentsAutomation> liveForSession(String sessionKey) =>
      forSession(sessionKey).where((a) => !a.isOver).toList();

  AgentsAutomation? byId(String id) => _byId[id];

  /// True once the host answered a list request for [sessionKey] (or for the
  /// whole host). Before that an empty list means "not asked yet".
  bool listed(String? sessionKey) =>
      _listedAll || (sessionKey != null && _listed.contains(sessionKey));

  /// Ask the host for the current list. Returns false when nothing is
  /// connected or the transport cannot send it.
  Future<bool> refresh({String? sessionKey}) async {
    final Object? controller = AgentsRelayLink.instance.controller.value;
    if (controller is! AgentsAutomationControl) return false;
    try {
      await controller.requestAutomationList(sessionKey: sessionKey);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Pause / resume / cancel one automation. The host answers with the
  /// `automation` event; nothing changes locally until it does.
  Future<bool> control(String id, String action) async {
    final Object? controller = AgentsRelayLink.instance.controller.value;
    if (controller is! AgentsAutomationControl) return false;
    try {
      await controller.sendAutomationControl(id: id, action: action);
      return true;
    } catch (_) {
      return false;
    }
  }

  void _onInbound(AgentsRelayInbound event) {
    switch (event) {
      case AgentsRelayAutomation():
        _byId[event.automation.id] = event.automation;
        notifyListeners();
      case AgentsRelayAgentList():
        // The same frame the roster reads. Held here so a group header can
        // name its coworker without the page having to reach the roster.
        for (final agent in event.agents) {
          _names[agent.agentId] = agent.name;
        }
        notifyListeners();
      case AgentsRelayAutomationList():
        // The reply is the truth for its scope: a row the host no longer
        // lists (it never deletes rows, but a future host may) is dropped.
        final scope = event.sessionKey;
        if (scope == null) {
          _byId.clear();
          _listedAll = true;
        } else {
          _byId.removeWhere((_, a) => a.sessionKey == scope);
          _listed.add(scope);
        }
        for (final automation in event.automations) {
          _byId[automation.id] = automation;
        }
        notifyListeners();
      default:
        break;
    }
  }

  static int _newestFirst(AgentsAutomation a, AgentsAutomation b) {
    final at = a.createdAt, bt = b.createdAt;
    if (at == null && bt == null) return a.id.compareTo(b.id);
    if (at == null) return 1;
    if (bt == null) return -1;
    return bt.compareTo(at);
  }

  /// Test seam: forget everything and stop listening.
  @visibleForTesting
  void reset() {
    _sub?.cancel();
    _sub = null;
    _byId.clear();
    _names.clear();
    _listed.clear();
    _listedAll = false;
  }
}
