/// "Open the phone and you are already linked."
///
/// The trust record is mirrored, encrypted, to Supabase (see
/// `supabase_pairing_sync.dart`). A fresh install therefore only has to sign in
/// and the pairing comes back — no code, no QR, no host address. That is the
/// promise; the failure mode was the restore that only ever tried ONCE, in a
/// post-frame callback, and gave up silently on anything that was merely *not
/// ready yet*:
///
///  * the Supabase session had not been restored from disk,
///  * the [EncryptionService] key had not been unlocked, so the ciphertext could
///    not be opened,
///  * the network was down for the two seconds the app happened to look.
///
/// Each of those leaves a signed-in user staring at a pairing screen for a host
/// they already own. So this runs as a small supervisor instead: it retries with
/// a capped backoff, it wakes on the auth event that makes a retry meaningful,
/// and it keeps a slow heartbeat afterwards so a pairing made on another device
/// lands here on its own.
///
/// It is deliberately cheap when there is nothing to do: one secure-storage read
/// and, at most, one small select every five minutes. It stops for good the
/// moment a local pairing exists, because from then on the ordinary code-free
/// reconnect owns the connection.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthChangeEvent, AuthState;

import 'package:cowork/services/account_session.dart';
import 'package:cowork/services/cowork/cowork_cloud_relay.dart';
import 'package:cowork/services/cowork/cowork_pairing_store.dart';
import 'package:cowork/services/encryption_service.dart';
import 'package:cowork/services/supabase_service.dart';

/// Restores the account's pairing onto this device, and keeps trying until it
/// can.
class CoworkPairingRestore {
  CoworkPairingRestore({
    required CoworkPairingStore store,
    required AccountSessionSource sessionSource,
    required Future<void> Function() onRestored,
    Stream<AuthState>? authChanges,
    bool Function()? hasEncryptionKey,
    Future<bool> Function()? loadEncryptionKey,
    Future<void> Function(Duration delay)? sleep,
    List<Duration> backoff = kDefaultBackoff,
    Duration heartbeat = const Duration(minutes: 5),
  }) : _store = store,
       _sessionSource = sessionSource,
       _onRestored = onRestored,
       _authChanges = authChanges,
       _hasEncryptionKey = hasEncryptionKey ?? _defaultHasKey,
       _loadEncryptionKey = loadEncryptionKey ?? _defaultLoadKey,
       _sleep = sleep ?? _defaultSleep,
       _backoff = backoff,
       _heartbeat = heartbeat;

  /// Fast at first — the two blockers that resolve in the first seconds of a
  /// cold start are the session load and the key unlock — then patient.
  static const List<Duration> kDefaultBackoff = <Duration>[
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 15),
    Duration(seconds: 30),
    Duration(seconds: 60),
  ];

  final CoworkPairingStore _store;
  final AccountSessionSource _sessionSource;
  final Future<void> Function() _onRestored;
  final Stream<AuthState>? _authChanges;
  final bool Function() _hasEncryptionKey;
  final Future<bool> Function() _loadEncryptionKey;
  final Future<void> Function(Duration delay) _sleep;
  final List<Duration> _backoff;
  final Duration _heartbeat;

  StreamSubscription<AuthState>? _authSub;
  Completer<void>? _wake;
  bool _running = false;
  bool _disposed = false;
  bool _done = false;

  /// How many passes the loop has made. Test-visible so a test can assert the
  /// supervisor really did retry rather than give up.
  int get attempts => _attempts;
  int _attempts = 0;

  /// True once a pairing exists locally and the supervisor has stood down.
  bool get isSettled => _done;

  /// Starts the supervisor. Safe to call twice; the second call is a no-op.
  void start() {
    if (_running || _disposed) return;
    _running = true;
    _listenForAuth();
    unawaited(_loop());
  }

  /// Nudges the supervisor to try again now instead of waiting out its sleep.
  /// Called when something that could unblock a restore just happened.
  void nudge() {
    final wake = _wake;
    if (wake != null && !wake.isCompleted) wake.complete();
  }

  Future<void> dispose() async {
    _disposed = true;
    nudge();
    await _authSub?.cancel();
    _authSub = null;
  }

  void _listenForAuth() {
    final stream = _authChanges ?? _defaultAuthChanges();
    if (stream == null) return;
    _authSub = stream.listen((AuthState state) {
      // A session appearing is the single most common unblocker: the key can
      // be loaded and the mirror can be read only after it.
      if (state.event == AuthChangeEvent.signedIn ||
          state.event == AuthChangeEvent.initialSession ||
          state.event == AuthChangeEvent.tokenRefreshed) {
        nudge();
      }
    }, onError: (Object _) {});
  }

  Future<void> _loop() async {
    while (!_disposed) {
      _attempts++;
      final settled = await _attempt();
      if (settled || _disposed) {
        _done = settled;
        return;
      }
      await _waitBeforeRetry();
    }
  }

  /// One pass. Returns true when there is nothing left to do — either the
  /// device is paired now, or it already was.
  Future<bool> _attempt() async {
    try {
      // Already paired locally: the ordinary code-free reconnect owns it.
      final existing = await _store.loadPairing();
      if (existing != null) return true;
    } catch (_) {
      // A locked keystore is a "not yet", not a "never".
      return false;
    }

    // The mirror is keyed to the account and encrypted with the account's key.
    // Both must be there; both arrive on their own schedule during a cold
    // start, which is exactly why this retries.
    if (_sessionSource.current() == null) return false;
    if (!_hasEncryptionKey()) {
      try {
        if (!await _loadEncryptionKey()) return false;
      } catch (_) {
        return false;
      }
    }

    CoworkStoredPairing? restored;
    try {
      restored = await _store.loadPairingFromCloud();
    } catch (_) {
      return false;
    }
    if (restored == null || _disposed) return false;

    // The mirror was written by another device. Its address may be that
    // device's own loopback, which is meaningless here — the relay plus the
    // host's device id is what this machine can actually dial.
    final normalised = CoworkStoredPairing(
      hostUrl: CoworkCloudRelayAddress.forRestoredTrust(
        restored.hostUrl,
        restored.peerDeviceId,
      ),
      channelId: restored.channelId,
      channelKey: restored.channelKey,
      peerDeviceId: restored.peerDeviceId,
      peerPublicKey: restored.peerPublicKey,
    );

    try {
      await _store.savePairing(normalised);
    } catch (_) {
      // The record is in hand but could not be written. Reconnecting from it
      // this session is still better than nothing, so fall through.
      if (kDebugMode) {
        debugPrint('[cowork-restore] could not persist the restored pairing');
      }
    }
    if (_disposed) return true;
    await _onRestored();
    return true;
  }

  Future<void> _waitBeforeRetry() async {
    final index = (_attempts - 1).clamp(0, _backoff.length - 1);
    final delay = _attempts > _backoff.length ? _heartbeat : _backoff[index];
    final wake = Completer<void>();
    _wake = wake;
    await Future.any(<Future<void>>[_sleep(delay), wake.future]);
    _wake = null;
  }

  static bool _defaultHasKey() => EncryptionService.hasKey;

  static Future<bool> _defaultLoadKey() => EncryptionService.tryLoadKey();

  static Future<void> _defaultSleep(Duration delay) =>
      Future<void>.delayed(delay);

  static Stream<AuthState>? _defaultAuthChanges() =>
      SupabaseService.isInitialized
      ? SupabaseService.auth.onAuthStateChange
      : null;
}
