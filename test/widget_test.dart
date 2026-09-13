import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/icon_finder.dart';

import 'package:chuk_chat/pages/account_settings_page.dart';
import 'package:chuk_chat/pages/desktop_settings_modal.dart';
import 'package:chuk_chat/pages/login_page.dart';
import 'package:chuk_chat/pages/messenger_shell.dart';
import 'package:chuk_chat/services/account_session.dart';
import 'package:chuk_chat/services/auth_service.dart';
import 'package:chuk_chat/services/agents/agents_pairing_store.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'support/shell_config.dart';
import 'support/test_app.dart';

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
class _MemoryStore implements AgentsSecureKeyValueStore {
  final Map<String, String> map = <String, String>{};

  @override
  Future<String?> read(String key) async => map[key];

  @override
  Future<void> write(String key, String value) async => map[key] = value;

  @override
  Future<void> delete(String key) async => map.remove(key);
}

/// Minimal relay controller so the shell can be pumped without a socket.
class _IdleRelayController implements AgentsRelayController {
  final ValueNotifier<AgentsRelayState> _state =
      ValueNotifier<AgentsRelayState>(
    const AgentsRelayState(phase: AgentsRelayPhase.idle),
  );
  final StreamController<AgentsRelayInbound> _inbound =
      StreamController<AgentsRelayInbound>.broadcast();

  @override
  ValueListenable<AgentsRelayState> get state => _state;

  @override
  Stream<AgentsRelayInbound> get inbound => _inbound.stream;

  @override
  Future<void> connect({
    required Uri hostUrl,
    required String pairingCode,
  }) async {}

  @override
  Future<void> reconnect({
    required Uri hostUrl,
    required AgentsStoredPairing pairing,
  }) async {}

  @override
  AgentsStoredPairing? get establishedTrust => null;

  @override
  Future<void> provisionAccount(AccountSession session) async {}

  @override
  Future<void> sendTask(
    String prompt, {
    String sessionKey = 'default',
    String? modelId,
    String? providerSlug,
    String? reasoningEffort,
    bool debug = false,
    bool regenerate = false,
    String? taskId,
  }) async {}

  @override
  Future<void> createRoom(
    String roomId,
    String name,
    List<Map<String, String>> members, {
    bool agentToAgent = true,
  }) async {}

  @override
  Future<void> setRoomAgentToAgent(String roomId, bool enabled) async {}

  @override
  Future<void> sendRoomTask(String roomId, String message) async {}

  @override
  Future<void> requestRoomHistory(String roomId) async {}

  @override
  Future<void> deleteRoom(String roomId) async {}

  @override
  Future<void> renameRoom(String roomId, String name) async {}

  @override
  Future<void> createAgent(String agentId, String name) async {}

  @override
  Future<void> renameAgent(String agentId, String name) async {}

  @override
  Future<void> requestAgentList() async {}

  @override
  Future<void> addRoomMember(String roomId, String agentId, String handle) async {}

  @override
  Future<void> removeRoomMember(String roomId, String agentId) async {}

  @override
  Future<void> requestStop({String sessionKey = 'default'}) async {}

  @override
  Future<void> requestReplay({
    String sessionKey = 'default',
    int afterId = 0,
    int beforeId = 0,
    int limit = 0,
  }) async {}

  @override
  Future<void> sendRunAck(String runId) async {}

  @override
  Future<void> startBrowserView({String? sessionKey}) async {}

  @override
  Future<void> stopBrowserView() async {}

  @override
  Future<void> sendBrowserData(Uint8List bytes) async {}

  @override
  Future<void> sendApprovalDecision({
    required String approvalId,
    required bool approved,
  }) async {}

  @override
  Future<void> sendSecrets({
    required Map<String, String> values,
    required int revision,
    String? requestId,
  }) async {}

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

    testWidgets('can reveal and conceal the entered password', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: LoginPage()));

      final passwordField = find.byKey(const ValueKey('login-password-field'));
      bool isObscured() => tester
          .widget<EditableText>(
            find.descendant(
              of: passwordField,
              matching: find.byType(EditableText),
            ),
          )
          .obscureText;

      expect(isObscured(), isTrue);
      expect(find.byTooltip('Show password'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('login-password-visibility-toggle')),
      );
      await tester.pump();

      expect(isObscured(), isFalse);
      expect(find.byTooltip('Hide password'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey('login-password-visibility-toggle')),
      );
      await tester.pump();

      expect(isObscured(), isTrue);
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
      SharedPreferences.setMockInitialValues(<String, Object>{});
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: kTestLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: MessengerShell(
            relayControllerBuilder: () async => _IdleRelayController(),
            sessionSource: const _FakeSessionSource(),
            pairingStore: AgentsPairingStore(backend: _MemoryStore()),
            shellConfig: testShellConfig(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The chat surface, not a dashboard.
      expect(find.widgetWithText(FilledButton, 'Connect'), findsOneWidget);
      expect(find.text('Connect to a host to start chatting.'), findsOneWidget);
      // The old account-models list is gone.
      expect(find.text('Account models'), findsNothing);
      // No app bar: chuk has none. Settings is the gear in the sidebar's
      // footer pill and opens chuk's desktop settings modal, whose footer
      // carries the sign-out — chuk's homes for both.
      expect(find.byType(AppBar), findsNothing);
      // The current shell starts with its sidebar collapsed.
      await tester.tap(findIcon(Icons.menu_rounded));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Settings'));
      await tester.pumpAndSettle();
      expect(find.byType(DesktopSettingsModal), findsOneWidget);
      // Once: the modal's own footer row. The Account page it opens on is
      // chuk's (bead cowork-4ih): profile, password, recovery, delete account —
      // and no second sign-out, exactly like chuk.
      expect(findIcon(Icons.logout), findsOneWidget);
      expect(find.byType(AccountSettingsPage), findsOneWidget);

      // Dispose inside the body and drain what the imported pages started
      // (see test/pages/settings_page_test.dart, closeSettings).
      await tester.pump(const Duration(seconds: 2));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 1));
      await tester.pumpAndSettle();
    });
  });
}
