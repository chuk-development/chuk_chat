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
/// Once paired, unchanged successfully published trust only needs a local read.
/// Missing cloud trust is retried; foreground/auth events wake it immediately.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart'
    show AuthChangeEvent, AuthState;

import 'package:chuk_chat/services/account_session.dart';
import 'package:chuk_chat/services/agents/agents_cloud_relay.dart';
import 'package:chuk_chat/services/agents/agents_pairing_store.dart';
import 'package:chuk_chat/services/agents/supabase_pairing_sync.dart';
import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';

/// Why the last restore pass ended the way it did. The shell reads it to say
/// the right thing: "Looking for your computer…" while a restore can still
/// succeed, "Add your computer" once it is clear there is nothing to restore.
enum AgentsPairingRestoreReason {
  /// No pass has finished yet.
  checking,

  /// This device holds a pairing (it was here, or it was just restored).
  paired,

  /// No signed-in session yet, so the mirror cannot be read.
  noSession,

  /// The account key is not unlocked yet, so the mirror cannot be opened.
  keyLocked,

  /// The mirror could not be reached (offline, timeout, server error).
  network,

  /// The local trust store could not be read (a locked keystore).
  localStoreFailed,

  /// The account has no computer on record.
  noCloudRecord,

  /// A record exists but this device cannot decrypt or parse it.
  decryptFailed,

  /// A record exists but names no computer this device can dial.
  noCloudRoute;

  /// True while a later pass can still restore a pairing without the user.
  /// False means the user has to add a computer.
  bool get mayStillRestore => switch (this) {
    checking || noSession || keyLocked || network || localStoreFailed => true,
    paired || noCloudRecord || decryptFailed || noCloudRoute => false,
  };
}

/// Restores the account's pairing onto this device, and keeps trying until it
/// can.
class AgentsPairingRestore {
  AgentsPairingRestore({
    required AgentsPairingStore store,
    required AccountSessionSource sessionSource,
    required Future<void> Function() onRestored,
    Stream<AuthState>? authChanges,
    bool Function()? hasEncryptionKey,
    Future<bool> Function()? loadEncryptionKey,
    Future<void> Function(Duration delay)? sleep,
    List<Duration> backoff = kDefaultBackoff,
    Duration heartbeat = const Duration(seconds: 1),
  }) : _store = store,
       _sessionSource = sessionSource,
       _onRestored = onRestored,
       _authChanges = authChanges,
       _hasEncryptionKey = hasEncryptionKey ?? _defaultHasKey,
       _loadEncryptionKey = loadEncryptionKey ?? _defaultLoadKey,
       _sleep = sleep,
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

  final AgentsPairingStore _store;
  final AccountSessionSource _sessionSource;
  final Future<void> Function() _onRestored;
  final Stream<AuthState>? _authChanges;
  final bool Function() _hasEncryptionKey;
  final Future<bool> Function() _loadEncryptionKey;
  final Future<void> Function(Duration delay)? _sleep;
  final List<Duration> _backoff;
  final Duration _heartbeat;

  /// Why the last pass ended as it did. Starts at
  /// [AgentsPairingRestoreReason.checking]; the shell listens.
  ValueListenable<AgentsPairingRestoreReason> get reason => _reason;
  final ValueNotifier<AgentsPairingRestoreReason> _reason =
      ValueNotifier<AgentsPairingRestoreReason>(
        AgentsPairingRestoreReason.checking,
      );

  StreamSubscription<AuthState>? _authSub;
  Completer<void>? _wake;
  bool _running = false;
  bool _disposed = false;
  bool _done = false;
  String? _published;
  Timer? _timer;

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
    _timer?.cancel();
    nudge();
    await _authSub?.cancel();
    _authSub = null;
    _reason.dispose();
  }

  /// Records why this pass ended, and logs it in a debug build. The reason is
  /// an enum name: no id, no address, no key material.
  bool _end(AgentsPairingRestoreReason reason, {required bool settled}) {
    if (_disposed) return settled;
    if (kDebugMode && _reason.value != reason) {
      debugPrint('[agents-restore] ${reason.name} (attempt $_attempts)');
    }
    _reason.value = reason;
    return settled;
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
      _done = settled;
      if (_disposed) return;
      await _waitBeforeRetry();
    }
  }

  /// One pass. Returns true when there is nothing left to do — either the
  /// device is paired now, or it already was.
  Future<bool> _attempt() async {
    try {
      // A local pairing is not proof it was uploaded. Retry once the account
      // key becomes available, and again after a route/pairing change.
      final existing = await _store.loadPairing();
      if (existing != null) {
        final account = _sessionSource.current();
        final address = AgentsCloudRelayAddress.tryParse(existing.hostUrl);
        if (account != null &&
            (address?.targetDeviceId == null ||
                address?.targetDeviceId == 'cowork-host')) {
          final cloud = await _store.loadPairingFromCloud();
          if (cloud != null && _hasCloudRoute(cloud)) {
            await _store.savePairing(cloud);
            if (!_disposed) await _onRestored();
          }
          return _end(AgentsPairingRestoreReason.paired, settled: true);
        }
        if (account != null &&
            AgentsCloudRelayAddress.tryParse(
                  existing.hostUrl,
                )?.targetDeviceId !=
                null) {
          final fingerprint =
              '${account.userId}:${jsonEncode(existing.toJson())}';
          if (_published != fingerprint &&
              await _store.publishPairing(existing)) {
            _published = fingerprint;
          }
        }
        return _end(AgentsPairingRestoreReason.paired, settled: true);
      }
    } catch (_) {
      // A locked keystore is a "not yet", not a "never".
      return _end(AgentsPairingRestoreReason.localStoreFailed, settled: false);
    }

    // The mirror is keyed to the account and encrypted with the account's key.
    // Both must be there; both arrive on their own schedule during a cold
    // start, which is exactly why this retries.
    if (_sessionSource.current() == null) {
      return _end(AgentsPairingRestoreReason.noSession, settled: false);
    }
    if (!_hasEncryptionKey()) {
      bool loaded;
      try {
        loaded = await _loadEncryptionKey();
      } catch (_) {
        loaded = false;
      }
      if (!loaded) {
        return _end(AgentsPairingRestoreReason.keyLocked, settled: false);
      }
    }

    AgentsCloudPairingRead read;
    try {
      read = await _store.readPairingFromCloud();
    } catch (_) {
      return _end(AgentsPairingRestoreReason.network, settled: false);
    }
    final AgentsStoredPairing? restored = read.pairing;
    if (_disposed) return false;
    if (restored == null) {
      return _end(switch (read.outcome) {
        AgentsCloudPairingOutcome.noSession =>
          AgentsPairingRestoreReason.noSession,
        AgentsCloudPairingOutcome.keyLocked =>
          AgentsPairingRestoreReason.keyLocked,
        AgentsCloudPairingOutcome.network => AgentsPairingRestoreReason.network,
        AgentsCloudPairingOutcome.decryptFailed =>
          AgentsPairingRestoreReason.decryptFailed,
        AgentsCloudPairingOutcome.noRecord ||
        AgentsCloudPairingOutcome.found =>
          AgentsPairingRestoreReason.noCloudRecord,
      }, settled: false);
    }
    if (!_hasCloudRoute(restored)) {
      return _end(AgentsPairingRestoreReason.noCloudRoute, settled: false);
    }

    // The mirror was written by another device. Its address may be that
    // device's own loopback, which is meaningless here — the relay plus the
    // host's device id is what this machine can actually dial.
    final normalised = AgentsStoredPairing(
      hostUrl: AgentsCloudRelayAddress.forRestoredTrust(
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
        debugPrint('[agents-restore] could not persist the restored pairing');
      }
    }
    if (_disposed) return true;
    await _onRestored();
    return _end(AgentsPairingRestoreReason.paired, settled: true);
  }

  Future<void> _waitBeforeRetry() async {
    final index = (_attempts - 1).clamp(0, _backoff.length - 1);
    final delay = _done || _attempts > _backoff.length
        ? _heartbeat
        : _backoff[index];
    final wake = Completer<void>();
    _wake = wake;
    final sleep = _sleep;
    if (sleep != null) {
      await Future.any(<Future<void>>[sleep(delay), wake.future]);
    } else {
      _timer = Timer(delay, () {
        if (!wake.isCompleted) wake.complete();
      });
      await wake.future;
      _timer?.cancel();
      _timer = null;
    }
    _wake = null;
  }

  static bool _defaultHasKey() => EncryptionService.hasKey;

  static bool _hasCloudRoute(AgentsStoredPairing trust) {
    final target = AgentsCloudRelayAddress.tryParse(
      trust.hostUrl,
    )?.targetDeviceId;
    return target != null && target.isNotEmpty && target != 'cowork-host';
  }

  static Future<bool> _defaultLoadKey() => EncryptionService.tryLoadKey();

  static Stream<AuthState>? _defaultAuthChanges() =>
      SupabaseService.isInitialized
      ? SupabaseService.auth.onAuthStateChange
      : null;
}
