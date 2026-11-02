// The Chukdoo row in the connector list and its own page: hidden without a
// chukdoo project, the pairing code with its hint and Cancel, and the
// connected state.

import 'dart:convert';

import 'package:chukdoo_core/chukdoo_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/pages/chukdoo_connector_page.dart';
import 'package:chuk_chat/pages/mcp_connectors_page.dart';
import 'package:chuk_chat/services/agents/agents_pairing_store.dart'
    show AgentsSecureKeyValueStore;
import 'package:chuk_chat/services/chukdoo/chukdoo_config.dart';
import 'package:chuk_chat/services/chukdoo/chukdoo_connector.dart';
import 'package:chuk_chat/services/chukdoo/chukdoo_connector_sync.dart';
import 'package:chuk_chat/services/mcp/mcp_icon_cache.dart';
import 'package:chuk_chat/services/mcp/mcp_service.dart';
import 'package:chuk_chat/services/mcp/mcp_store.dart';

import '../support/mcp_memory_list.dart';

class _Memory implements AgentsSecureKeyValueStore {
  final Map<String, String> map = <String, String>{};

  @override
  Future<String?> read(String key) async => map[key];

  @override
  Future<void> write(String key, String value) async => map[key] = value;

  @override
  Future<void> delete(String key) async => map.remove(key);
}

class _NoCloud implements ChukdooMirror {
  @override
  Future<ChukdooMirrorRead> load() async => const ChukdooMirrorRead.empty();

  @override
  Future<bool> save(Map<String, dynamic> payload) async => true;
}

final MockClient _pairingServer = MockClient((request) async {
  final fn = request.url.pathSegments.last;
  if (fn == 'pairing_open') {
    return http.Response(
      jsonEncode({
        'expires_at': DateTime.now()
            .add(const Duration(minutes: 10))
            .toUtc()
            .toIso8601String(),
      }),
      200,
    );
  }
  return http.Response('{"status":"pending"}', 200);
});

ChukdooConnector _connector() => ChukdooConnector.resetForTest(
  secrets: _Memory(),
  mirror: _NoCloud(),
  currentUserId: () => 'user-1',
  httpClientFactory: () => _pairingServer,
  toolsFactory: (c) => ChukdooTools.fromCredentials(
    c,
    httpClient: MockClient((_) async => http.Response('[]', 200)),
  ),
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    McpIconCache.httpClient = MockClient((_) async => http.Response('', 404));
    McpService.resetForTest(
      store: McpStore(secrets: _Memory(), list: memoryMcpList()),
    );
  });

  tearDown(() {
    McpIconCache.httpClient = null;
    ChukdooConfig.debugOverride();
  });

  testWidgets('the list hides Chukdoo without a chukdoo project',
      (tester) async {
    ChukdooConfig.debugOverride(url: '', anonKey: '');
    _connector();
    await tester.pumpWidget(const MaterialApp(home: McpConnectorsPage()));
    await tester.pumpAndSettle();
    expect(find.text('Chukdoo'), findsNothing);
  });

  testWidgets('the list shows Chukdoo first and opens its page',
      (tester) async {
    ChukdooConfig.debugOverride(url: 'https://chukdoo.invalid', anonKey: 'a');
    _connector();
    await tester.pumpWidget(const MaterialApp(home: McpConnectorsPage()));
    await tester.pumpAndSettle();
    expect(find.text('Built in'), findsOneWidget);
    expect(find.text('Chukdoo'), findsOneWidget);

    await tester.tap(find.text('Chukdoo'));
    await tester.pumpAndSettle();
    expect(find.byType(ChukdooConnectorPage), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Connect'), findsOneWidget);
  });

  testWidgets('Connect shows the code, the hint and Cancel', (tester) async {
    ChukdooConfig.debugOverride(url: 'https://chukdoo.invalid', anonKey: 'a');
    final connector = _connector();
    await tester.pumpWidget(const MaterialApp(home: ChukdooConnectorPage()));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
    await tester.pump();
    await tester.pump();

    final code = tester.widget<SelectableText>(
      find.byKey(const ValueKey<String>('chukdoo-pairing-code')),
    );
    expect(code.data, matches(RegExp(r'^[0-9A-Z]{5}-[0-9A-Z]{5}$')));
    expect(find.text('In Chukdoo: Settings'), findsOneWidget);
    expect(find.text('AI access'), findsOneWidget);
    expect(find.text('Pair a device'), findsOneWidget);
    expect(find.byTooltip('Copy code'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pump();
    expect(find.widgetWithText(FilledButton, 'Connect'), findsOneWidget);
    // Let the cancelled poll loop run out, so no timer is left behind.
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
    expect(connector.state.value.connected, isFalse);
  });

  testWidgets('connected: Disconnect and the tool list', (tester) async {
    ChukdooConfig.debugOverride(url: 'https://chukdoo.invalid', anonKey: 'a');
    final connector = _connector();
    await tester.runAsync(
      () => connector.connectWith(
        ChukdooCredentials(
          supabaseUrl: 'https://chukdoo.invalid',
          anonKey: 'a',
          userId: 'u',
          deviceId: 'd',
          deviceToken: 'cdk_x',
          dataKey: 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=',
          deviceName: 'Chuk Chat',
          pairedAt: DateTime.utc(2026, 11, 2),
        ),
      ),
    );
    await tester.pumpWidget(const MaterialApp(home: ChukdooConnectorPage()));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilledButton, 'Disconnect'), findsOneWidget);
    expect(find.text('list_todos'), findsOneWidget);
  });

  testWidgets('revoked: the page says why', (tester) async {
    ChukdooConfig.debugOverride(url: 'https://chukdoo.invalid', anonKey: 'a');
    final secrets = _Memory();
    secrets.map['chukdoo_connector_v1_user-1'] = jsonEncode(
      ChukdooRecord.ended(ChukdooEndReason.revoked, DateTime.utc(2026, 11, 2))
          .toJson(),
    );
    final connector = ChukdooConnector.resetForTest(
      secrets: secrets,
      mirror: _NoCloud(),
      currentUserId: () => 'user-1',
    );
    await tester.runAsync(connector.load);
    await tester.pumpWidget(const MaterialApp(home: ChukdooConnectorPage()));
    await tester.pumpAndSettle();
    expect(
      find.textContaining('removed in the Chukdoo app'),
      findsOneWidget,
    );
  });
}
