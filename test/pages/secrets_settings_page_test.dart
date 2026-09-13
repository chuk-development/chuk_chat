import 'package:flutter/material.dart';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/pages/secrets_settings_page.dart';
import 'package:chuk_chat/services/agents/agents_pairing_store.dart'
    show AgentsSecureKeyValueStore;
import 'package:chuk_chat/services/secrets/secrets_service.dart';
import 'package:chuk_chat/services/secrets/secrets_store.dart';
import 'package:chuk_chat/services/secrets/secrets_sync.dart';

class _Memory implements AgentsSecureKeyValueStore {
  final Map<String, String> map = <String, String>{};

  @override
  Future<String?> read(String key) async => map[key];

  @override
  Future<void> write(String key, String value) async => map[key] = value;

  @override
  Future<void> delete(String key) async => map.remove(key);
}

/// Settings > API Keys: names are listed with a "set" badge, values are never
/// rendered, and add / change / delete go through the service (which mirrors
/// and forwards the whole set to the host).

/// Records with a Map inside compare by identity; flatten to compare by value.
List<(String, int, String?)> _flat(List<(Map<String, String>, int, String?)> xs) =>
    <(String, int, String?)>[
      for (final x in xs) (jsonEncode(SplayTreeMap<String, String>.of(x.$1)), x.$2, x.$3),
    ];

String _j(Map<String, String> m) => jsonEncode(SplayTreeMap<String, String>.of(m));

void main() {
  late List<(Map<String, String>, int, String?)> sent;

  SecretsService boot(_Memory backend) {
    sent = <(Map<String, String>, int, String?)>[];
    return SecretsService.resetForTest(
      store: SecretsStore(backend: backend),
      mirror: const NoopSecretsMirror(),
      hostSink: (set, {requestId}) async =>
          sent.add((Map<String, String>.of(set.values), set.revision, requestId)),
    );
  }

  Future<void> pump(WidgetTester tester, SecretsService service) async {
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(home: SecretsSettingsPage(service: service)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('lists the set names with a badge and never the value',
      (tester) async {
    final backend = _Memory();
    await SecretsStore(backend: backend).set('PEXELS_API_KEY', 'pexels-0123456789');
    final service = boot(backend);
    await pump(tester, service);

    expect(find.text('PEXELS_API_KEY'), findsOneWidget);
    expect(find.text('set'), findsOneWidget);
    expect(find.textContaining('pexels-0123456789'), findsNothing);
    expect(find.text('No keys yet'), findsNothing);
  });

  testWidgets('an empty set says so and offers Add key', (tester) async {
    final service = boot(_Memory());
    await pump(tester, service);
    expect(find.text('No keys yet'), findsOneWidget);
    expect(find.text('Add key'), findsOneWidget);
    // The < 8 characters rule is stated on the page.
    expect(find.textContaining('shorter than 8'), findsOneWidget);
  });

  testWidgets('adding a key stores it, lists it and forwards the whole set',
      (tester) async {
    final service = boot(_Memory());
    await pump(tester, service);

    await tester.tap(find.text('Add key'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Name'),
      'pixabay_api_key',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Value'),
      'pixabay-0123456789',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    // Upper-cased on save; value hidden.
    expect(find.text('PIXABAY_API_KEY'), findsOneWidget);
    expect(find.textContaining('pixabay-0123456789'), findsNothing);
    expect(_flat(sent), [
      (_j({'PIXABAY_API_KEY': 'pixabay-0123456789'}), 1, null),
    ]);
  });

  testWidgets('a bad name is refused in the dialog', (tester) async {
    final service = boot(_Memory());
    await pump(tester, service);

    await tester.tap(find.text('Add key'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'bad-name');
    await tester.enterText(find.widgetWithText(TextField, 'Value'), 'vvvvvvvvvv');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(find.text('Letters, digits and underscores only'), findsOneWidget);
    expect(sent, isEmpty);
  });

  testWidgets('deleting a key asks first, then removes it and forwards',
      (tester) async {
    final backend = _Memory();
    await SecretsStore(backend: backend).set('OLD_KEY', 'old-0123456789');
    final service = boot(backend);
    await pump(tester, service);

    await tester.tap(find.byTooltip('Options for OLD_KEY'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(find.text('Delete OLD_KEY?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
    await tester.pumpAndSettle();

    expect(find.text('OLD_KEY'), findsNothing);
    expect(find.text('No keys yet'), findsOneWidget);
    expect(_flat(sent).last, ('{}', 2, null));
  });

  testWidgets('changing a value keeps the name and forwards the new set',
      (tester) async {
    final backend = _Memory();
    await SecretsStore(backend: backend).set('K', 'first-0123456789');
    final service = boot(backend);
    await pump(tester, service);

    await tester.tap(find.byTooltip('Options for K'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Change value'));
    await tester.pumpAndSettle();
    expect(find.text('Change K'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Value'), 'second-0123456789');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(_flat(sent).single, (_j({'K': 'second-0123456789'}), 2, null));
    expect(find.text('K'), findsOneWidget);
  });
}
