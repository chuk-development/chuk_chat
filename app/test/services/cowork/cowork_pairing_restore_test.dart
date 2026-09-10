import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:cowork/services/account_session.dart';
import 'package:cowork/services/cowork/cowork_device_keys.dart';
import 'package:cowork/services/cowork/cowork_pairing_restore.dart';
import 'package:cowork/services/cowork/cowork_pairing_store.dart';
import 'package:cowork/services/cowork/supabase_pairing_sync.dart';

class _MemoryStore implements CoworkSecureKeyValueStore {
  final Map<String, String> map = <String, String>{};

  @override
  Future<String?> read(String key) async => map[key];

  @override
  Future<void> write(String key, String value) async => map[key] = value;

  @override
  Future<void> delete(String key) async => map.remove(key);
}

/// The encrypted mirror, scripted. [record] is what a read returns once
/// [available] is true; before that a read answers null, which is exactly what
/// the real mirror does while the encryption key is still locked.
class _FakeMirror extends SupabasePairingSync {
  _FakeMirror(this.record);

  final CoworkStoredPairing record;
  bool available = false;
  int reads = 0;
  int publishes = 0;
  bool writable = false;

  @override
  Future<bool> publishEncryptedPairing(CoworkStoredPairing pairing) async {
    publishes++;
    return writable;
  }

  @override
  Future<CoworkStoredPairing?> loadEncryptedPairing() async {
    reads++;
    return available ? record : null;
  }

  @override
  Future<void> saveEncryptedPairing(CoworkStoredPairing pairing) async {}

  @override
  Future<void> clearEncryptedPairing() async {}
}

class _Session implements AccountSessionSource {
  AccountSession? session;

  @override
  AccountSession? current() => session;

  @override
  Future<AccountSession?> refresh() async => session;
}

void main() {
  late CoworkStoredPairing record;

  setUpAll(() async {
    final hostKey = await CoworkDeviceKeys.generate();
    record = CoworkStoredPairing(
      hostUrl: Uri.parse(
        'wss://api.chuk.chat/v2/relay/ws?cw_device=host-device-uuid',
      ),
      channelId: 'chan-1',
      channelKey: Uint8List.fromList(List<int>.generate(32, (i) => i)),
      peerDeviceId: 'host-device-uuid',
      peerPublicKey: await hostKey.extractPublicKey(),
    );
  });

  /// Sleeps for one event-loop turn instead of the real backoff, so a test
  /// measures passes rather than seconds. A zero-duration TIMER, not a bare
  /// future: a microtask-only loop starves the test's own clock and the whole
  /// test hangs.
  Future<void> noSleep(Duration _) => Future<void>.delayed(Duration.zero);

  /// Yields until [condition] holds. The supervisor makes progress on the event
  /// loop, so a fixed delay would be a race; this is the deterministic form.
  Future<void> until(bool Function() condition, {String? reason}) async {
    for (var turn = 0; turn < 5000; turn++) {
      if (condition()) return;
      await Future<void>.delayed(Duration.zero);
    }
    fail('condition never held${reason == null ? '' : ': $reason'}');
  }

  test('a device that is already paired never reads the mirror', () async {
    final backend = _MemoryStore();
    final mirror = _FakeMirror(record)..available = true;
    final store = CoworkPairingStore(backend: backend, cloudSync: mirror);
    await store.savePairing(record);

    var restored = 0;
    final supervisor = CoworkPairingRestore(
      store: store,
      sessionSource: _Session()..session = null,
      onRestored: () async => restored++,
      authChanges: const Stream<Never>.empty(),
      hasEncryptionKey: () => true,
      sleep: noSleep,
    )..start();
    addTearDown(supervisor.dispose);

    await until(() => supervisor.isSettled, reason: 'already-paired settles');

    expect(mirror.reads, 0);
    expect(restored, 0);
  });

  test(
    'retries failed upload of existing pairing and stops duplicate writes',
    () async {
      final mirror = _FakeMirror(record);
      final store = CoworkPairingStore(
        backend: _MemoryStore(),
        cloudSync: mirror,
      );
      await store.savePairing(record);
      final session = _Session()
        ..session = const AccountSession(
          accessToken: 'jwt',
          refreshToken: 'refresh',
          userId: 'user-1',
        );
      final supervisor = CoworkPairingRestore(
        store: store,
        sessionSource: session,
        onRestored: () async {},
        authChanges: const Stream<Never>.empty(),
        sleep: noSleep,
      )..start();
      addTearDown(supervisor.dispose);
      await until(() => mirror.publishes >= 3);
      mirror.writable = true;
      final previous = mirror.publishes;
      await until(() => mirror.publishes > previous);
      final successful = mirror.publishes;
      final attempts = supervisor.attempts;
      await until(() => supervisor.attempts > attempts + 3);
      expect(mirror.publishes, successful);
    },
  );

  test(
    'keeps trying while the session and the key are still missing, then restores',
    () async {
      final mirror = _FakeMirror(record);
      final session = _Session();
      final store = CoworkPairingStore(
        backend: _MemoryStore(),
        cloudSync: mirror,
      );

      var hasKey = false;
      var keyLoads = 0;
      var restored = 0;

      final supervisor = CoworkPairingRestore(
        store: store,
        sessionSource: session,
        onRestored: () async => restored++,
        authChanges: const Stream<Never>.empty(),
        hasEncryptionKey: () => hasKey,
        loadEncryptionKey: () async {
          keyLoads++;
          return hasKey;
        },
        sleep: noSleep,
      )..start();
      addTearDown(supervisor.dispose);

      // No session yet: the old one-shot restore gave up here, for good.
      await until(
        () => supervisor.attempts > 3,
        reason: 'retries with no session',
      );
      expect(supervisor.isSettled, isFalse);
      expect(mirror.reads, 0, reason: 'nothing to read without an account');

      // Signed in, but the key is not unlocked: still a "not yet".
      session.session = const AccountSession(
        accessToken: 'jwt',
        refreshToken: 'refresh',
        userId: 'user-1',
      );
      await until(() => keyLoads > 0, reason: 'tries to unlock the key');
      expect(supervisor.isSettled, isFalse);
      expect(mirror.reads, 0);

      // Key unlocked, mirror answers: the device links itself.
      hasKey = true;
      mirror.available = true;
      await until(() => supervisor.isSettled, reason: 'restores once it can');

      expect(restored, 1);
      final saved = await store.loadPairing();
      expect(saved, isNotNull);
      expect(saved!.peerDeviceId, 'host-device-uuid');
      // The loopback the other machine wrote is not what this device dials.
      expect(
        saved.hostUrl,
        Uri.parse('wss://api.chuk.chat/v2/relay/ws?cw_device=host-device-uuid'),
      );
    },
  );

  test(
    'an auth event wakes the supervisor instead of waiting out a sleep',
    () async {
      final mirror = _FakeMirror(record)..available = true;
      final session = _Session();
      final store = CoworkPairingStore(
        backend: _MemoryStore(),
        cloudSync: mirror,
      );

      var sleeping = false;
      final supervisor = CoworkPairingRestore(
        store: store,
        sessionSource: session,
        onRestored: () async {},
        authChanges: const Stream<Never>.empty(),
        hasEncryptionKey: () => true,
        // A sleep that never ends on its own: only a nudge can move this on.
        sleep: (_) {
          sleeping = true;
          return Completer<void>().future;
        },
      )..start();
      addTearDown(supervisor.dispose);

      await until(() => sleeping, reason: 'parks on the backoff');
      expect(supervisor.isSettled, isFalse);

      session.session = const AccountSession(
        accessToken: 'jwt',
        refreshToken: 'refresh',
        userId: 'user-1',
      );
      supervisor.nudge(); // what an auth event does

      await until(() => supervisor.isSettled, reason: 'the nudge resumes it');
      expect(await store.loadPairing(), isNotNull);
    },
  );
}
