import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/services/mcp/mcp_service.dart';
import 'package:chuk_chat/widgets/agents_reconnect_card.dart';

Widget _app(Widget child) => MaterialApp(
  locale: const Locale('de'),
  localizationsDelegates: const <LocalizationsDelegate<Object>>[
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: Center(child: child)),
);

ToolCall _call(Map<String, dynamic> result) => ToolCall(
  name: 'Fastmail__list_mailboxes',
  arguments: const <String, dynamic>{},
  result: jsonEncode(result),
  status: ToolCallStatus.error,
);

/// CHAT-77: a connector whose sign-in lapsed answers `auth_required`; the
/// thread draws a reconnect card from that field.
void main() {
  tearDown(() => AgentsContinueSender.debugSend = null);

  test('reads the structured auth_required block, nothing else', () {
    final auth = AgentsAuthRequired.fromToolCall(
      _call(<String, dynamic>{
        'ok': false,
        'error': 'auth_required',
        'auth_required': <String, dynamic>{
          'server': 'Fastmail',
          'connector_id': 'fastmail',
          'url': 'https://api.fastmail.com/mcp',
        },
      }),
    );
    expect(auth?.server, 'Fastmail');
    expect(auth?.connectorId, 'fastmail');
    // Text that only mentions the words is not a card.
    expect(
      AgentsAuthRequired.fromToolCall(
        _call(<String, dynamic>{'ok': false, 'error': 'auth_required'}),
      ),
      isNull,
    );
  });

  testWidgets('the tap signs in and tells the agent to go on', (tester) async {
    final sent = <String>[];
    AgentsContinueSender.debugSend = (String key, String text) async {
      sent.add('$key|$text');
      return true;
    };
    var signIns = 0;
    await tester.pumpWidget(
      _app(
        AgentsReconnectCard(
          auth: const AgentsAuthRequired(
            server: 'Fastmail',
            connectorId: 'fastmail',
          ),
          threadKey: 'local:Mail:1',
          connect: (_) async {
            signIns++;
            return McpConnectStatus.connected;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Fastmail: Anmeldung abgelaufen'), findsOneWidget);
    await tester.tap(find.text('Fastmail neu verbinden'));
    await tester.pumpAndSettle();
    expect(signIns, 1);
    expect(find.text('Fastmail ist wieder verbunden'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('agents-reconnect-button')),
      findsNothing,
    );
    expect(sent, <String>[
      'local:Mail:1|Fastmail ist wieder verbunden. Mach bitte weiter.',
    ]);
  });

  testWidgets('a cancelled sign-in leaves the card as it was', (tester) async {
    final sent = <String>[];
    AgentsContinueSender.debugSend = (String key, String text) async {
      sent.add(text);
      return true;
    };
    await tester.pumpWidget(
      _app(
        AgentsReconnectCard(
          auth: const AgentsAuthRequired(server: 'Canva'),
          threadKey: 't',
          connect: (_) async => McpConnectStatus.cancelled,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Canva neu verbinden'));
    await tester.pumpAndSettle();
    expect(find.text('Canva neu verbinden'), findsOneWidget);
    expect(sent, isEmpty);
  });
}
