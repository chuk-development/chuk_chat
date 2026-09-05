import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cowork/pages/settings/mcp_connectors_page.dart';
import 'package:cowork/services/cowork/cowork_pairing_store.dart'
    show CoworkSecureKeyValueStore;
import 'package:cowork/services/mcp/mcp_icon_cache.dart';
import 'package:cowork/services/mcp/mcp_service.dart';
import 'package:cowork/services/mcp/mcp_store.dart';

/// In-memory secure backend so secrets round-trip with no platform channel.
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
    // No real favicon downloads: a fast 404 keeps the icon cache from leaving
    // a pending timeout timer under the widget test's fake async.
    McpIconCache.httpClient =
        MockClient((_) async => http.Response('', 404));
  });

  tearDown(() {
    McpIconCache.httpClient = null;
  });

  testWidgets('adding a connector by URL stores it and shows it in the list',
      (tester) async {
    final store = McpStore(secrets: _MemorySecrets());
    McpService.resetForTest(store: store);

    await tester.pumpWidget(
      const MaterialApp(home: McpConnectorsPage()),
    );
    await tester.pumpAndSettle();

    // The Add-by-URL row is always offered, but it sits in a long scrolling
    // list, so bring it into view first.
    final addByUrl = find.text('Add by URL');
    await tester.scrollUntilVisible(addByUrl, 300.0, scrollable: find.byType(Scrollable).first);
    expect(addByUrl, findsOneWidget);

    await tester.tap(addByUrl);
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'Server URL'),
      'https://api.github.com/mcp',
    );
    await tester.tap(find.widgetWithText(ElevatedButton, 'Connect'));
    await tester.pumpAndSettle();

    // The config reached the store and the row shows under Connected, named
    // for its host. The list is still scrolled down to the Add-by-URL row, so
    // scroll back up to the Connected section before asserting the row.
    expect((await store.load()).single.url, 'https://api.github.com/mcp');
    final connectedRow = find.text('api.github.com');
    await tester.scrollUntilVisible(
      connectedRow,
      -300.0,
      scrollable: find.byType(Scrollable).first,
    );
    expect(connectedRow, findsWidgets);
  });

  testWidgets('a bad URL is rejected and nothing is stored', (tester) async {
    final store = McpStore(secrets: _MemorySecrets());
    McpService.resetForTest(store: store);

    await tester.pumpWidget(
      const MaterialApp(home: McpConnectorsPage()),
    );
    await tester.pumpAndSettle();

    final addByUrl = find.text('Add by URL');
    await tester.scrollUntilVisible(addByUrl, 300.0, scrollable: find.byType(Scrollable).first);
    await tester.tap(addByUrl);
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'Server URL'),
      'not a url',
    );
    await tester.tap(find.widgetWithText(ElevatedButton, 'Connect'));
    await tester.pumpAndSettle();

    expect(await store.load(), isEmpty);
  });
}
