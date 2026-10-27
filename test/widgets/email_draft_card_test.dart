// Widget tests for the mail draft card an `<email>` block renders as.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/widgets/email_draft_card.dart';

void main() {
  testWidgets('shows head, subject, rows, body, status; Send calls back', (
    WidgetTester tester,
  ) async {
    int sends = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: SingleChildScrollView(
            child: SizedBox(
              width: 340,
              child: EmailDraftCard(
                to: 'team@example.com',
                cc: 'boss@example.com',
                from: 'me@example.com',
                subject: 'Weekly update',
                body: 'Hi all,\nhere is the update.',
                status: 'Needs approval',
                onSend: () => sends++,
              ),
            ),
          ),
        ),
      ),
    );
    for (final String t in <String>[
      'Mail',
      'Weekly update',
      'From',
      'me@example.com',
      'To',
      'team@example.com',
      'Cc',
      'boss@example.com',
      'Needs approval',
      'Copy',
      'Send',
    ]) {
      expect(find.text(t), findsOneWidget, reason: t);
    }
    expect(find.text('Hi all,\nhere is the update.'), findsOneWidget);
    expect(find.text('Bcc'), findsNothing);
    await tester.tap(find.text('Send'));
    expect(sends, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Copy puts the whole draft on the clipboard', (
    WidgetTester tester,
  ) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map<Object?, Object?>)['text'] as String?;
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
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EmailDraftCard(
            to: 'a@example.com',
            subject: 'Hallo',
            body: 'Text',
            onSend: () {},
          ),
        ),
      ),
    );
    // No status given: the pill says "Draft"; no subject row for From.
    expect(find.text('Draft'), findsOneWidget);
    expect(find.text('From'), findsNothing);
    await tester.tap(find.text('Copy'));
    await tester.pump();
    expect(copied, 'To: a@example.com\nSubject: Hallo\n\nText');
    expect(find.text('Draft copied'), findsOneWidget);
  });

  testWidgets('no subject shows the placeholder', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EmailDraftCard(to: '', subject: '', body: '', onSend: () {}),
        ),
      ),
    );
    expect(find.text('No subject'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
