import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show AuthChangeEvent, AuthState;

import 'package:chuk_chat/services/notifications/notification_router.dart';
import 'package:chuk_chat/services/notifications/push_service.dart';

/// Firebase, faked: the tests drive tokens and taps by hand.
class FakeTransport implements PushTransport {
  bool available = true;
  String? currentToken = 'tok-1';
  PushMessage? initial;
  int permissionRequests = 0;
  final StreamController<String> refresh = StreamController<String>.broadcast();
  final StreamController<PushMessage> opened =
      StreamController<PushMessage>.broadcast();

  @override
  Future<bool> initialize() async => available;

  @override
  Future<String?> token() async => currentToken;

  @override
  Stream<String> get onTokenRefresh => refresh.stream;

  @override
  Stream<PushMessage> get onMessageOpenedApp => opened.stream;

  @override
  Future<PushMessage?> initialMessage() async => initial;

  @override
  Future<void> requestPermission() async => permissionRequests++;
}

class FakeStore implements DeviceTokenStore {
  final List<Map<String, String>> upserts = <Map<String, String>>[];
  final List<(String, String)> deletes = <(String, String)>[];

  @override
  Future<void> upsert({
    required String userId,
    required String deviceId,
    required String token,
    required String platform,
  }) async {
    upserts.add(<String, String>{
      'user_id': userId,
      'device_id': deviceId,
      'token': token,
      'platform': platform,
    });
  }

  @override
  Future<void> delete({required String userId, required String deviceId}) async {
    deletes.add((userId, deviceId));
  }
}

void main() {
  late FakeTransport transport;
  late FakeStore store;
  late StreamController<AuthState> auth;
  String? userId;

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  setUp(() async {
    await PushService.instance.reset();
    NotificationRouter.instance.reset();
    transport = FakeTransport();
    store = FakeStore();
    auth = StreamController<AuthState>.broadcast();
    userId = null;
  });

  tearDown(() async {
    await PushService.instance.reset();
    NotificationRouter.instance.reset();
    await auth.close();
    await transport.refresh.close();
    await transport.opened.close();
  });

  Future<void> start() => PushService.instance.start(
        transport: transport,
        store: store,
        deviceId: () async => 'device-A',
        authStates: auth.stream,
        currentUserId: () => userId,
        platform: 'android',
      );

  test('signed in at start: token row upserted with the Agents device id',
      () async {
    userId = 'user-1';
    await start();
    await settle();
    expect(transport.permissionRequests, 1);
    expect(store.upserts, <Map<String, String>>[
      <String, String>{
        'user_id': 'user-1',
        'device_id': 'device-A',
        'token': 'tok-1',
        'platform': 'android',
      },
    ]);
  });

  test('sign-in later registers; token refresh re-upserts; sign-out deletes',
      () async {
    await start();
    await settle();
    expect(store.upserts, isEmpty, reason: 'nobody signed in yet');

    userId = 'user-2';
    auth.add(const AuthState(AuthChangeEvent.signedIn, null));
    await settle();
    await settle();
    expect(store.upserts.single['user_id'], 'user-2');

    transport.refresh.add('tok-2');
    await settle();
    await settle();
    expect(store.upserts.last['token'], 'tok-2');
    expect(store.upserts, hasLength(2));

    auth.add(const AuthState(AuthChangeEvent.signedOut, null));
    await settle();
    await settle();
    expect(store.deletes, <(String, String)>[('user-2', 'device-A')]);
    expect(PushService.instance.registeredUserId, isNull);

    // A refresh while signed out writes nothing.
    transport.refresh.add('tok-3');
    await settle();
    expect(store.upserts, hasLength(2));
  });

  test('the same user signing in twice does not upsert twice', () async {
    userId = 'user-3';
    await start();
    await settle();
    auth.add(const AuthState(AuthChangeEvent.signedIn, null));
    auth.add(const AuthState(AuthChangeEvent.tokenRefreshed, null));
    await settle();
    await settle();
    expect(store.upserts, hasLength(1));
  });

  test('a tapped push and a cold-start push reach the router', () async {
    transport.initial = const PushMessage(<String, dynamic>{
      'session_key': 'thread-cold',
      'run_id': 'run-1',
    });
    await start();
    await settle();
    expect(
      NotificationRouter.instance.pending.value,
      const NotificationTarget(sessionKey: 'thread-cold', runId: 'run-1'),
    );
    NotificationRouter.instance.take();

    transport.opened.add(const PushMessage(<String, dynamic>{
      'session_key': 'thread-warm',
    }));
    await settle();
    expect(NotificationRouter.instance.pending.value?.sessionKey, 'thread-warm');

    // A push without a thread is ignored.
    NotificationRouter.instance.take();
    transport.opened.add(const PushMessage(<String, dynamic>{'x': 'y'}));
    await settle();
    expect(NotificationRouter.instance.pending.value, isNull);
  });

  test('no Firebase (keys missing, Linux): the service stays off, no throw',
      () async {
    transport.available = false;
    userId = 'user-4';
    await start();
    await settle();
    expect(PushService.instance.isStarted, isFalse);
    expect(store.upserts, isEmpty);
    expect(transport.permissionRequests, 0);
  });

  test('a token store failure is swallowed', () async {
    userId = 'user-5';
    final throwing = _ThrowingStore();
    await PushService.instance.start(
      transport: transport,
      store: throwing,
      deviceId: () async => 'device-A',
      authStates: auth.stream,
      currentUserId: () => userId,
      platform: 'ios',
    );
    await settle();
    expect(PushService.instance.isStarted, isTrue);
  });
}

class _ThrowingStore implements DeviceTokenStore {
  @override
  Future<void> upsert({
    required String userId,
    required String deviceId,
    required String token,
    required String platform,
  }) async =>
      throw StateError('offline');

  @override
  Future<void> delete({required String userId, required String deviceId}) async =>
      throw StateError('offline');
}
