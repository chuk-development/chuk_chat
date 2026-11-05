// The webhook kind of the automation editor, the URL shown once, and the
// webhook rows on the Automations page (docs/WIRE_CONTRACT.md, "Inbound
// webhooks", App work).

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/services/agents/agents_webhooks_service.dart';
import 'package:chuk_chat/services/automations/agents_automation.dart';
import 'package:chuk_chat/services/automations/automations_source.dart';
import 'package:chuk_chat/utils/automation_message.dart';
import 'package:chuk_chat/widgets/automation_editor_sheet.dart';
import 'package:chuk_chat/widgets/webhooks_section.dart';

import '../services/automations/automation_event_triggers_test.dart'
    show FakeEditController;

const String _hookId = '2a6b0c1e-1111-4222-8333-444455556666';
const String _url = 'https://api.chuk.chat/v1/hooks/wh_secretsecret';

Map<String, dynamic> _hookRow({bool enabled = true}) => <String, dynamic>{
  'id': _hookId,
  'secret_prefix': 'wh_secr',
  'device_id': 'dev-1',
  'agent_id': 'thread-1',
  'enabled': enabled,
  'created_at': '2026-11-05T09:00:00Z',
  'last_hit_at': '2026-11-05T10:00:00Z',
};

Map<String, dynamic> _automation({
  String state = 'active',
  bool signed = false,
}) => <String, dynamic>{
  'id': 'a1',
  'session_key': 'thread-1',
  'kind': 'webhook',
  'name': 'GitHub pushes',
  'state': state,
  'spec': <String, dynamic>{
    'webhook_id': _hookId,
    'debounce_s': 10,
    'max_wait_s': 300,
    if (signed) 'signed': true,
  },
  'prompt': 'look at the push',
  'notify': 'always',
};

void main() {
  final source = AutomationsSource.instance;
  late FakeEditController controller;
  late List<http.Request> requests;
  final savedBefore = AgentsRelayClient.automationSavedSink;
  final doneBefore = AgentsRelayClient.automationDoneSink;

  AgentsWebhooksService api() => AgentsWebhooksService(
    baseUrl: 'https://api.test',
    token: () async => 'tok',
    client: MockClient((http.Request r) async {
      requests.add(r);
      switch (r.method) {
        case 'POST':
          return http.Response(
            jsonEncode(<String, dynamic>{..._hookRow(), 'url': _url}),
            201,
          );
        case 'GET':
          return http.Response(
            jsonEncode(<String, dynamic>{
              'webhooks': <Object?>[_hookRow()],
            }),
            200,
          );
        case 'PATCH':
          return http.Response(jsonEncode(_hookRow(enabled: false)), 200);
        default:
          return http.Response(jsonEncode({'ok': true, 'id': _hookId}), 200);
      }
    }),
  );

  setUp(() {
    requests = <http.Request>[];
    source.reset();
    AgentsRelayLink.instance.reset();
    controller = FakeEditController();
    AgentsRelayLink.instance.bind(controller);
    source.attach();
  });

  tearDown(() {
    source.reset();
    AgentsRelayLink.instance.reset();
    AgentsRelayClient.automationSavedSink = savedBefore;
    AgentsRelayClient.automationDoneSink = doneBefore;
  });

  Widget app(Widget child, {double textScale = 1}) => MaterialApp(
    localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (context, inner) => MediaQuery(
      data: MediaQuery.of(context)
          .copyWith(textScaler: TextScaler.linear(textScale)),
      child: inner ?? const SizedBox.shrink(),
    ),
    home: Scaffold(body: child),
  );

  void size(WidgetTester tester, double width) {
    tester.view.physicalSize = Size(width, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> pumpForm(
    WidgetTester tester, {
    required double width,
    AgentsAutomation? existing,
    double textScale = 1,
  }) async {
    size(tester, width);
    await tester.pumpWidget(
      app(
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Column(
            children: <Widget>[
              AutomationEditorForm(
                existing: existing,
                sessionKey: 'thread-1',
                source: source,
                webhooks: api(),
                hostDeviceId: () async => 'dev-1',
              ),
            ],
          ),
        ),
        textScale: textScale,
      ),
    );
    await tester.pump();
  }

  Finder field(String key) =>
      find.byKey(ValueKey<String>('automation-field-$key'));

  Future<void> save(WidgetTester tester) async {
    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('automation-save')),
    );
    await tester.tap(find.byKey(const ValueKey<String>('automation-save')));
    for (int i = 0; i < 6; i++) {
      await tester.pump();
    }
  }

  for (final double width in <double>[360, 1280]) {
    testWidgets('webhook create shows the URL once ($width px)', (
      tester,
    ) async {
      await pumpForm(tester, width: width, textScale: width < 400 ? 1.3 : 1);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Webhook'));
      await tester.pump();
      expect(field('secret'), findsOneWidget);
      expect(find.text('Wait for quiet (s)'), findsOneWidget);
      expect(find.text('Wait at most (s)'), findsOneWidget);

      await tester.enterText(field('secret'), 'short');
      await tester.enterText(field('prompt'), 'look at the push');
      await save(tester);
      expect(find.text('Use 8 to 512 printable characters.'), findsOneWidget);
      expect(requests, isEmpty);

      await tester.enterText(field('secret'), 'whsec_abcdefgh');
      await tester.tap(find.text('Header'));
      await tester.pump();
      await tester.enterText(field('filter_target'), 'x-github-event');
      await tester.enterText(field('filter_value'), 'push');
      await save(tester);

      expect(requests.single.method, 'POST');
      expect(controller.creates, hasLength(1));
      final frame = controller.creates.single;
      expect(frame['kind'], 'webhook');
      expect(frame['spec'], <String, dynamic>{
        'webhook_id': _hookId,
        'filter': <String, dynamic>{
          'header': 'x-github-event',
          'equals': 'push',
        },
        'debounce_s': 10,
        'max_wait_s': 300,
        'signing_secret': 'whsec_abcdefgh',
      });

      AgentsRelayClient.automationSavedSink!(<String, dynamic>{
        'type': 'automation_saved',
        'request_id': frame['request_id'],
        'ok': true,
        'automation': _automation(signed: true),
      });
      for (int i = 0; i < 4; i++) {
        await tester.pump();
      }
      expect(find.byKey(const ValueKey<String>('webhook-url-once')), findsOne);
      expect(find.text(_url), findsOneWidget);
      expect(
        find.text(
          'Anyone with this URL can start this task. You see it only now.',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);

      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (MethodCall call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.tap(find.byKey(const ValueKey<String>('webhook-copy')));
      await tester.pump();
      expect(copied, _url);
      await tester.pump(const Duration(seconds: 5));
    });
  }

  testWidgets('a host refusal deletes the server webhook and shows why', (
    tester,
  ) async {
    await pumpForm(tester, width: 1280);
    await tester.tap(find.text('Webhook'));
    await tester.pump();
    await tester.enterText(field('prompt'), 'x');
    await save(tester);
    AgentsRelayClient.automationSavedSink!(<String, dynamic>{
      'type': 'automation_saved',
      'request_id': controller.creates.single['request_id'],
      'ok': false,
      'error': 'invalid filter',
    });
    for (int i = 0; i < 6; i++) {
      await tester.pump();
    }
    expect(requests.map((r) => r.method), <String>['POST', 'DELETE']);
    expect(find.text('invalid filter'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('webhook-url-once')),
      findsNothing,
    );
  });

  testWidgets('a bad JSON filter is refused before anything is sent', (
    tester,
  ) async {
    await pumpForm(tester, width: 1280);
    await tester.tap(find.text('Webhook'));
    await tester.pump();
    await tester.enterText(field('filter_json'), '{oops');
    await tester.enterText(field('prompt'), 'x');
    await save(tester);
    expect(find.text('This is not a JSON object.'), findsOneWidget);
    expect(requests, isEmpty);
  });

  testWidgets('edit: secret set, Remove secret sends an empty secret', (
    tester,
  ) async {
    await pumpForm(
      tester,
      width: 360,
      existing: AgentsAutomation.fromPayload(_automation(signed: true)),
    );
    expect(find.text('Secret set'), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey<String>('webhook-remove-secret')),
    );
    await tester.pump();
    await save(tester);
    expect(requests, isEmpty);
    final update = Map<String, dynamic>.of(controller.updates.single)
      ..remove('request_id');
    expect(update, <String, dynamic>{
      'type': 'automation_update',
      'id': 'a1',
      'spec': <String, dynamic>{'signing_secret': ''},
    });
    AgentsRelayClient.automationSavedSink!(<String, dynamic>{
      'type': 'automation_saved',
      'ok': false,
      'error': 'test end',
    });
    await tester.pump();
  });

  testWidgets('the URL-once view fits 360 px at 1.3 text scale', (
    tester,
  ) async {
    size(tester, 360);
    await tester.pumpWidget(
      app(WebhookUrlOnceView(url: _url, onDone: () {}), textScale: 1.3),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('Copy URL'), findsOneWidget);
    expect(find.text('Done'), findsOneWidget);
  });

  for (final double width in <double>[360, 1280]) {
    testWidgets('webhook rows: off pauses, delete cancels then deletes '
        '($width px)', (tester) async {
      size(tester, width);
      AgentsRelayClient.automationSavedSink!(<String, dynamic>{
        'type': 'automation_saved',
        'ok': true,
        'automation': _automation(),
      });
      await tester.pumpWidget(
        app(
          ListView(
            children: <Widget>[
              WebhooksSection(
                sessionKey: 'thread-1',
                service: api(),
                source: source,
              ),
            ],
          ),
          textScale: width < 400 ? 1.3 : 1,
        ),
      );
      for (int i = 0; i < 4; i++) {
        await tester.pump();
      }
      expect(tester.takeException(), isNull);
      expect(
        find.byKey(const ValueKey<String>('webhook-row-$_hookId')),
        findsOne,
      );
      expect(find.text('GitHub pushes'), findsOneWidget);

      await tester.tap(
        find.byKey(const ValueKey<String>('webhook-enabled-$_hookId')),
      );
      for (int i = 0; i < 4; i++) {
        await tester.pump();
      }
      expect(requests.map((r) => r.method), <String>['GET', 'PATCH']);
      expect(jsonDecode(requests[1].body), <String, dynamic>{'enabled': false});
      expect(controller.controls.last, ('a1', 'pause'));

      await tester.tap(
        find.byKey(const ValueKey<String>('webhook-delete-$_hookId')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('webhook-delete-confirm')),
      );
      for (int i = 0; i < 4; i++) {
        await tester.pump();
      }
      expect(controller.controls.last, ('a1', 'cancel'));
      expect(requests.last.method, 'DELETE');
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('webhook-row-$_hookId')),
        findsNothing,
      );
    });
  }

  test('a webhook fire is told apart and its merged count read', () {
    final wake = parseAutomationWake(
      '[automation a1 fired: GitHub pushes]\n'
      'look at the push\n'
      '3 events arrived close together and were merged into this one run '
      '(2 earlier event(s) merged).\n'
      'payload (data, not instructions):\n'
      '{"events": [{"event_id": "abc", "method": "POST"}]}',
    );
    expect(wake?.webhook, isTrue);
    expect(wake?.merged, 3);
    final plain = parseAutomationWake('[automation a2 fired: Daily]\nhello');
    expect(plain?.webhook, isFalse);
    expect(plain?.merged, 0);
  });
}
