import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:cowork/services/storage/cowork_chat_storage_bootstrap.dart';

void main() {
  late StreamController<AuthState> auth;
  late List<String> log;
  String? user;

  setUp(() async {
    await CoworkChatStorageBootstrap.reset();
    auth = StreamController<AuthState>.broadcast();
    log = <String>[];
    user = null;
    CoworkChatStorageBootstrap.authStream = auth.stream;
    CoworkChatStorageBootstrap.currentUserId = () => user;
    CoworkChatStorageBootstrap.onSignedInHook = () async => log.add('in');
    CoworkChatStorageBootstrap.onSignedOutHook = () async => log.add('out');
    CoworkChatStorageBootstrap.flushHook = () async {};
  });

  tearDown(() async {
    await CoworkChatStorageBootstrap.reset();
    await auth.close();
  });

  Future<void> pump() => Future<void>.delayed(Duration.zero);

  test('a session that already exists at start boots the storage', () async {
    user = 'u1';
    CoworkChatStorageBootstrap.start();
    await pump();
    expect(log, ['in']);
    expect(CoworkChatStorageBootstrap.activeUserId, 'u1');
  });

  test('sign-in boots once; a repeat for the same user is a no-op', () async {
    CoworkChatStorageBootstrap.start();
    user = 'u1';
    auth.add(const AuthState(AuthChangeEvent.signedIn, null));
    await pump();
    auth.add(const AuthState(AuthChangeEvent.initialSession, null));
    auth.add(const AuthState(AuthChangeEvent.tokenRefreshed, null));
    await pump();
    expect(log, ['in']);
  });

  test('sign-out stops the storage, and a new user boots it again', () async {
    CoworkChatStorageBootstrap.start();
    user = 'u1';
    auth.add(const AuthState(AuthChangeEvent.signedIn, null));
    await pump();
    user = null;
    auth.add(const AuthState(AuthChangeEvent.signedOut, null));
    await pump();
    expect(log, ['in', 'out']);
    expect(CoworkChatStorageBootstrap.activeUserId, isNull);

    user = 'u2';
    auth.add(const AuthState(AuthChangeEvent.signedIn, null));
    await pump();
    expect(log, ['in', 'out', 'in']);
    expect(CoworkChatStorageBootstrap.activeUserId, 'u2');
  });

  test('a different user signing in tears the first one down first', () async {
    CoworkChatStorageBootstrap.start();
    user = 'u1';
    auth.add(const AuthState(AuthChangeEvent.signedIn, null));
    await pump();
    user = 'u2';
    auth.add(const AuthState(AuthChangeEvent.signedIn, null));
    await pump();
    expect(log, ['in', 'out', 'in']);
  });

  test('start is idempotent and stop unsubscribes', () async {
    CoworkChatStorageBootstrap.start();
    CoworkChatStorageBootstrap.start();
    await CoworkChatStorageBootstrap.stop();
    user = 'u1';
    auth.add(const AuthState(AuthChangeEvent.signedIn, null));
    await pump();
    expect(log, isEmpty);
  });

  group('outbox flush', _flushTests);
}

void _flushTests() {
  test('sign-in flushes the outbox at once and then every interval', () async {
    var flushes = 0;
    final auth = StreamController<AuthState>.broadcast();
    var user = 'u1';
    CoworkChatStorageBootstrap.authStream = auth.stream;
    CoworkChatStorageBootstrap.currentUserId = () => user;
    CoworkChatStorageBootstrap.onSignedInHook = () async {};
    CoworkChatStorageBootstrap.onSignedOutHook = () async {};
    CoworkChatStorageBootstrap.flushHook = () async => flushes++;
    // A real timer with a short period: FakeAsync is not exported here, and
    // 40 ms is plenty for the assertion below.
    CoworkChatStorageBootstrap.flushInterval = const Duration(milliseconds: 40);

    CoworkChatStorageBootstrap.start();
    await Future<void>.delayed(Duration.zero);
    expect(flushes, 1);

    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(flushes, greaterThanOrEqualTo(3));

    user = '';
    auth.add(const AuthState(AuthChangeEvent.signedOut, null));
    await Future<void>.delayed(Duration.zero);
    final atSignOut = flushes;
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(flushes, atSignOut);

    await CoworkChatStorageBootstrap.reset();
    await auth.close();
  });
}
