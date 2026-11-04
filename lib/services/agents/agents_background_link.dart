// lib/services/agents/agents_background_link.dart
//
// Opens the relay link app-wide when queued Agents prompts wait and no
// thread view holds a link (bead chuk_chat-16de, docs/OFFLINE_SEND.md).
//
// The thread view owns the link while it is mounted: it builds the relay
// controller, reconnects from the stored pairing and binds the controller to
// [AgentsRelayLink]. Before a view mounts (or after it went away) nothing
// connected, so a prompt queued while the computer was away waited until the
// user opened a thread. This service closes that gap:
//
//  * every few seconds, and when the outbox changes or the network returns,
//    it looks for work: a due outbox entry or a task with no `task_ack`;
//  * with work, a signed-in user, a stored pairing and no controller bound,
//    it builds a controller, binds it and reconnects with no code. The
//    app-wide [AgentsOutboxFlusher] then flushes every thread on `paired`;
//  * once nothing is left, it unbinds and closes its socket again;
//  * the moment a thread view binds its own controller, this one steps
//    back and closes its socket: two sockets for one device displace each
//    other on the relay.
import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/platform_config.dart';
import 'package:chuk_chat/services/account_session.dart';
import 'package:chuk_chat/services/agents/agents_pairing_store.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_factory.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/services/agents/agents_task_outbox.dart';
import 'package:chuk_chat/services/network_status_service.dart';

class AgentsBackgroundLink {
  AgentsBackgroundLink._(
    this._slot,
    this._bind,
    this._unbind,
    this._build,
    this._loadPairing,
    this._session,
    this._hasWork,
    this._online,
    this._interval,
  );

  static AgentsBackgroundLink? _instance;

  /// The controller this service opened, or null.
  static AgentsRelayController? get ownController => _instance?._own;

  /// Whether [controller] is the one this service opened (no thread view).
  static bool owns(AgentsRelayController? controller) =>
      controller != null && identical(controller, _instance?._own);

  /// Starts the service. Idempotent; a no-op without `FEATURE_AGENTS`.
  static void start() {
    if (!kFeatureAgents || _instance != null) return;
    final AgentsPairingStore store = AgentsPairingStore();
    const AccountSessionSource sessionSource = SupabaseAccountSession();
    final AgentsRelayLink link = AgentsRelayLink.instance;
    _instance = AgentsBackgroundLink._(
      link.controller,
      link.bind,
      link.unbind,
      () => buildDefaultAgentsRelayController(store, sessionSource),
      store.loadPairing,
      sessionSource.current,
      hasQueuedWork,
      () => NetworkStatusService.isOnline,
      const Duration(seconds: 15),
    ).._attach();
  }

  @visibleForTesting
  static AgentsBackgroundLink startForTest({
    required ValueNotifier<AgentsRelayController?> slot,
    required Future<AgentsRelayController> Function() build,
    required Future<AgentsStoredPairing?> Function() loadPairing,
    AccountSession? Function()? session,
    required Future<bool> Function() hasWork,
    bool Function()? online,
    Duration interval = const Duration(hours: 1),
  }) {
    stopForTest();
    return _instance = AgentsBackgroundLink._(
      slot,
      (AgentsRelayController c) => slot.value = c,
      () => slot.value = null,
      build,
      loadPairing,
      session ?? () => null,
      hasWork,
      online ?? () => true,
      interval,
    ).._attach();
  }

  @visibleForTesting
  static void stopForTest() {
    _instance?._detach();
    _instance = null;
  }

  /// Whether anything waits for the host: a due outbox entry, or a task the
  /// host never acknowledged.
  static Future<bool> hasQueuedWork() async {
    try {
      if (await AgentsTaskOutbox.anyDue()) return true;
      for (final String key in await AgentsPendingTasks.sessionKeys()) {
        if ((await AgentsPendingTasks.pendingFor(key)).isNotEmpty) return true;
      }
    } catch (_) {}
    return false;
  }

  final ValueNotifier<AgentsRelayController?> _slot;
  final void Function(AgentsRelayController) _bind;
  final VoidCallback _unbind;
  final Future<AgentsRelayController> Function() _build;
  final Future<AgentsStoredPairing?> Function() _loadPairing;
  final AccountSession? Function() _session;
  final Future<bool> Function() _hasWork;
  final bool Function() _online;
  final Duration _interval;

  AgentsRelayController? _own;
  bool _busy = false;
  Timer? _timer;

  void _attach() {
    _slot.addListener(_onSlot);
    AgentsTaskOutbox.changes.addListener(_poke);
    try {
      NetworkStatusService.isOnlineListenable.addListener(_poke);
    } catch (_) {}
    // The first look waits a little: at start the thread view usually
    // mounts and binds its own link, and this one should not race it.
    _timer = Timer.periodic(_interval, (_) => _poke());
  }

  void _detach() {
    _timer?.cancel();
    _timer = null;
    _slot.removeListener(_onSlot);
    AgentsTaskOutbox.changes.removeListener(_poke);
    try {
      NetworkStatusService.isOnlineListenable.removeListener(_poke);
    } catch (_) {}
    _release();
  }

  void _poke() => unawaited(check());

  /// A thread view bound its own controller: this one steps back.
  void _onSlot() {
    final AgentsRelayController? own = _own;
    final AgentsRelayController? bound = _slot.value;
    if (own == null || identical(bound, own)) return;
    _own = null;
    unawaited(own.dispose());
  }

  void _release() {
    final AgentsRelayController? own = _own;
    if (own == null) return;
    _own = null;
    if (identical(_slot.value, own)) _unbind();
    unawaited(own.dispose());
  }

  /// One look: open the link when work waits, close it when it is done.
  @visibleForTesting
  Future<void> check() async {
    if (_busy) return;
    _busy = true;
    try {
      final AgentsRelayController? own = _own;
      if (own != null) {
        // Ours is up: keep it while work is left, also while it reconnects.
        if (!await _hasWork()) _release();
        return;
      }
      if (_slot.value != null) return; // A thread view holds the link.
      if (!_online()) return;
      final AccountSession? session = _session();
      if (session == null) return;
      if (!await _hasWork()) return;
      final AgentsStoredPairing? pairing = await _loadPairing();
      if (pairing == null) return;
      final AgentsRelayController controller = await _build();
      if (_slot.value != null) {
        // A view came up while this one was built.
        unawaited(controller.dispose());
        return;
      }
      _own = controller;
      _bind(controller);
      try {
        await controller.reconnect(hostUrl: pairing.hostUrl, pairing: pairing);
        await controller.provisionAccount(session);
      } catch (error) {
        if (kDebugMode) {
          debugPrint('[agents-bg-link] reconnect failed: ${error.runtimeType}');
        }
        if (identical(_own, controller)) _release();
      }
    } catch (error) {
      if (kDebugMode) debugPrint('[agents-bg-link] check failed: $error');
    } finally {
      _busy = false;
    }
  }
}
