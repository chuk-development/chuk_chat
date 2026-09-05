import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:cowork/services/automations/cowork_automation.dart';
import 'package:cowork/services/cowork/cowork_relay_client.dart';
import 'package:cowork/services/cowork/cowork_relay_link.dart';

/// The app's copy of the host's automations, kept current from the relay.
///
/// One instance for the app (like the replay loader): it listens to
/// [CoworkRelayLink.inbound], folds every `automation` event (live or
/// replayed) and every `automation_list` reply into one map by id, and
/// notifies. The thread view reads [forSession] for its strip; the
/// Automations page reads [all]. Both send through [control] and [refresh],
/// which need the bound controller to be a [CoworkAutomationControl] (the
/// real relay client is; a test double may not be).
class AutomationsSource extends ChangeNotifier {
  AutomationsSource._();

  static final AutomationsSource instance = AutomationsSource._();

  final Map<String, CoworkAutomation> _byId = <String, CoworkAutomation>{};
  StreamSubscription<CoworkRelayInbound>? _sub;

  /// Sessions whose list the host has answered at least once.
  final Set<String> _listed = <String>{};
  bool _listedAll = false;

  /// Starts listening. Idempotent.
  void attach() {
    _sub ??= CoworkRelayLink.instance.inbound.listen(_onInbound);
  }

  /// Every automation known to this app, newest first.
  List<CoworkAutomation> get all {
    final list = _byId.values.toList();
    list.sort(_newestFirst);
    return list;
  }

  /// The automations of one conversation, newest first.
  List<CoworkAutomation> forSession(String sessionKey) =>
      all.where((a) => a.sessionKey == sessionKey).toList();

  /// The active and paused ones of one conversation: what a thread's strip
  /// shows. A done or failed automation is history (its card is in the
  /// transcript).
  List<CoworkAutomation> liveForSession(String sessionKey) =>
      forSession(sessionKey).where((a) => !a.isOver).toList();

  CoworkAutomation? byId(String id) => _byId[id];

  /// True once the host answered a list request for [sessionKey] (or for the
  /// whole host). Before that an empty list means "not asked yet".
  bool listed(String? sessionKey) =>
      _listedAll || (sessionKey != null && _listed.contains(sessionKey));

  /// Ask the host for the current list. Returns false when nothing is
  /// connected or the transport cannot send it.
  Future<bool> refresh({String? sessionKey}) async {
    final Object? controller = CoworkRelayLink.instance.controller.value;
    if (controller is! CoworkAutomationControl) return false;
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
    final Object? controller = CoworkRelayLink.instance.controller.value;
    if (controller is! CoworkAutomationControl) return false;
    try {
      await controller.sendAutomationControl(id: id, action: action);
      return true;
    } catch (_) {
      return false;
    }
  }

  void _onInbound(CoworkRelayInbound event) {
    switch (event) {
      case CoworkRelayAutomation():
        _byId[event.automation.id] = event.automation;
        notifyListeners();
      case CoworkRelayAutomationList():
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

  static int _newestFirst(CoworkAutomation a, CoworkAutomation b) {
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
    _listed.clear();
    _listedAll = false;
  }
}
