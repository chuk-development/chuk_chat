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
import 'package:chuk_chat/widgets/icons/icon_map.dart';

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

  group('with Agents on, a connected row speaks plainly', () {
    setUp(() async {
      debugAgentsChatCoreOverride = true;
      final store = McpStore(secrets: _MemorySecrets(), list: memoryMcpList());
      McpService.resetForTest(store: store);
      McpService.unreachable.value = <String>{};
      McpService.probeClientFactory = () =>
          MockClient((_) async => http.Response('', 401));
      for (final (String id, McpErrorKind? kind, DateTime? checked)
          in <(String, McpErrorKind?, DateTime?)>[
            ('a', McpErrorKind.auth, DateTime(2026, 10, 29)),
            ('n', McpErrorKind.network, DateTime(2026, 10, 29)),
            ('o', McpErrorKind.other, DateTime(2026, 10, 29)),
            ('ok', null, DateTime(2026, 10, 29)),
            ('new', null, null),
          ]) {
        await store.upsert(
          McpConnection(
            id: id,
            name: 'Server $id',
            url: 'https://$id.example.com/mcp',
            checkedAt: checked,
            lastError: kind == null ? null : 'HTTP 401 reason $id',
            lastErrorKind: kind,
          ),
        );
      }
      McpService.connections.value = await store.load();
    });

    tearDown(() {
      McpService.unreachable.value = <String>{};
      debugAgentsChatCoreOverride = null;
    });

    testWidgets('each state has its own plain line and no technical text',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(home: McpConnectorsPage()));
      await tester.pumpAndSettle();

      expect(find.text('Sign-in expired'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Sign in again'), findsOneWidget);
      expect(find.text('Server not answering – we keep trying'), findsOneWidget);
      expect(find.text('Something went wrong'), findsOneWidget);
      // Confirmed and not yet confirmed both read "Signed in"; the second
      // says it is still being checked. Never an error.
      expect(find.text('Signed in'), findsNWidgets(2));
      expect(find.text('Signed in, checking…'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) => w is AppIcon && w.icon == Icons.check_rounded,
        ),
        findsNWidgets(2),
      );
      // No technical reason in the list, and none of the old words.
      expect(find.textContaining('HTTP 401'), findsNothing);
      expect(find.text('not reachable'), findsNothing);
      expect(find.text('not checked'), findsNothing);
    });

    testWidgets('a running sign-in reads "Connecting…"', (tester) async {
      McpService.connecting.value = <String>{'ok'};
      await tester.pumpWidget(const MaterialApp(home: McpConnectorsPage()));
      await tester.pumpAndSettle();
      expect(find.text('Connecting…'), findsOneWidget);
    });

    testWidgets('the detail of an expired sign-in names it and has one action',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: McpConnectorDetailPage(id: 'a')),
      );
      await tester.pumpAndSettle();

      expect(find.widgetWithText(FilledButton, 'Sign in again'), findsOneWidget);
      expect(
        find.textContaining(
          'Server a: sign-in expired. Sign in again to keep using it.',
        ),
        findsOneWidget,
      );
      // The technical reason only behind "Details".
      expect(find.textContaining('HTTP 401 reason a'), findsNothing);
      await tester.tap(find.widgetWithText(ExpansionTile, 'Details'));
      await tester.pumpAndSettle();
      expect(find.textContaining('HTTP 401 reason a'), findsOneWidget);
    });

    testWidgets('the detail of a silent server says we keep trying',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: McpConnectorDetailPage(id: 'n')),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Server not answering – we keep trying'),
        findsOneWidget,
      );
    });
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
      McpService.unreachable.value = <String>{};
      previousProbeClientFactory = McpService.probeClientFactory;
      McpService.probeClientFactory = () => MockClient((_) async {
        dials++;
        return http.Response('', 200);
      });
    });

    tearDown(() {
      McpService.probeClientFactory = previousProbeClientFactory;
      McpService.unreachable.value = <String>{};
      debugAgentsChatCoreOverride = null;
    });

    testWidgets('with Agents on it offers a new sign-in, reason under Details',
        (tester) async {
      debugAgentsChatCoreOverride = true;

      await tester.pumpWidget(
        const MaterialApp(home: McpConnectorDetailPage(id: 'example')),
      );
      await tester.pumpAndSettle();

      expect(find.widgetWithText(FilledButton, 'Sign in again'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Disconnect'), findsNothing);
      expect(find.text('Something went wrong'), findsOneWidget);
      await tester.tap(find.widgetWithText(ExpansionTile, 'Details'));
      await tester.pumpAndSettle();
      expect(find.textContaining('HTTP 401 from the server'), findsOneWidget);
      expect(find.text('Remove this connector'), findsOneWidget);
      expect(dials, 1);
      expect(
        find.textContaining('This device could not reach the server'),
        findsNothing,
      );
    });

    testWidgets('with Agents on a device that cannot reach it offers '
        'a new sign-in, though the host can', (tester) async {
      debugAgentsChatCoreOverride = true;
      await McpService.store.upsert(
        failing.copyWith(checkedAt: DateTime(2026, 9, 1), clearError: true),
      );
      McpService.connections.value = await McpService.store.load();
      McpService.probeClientFactory = () =>
          MockClient((_) async => throw http.ClientException('down'));

      await tester.pumpWidget(
        const MaterialApp(home: McpConnectorDetailPage(id: 'example')),
      );
      await tester.pumpAndSettle();

      expect(find.widgetWithText(FilledButton, 'Sign in again'), findsOneWidget);
      expect(
        find.textContaining('This device could not reach the server'),
        findsOneWidget,
      );
      expect(find.byType(ExpansionTile), findsNothing);
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
