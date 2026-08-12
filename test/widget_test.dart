import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cowork/pages/login_page.dart';
import 'package:cowork/pages/messenger_shell.dart';
import 'package:cowork/services/account_session.dart';
import 'package:cowork/services/auth_service.dart';
import 'package:cowork/services/cowork/cowork_pairing_store.dart';
import 'package:cowork/services/cowork/cowork_relay_client.dart';

/// Auth service that always fails, so the login test can exercise the error
/// path without a real Supabase backend.
class _FailingAuthService extends AuthService {
  const _FailingAuthService();

  @override
  Future<void> signInWithPassword({
    required String email,
    required String password,
  }) async {
    throw const AuthServiceException(message: 'Invalid login credentials');
  }
}

/// Session source returning fixed tokens, so tests never touch Supabase.
class _FakeSessionSource implements AccountSessionSource {
  const _FakeSessionSource();

  @override
  AccountSession? current() => const AccountSession(
    accessToken: 'access-1',
    refreshToken: 'refresh-1',
    userId: 'user-1',
  );

  @override
  Future<AccountSession?> refresh() async => const AccountSession(
    accessToken: 'access-2',
    refreshToken: 'refresh-2',
    userId: 'user-1',
  );
}

/// In-memory secure backend so the shell's store never touches a platform
/// channel in the test.
class _MemoryStore implements CoworkSecureKeyValueStore {
  final Map<String, String> map = <String, String>{};

  @override
  Future<String?> read(String key) async => map[key];

  @override
  Future<void> write(String key, String value) async => map[key] = value;

  @override
  Future<void> delete(String key) async => map.remove(key);
}

/// Minimal relay controller so the shell can be pumped without a socket.
class _IdleRelayController implements CoworkRelayController {
  final ValueNotifier<CoworkRelayState> _state =
      ValueNotifier<CoworkRelayState>(
    const CoworkRelayState(phase: CoworkRelayPhase.idle),
  );
  final StreamController<CoworkRelayInbound> _inbound =
      StreamController<CoworkRelayInbound>.broadcast();

  @override
  ValueListenable<CoworkRelayState> get state => _state;

  @override
  Stream<CoworkRelayInbound> get inbound => _inbound.stream;

  @override
  Future<void> connect({
    required Uri hostUrl,
    required String pairingCode,
  }) async {}

  @override
  Future<void> reconnect({
    required Uri hostUrl,
    required CoworkStoredPairing pairing,
  }) async {}

  @override
  CoworkStoredPairing? get establishedTrust => null;

  @override
  Future<void> provisionAccount(AccountSession session) async {}

  @override
  Future<void> sendTask(String prompt) async {}

  @override
  Future<void> dispose() async {
    if (!_inbound.isClosed) await _inbound.close();
    _state.dispose();
  }
}

void main() {
  group('LoginPage', () {
    testWidgets('renders email, password and sign-in button', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: LoginPage()));

      expect(find.text('Email'), findsOneWidget);
      expect(find.text('Password'), findsOneWidget);
      expect(find.text('Sign in'), findsOneWidget);
    });

    testWidgets('shows an inline error when auth fails', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: LoginPage(auth: _FailingAuthService())),
      );

      await tester.enterText(find.byType(TextFormField).at(0), 'a@b.com');
      await tester.enterText(find.byType(TextFormField).at(1), 'secret');
      await tester.tap(find.text('Sign in'));
      await tester.pumpAndSettle();

      expect(find.text('Invalid login credentials'), findsOneWidget);
    });
  });

  group('MessengerShell', () {
    testWidgets('is a chat: connect affordance, no account-models panel',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MessengerShell(
            relayControllerBuilder: () async => _IdleRelayController(),
            sessionSource: const _FakeSessionSource(),
            pairingStore: CoworkPairingStore(backend: _MemoryStore()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The chat surface, not a dashboard.
      expect(find.widgetWithText(FilledButton, 'Connect'), findsOneWidget);
      expect(find.text('Connect to a host to start chatting.'), findsOneWidget);
      expect(find.byIcon(Icons.logout), findsOneWidget);
      // The old account-models list is gone.
      expect(find.text('Account models'), findsNothing);
    });
  });
}
