import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/pages/automations_page.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/services/automations/agents_automation.dart';
import 'package:chuk_chat/services/automations/automations_source.dart';
import 'package:chuk_chat/widgets/automation_card.dart';
import 'package:chuk_chat/widgets/automation_editor_sheet.dart';

import '../services/automations/automation_event_triggers_test.dart'
    show FakeEditController, row;

void main() {
  final source = AutomationsSource.instance;
  late FakeEditController controller;
  final savedBefore = AgentsRelayClient.automationSavedSink;
  final doneBefore = AgentsRelayClient.automationDoneSink;

  setUp(() {
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

  void bigView(WidgetTester tester) {
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<void> pumpForm(
    WidgetTester tester, {
    AgentsAutomation? existing,
    String? sessionKey = 'thread-1',
    Map<String, String> coworkers = const <String, String>{},
    Locale locale = const Locale('en'),
  }) async {
    bigView(tester);
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Column(
            children: <Widget>[
              AutomationEditorForm(
                existing: existing,
                sessionKey: sessionKey,
                coworkers: coworkers,
                source: source,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Finder field(String key) => find.byKey(ValueKey<String>('automation-field-$key'));

  /// Answers the request in flight, so no save timer outlives the test.
  Future<void> answer(WidgetTester tester) async {
    AgentsRelayClient.automationSavedSink!(<String, dynamic>{
      'type': 'automation_saved',
      'ok': false,
      'error': 'test end',
    });
    await tester.pump();
  }

  Future<void> tapSave(WidgetTester tester) async {
    await tester.tap(find.byKey(const ValueKey<String>('automation-save')));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('a new schedule sends automation_create', (tester) async {
    await pumpForm(tester);
    await tester.enterText(field('schedule'), 'every 1h');
    await tester.enterText(field('prompt'), 'news on my interests');
    await tester.enterText(field('name'), 'Morning news');
    await tester.tap(find.byKey(const ValueKey<String>('automation-notify')));
    await tester.pump();
    await tapSave(tester);
    expect(controller.creates, hasLength(1));
    // The request id is fresh per send; the rest is the frame.
    expect(controller.creates.single['request_id'], isA<String>());
    expect(Map<String, dynamic>.of(controller.creates.single)
      ..remove('request_id'), <String, dynamic>{
      'type': 'automation_create',
      'session_key': 'thread-1',
      'kind': 'schedule',
      'spec': 'every 1h',
      'prompt': 'news on my interests',
      'name': 'Morning news',
      'notify': 'on_change',
    });
    AgentsRelayClient.automationSavedSink!(<String, dynamic>{
      'type': 'automation_saved',
      'ok': true,
      'automation': row('s1', kind: 'schedule', spec: {'every': 3600}),
    });
    await tester.pump();
  });

  testWidgets('a page watch refuses less than 15 minutes before sending', (
    tester,
  ) async {
    await pumpForm(tester);
    await tester.tap(find.text('Watch a page'));
    await tester.pump();
    await tester.enterText(field('url'), 'https://shop.example/p');
    await tester.enterText(field('minutes'), '10');
    await tester.enterText(field('prompt'), 'tell me the price');
    await tapSave(tester);
    expect(controller.creates, isEmpty);
    expect(find.text('Enter whole minutes, at least 15.'), findsOneWidget);

    await tester.enterText(field('url'), 'ftp://x');
    await tester.enterText(field('minutes'), '15');
    await tapSave(tester);
    expect(controller.creates, isEmpty);
    expect(
      find.text('Enter a full address that starts with http:// or https://.'),
      findsOneWidget,
    );

    await tester.enterText(field('url'), 'https://shop.example/p');
    await tapSave(tester);
    expect(controller.creates.single['kind'], 'watch_url');
    expect(controller.creates.single['spec'], <String, dynamic>{
      'url': 'https://shop.example/p',
      'every': 900,
    });
    expect(controller.creates.single['notify'], 'always');
    await answer(tester);
  });

  testWidgets('a mail trigger needs a sender or a subject; host errors show', (
    tester,
  ) async {
    await pumpForm(tester);
    await tester.tap(find.text('Mail'));
    await tester.pump();
    await tester.enterText(field('prompt'), 'read it');
    await tapSave(tester);
    expect(find.text('Enter a sender or a subject.'), findsOneWidget);
    await tester.enterText(field('subject'), 'invoice');
    await tapSave(tester);
    expect(controller.creates.single['spec'], <String, dynamic>{
      'subject': 'invoice',
    });
    AgentsRelayClient.automationSavedSink!(<String, dynamic>{
      'type': 'automation_saved',
      'ok': false,
      'error': 'agent mail is not set up on this host',
    });
    await tester.pump();
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('automation-host-error')),
      findsOneWidget,
    );
    expect(find.text('agent mail is not set up on this host'), findsOneWidget);
  });

  testWidgets('the edit sheet sends only what changed', (tester) async {
    final existing = AgentsAutomation.fromPayload(row('w1'))!;
    await pumpForm(tester, existing: existing);
    // The kind cannot change in an edit.
    expect(find.text('Watch a page'), findsNothing);
    await tapSave(tester);
    expect(controller.updates, isEmpty);
    expect(find.text('Nothing changed.'), findsOneWidget);

    await tester.enterText(field('minutes'), '120');
    await tapSave(tester);
    expect(Map<String, dynamic>.of(controller.updates.single)
      ..remove('request_id'), <String, dynamic>{
      'type': 'automation_update',
      'id': 'w1',
      'spec': <String, dynamic>{'url': 'https://shop.example/p', 'every': 7200},
    });
    await answer(tester);
  });

  testWidgets('the global page asks for the coworker first', (tester) async {
    await pumpForm(
      tester,
      sessionKey: null,
      coworkers: const <String, String>{'a': 'Amber', 'b': 'Basil'},
    );
    await tester.enterText(field('schedule'), 'every 1h');
    await tester.enterText(field('prompt'), 'x');
    await tapSave(tester);
    expect(controller.creates, isEmpty);
    expect(find.text('Choose a coworker.'), findsOneWidget);
  });

  testWidgets('fits 360 dp at 1.3 text scale', (tester) async {
    tester.view.physicalSize = const Size(360, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('de'),
        localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(1.3)),
          child: child!,
        ),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              children: <Widget>[
                AutomationEditorForm(
                  sessionKey: null,
                  coworkers: const <String, String>{
                    'a': 'A coworker with a rather long name indeed',
                  },
                  source: source,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Seite beobachten'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('German strings', (tester) async {
    await pumpForm(tester, locale: const Locale('de'));
    expect(find.text('Seite beobachten'), findsOneWidget);
    expect(find.text('Nur bei Änderung benachrichtigen'), findsOneWidget);
    expect(find.text('Anlegen'), findsOneWidget);
  });

  group('Automations page', () {
    Future<void> pumpPage(WidgetTester tester) async {
      bigView(tester);
      await tester.pumpWidget(
        const MaterialApp(home: AutomationsPage(sessionKey: 'thread-1')),
      );
      await tester.pump();
    }

    testWidgets('a card shows the trigger, notify mode, quiet runs, summary', (
      tester,
    ) async {
      await pumpPage(tester);
      controller.emit(
        AgentsRelayAutomationList(
          sessionKey: 'thread-1',
          automations: <AgentsAutomation>[
            AgentsAutomation.fromPayload(<String, dynamic>{
              ...row('w1', summary: 'price 129 EUR', unchanged: 3),
              'next_fire_at':
                  DateTime.now()
                      .add(const Duration(minutes: 30))
                      .millisecondsSinceEpoch /
                  1000,
            })!,
            AgentsAutomation.fromPayload(
              row(
                'm1',
                kind: 'mail',
                notify: 'always',
                spec: <String, dynamic>{'from': 'bank'},
              ),
            )!,
          ],
        ),
      );
      await tester.pump();
      expect(find.byType(AutomationCard), findsNWidgets(2));
      final facts = find.textContaining('Page · shop.example · every 1h');
      expect(facts, findsOneWidget);
      final String text = tester.widget<Text>(facts).data!;
      expect(text, contains('next check in '));
      expect(text, contains('notifies on change'));
      expect(text, contains('quiet 3 runs'));
      expect(find.text('Last result: price 129 EUR'), findsOneWidget);
      expect(find.textContaining('Mail · from bank'), findsOneWidget);
      // Both rows can be edited.
      expect(find.byTooltip('Edit'), findsNWidgets(2));
    });

    testWidgets('New opens the sheet, Edit opens it filled in', (tester) async {
      await pumpPage(tester);
      controller.emit(
        AgentsRelayAutomationList(
          sessionKey: 'thread-1',
          automations: <AgentsAutomation>[
            AgentsAutomation.fromPayload(row('w1'))!,
          ],
        ),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey<String>('automations-new')));
      await tester.pumpAndSettle();
      expect(find.text('New automation'), findsOneWidget);
      expect(find.byType(AutomationEditorForm), findsOneWidget);
      Navigator.of(tester.element(find.byType(AutomationEditorForm))).pop();
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Edit'));
      await tester.pumpAndSettle();
      expect(find.text('Edit automation'), findsOneWidget);
      expect(find.text('https://shop.example/p'), findsOneWidget);
    });
  });
}
