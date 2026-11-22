// lib/services/agents/agents_host_peering.dart
//
// The app introduces the user's computers to each other (CHAT-177 phase 2,
// docs/agents/MULTI_HOST.md "Trust between hosts", docs/WIRE_CONTRACT.md
// "Hosts that work together").
//
// The app has a sealed channel to every paired computer. For every two
// computers that both name `host_peers`, it makes one fresh 32-byte pair key
// K and sends `host_peer_introduce` to each, with the OTHER computer's relay
// device id, its approved Ed25519 key (from the trust record), its name, its
// kind and the same K. Both must answer `ok: true`; when the second one
// fails, the first gets `host_peer_forget`, so no computer keeps half a link.
//
// It runs again:
//  * when a computer is added (the pairing store changes),
//  * when a computer first says `host_peers` or its link comes up,
//  * as a repair: every few minutes each computer's `host_peer_list` is read,
//    and a paired computer missing in `peers` is introduced again.
//
// An introduce of a pair that is already linked is never sent: the peer
// lists say so. K lives only in this pass and is wiped after it; it is never
// logged and never stored.
//
// Unlink ([unlink]): `host_peer_forget` to every other computer, then the
// pairing is removed (store and Supabase row). A computer that is offline
// gets its forget when it comes back while this app runs.
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/services/agents/agents_pairing_store.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';

/// What one computer said about its peers in its last `host_peer_list`.
@immutable
class AgentsHostPeerStatus {
  const AgentsHostPeerStatus({
    required this.peerIds,
    required this.online,
    required this.at,
  });

  /// The relay device ids of the computers this one is linked to.
  final Set<String> peerIds;

  /// What the computer saw last per peer: true, false or null (unknown). A
  /// hint only; the app's own link state is the better source.
  final Map<String, bool?> online;

  /// When the list was read.
  final DateTime at;

  /// Reads the `peers` of a `host_peer_list` answer.
  static AgentsHostPeerStatus fromReply(
    Map<String, dynamic> reply,
    DateTime at,
  ) {
    final Set<String> ids = <String>{};
    final Map<String, bool?> online = <String, bool?>{};
    final Object? peers = reply['peers'];
    if (peers is List) {
      for (final Object? row in peers) {
        if (row is! Map) continue;
        final Object? id = row['peer_host_id'];
        if (id is! String || id.isEmpty) continue;
        ids.add(id);
        final Object? seen = row['online'];
        online[id] = seen is bool ? seen : null;
      }
    }
    return AgentsHostPeerStatus(
      peerIds: Set<String>.unmodifiable(ids),
      online: Map<String, bool?>.unmodifiable(online),
      at: at,
    );
  }
}

class AgentsHostPeering extends ChangeNotifier {
  AgentsHostPeering({
    required AgentsPairingStore store,
    AgentsRelayLinks? links,
    AgentsHostPeersControl? Function(String hostId)? controlFor,
    Random? random,
    Duration interval = const Duration(minutes: 2),
    Duration listMaxAge = const Duration(minutes: 2),
    Duration retryAfterFailure = const Duration(minutes: 1),
    Duration requestTimeout = const Duration(seconds: 20),
    DateTime Function()? now,
  }) : _store = store,
       _links = links ?? AgentsRelayLinks.instance,
       _controlFor = controlFor,
       _random = random ?? Random.secure(),
       _interval = interval,
       _listMaxAge = listMaxAge,
       _retryAfterFailure = retryAfterFailure,
       _requestTimeout = requestTimeout,
       _now = now ?? DateTime.now;

  /// The service the shell started, or null (no Agents shell mounted).
  static AgentsHostPeering? get current => _current;
  static AgentsHostPeering? _current;

  final AgentsPairingStore _store;
  final AgentsRelayLinks _links;
  final AgentsHostPeersControl? Function(String hostId)? _controlFor;
  final Random _random;
  final Duration _interval;
  final Duration _listMaxAge;
  final Duration _retryAfterFailure;
  final Duration _requestTimeout;
  final DateTime Function() _now;

  final Map<String, AgentsHostPeerStatus> _status =
      <String, AgentsHostPeerStatus>{};

  /// Computers whose peer list must be read again on the next pass (a new
  /// pairing, a link that just came up).
  final Set<String> _dirty = <String>{};

  /// The computers that were ready (online and capable) on the last pass.
  Set<String> _ready = <String>{};

  /// `host -> computers it must forget`: an unlink that could not reach it.
  final Map<String, Set<String>> _pendingForget = <String, Set<String>>{};

  /// A pair whose introduce failed waits until then.
  final Map<String, DateTime> _pairNotBefore = <String, DateTime>{};

  Timer? _timer;
  bool _started = false;
  bool _disposed = false;

  /// What [hostId] said about its peers last, or null when it never did.
  AgentsHostPeerStatus? statusFor(String hostId) => _status[hostId];

  /// How many other computers [hostId] is linked to, or null when unknown.
  int? linkedCount(String hostId) => _status[hostId]?.peerIds.length;

  void start() {
    if (_started || _disposed) return;
    _started = true;
    _current = this;
    _store.changes.addListener(_onPairingsChanged);
    _links.addListener(_poke);
    _links.primary.controller.addListener(_poke);
    AgentsRelayClient.capabilitiesByHost.addListener(_poke);
    _timer = Timer.periodic(_interval, (_) => _poke());
    _poke();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (identical(_current, this)) _current = null;
    _timer?.cancel();
    _timer = null;
    if (_started) {
      _store.changes.removeListener(_onPairingsChanged);
      _links.removeListener(_poke);
      _links.primary.controller.removeListener(_poke);
      AgentsRelayClient.capabilitiesByHost.removeListener(_poke);
    }
    super.dispose();
  }

  void _onPairingsChanged() {
    // A new or changed computer: every list is read again.
    _dirty.addAll(_status.keys);
    _poke();
  }

  void _poke() => unawaited(sync());

  /// The peer control of [hostId] when its link is up, else null.
  AgentsHostPeersControl? _control(String hostId) {
    final AgentsHostPeersControl? Function(String hostId)? seam = _controlFor;
    if (seam != null) return seam(hostId);
    final AgentsRelayController? controller = _links.pairedControllerFor(
      hostId,
    );
    return controller is AgentsHostPeersControl
        ? controller as AgentsHostPeersControl
        : null;
  }

  /// [hostId]'s peer control when it is up AND names `host_peers`.
  AgentsHostPeersControl? _peerReady(String hostId) {
    final AgentsHostPeersControl? control = _control(hostId);
    if (control == null) return null;
    if (!control.capabilities.value.contains(
      AgentsRelayClient.hostPeersCapability,
    )) {
      return null;
    }
    return control;
  }

  /// Passes and unlinks run one at a time, so an unlink never races a pass
  /// that read the old list.
  Future<void> _chain = Future<void>.value();
  Future<void>? _queued;

  Future<T> _exclusive<T>(Future<T> Function() body) {
    final Future<T> next = _chain.then((_) => body());
    _chain = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  /// One pass. Triggers while a pass waits to start share that pass.
  Future<void> sync() {
    if (_disposed) return Future<void>.value();
    final Future<void>? queued = _queued;
    if (queued != null) return queued;
    late final Future<void> pass;
    pass = _exclusive(() async {
      if (identical(_queued, pass)) _queued = null;
      if (_disposed) return;
      try {
        await _syncOnce();
      } catch (error) {
        if (kDebugMode) {
          debugPrint('[agents-host-peering] sync failed: ${error.runtimeType}');
        }
      }
    });
    _queued = pass;
    return pass;
  }

  Future<void> _syncOnce() async {
    final List<AgentsStoredPairing> pairings = <AgentsStoredPairing>[
      for (final AgentsStoredPairing p in await _store.listPairings())
        // Only a computer with a relay device id can be a peer.
        if (p.relayDeviceId != null) p,
    ];
    if (_disposed) return;
    final Set<String> paired = <String>{
      for (final AgentsStoredPairing p in pairings) p.hostId,
    };
    bool changed = false;
    // A removed computer has no status; a computer paired again must not be
    // forgotten by an old unlink.
    final int before = _status.length;
    _status.removeWhere((String id, _) => !paired.contains(id));
    changed |= _status.length != before;
    for (final Set<String> gone in _pendingForget.values) {
      gone.removeAll(paired);
    }
    _pendingForget.removeWhere(
      (String id, Set<String> gone) => gone.isEmpty || !paired.contains(id),
    );

    final Map<String, AgentsHostPeersControl> ready =
        <String, AgentsHostPeersControl>{};
    for (final AgentsStoredPairing p in pairings) {
      final AgentsHostPeersControl? control = _peerReady(p.hostId);
      if (control != null) ready[p.hostId] = control;
    }
    // A computer that just came up (or just said host_peers) is read again.
    for (final String id in ready.keys) {
      if (!_ready.contains(id)) _dirty.add(id);
    }
    _ready = ready.keys.toSet();

    // Unlinks that could not reach a computer before.
    for (final MapEntry<String, AgentsHostPeersControl> e in ready.entries) {
      final Set<String>? gone = _pendingForget[e.key];
      if (gone == null) continue;
      for (final String peer in List<String>.of(gone)) {
        final Map<String, dynamic>? reply = await _ask(
          e.value,
          <String, dynamic>{'type': 'host_peer_forget', 'peer_host_id': peer},
        );
        if (reply == null) continue;
        gone.remove(peer);
        if (_take(e.key, reply)) changed = true;
      }
      if (gone.isEmpty) _pendingForget.remove(e.key);
    }

    // Read the lists that are old or marked.
    final DateTime now = _now();
    for (final MapEntry<String, AgentsHostPeersControl> e in ready.entries) {
      final AgentsHostPeerStatus? known = _status[e.key];
      final bool stale =
          known == null ||
          _dirty.contains(e.key) ||
          now.difference(known.at) >= _listMaxAge;
      if (!stale) continue;
      final Map<String, dynamic>? reply = await _ask(e.value, <String, dynamic>{
        'type': 'host_peer_list',
      });
      if (reply == null) continue;
      _dirty.remove(e.key);
      if (_take(e.key, reply)) changed = true;
    }

    // Introduce every pair that is not linked both ways.
    final List<AgentsStoredPairing> linkable = <AgentsStoredPairing>[
      for (final AgentsStoredPairing p in pairings)
        if (ready.containsKey(p.hostId)) p,
    ];
    for (int i = 0; i < linkable.length; i++) {
      for (int j = i + 1; j < linkable.length; j++) {
        final AgentsStoredPairing a = linkable[i];
        final AgentsStoredPairing b = linkable[j];
        if (_linked(a.hostId, b.hostId)) continue;
        // Unknown lists (a read that failed): wait for the next pass.
        if (_status[a.hostId] == null || _status[b.hostId] == null) continue;
        final String pair = _pairKey(a.hostId, b.hostId);
        final DateTime? wait = _pairNotBefore[pair];
        if (wait != null && _now().isBefore(wait)) continue;
        final AgentsHostPeersControl? controlA = ready[a.hostId];
        final AgentsHostPeersControl? controlB = ready[b.hostId];
        if (_disposed || controlA == null || controlB == null) return;
        final bool ok = await _introduce(a, controlA, b, controlB);
        changed = true;
        if (ok) {
          _pairNotBefore.remove(pair);
        } else {
          _pairNotBefore[pair] = _now().add(_retryAfterFailure);
        }
      }
    }
    if (changed && !_disposed) notifyListeners();
  }

  bool _linked(String a, String b) =>
      (_status[a]?.peerIds.contains(b) ?? false) &&
      (_status[b]?.peerIds.contains(a) ?? false);

  static String _pairKey(String a, String b) =>
      a.compareTo(b) < 0 ? '$a|$b' : '$b|$a';

  /// Stores the peers of a `host_peer_list` answer. False when the answer
  /// carries no list (a refusal still lists the peers the host keeps).
  bool _take(String hostId, Map<String, dynamic> reply) {
    if (reply['peers'] is! List) return false;
    _status[hostId] = AgentsHostPeerStatus.fromReply(reply, _now());
    return true;
  }

  /// Sends [frame], returns the answer or null when the link failed. Never
  /// logs the frame: an introduce carries the pair key.
  Future<Map<String, dynamic>?> _ask(
    AgentsHostPeersControl control,
    Map<String, dynamic> frame,
  ) async {
    try {
      return await control.hostPeerRequest(frame, timeout: _requestTimeout);
    } catch (error) {
      if (kDebugMode) {
        debugPrint(
          '[agents-host-peering] ${frame['type']} failed: '
          '${error.runtimeType}',
        );
      }
      return null;
    }
  }

  /// Links [a] and [b] with one fresh key. True when both answered `ok`.
  Future<bool> _introduce(
    AgentsStoredPairing a,
    AgentsHostPeersControl controlA,
    AgentsStoredPairing b,
    AgentsHostPeersControl controlB,
  ) async {
    final Uint8List key = Uint8List(32);
    for (int i = 0; i < key.length; i++) {
      key[i] = _random.nextInt(256);
    }
    try {
      final String pairKey = base64.encode(key);
      final Map<String, dynamic>? replyA = await _ask(
        controlA,
        _introduceFrame(b, pairKey),
      );
      if (replyA != null) _take(a.hostId, replyA);
      if (replyA?['ok'] != true) return false;
      final Map<String, dynamic>? replyB = await _ask(
        controlB,
        _introduceFrame(a, pairKey),
      );
      if (replyB != null) _take(b.hostId, replyB);
      if (replyB?['ok'] == true) return true;
      // B did not take it: A must not keep half a link.
      final Map<String, dynamic>? undo = await _ask(controlA, <String, dynamic>{
        'type': 'host_peer_forget',
        'peer_host_id': b.hostId,
      });
      if (undo != null) {
        _take(a.hostId, undo);
      } else {
        (_pendingForget[a.hostId] ??= <String>{}).add(b.hostId);
      }
      return false;
    } finally {
      key.fillRange(0, key.length, 0);
    }
  }

  /// The introduce frame that tells one computer about [other].
  static Map<String, dynamic> _introduceFrame(
    AgentsStoredPairing other,
    String pairKey,
  ) => <String, dynamic>{
    'type': 'host_peer_introduce',
    'peer_host_id': other.hostId,
    'peer_public_key': base64.encode(other.peerPublicKey.bytes),
    'pair_key': pairKey,
    'name': other.label,
    'kind': other.effectiveKind.name,
  };

  /// Removes the computer [hostId]: `host_peer_forget` to every other
  /// computer (the ones that are offline get it when they come back while
  /// the app runs), then the pairing itself (store and Supabase row).
  Future<void> unlink(String hostId) => _exclusive(() => _unlink(hostId));

  Future<void> _unlink(String hostId) async {
    List<AgentsStoredPairing> pairings;
    try {
      pairings = await _store.listPairings();
    } catch (_) {
      pairings = const <AgentsStoredPairing>[];
    }
    for (final AgentsStoredPairing p in pairings) {
      if (p.hostId == hostId || p.relayDeviceId == null) continue;
      final AgentsHostPeersControl? control = _peerReady(p.hostId);
      Map<String, dynamic>? reply;
      if (control != null) {
        reply = await _ask(control, <String, dynamic>{
          'type': 'host_peer_forget',
          'peer_host_id': hostId,
        });
      }
      if (reply != null) {
        _take(p.hostId, reply);
      } else {
        (_pendingForget[p.hostId] ??= <String>{}).add(hostId);
      }
    }
    _status.remove(hostId);
    _dirty.remove(hostId);
    _pairNotBefore.removeWhere((String k, _) => k.split('|').contains(hostId));
    await _store.removePairing(hostId);
    if (!_disposed) notifyListeners();
  }

  /// Test-visible: the forgets still owed, `host -> computers`.
  @visibleForTesting
  Map<String, Set<String>> get pendingForgets => <String, Set<String>>{
    for (final MapEntry<String, Set<String>> e in _pendingForget.entries)
      e.key: Set<String>.of(e.value),
  };
}
