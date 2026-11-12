// The Agents thread reads like a messenger: centred time lines (CHAT-53),
// every message its own bubble, the user's in the agent's colour (CHAT-52),
// and no Resend or Retry on a good answer (CHAT-32).

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/platform_specific/chat/chat_ui_helpers.dart';
import 'package:chuk_chat/platform_specific/chat/handlers/message_actions_handler.dart';
import 'package:chuk_chat/models/content_block.dart';
import 'package:chuk_chat/services/agents/agents_chat_core.dart';
import 'package:chuk_chat/services/agents/agents_run_ledger.dart'
    show isAgentsRunNoticeRow;
import 'package:chuk_chat/services/storage/chat_origin.dart';
import 'package:chuk_chat/ui/expressive/agent_face.dart';
import 'package:chuk_chat/widgets/agent_thread_accent.dart';
import 'package:chuk_chat/widgets/message_bubble.dart';
import 'package:chuk_chat/widgets/message_time_label.dart';

import '../support/test_app.dart';

void main() {
  final DateTime now = DateTime(2026, 11, 12, 14, 40);

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    debugMessageTimeNow = () => now;
  });
  tearDown(() {
    debugMessageTimeNow = null;
    ChatOrigin.reset();
  });

  Future<String> labelFor(WidgetTester tester, DateTime when) async {
    late String label;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: kTestLocalizationsDelegates,
        home: MediaQuery(
          data: const MediaQueryData(alwaysUse24HourFormat: true),
          child: Builder(
            builder: (BuildContext context) {
              label = messageTimeLabel(context, when);
              return const SizedBox();
            },
          ),
        ),
      ),
    );
    await tester.pump();
    return label;
  }

  group('messageTimeLabel', () {
    testWidgets('today gives the day and the clock time', (tester) async {
      expect(
        await labelFor(tester, DateTime(2026, 11, 12, 9, 5)),
        'Today 09:05',
      );
    });

    testWidgets('yesterday by calendar day, not 24 hours', (tester) async {
      expect(
        await labelFor(tester, DateTime(2026, 11, 11, 23, 50)),
        'Yesterday 23:50',
      );
    });

    testWidgets('older in the same year: weekday, date and time', (
      tester,
    ) async {
      final String label = await labelFor(
        tester,
        DateTime(2026, 11, 4, 20, 39),
      );
      expect(label, 'Wed, Nov 4 20:39');
    });

    testWidgets('another year gives the year', (tester) async {
      final String label = await labelFor(tester, DateTime(2025, 2, 1, 8, 0));
      expect(label, contains('2025'));
      expect(label, endsWith('08:00'));
    });
  });

  group('messageOpensTimeDivider', () {
    Map<String, String> row(DateTime at, [String sender = 'ai']) =>
        <String, String>{'sender': sender, 'sentAt': at.toIso8601String()};

    test('the first dated row opens a line', () {
      expect(
        messageOpensTimeDivider(<Map<String, String>>[row(now)], 0),
        isTrue,
      );
    });

    test('a short pause opens none, a long pause and a new day do', () {
      final List<Map<String, String>> rows = <Map<String, String>>[
        row(DateTime(2026, 11, 11, 23, 50), 'user'),
        row(DateTime(2026, 11, 12, 0, 5)), // new day
        row(DateTime(2026, 11, 12, 0, 20), 'user'), // 15 min
        row(DateTime(2026, 11, 12, 1, 30)), // 70 min
      ];
      expect(messageOpensTimeDivider(rows, 1), isTrue);
      expect(messageOpensTimeDivider(rows, 2), isFalse);
      expect(messageOpensTimeDivider(rows, 3), isTrue);
    });

    test('an undated row opens none', () {
      expect(
        messageOpensTimeDivider(<Map<String, String>>[
          <String, String>{'sender': 'ai'},
        ], 0),
        isFalse,
      );
    });
  });

  group('Agents bubbles', () {
    Future<void> pumpBubble(
      WidgetTester tester, {
      required bool isUser,
      required String chatId,
      String? agentId,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: kTestLocalizationsDelegates,
          home: Scaffold(
            body: AgentThreadAccent(
              agentId: agentId,
              child: MessageBubble(
                message: 'Hello there',
                isUser: isUser,
                chatId: chatId,
                maxWidth: 360,
                sentAt: DateTime(2026, 11, 12, 14, 32),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    BoxDecoration? decorationAround(WidgetTester tester, String text) {
      final Iterable<Container> boxes = tester.widgetList<Container>(
        find.ancestor(of: find.text(text), matching: find.byType(Container)),
      );
      for (final Container c in boxes) {
        final Decoration? d = c.decoration;
        if (d is BoxDecoration && d.color != null) return d;
      }
      return null;
    }

    testWidgets('an Agents answer is a bubble', (tester) async {
      debugAgentsChatCoreOverride = true;
      addTearDown(() => debugAgentsChatCoreOverride = null);
      await pumpBubble(tester, isUser: false, chatId: 'agent:chief:main');
      expect(decorationAround(tester, 'Hello there'), isNotNull);
    });

    testWidgets('a chuk_chat answer stays on the page', (tester) async {
      await pumpBubble(
        tester,
        isUser: false,
        chatId: '2b7f0c1e-0000-4000-8000-000000000001',
      );
      expect(decorationAround(tester, 'Hello there'), isNull);
    });

    testWidgets('the user bubble takes the agent colour', (tester) async {
      debugAgentsChatCoreOverride = true;
      addTearDown(() => debugAgentsChatCoreOverride = null);
      await pumpBubble(
        tester,
        isUser: true,
        chatId: 'agent:chief:main',
        agentId: 'chief',
      );
      final BuildContext context = tester.element(find.text('Hello there'));
      expect(
        decorationAround(tester, 'Hello there')?.color,
        agentAccent(context, 'chief'),
      );
    });

    testWidgets('desktop hover shows react, reply and more, no Resend', (
      tester,
    ) async {
      debugAgentsChatCoreOverride = true;
      addTearDown(() => debugAgentsChatCoreOverride = null);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: kTestLocalizationsDelegates,
          home: Scaffold(
            body: MessageBubble(
              message: 'Hello there',
              isUser: false,
              chatId: 'agent:chief:main',
              maxWidth: 360,
              onReply: () {},
              onReaction: (_) {},
            ),
          ),
        ),
      );
      await tester.pump();
      final TestGesture mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(find.text('Hello there')));
      await tester.pump(const Duration(milliseconds: 300));
      for (final String id in <String>['react', 'reply', 'more']) {
        expect(
          find.byKey(ValueKey<String>('bubble-hover-$id')),
          findsOneWidget,
        );
      }
      expect(find.byTooltip('Resend message'), findsNothing);
      expect(find.byTooltip('Retry response'), findsNothing);
    });

    testWidgets('a failed Agents turn is a quiet line, not a bubble', (
      tester,
    ) async {
      debugAgentsChatCoreOverride = true;
      addTearDown(() => debugAgentsChatCoreOverride = null);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: kTestLocalizationsDelegates,
          home: const Scaffold(
            body: MessageBubble(
              message: 'The model service did not answer for 30 min.',
              isUser: false,
              chatId: 'agent:chief:main',
              maxWidth: 360,
              turnFailed: true,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey<String>('agents-failed-turn-line')),
        findsOneWidget,
      );
      expect(
        decorationAround(
          tester,
          'The model service did not answer for 30 min.',
        ),
        isNull,
      );
      expect(find.byTooltip('Resend message'), findsNothing);
      expect(find.byTooltip('Retry response'), findsNothing);
    });

    testWidgets('only the final answer is in the bubble; interim folds', (
      tester,
    ) async {
      debugAgentsChatCoreOverride = true;
      addTearDown(() => debugAgentsChatCoreOverride = null);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: kTestLocalizationsDelegates,
          home: const Scaffold(
            body: MessageBubble(
              message: 'Nothing new.',
              isUser: false,
              chatId: 'agent:chief:main',
              maxWidth: 360,
              contentBlocks: <ContentBlock>[
                ContentBlock.reasoning('Check the mailbox.'),
                ContentBlock.text("I'll check the mailbox."),
                ContentBlock.reasoning('Mailbox is empty.'),
                ContentBlock.text('Nothing new.'),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      expect(
        find.textContaining('Nothing new.', findRichText: true),
        findsOneWidget,
      );
      // The interim line is folded into the closed work block.
      expect(
        find.textContaining("I'll check the mailbox.", findRichText: true),
        findsNothing,
      );
    });

    testWidgets('an answer with no text draws no empty bubble', (tester) async {
      debugAgentsChatCoreOverride = true;
      addTearDown(() => debugAgentsChatCoreOverride = null);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: kTestLocalizationsDelegates,
          home: const Scaffold(
            body: MessageBubble(
              message: '',
              isUser: false,
              chatId: 'agent:chief:main',
              maxWidth: 360,
              contentBlocks: <ContentBlock>[
                ContentBlock.reasoning('Nothing to say.'),
              ],
            ),
          ),
        ),
      );
      await tester.pump();
      expect(
        find.byWidgetPredicate(
          (Widget w) =>
              w is Container &&
              w.decoration is BoxDecoration &&
              (w.decoration! as BoxDecoration).color != null &&
              (w.decoration! as BoxDecoration).borderRadius != null &&
              w.padding == const EdgeInsets.fromLTRB(14, 6, 14, 6),
        ),
        findsNothing,
      );
    });

    testWidgets('no stamp on the bubble itself', (tester) async {
      debugAgentsChatCoreOverride = true;
      addTearDown(() => debugAgentsChatCoreOverride = null);
      await pumpBubble(tester, isUser: false, chatId: 'agent:chief:main');
      expect(find.textContaining('Today'), findsNothing);
    });
  });

  group('actions: no Resend, Retry only on a failed request', () {
    final MessageActionsHandler handler = MessageActionsHandler();

    List<String> ai({bool failed = false, bool agents = false}) => handler
        .buildActionsForMessage(
          index: 1,
          messageText: 'An answer',
          isUser: false,
          isStreaming: false,
          onEdit: (_) {},
          onResendMessage: (_) {},
          failed: failed,
          agentsThread: agents,
        )
        .map((MessageBubbleAction a) => a.label ?? a.tooltip)
        .toList();

    test('user messages never offer Resend', () {
      final List<String> labels = handler
          .buildUserMessageActions(index: 0, messageText: 'Hi', onEdit: (_) {})
          .map((MessageBubbleAction a) => a.label ?? a.tooltip)
          .toList();
      expect(labels, isNot(contains('Resend')));
      expect(labels, containsAll(<String>['Copy', 'Edit']));
    });

    test('a good answer has no Retry', () {
      expect(ai(), isNot(contains('Retry')));
    });

    test('a failed chuk_chat answer offers Retry', () {
      expect(ai(failed: true), contains('Retry'));
    });

    test('a failed Agents answer has no Retry: the host retries', () {
      expect(ai(failed: true, agents: true), isNot(contains('Retry')));
    });

    test('a run end notice row is recognised, marked or legacy', () {
      expect(
        isAgentsRunNoticeRow(<String, String>{'agentsNotice': '1'}),
        isTrue,
      );
      expect(
        isAgentsRunNoticeRow(<String, String>{
          'status': 'interrupted',
          'text': 'This run failed. No answer was written.',
        }),
        isTrue,
      );
      expect(
        isAgentsRunNoticeRow(<String, String>{
          'status': 'interrupted',
          'text': 'A real answer that was cut.',
        }),
        isFalse,
      );
    });

    test('the error mark is set and cleared on finalize', () {
      final Map<String, String> row = <String, String>{'text': 'x'};
      markTurnError(row, failed: true);
      expect(isTurnError(row), isTrue);
      markTurnError(row, failed: false);
      expect(isTurnError(row), isFalse);
    });
  });
}
