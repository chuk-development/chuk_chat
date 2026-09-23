import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chuk_chat/services/storage/agents_chat_storage_bootstrap.dart';
import 'package:chuk_chat/services/storage/chat_origin.dart';

void main() {
  // These tests model the Agents build: Agents threads take the Agents
  // store and queue (ChatOrigin). Tests run with FEATURE_AGENTS off.
  ChatOrigin.agentsEnabled = true;
  late StreamController<AuthState> auth;
  late List<String> log;
  String? user;

  setUp(() async {
    await AgentsChatStorageBootstrap.reset();
    auth = StreamController<AuthState>.broadcast();
    log = <String>[];
    user = null;
    AgentsChatStorageBootstrap.authStream = auth.stream;
    AgentsChatStorageBootstrap.currentUserId = () => user;
    AgentsChatStorageBootstrap.onSignedInHook = () async => log.add('in');
    AgentsChatStorageBootstrap.onSignedOutHook = () async => log.add('out');
    AgentsChatStorageBootstrap.flushHook = () async {};
  });

  tearDown(() async {
    await AgentsChatStorageBootstrap.reset();
    await auth.close();
  });

  Future<void> pump() => Future<void>.delayed(Duration.zero);

  test('a session that already exists at start boots the storage', () async {
    user = 'u1';
    AgentsChatStorageBootstrap.start();
    await pump();
    expect(log, ['in']);
    expect(AgentsChatStorageBootstrap.activeUserId, 'u1');
  });

  test('sign-in boots once; a repeat for the same user is a no-op', () async {
    AgentsChatStorageBootstrap.start();
    user = 'u1';
    auth.add(const AuthState(AuthChangeEvent.signedIn, null));
    await pump();
    auth.add(const AuthState(AuthChangeEvent.initialSession, null));
    auth.add(const AuthState(AuthChangeEvent.tokenRefreshed, null));
    await pump();
    expect(log, ['in']);
  });

  test('sign-out stops the storage, and a new user boots it again', () async {
    AgentsChatStorageBootstrap.start();
    user = 'u1';
    auth.add(const AuthState(AuthChangeEvent.signedIn, null));
    await pump();
    user = null;
    auth.add(const AuthState(AuthChangeEvent.signedOut, null));
    await pump();
    expect(log, ['in', 'out']);
    expect(AgentsChatStorageBootstrap.activeUserId, isNull);

    user = 'u2';
    auth.add(const AuthState(AuthChangeEvent.signedIn, null));
    await pump();
    expect(log, ['in', 'out', 'in']);
    expect(AgentsChatStorageBootstrap.activeUserId, 'u2');
  });

  test('a different user signing in tears the first one down first', () async {
    AgentsChatStorageBootstrap.start();
    user = 'u1';
    auth.add(const AuthState(AuthChangeEvent.signedIn, null));
    await pump();
    user = 'u2';
    auth.add(const AuthState(AuthChangeEvent.signedIn, null));
    await pump();
    expect(log, ['in', 'out', 'in']);
  });

  test('start is idempotent and stop unsubscribes', () async {
    AgentsChatStorageBootstrap.start();
    AgentsChatStorageBootstrap.start();
    await AgentsChatStorageBootstrap.stop();
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
    AgentsChatStorageBootstrap.authStream = auth.stream;
    AgentsChatStorageBootstrap.currentUserId = () => user;
    AgentsChatStorageBootstrap.onSignedInHook = () async {};
    AgentsChatStorageBootstrap.onSignedOutHook = () async {};
    AgentsChatStorageBootstrap.flushHook = () async => flushes++;
    // A real timer with a short period: FakeAsync is not exported here, and
    // 40 ms is plenty for the assertion below.
    AgentsChatStorageBootstrap.flushInterval = const Duration(milliseconds: 40);

    AgentsChatStorageBootstrap.start();
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

    await AgentsChatStorageBootstrap.reset();
    await auth.close();
  });
}
