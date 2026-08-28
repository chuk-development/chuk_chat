import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cowork/pages/settings/mcp_connectors_page.dart';
import 'package:cowork/services/cowork/cowork_pairing_store.dart'
    show CoworkSecureKeyValueStore;
import 'package:cowork/services/mcp/mcp_store.dart';

class _MemorySecrets implements CoworkSecureKeyValueStore {
  final Map<String, String> map = <String, String>{};

  @override
  Future<String?> read(String key) async => map[key];

  @override
  Future<void> write(String key, String value) async => map[key] = value;

  @override
  Future<void> delete(String key) async => map.remove(key);
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  testWidgets('adding a connector by URL stores it and shows it in the list',
      (tester) async {
    final secrets = _MemorySecrets();
    final store = McpStore(secrets: secrets);

    await tester.pumpWidget(
      MaterialApp(home: McpConnectorsPage(store: store)),
    );
    await tester.pumpAndSettle();

    // Empty state: only the Add tile.
    expect(find.text('Add a connector'), findsOneWidget);

    await tester.tap(find.text('Add a connector'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'GitHub');
    await tester.enterText(
      find.widgetWithText(TextField, 'Server URL'),
      'https://api.github.com/mcp',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();

    // The row is on the list and the config reached the store.
    expect(find.text('GitHub'), findsOneWidget);
    expect((await store.load()).single.url, 'https://api.github.com/mcp');
  });

  testWidgets('a bad URL is rejected with an error', (tester) async {
    final store = McpStore(secrets: _MemorySecrets());
    await tester.pumpWidget(
      MaterialApp(home: McpConnectorsPage(store: store)),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Add a connector'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'Server URL'),
      'not a url',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();

    expect(find.textContaining('full URL'), findsOneWidget);
    expect(await store.load(), isEmpty);
  });
}
