import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:cowork/pages/login_page.dart';
import 'package:cowork/pages/messenger_shell.dart';
import 'package:cowork/services/account_session.dart';
import 'package:cowork/services/auth_service.dart';
import 'package:cowork/services/models_service.dart';

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

const _kModelsJson = '''
[
  {"id": "openai/gpt-4o", "name": "GPT-4o"},
  {"id": "anthropic/claude", "name": "Claude"}
]
''';

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
    testWidgets('renders the account model list from a mocked fetch', (
      tester,
    ) async {
      final client = MockClient(
        (request) async => http.Response(_kModelsJson, 200),
      );
      final service = ModelsService(
        sessionSource: const _FakeSessionSource(),
        httpClient: client,
        apiBaseUrl: 'https://api.test',
      );

      await tester.pumpWidget(
        MaterialApp(home: MessengerShell(modelsService: service)),
      );
      await tester.pumpAndSettle();

      expect(find.text('Account models'), findsOneWidget);
      expect(find.text('GPT-4o'), findsOneWidget);
      expect(find.text('openai/gpt-4o'), findsOneWidget);
      expect(find.text('Claude'), findsOneWidget);
      expect(find.byIcon(Icons.logout), findsOneWidget);
    });
  });

  group('ModelsService', () {
    test('fetches and parses the model list', () async {
      final client = MockClient(
        (request) async {
          expect(request.url.toString(), 'https://api.test/v1/models_info');
          expect(request.headers['Authorization'], 'Bearer access-1');
          return http.Response(_kModelsJson, 200);
        },
      );
      final service = ModelsService(
        sessionSource: const _FakeSessionSource(),
        httpClient: client,
        apiBaseUrl: 'https://api.test',
      );

      final models = await service.fetchModels();

      expect(models, hasLength(2));
      expect(models.first.id, 'openai/gpt-4o');
      expect(models.first.name, 'GPT-4o');
    });

    test('refreshes the session and retries on a 401', () async {
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        if (calls == 1) {
          expect(request.headers['Authorization'], 'Bearer access-1');
          return http.Response('unauthorized', 401);
        }
        expect(request.headers['Authorization'], 'Bearer access-2');
        return http.Response(_kModelsJson, 200);
      });
      final service = ModelsService(
        sessionSource: const _FakeSessionSource(),
        httpClient: client,
        apiBaseUrl: 'https://api.test',
      );

      final models = await service.fetchModels();

      expect(calls, 2);
      expect(models, hasLength(2));
    });
  });
}
