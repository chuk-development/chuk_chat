// lib/services/agents/agents_host_links.dart
//
// Keeps one relay socket up for every paired computer that is NOT the one on
// screen (CHAT-177, docs/agents/MULTI_HOST.md "Connections").
//
// The thread view owns the PRIMARY link: the computer of the conversation the
// user reads. Every other computer of the account gets a secondary link in
// [AgentsRelayLinks], and this supervisor fills it:
//
//  * it follows the pairing store and the primary computer: a computer that is
//    paired and not primary gets a controller, a computer that was removed or
//    became primary loses it;
//  * a controller is built like the thread view's, reconnected from the
//    stored trust with no code, provisioned with the account token and asked
//    for its agent list, so the roster shows the agents of every computer;
//  * a dead link (closed, error, a failed reconnect) is built again with a
//    capped backoff per computer;
//  * the thread view switches computers without a new handshake: it takes the
//    paired controller of the computer it switches to ([takeController]) and
//    hands its old one back ([adopt]).
//
// Each controller has its own socket, approved devices and controller session.
// The relay names the sending computer on every frame, and a socket drops the
// frames of every other computer (AgentsCloudRelaySocket.acceptsFrameFrom).
import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/services/account_session.dart';
import 'package:chuk_chat/services/agents/agents_pairing_store.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';

class AgentsHostLinks {
  AgentsHostLinks({
    required AgentsPairingStore store,
    required Future<AgentsRelayController> Function() build,
    required AccountSessionSource sessionSource,
    AgentsRelayLinks? links,
    Duration interval = const Duration(seconds: 15),
    List<Duration> backoff = const <Duration>[
      Duration(seconds: 2),
      Duration(seconds: 5),
      Duration(seconds: 15),
      Duration(seconds: 30),
      Duration(seconds: 60),
    ],
    DateTime Function()? now,
  }) : _store = store,
       _build = build,
       _session = sessionSource,
       _links = links ?? AgentsRelayLinks.instance,
       _interval = interval,
       _backoff = backoff,
       _now = now ?? DateTime.now;

  /// The supervisor the shell started, or null (no Agents shell mounted).
  static AgentsHostLinks? get current => _current;
  static AgentsHostLinks? _current;

  final AgentsPairingStore _store;
  final Future<AgentsRelayController> Function() _build;
  final AccountSessionSource _session;
  final AgentsRelayLinks _links;
  final Duration _interval;
  final List<Duration> _backoff;
  final DateTime Function() _now;

  final Map<String, AgentsRelayController> _own =
      <String, AgentsRelayController>{};
  final Map<String, int> _failures = <String, int>{};
  final Map<String, DateTime> _notBefore = <String, DateTime>{};
  final Set<String> _dialling = <String>{};

  Timer? _timer;
  bool _started = false;
  bool _disposed = false;
  bool _busy = false;
  bool _again = false;

  /// The computers this supervisor holds a controller for. Test-visible.
  Iterable<String> get hostIds => _own.keys;

  /// The controller of [hostId], or null.
  AgentsRelayController? controllerFor(String hostId) => _own[hostId];

  void start() {
    if (_started || _disposed) return;
    _started = true;
    _current = this;
    _store.changes.addListener(_poke);
    _links.primary.hostId.addListener(_poke);
    _timer = Timer.periodic(_interval, (_) => _poke());
    _poke();
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    if (identical(_current, this)) _current = null;
    _timer?.cancel();
    _timer = null;
    if (_started) {
      _store.changes.removeListener(_poke);
      _links.primary.hostId.removeListener(_poke);
    }
    for (final String id in List<String>.of(_own.keys)) {
      _release(id, forget: true);
    }
  }

  void _poke() => unawaited(sync());

  /// Hands the paired controller of [hostId] to the caller (the thread view
  /// switching to that computer) and stops managing it. Null when there is
  /// none, or it is not paired: the caller then dials itself.
  AgentsRelayController? takeController(String hostId) {
    final AgentsRelayController? controller = _own[hostId];
    if (controller == null || !controller.state.value.isPaired) return null;
    _own.remove(hostId);
    final AgentsRelayLink? link = _links.secondaryFor(hostId);
    if (link != null && identical(link.controller.value, controller)) {
      link.unbind();
    }
    return controller;
  }

  /// Takes over [controller] for [hostId] (the thread view switched away
  /// from that computer and its socket is still good). A controller for a
  /// computer that is primary again, or that already has one, is disposed.
  void adopt(String hostId, AgentsRelayController controller) {
    if (_disposed ||
        hostId == _links.primaryHostId ||
        _own.containsKey(hostId)) {
      unawaited(controller.dispose());
      return;
    }
    _own[hostId] = controller;
    _links.linkFor(hostId).bind(controller);
  }

  /// Stops managing [hostId] and disposes its controller. [forget] also drops
  /// its backoff (the computer is no longer wanted at all).
  void _release(String hostId, {bool forget = false}) {
    final AgentsRelayController? controller = _own.remove(hostId);
    if (forget) {
      _failures.remove(hostId);
      _notBefore.remove(hostId);
    }
    final AgentsRelayLink? link = _links.secondaryFor(hostId);
    if (controller != null &&
        link != null &&
        identical(link.controller.value, controller)) {
      link.unbind();
    }
    if (controller != null) unawaited(controller.dispose());
  }

  /// One pass: the wanted set of computers against the held one.
  @visibleForTesting
  Future<void> sync() async {
    if (_disposed) return;
    if (_busy) {
      _again = true;
      return;
    }
    _busy = true;
    try {
      do {
        _again = false;
        await _syncOnce();
      } while (_again && !_disposed);
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[agents-host-links] sync failed: ${error.runtimeType}');
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> _syncOnce() async {
    final List<AgentsStoredPairing> pairings = await _store.listPairings();
    if (_disposed) return;
    final String? primary = _links.primaryHostId;
    // Until the thread view has picked its computer, nothing is dialled: the
    // computer it picks must not get a second socket.
    final Set<String> wanted = primary == null
        ? <String>{}
        : <String>{
            for (final AgentsStoredPairing p in pairings)
              if (p.hostId != primary) p.hostId,
          };
    for (final String id in List<String>.of(_own.keys)) {
      if (!wanted.contains(id)) {
        _release(id, forget: true);
        _links.drop(id);
      }
    }
    for (final String id in List<String>.of(_links.secondaryHostIds)) {
      if (!wanted.contains(id)) _links.drop(id);
    }
    if (_session.current() == null) return;
    for (final AgentsStoredPairing pairing in pairings) {
      final String id = pairing.hostId;
      if (!wanted.contains(id) || _dialling.contains(id)) continue;
      final AgentsRelayController? held = _own[id];
      if (held != null) {
        final AgentsRelayPhase phase = held.state.value.phase;
        if (phase != AgentsRelayPhase.closed &&
            phase != AgentsRelayPhase.error) {
          continue;
        }
        _release(id);
        _bumpFailure(id);
      }
      final DateTime? wait = _notBefore[id];
      if (wait != null && _now().isBefore(wait)) continue;
      unawaited(_dial(pairing));
    }
  }

  void _bumpFailure(String hostId) {
    final int failures = (_failures[hostId] ?? 0) + 1;
    _failures[hostId] = failures;
    final Duration delay =
        _backoff[(failures - 1).clamp(0, _backoff.length - 1)];
    _notBefore[hostId] = _now().add(delay);
  }

  Future<void> _dial(AgentsStoredPairing pairing) async {
    final String id = pairing.hostId;
    _dialling.add(id);
    AgentsRelayController? controller;
    try {
      controller = await _build();
      if (_disposed || id == _links.primaryHostId || _own.containsKey(id)) {
        unawaited(controller.dispose());
        return;
      }
      _own[id] = controller;
      _links.linkFor(id).bind(controller);
      await controller.reconnect(hostUrl: pairing.hostUrl, pairing: pairing);
      final AccountSession? session = _session.current();
      if (session != null) await controller.provisionAccount(session);
      _failures.remove(id);
      _notBefore.remove(id);
      // The roster lists the agents of every computer.
      unawaited(controller.requestAgentList().catchError((Object _) {}));
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[agents-host-links] dial failed: ${error.runtimeType}');
      }
      if (controller != null && identical(_own[id], controller)) {
        _release(id);
      }
      _bumpFailure(id);
    } finally {
      _dialling.remove(id);
    }
  }
}
