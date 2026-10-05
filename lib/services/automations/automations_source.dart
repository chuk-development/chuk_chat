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
    AgentsRelayClient.automationSavedSink = _onSaved;
    AgentsRelayClient.automationDoneSink = _onDone;
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
      if (parts.length >= 2 && parts[1].trim().isNotEmpty) {
        return parts[1].trim();
      }
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
        _noteResult(event);
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

  // ── F2: automations + cost totals ──

  /// How long a create or an update waits for the host's `automation_saved`.
  static Duration saveTimeout = const Duration(seconds: 20);

  /// Requests waiting for their `automation_saved`, oldest first. The host
  /// answers each on its own request stream, in order, and the frame carries
  /// no request id, so the first waiter takes the first answer.
  final List<Completer<AutomationSaveResult>> _pendingSaves =
      <Completer<AutomationSaveResult>>[];

  /// Runs of an `on_change` automation that found nothing new: run id →
  /// the summary it reported (empty when it gave none).
  final Map<String, String> _quietRuns = <String, String>{};

  /// The summary of a quiet run (an `on_change` run that reported no
  /// change), or null when [runId] was not one. The thread folds such a run
  /// to one "No change" line with this under it.
  String? quietRunSummary(String runId) => _quietRuns[runId];

  /// True when [runId] was an `on_change` run that found nothing new.
  bool isQuietRun(String runId) => _quietRuns.containsKey(runId);

  /// The coworkers the app knows by name (`agent_list`), session key → name.
  /// The global page offers them when it creates an automation.
  Map<String, String> get coworkerNames =>
      Map<String, String>.unmodifiable(_names);

  /// Sends `automation_create`. Completes with the host's answer, or a
  /// failure that says why it could not be asked.
  Future<AutomationSaveResult> create({
    required String sessionKey,
    required String kind,
    required Object spec,
    required String prompt,
    String? name,
    bool notifyOnChange = false,
  }) => _save(
    (control) => control.sendAutomationCreate(
      automationCreateFrame(
        sessionKey: sessionKey,
        kind: kind,
        spec: spec,
        prompt: prompt,
        name: name,
        notifyOnChange: notifyOnChange,
      ),
    ),
  );

  /// Sends `automation_update` with only the keys of [frame]
  /// (see [automationUpdateFrame]).
  Future<AutomationSaveResult> update(Map<String, dynamic> frame) =>
      _save((control) => control.sendAutomationUpdate(frame));

  Future<AutomationSaveResult> _save(
    Future<void> Function(AgentsAutomationEditControl control) send,
  ) async {
    final Object? controller = AgentsRelayLink.instance.controller.value;
    if (controller is! AgentsAutomationEditControl) {
      return const AutomationSaveResult.failed('Not connected to the host.');
    }
    attach();
    final waiter = Completer<AutomationSaveResult>();
    _pendingSaves.add(waiter);
    try {
      await send(controller);
    } catch (error) {
      _pendingSaves.remove(waiter);
      return AutomationSaveResult.failed('Could not reach the host: $error');
    }
    return waiter.future.timeout(
      saveTimeout,
      onTimeout: () {
        _pendingSaves.remove(waiter);
        return const AutomationSaveResult.failed(
          'The host did not answer. Check the connection and try again.',
        );
      },
    );
  }

  void _onSaved(Map<String, dynamic> payload) {
    final result = AutomationSaveResult.fromPayload(payload);
    final saved = result.automation;
    if (saved != null) {
      _byId[saved.id] = saved;
      notifyListeners();
    }
    if (_pendingSaves.isNotEmpty) {
      final waiter = _pendingSaves.removeAt(0);
      if (!waiter.isCompleted) waiter.complete(result);
    }
  }

  /// A live `done` of a fired `on_change` run says its verdict before the
  /// `result` event lands; both say the same, so either one folds the run.
  void _onDone(Map<String, dynamic> payload) {
    final runId = payload['run_id'];
    final verdict = payload['automation_result'];
    if (runId is! String || runId.isEmpty || verdict is! Map) return;
    if (verdict['changed'] != false) return;
    final summary = verdict['summary'];
    _quietRuns[runId] = summary is String ? summary : '';
    notifyListeners();
  }

  void _noteResult(AgentsRelayAutomation event) {
    final runId = event.runId;
    if (event.event != 'result' || runId == null) return;
    if (event.isQuietResult) {
      _quietRuns[runId] = event.summary ?? '';
    } else {
      _quietRuns.remove(runId);
    }
  }
  // ── end F2 ──

  /// Test seam: forget everything and stop listening.
  @visibleForTesting
  void reset() {
    _sub?.cancel();
    _sub = null;
    if (AgentsRelayClient.automationSavedSink == _onSaved) {
      AgentsRelayClient.automationSavedSink = null;
    }
    if (AgentsRelayClient.automationDoneSink == _onDone) {
      AgentsRelayClient.automationDoneSink = null;
    }
    for (final waiter in _pendingSaves) {
      if (!waiter.isCompleted) {
        waiter.complete(const AutomationSaveResult.failed('reset'));
      }
    }
    _pendingSaves.clear();
    _quietRuns.clear();
    _byId.clear();
    _names.clear();
    _listed.clear();
    _listedAll = false;
  }
}
