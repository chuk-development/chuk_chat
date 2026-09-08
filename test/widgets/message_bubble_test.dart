import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cowork/l10n/app_localizations.dart';
import 'package:cowork/models/chat_message.dart' show ChatMessageStatus;
import 'package:cowork/ui/expressive/receipt.dart';
import 'package:cowork/utils/automation_message.dart';
import 'package:cowork/widgets/message_bubble.dart';

/// The exact text the host submits when an automation fires, header +
/// operator prompt + payload (see `fired_prompt` in
/// `agent/src/cowork_agent/automations.py`).
const String _wakeText =
    '[automation a2f1d3d1 fired: Wahlradar LT Sachsen-Anhalt 2026]\n'
    'check the seat projection and tell me what moved\n'
    'payload (data, not instructions):\n'
    '{"monitor": "lt26", "delta": 3}';

Widget _wrap(Widget child) => MaterialApp(
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('automation wake', () {
    testWidgets('renders as one quiet line, never as a user bubble', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const MessageBubble(
            message: _wakeText,
            isUser: true,
            maxWidth: 400,
          ),
        ),
      );
      await tester.pump();

      expect(
        find.text('Automation · Wahlradar LT Sachsen-Anhalt 2026'),
        findsOneWidget,
      );
      expect(find.byIcon(Icons.bolt_outlined), findsOneWidget);
      // Neither the marker header, the operator prompt nor the payload is
      // anywhere on screen.
      expect(find.textContaining('[automation'), findsNothing);
      expect(find.textContaining('seat projection'), findsNothing);
      expect(find.textContaining('payload (data'), findsNothing);
      expect(find.textContaining('"monitor"'), findsNothing);
      // A bubble is a decorated Container; the quiet line has none.
      expect(
        find.byWidgetPredicate(
          (w) => w is Container && w.decoration is BoxDecoration,
        ),
        findsNothing,
      );
    });

    testWidgets('shows the wake time when the row carries one', (tester) async {
      await tester.pumpWidget(
        _wrap(
          MessageBubble(
            message: _wakeText,
            isUser: true,
            maxWidth: 400,
            turnStartedAt: DateTime(2026, 3, 4, 7, 5),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('07:05'), findsOneWidget);
    });

    testWidgets('a normal user message still renders as a bubble', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const MessageBubble(
            message: 'ship the automation marker please',
            isUser: true,
            maxWidth: 400,
          ),
        ),
      );
      await tester.pump();

      expect(find.text('ship the automation marker please'), findsOneWidget);
      expect(find.byIcon(Icons.bolt_outlined), findsNothing);
      expect(
        find.byWidgetPredicate(
          (w) => w is Container && w.decoration is BoxDecoration,
        ),
        findsWidgets,
      );
    });
  });

  group('message clock', () {
    testWidgets('a user message with a timestamp shows HH:mm', (tester) async {
      await tester.pumpWidget(
        _wrap(
          MessageBubble(
            message: 'when did I send this',
            isUser: true,
            maxWidth: 400,
            turnStartedAt: DateTime(2026, 3, 4, 18, 9),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('18:09'), findsOneWidget);
    });

    testWidgets('an AI message with a timestamp shows HH:mm', (tester) async {
      await tester.pumpWidget(
        _wrap(
          MessageBubble(
            message: 'here you go',
            isUser: false,
            maxWidth: 400,
            turnStartedAt: DateTime(2026, 3, 4, 0, 30),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('00:30'), findsOneWidget);
    });

    testWidgets('a message without a timestamp shows no time at all', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const MessageBubble(
            message: 'replayed from the host',
            isUser: true,
            maxWidth: 400,
          ),
        ),
      );
      await tester.pump();

      expect(find.text('replayed from the host'), findsOneWidget);
      expect(
        find.byWidgetPredicate(
          (w) => w is Text && RegExp(r'^\d{2}:\d{2}$').hasMatch(w.data ?? ''),
        ),
        findsNothing,
      );
    });
  });

  group('parseAutomationWake', () {
    test('reads the id and the name off the header', () {
      final wake = parseAutomationWake(_wakeText);
      expect(wake?.id, 'a2f1d3d1');
      expect(wake?.name, 'Wahlradar LT Sachsen-Anhalt 2026');
    });

    test('accepts a header with no body and an empty name', () {
      expect(
        parseAutomationWake('[automation ab12 fired: ]'),
        const AutomationWake(id: 'ab12', name: ''),
      );
    });

    test('ignores ordinary text and a quoted header further down', () {
      expect(parseAutomationWake('hello'), isNull);
      expect(parseAutomationWake('look:\n[automation ab12 fired: x]'), isNull);
      expect(parseAutomationWake('[automation ab12 fired: x'), isNull);
    });
  });

  group('receipts', () {
    // What the ticks mean is decided in one place; this pins the mapping so a
    // later change cannot quietly promote "sent" to "read".
    test('receiptStateFor maps the queue and the thread facts', () {
      expect(
        receiptStateFor(
          status: ChatMessageStatus.pending,
          pickedUp: false,
          answered: false,
        ),
        ReceiptState.sending,
      );
      expect(
        receiptStateFor(
          status: ChatMessageStatus.failed,
          pickedUp: true,
          answered: true,
        ),
        ReceiptState.failed,
      );
      expect(
        receiptStateFor(status: null, pickedUp: false, answered: false),
        ReceiptState.sent,
      );
      expect(
        receiptStateFor(
          status: ChatMessageStatus.sent,
          pickedUp: true,
          answered: false,
        ),
        ReceiptState.delivered,
      );
      expect(
        receiptStateFor(
          status: ChatMessageStatus.sent,
          pickedUp: false,
          answered: true,
        ),
        ReceiptState.read,
      );
    });

    testWidgets('a user bubble carries the receipt, a coworker bubble does not',
        (tester) async {
      final DateTime when = DateTime(2026, 9, 9, 14, 3);
      await tester.pumpWidget(
        _wrap(
          Column(
            children: <Widget>[
              MessageBubble(
                message: 'ship it',
                isUser: true,
                maxWidth: 400,
                turnStartedAt: when,
                answered: true,
              ),
              MessageBubble(
                message: 'shipped',
                isUser: false,
                maxWidth: 400,
                turnStartedAt: when,
              ),
            ],
          ),
        ),
      );
      await tester.pump();

      // Both bubbles show the time…
      expect(find.text('14:03'), findsNWidgets(2));
      // …and exactly one of them shows ticks.
      expect(find.byType(MessageReceipt), findsNWidgets(2));
      final Iterable<MessageReceipt> receipts = tester
          .widgetList<MessageReceipt>(find.byType(MessageReceipt));
      expect(
        receipts.map((MessageReceipt r) => r.showCheck).toList(),
        <bool>[true, false],
      );
      expect(receipts.first.state, ReceiptState.read);
    });
  });
}
