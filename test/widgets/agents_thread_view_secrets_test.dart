import 'dart:collection';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/account_session.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/agents/agent_file_saver.dart';
import 'package:chuk_chat/services/agents/agents_pairing_store.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/services/agents/agents_replay_loader.dart';
import 'package:chuk_chat/services/agents/agents_run_ledger.dart';
import 'package:chuk_chat/services/secrets/secrets_service.dart';
import 'package:chuk_chat/services/secrets/secrets_store.dart';
import 'package:chuk_chat/services/secrets/secrets_sync.dart';
import 'package:chuk_chat/services/settings/verbose_service.dart';
import 'package:chuk_chat/widgets/agents_thread_view.dart';

import '../support/fake_relay_controller.dart';

/// In-memory secure backend so the stores round-trip with no platform channel.
class _MemoryStore implements AgentsSecureKeyValueStore {
  final Map<String, String> map = <String, String>{};

  @override
  Future<String?> read(String key) async => map[key];

  @override
  Future<void> write(String key, String value) async => map[key] = value;

  @override
  Future<void> delete(String key) async => map.remove(key);
}

class _NoopSaver implements AgentFileSaver {
  @override
  Future<String> save(AgentsRelayFile file) async => '/dev/null/${file.name}';
}

class _FakeSessionSource implements AccountSessionSource {
  const _FakeSessionSource();

  @override
  AccountSession? current() => const AccountSession(
        accessToken: 'access-1',
        refreshToken: 'refresh-1',
        userId: 'user-1',
      );

  @override
  Future<AccountSession?> refresh() async => current();
}

Widget _app(Widget child) => MaterialApp(
      localizationsDelegates: const <LocalizationsDelegate<Object>>[
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    );

/// The `secret_request` card (docs/WIRE_CONTRACT.md, "Secrets"): one field
/// per name over the thread the run belongs to; Save answers with the whole
/// set and the request id through the bound controller; Skip answers with the
/// unchanged set. Values never appear in the tree.

/// Records with a Map inside compare by identity; flatten to compare by value.
List<(String, int, String?)> _flat(List<(Map<String, String>, int, String?)> xs) =>
    <(String, int, String?)>[
      for (final x in xs) (jsonEncode(SplayTreeMap<String, String>.of(x.$1)), x.$2, x.$3),
    ];

String _j(Map<String, String> m) => jsonEncode(SplayTreeMap<String, String>.of(m));

void main() {
  late _MemoryStore secretsBackend;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await VerboseService.instance.setEnabled(false);
    AgentsRelayLink.instance.reset();
    AgentsRunLedger.instance.reset();
    AgentsReplayLoader.instance.reset();
    await ChatStorageService.reset();
    secretsBackend = _MemoryStore();
    SecretsService.resetForTest(
      store: SecretsStore(backend: secretsBackend),
      mirror: const NoopSecretsMirror(),
    );
  });

  tearDown(() async {
    AgentsRelayLink.instance.reset();
    AgentsRunLedger.instance.reset();
    AgentsReplayLoader.instance.reset();
    await ChatStorageService.reset();
    SecretsService.resetForTest(
      store: SecretsStore(backend: _MemoryStore()),
      mirror: const NoopSecretsMirror(),
    );
  });

  Future<FakeRelayController> pumpPaired(
    WidgetTester tester, {
    String threadKey = 'thread-1',
  }) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final controller = FakeRelayController();
    await tester.pumpWidget(
      _app(
        AgentsThreadView(
          controllerBuilder: () async => controller,
          sessionSource: const _FakeSessionSource(),
          threadKey: threadKey,
          fileSaver: _NoopSaver(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    controller.set(
      const AgentsRelayState(
        phase: AgentsRelayPhase.paired,
        peerDeviceId: 'cowork-host',
      ),
    );
    await tester.pumpAndSettle();
    return controller;
  }

  testWidgets('a secret_request shows one field per name and Save answers '
      'with the whole set and the request id', (tester) async {
    final controller = await pumpPaired(tester);

    controller.emit(const AgentsRelaySecretRequest(
      requestId: 'sr-1',
      names: ['PEXELS_API_KEY', 'PIXABAY_API_KEY'],
      purpose: 'fetch stock photos',
      sessionKey: 'thread-1',
    ));
    await tester.pumpAndSettle();

    expect(find.text('The agent needs API keys'), findsOneWidget);
    expect(find.text('fetch stock photos'), findsOneWidget);
    final pexels = find.byKey(const ValueKey<String>('secret-field-PEXELS_API_KEY'));
    final pixabay = find.byKey(const ValueKey<String>('secret-field-PIXABAY_API_KEY'));
    expect(pexels, findsOneWidget);
    expect(pixabay, findsOneWidget);
    // Obscured input: the typed value is never drawn as text.
    expect(tester.widget<TextField>(pexels).obscureText, isTrue);

    await tester.enterText(pexels, 'pexels-0123456789');
    await tester.tap(find.widgetWithText(FilledButton, 'Save keys'));
    await tester.pumpAndSettle();

    expect(_flat(controller.secretsSent), [
      (_j({'PEXELS_API_KEY': 'pexels-0123456789'}), 1, 'sr-1'),
    ]);
    // The card is gone and the value is nowhere in the tree.
    expect(find.text('The agent needs API keys'), findsNothing);
    expect(find.textContaining('pexels-0123456789'), findsNothing);
    // And it landed in the store, so the settings page lists it.
    expect(SecretsService.instance.names.value, ['PEXELS_API_KEY']);
  });

  testWidgets('Skip answers the request with the unchanged set',
      (tester) async {
    final controller = await pumpPaired(tester);
    await SecretsService.instance.set('OLD', 'old-0123456789');
    controller.secretsSent.clear();

    controller.emit(const AgentsRelaySecretRequest(
      requestId: 'sr-2',
      names: ['NEW_ONE'],
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Skip'));
    await tester.pumpAndSettle();

    expect(_flat(controller.secretsSent), [
      (_j({'OLD': 'old-0123456789'}), 1, 'sr-2'),
    ]);
    expect(find.text('The agent needs API keys'), findsNothing);
  });

  testWidgets('a name already set is marked and may be left blank',
      (tester) async {
    final controller = await pumpPaired(tester);
    await SecretsService.instance.set('HAVE', 'have-0123456789');
    controller.secretsSent.clear();

    controller.emit(const AgentsRelaySecretRequest(
      requestId: 'sr-3',
      names: ['HAVE', 'WANT'],
    ));
    await tester.pumpAndSettle();
    expect(find.text('Already set. Leave blank to keep it.'), findsOneWidget);

    await tester.enterText(
      find.byKey(const ValueKey<String>('secret-field-WANT')),
      'want-0123456789',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save keys'));
    await tester.pumpAndSettle();

    expect(
      _flat(controller.secretsSent).single,
      (_j({'HAVE': 'have-0123456789', 'WANT': 'want-0123456789'}), 2, 'sr-3'),
    );
  });

  testWidgets('a request for another thread is left to that view',
      (tester) async {
    final controller = await pumpPaired(tester);
    controller.emit(const AgentsRelaySecretRequest(
      requestId: 'sr-4',
      names: ['X'],
      sessionKey: 'other-thread',
    ));
    await tester.pumpAndSettle();
    expect(find.text('The agent needs API keys'), findsNothing);
  });
}
