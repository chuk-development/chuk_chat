import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/pages/mcp_connectors_page.dart';
import 'package:chuk_chat/services/agents/agents_chat_core.dart';
import 'package:chuk_chat/services/agents/agents_pairing_store.dart'
    show AgentsSecureKeyValueStore;
import 'package:chuk_chat/services/mcp/mcp_connection.dart';
import 'package:chuk_chat/services/mcp/mcp_icon_cache.dart';
import 'package:chuk_chat/services/mcp/mcp_service.dart';
import 'package:chuk_chat/services/mcp/mcp_store.dart';

import '../support/mcp_memory_list.dart';

/// In-memory secure backend so secrets round-trip with no platform channel.
class _MemorySecrets implements AgentsSecureKeyValueStore {
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
    final store = McpStore(secrets: _MemorySecrets(), list: memoryMcpList());
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
    final store = McpStore(secrets: _MemorySecrets(), list: memoryMcpList());
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

  testWidgets('with Agents on a connected row says what the host found, and '
      'the device dials nobody', (tester) async {
    debugAgentsChatCoreOverride = true;
    addTearDown(() => debugAgentsChatCoreOverride = null);
    final store = McpStore(secrets: _MemorySecrets(), list: memoryMcpList());
    McpService.resetForTest(store: store);
    await store.upsert(
      const McpConnection(
        id: 'example',
        name: 'Example',
        url: 'https://mcp.example.com/mcp',
      ),
    );
    var dials = 0;
    final previousProbeClientFactory = McpService.probeClientFactory;
    addTearDown(
      () => McpService.probeClientFactory = previousProbeClientFactory,
    );
    McpService.probeClientFactory = () => MockClient((_) async {
      dials++;
      return http.Response('', 200);
    });

    await tester.pumpWidget(const MaterialApp(home: McpConnectorsPage()));
    await tester.pumpAndSettle();

    // The host has not reported on it yet, so the row says so instead of
    // "0 tools" or "Offline".
    expect(find.text('Example'), findsOneWidget);
    expect(find.text('not checked'), findsOneWidget);
    expect(find.text('Offline'), findsNothing);
    expect(dials, 0);
  });

  group('detail page of a connector the host could not use', () {
    // What the host reported for the connector: it asked, and it failed.
    const McpConnection failing = McpConnection(
      id: 'example',
      name: 'Example',
      url: 'https://mcp.example.com/mcp',
      lastError: 'HTTP 401 from the server',
    );

    var dials = 0;
    http.Client Function()? previousProbeClientFactory;

    setUp(() async {
      final store = McpStore(secrets: _MemorySecrets(), list: memoryMcpList());
      McpService.resetForTest(store: store);
      await store.upsert(failing.copyWith(checkedAt: DateTime(2026, 9, 1)));
      McpService.connections.value = await store.load();
      dials = 0;
      previousProbeClientFactory = McpService.probeClientFactory;
      // The server answers any device-side check, so only the host's report
      // can call the connector broken.
      McpService.probeClientFactory = () => MockClient((_) async {
        dials++;
        return http.Response('', 200);
      });
    });

    tearDown(() {
      McpService.probeClientFactory = previousProbeClientFactory;
      debugAgentsChatCoreOverride = null;
    });

    testWidgets('with Agents on it offers Reconnect and shows the host error',
        (tester) async {
      debugAgentsChatCoreOverride = true;

      await tester.pumpWidget(
        const MaterialApp(home: McpConnectorDetailPage(id: 'example')),
      );
      await tester.pumpAndSettle();

      expect(find.widgetWithText(FilledButton, 'Reconnect'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Disconnect'), findsNothing);
      expect(
        find.textContaining('HTTP 401 from the server'),
        findsOneWidget,
      );
      expect(find.text('Remove this connector'), findsOneWidget);
      // The host dials the server; this device does not.
      expect(dials, 0);
    });

    testWidgets('with Agents off the device check decides, as before',
        (tester) async {
      debugAgentsChatCoreOverride = false;

      await tester.pumpWidget(
        const MaterialApp(home: McpConnectorDetailPage(id: 'example')),
      );
      await tester.pumpAndSettle();

      // The device reached the server, so a stored host error changes
      // nothing in chuk's own build.
      expect(dials, 1);
      expect(find.widgetWithText(FilledButton, 'Disconnect'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Reconnect'), findsNothing);
      expect(find.textContaining('HTTP 401 from the server'), findsNothing);
    });
  });
}
