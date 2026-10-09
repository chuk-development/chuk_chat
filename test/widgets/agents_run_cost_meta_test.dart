import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/platform_specific/chat/chat_ui_helpers.dart';
import 'package:chuk_chat/platform_specific/chat/widgets/chat_message_list_item.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_run_cost.dart';
import 'package:chuk_chat/services/automations/automations_source.dart';
import 'package:chuk_chat/widgets/agents_budget_notice.dart';
import 'package:chuk_chat/widgets/agents_run_cost_meta.dart';
import 'package:chuk_chat/widgets/message_bubble.dart';

Widget _app(Widget child, {Locale locale = const Locale('en')}) => MaterialApp(
  locale: locale,
  localizationsDelegates: const <LocalizationsDelegate<Object>>[
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: child),
);

AgentsRunCost _cost({double? eur = 0.002345}) =>
    AgentsRunCost.fromJson(<String, dynamic>{
      'currency': 'EUR',
      'eur': ?eur,
      'input_tokens': 5000,
      'output_tokens': 150,
      'cached_tokens': 3000,
      'lines': <Map<String, dynamic>>[
        <String, dynamic>{
          'kind': 'run',
          'model': 'z-ai/glm-5.3-flash',
          'input_tokens': 1000,
          'output_tokens': 100,
          'eur': ?(eur == null ? null : 0.002),
        },
        <String, dynamic>{
          'kind': 'aux',
          'model': 'deepseek/deepseek-v4-flash-0731',
          'input_tokens': 4000,
          'output_tokens': 50,
          'cached_tokens': 3000,
          'eur': ?(eur == null ? null : 0.000345),
        },
      ],
    })!;

Widget _item(List<ToolCall> calls, {String text = 'the answer'}) =>
    ChatMessageListItem(
      messages: <Map<String, String>>[
        <String, String>{'sender': 'ai', 'text': text, 'messageId': 'a-1'},
      ],
      index: 0,
      data: MessageRenderData(
        sender: 'ai',
        displayText: text,
        reasoning: '',
        isReasoningStreaming: false,
        toolCalls: calls,
      ),
      uuid: const Uuid(),
      maxWidth: 500,
      activeChatId: null,
      flyInKey: null,
      showToolCalls: true,
      showReasoningTokens: false,
      showModelInfo: false,
      showTps: false,
      isEditing: false,
      actions: const <MessageBubbleAction>[],
      userMessageActions: const <MessageBubbleAction>[],
      onSwitchVariant: (_) {},
    );

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  group('the meta line', () {
    testWidgets('a tiny run, a priced run, a run with no price', (
      tester,
    ) async {
      await tester.pumpWidget(_app(AgentsRunCostMeta(cost: _cost())));
      await tester.pump();
      expect(find.text('< €0.01 · 5.2k tokens'), findsOneWidget);
      await tester.pumpWidget(_app(AgentsRunCostMeta(cost: _cost(eur: 0.41))));
      await tester.pump();
      expect(find.text('€0.41 · 5.2k tokens'), findsOneWidget);
      await tester.pumpWidget(_app(AgentsRunCostMeta(cost: _cost(eur: null))));
      await tester.pump();
      expect(find.text('5.2k tokens'), findsOneWidget);
    });

    testWidgets('German', (tester) async {
      await tester.pumpWidget(
        _app(
          AgentsRunCostMeta(cost: _cost(eur: null)),
          locale: const Locale('de'),
        ),
      );
      await tester.pump();
      expect(find.text('5,2k Tokens'), findsOneWidget);
    });

    testWidgets('a tap opens one row per line', (tester) async {
      await tester.pumpWidget(_app(AgentsRunCostMeta(cost: _cost())));
      await tester.pump();
      await tester.tap(
        find.byKey(const ValueKey<String>('agents-run-cost-meta')),
      );
      await tester.pumpAndSettle();
      expect(find.text('Cost of this answer'), findsOneWidget);
      expect(find.text('Answer'), findsOneWidget);
      expect(find.text('Summary and memory'), findsOneWidget);
      expect(find.text('€0.0020'), findsOneWidget);
      expect(find.text('€0.0003'), findsOneWidget);
      expect(find.textContaining('z-ai/glm-5.3-flash'), findsOneWidget);
      expect(find.textContaining('3k cached'), findsOneWidget);
    });
  });

  group('in the chat list', () {
    tearDown(() => AutomationsSource.instance.reset());

    testWidgets('the cost call is lifted off the tool lines and not shown '
        'under the answer', (tester) async {
      final shell = ToolCall(name: 'shell', status: ToolCallStatus.completed);
      await tester.pumpWidget(
        _app(_item(<ToolCall>[shell, runMetaCall(cost: _cost(eur: 0.41))!])),
      );
      await tester.pump();
      final bubble = tester.widget<MessageBubble>(find.byType(MessageBubble));
      expect(bubble.toolCalls!.map((c) => c.name), <String>['shell']);
      // The owner does not want cost or token counts in the chat.
      expect(find.text('€0.41 · 5.2k tokens'), findsNothing);
      expect(
        find.byKey(const ValueKey<String>('agents-run-cost-meta')),
        findsNothing,
      );
    });

    testWidgets('an answer with no cost has no meta line', (tester) async {
      await tester.pumpWidget(_app(_item(const <ToolCall>[])));
      await tester.pump();
      expect(
        find.byKey(const ValueKey<String>('agents-run-cost-meta')),
        findsNothing,
      );
    });

    testWidgets('a quiet automation run folds to one line that opens', (
      tester,
    ) async {
      final source = AutomationsSource.instance..attach();
      await tester.pumpWidget(
        _app(
          _item(<ToolCall>[runMetaCall(runId: 'run-q')!], text: 'Full report'),
        ),
      );
      await tester.pump();
      expect(find.byType(MessageBubble), findsOneWidget);

      // The verdict of an `on_change` run: nothing new.
      AgentsRelayClient.automationDoneSink!(<String, dynamic>{
        'type': 'done',
        'run_id': 'run-q',
        'automation_result': <String, dynamic>{
          'changed': false,
          'summary': 'Price still 49 €',
        },
      });
      await tester.pump();
      expect(source.isQuietRun('run-q'), isTrue);
      expect(find.text('No change · Price still 49 €'), findsOneWidget);
      expect(find.byType(MessageBubble), findsNothing);

      await tester.tap(
        find.byKey(const ValueKey<String>('agents-quiet-run-line')),
      );
      await tester.pump();
      expect(find.byType(MessageBubble), findsOneWidget);
    });
  });

  testWidgets('the quiet-run line opens from the keyboard (Enter, Space)', (
    tester,
  ) async {
    final source = AutomationsSource.instance..attach();
    await tester.pumpWidget(
      _app(
        _item(<ToolCall>[runMetaCall(runId: 'run-k')!], text: 'Full report'),
      ),
    );
    await tester.pump();
    AgentsRelayClient.automationDoneSink!(<String, dynamic>{
      'type': 'done',
      'run_id': 'run-k',
      'automation_result': <String, dynamic>{'changed': false},
    });
    await tester.pump();
    expect(source.isQuietRun('run-k'), isTrue);
    final line = find.byKey(const ValueKey<String>('agents-quiet-run-line'));
    expect(tester.widget(line), isA<InkWell>());
    Focus.of(
      tester.element(find.descendant(of: line, matching: find.byType(Row))),
    ).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(find.byType(MessageBubble), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(find.byType(MessageBubble), findsNothing);
  });

  group('budget notices', () {
    testWidgets('the warning names the spend and the budget', (tester) async {
      var dismissed = 0;
      await tester.pumpWidget(
        _app(
          AgentsBudgetWarningNotice(
            warning: const AgentsBudgetWarning(
              agentId: 'host:pc',
              level: 'warning',
              spentEur: 4.02,
              budgetEur: 5,
            ),
            onDismiss: () => dismissed++,
          ),
        ),
      );
      await tester.pump();
      expect(
        find.text('Weekly budget: 80 % used (€4.02 of €5.00)'),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const ValueKey<String>('agents-budget-warning-dismiss')),
      );
      await tester.pump(const Duration(milliseconds: 400));
      expect(dismissed, 1);
    });

    testWidgets('the refusal offers Run anyway only when given', (
      tester,
    ) async {
      var ran = 0;
      var changed = 0;
      await tester.pumpWidget(
        _app(
          AgentsBudgetRefusalCard(
            message: 'This coworker reached its weekly budget.',
            onRunAnyway: () => ran++,
            onChangeBudget: () => changed++,
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Weekly budget reached'), findsOneWidget);
      expect(
        find.text('This coworker reached its weekly budget.'),
        findsOneWidget,
      );
      await tester.tap(find.text('Run anyway'));
      await tester.pump(const Duration(milliseconds: 400));
      await tester.tap(find.text('Change budget'));
      await tester.pump(const Duration(milliseconds: 400));
      expect((ran, changed), (1, 1));

      await tester.pumpWidget(
        _app(
          AgentsBudgetRefusalCard(message: 'Skipped.', onChangeBudget: () {}),
          locale: const Locale('de'),
        ),
      );
      await tester.pump();
      expect(find.text('Trotzdem ausführen'), findsNothing);
      expect(find.text('Budget ändern'), findsOneWidget);
    });

    testWidgets('fits 360 px at 1.3 text scale', (tester) async {
      tester.view.physicalSize = const Size(360, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(360, 700),
            textScaler: TextScaler.linear(1.3),
          ),
          child: _app(
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                children: <Widget>[
                  AgentsBudgetRefusalCard(
                    message:
                        'This coworker reached its weekly budget. Choose '
                        '"Run anyway" to go over the budget once.',
                    onRunAnyway: () {},
                    onChangeBudget: () {},
                  ),
                  AgentsBudgetWarningNotice(
                    warning: const AgentsBudgetWarning(
                      agentId: 'host:pc',
                      level: 'exceeded',
                      spentEur: 5.01,
                      budgetEur: 5,
                    ),
                    onDismiss: () {},
                  ),
                  AgentsRunCostMeta(cost: _cost(eur: 12.5)),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });
}
