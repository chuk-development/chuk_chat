// Layout of `::: tiles`: short labels as an aligned grid, anything with a
// subline or a sentence-long label as rows with the icon on the left.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/widgets/icons/huge_icon.dart';
import 'package:chuk_chat/widgets/markdown_message.dart';

Future<void> _pump(WidgetTester tester, String markdown, double width) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            child: SingleChildScrollView(
              child: MarkdownMessage(
                text: markdown,
                textColor: const Color(0xFF111111),
                backgroundColor: const Color(0xFFFFFFFF),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('short labels share one row, tops aligned', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      '::: tiles\nChatbot | chat\nCrawler | search\nSpiele | game\n:::',
      720,
    );
    final Rect a = tester.getRect(find.text('Chatbot'));
    final Rect b = tester.getRect(find.text('Crawler'));
    final Rect c = tester.getRect(find.text('Spiele'));
    expect((a.top - b.top).abs(), lessThan(1));
    expect((b.top - c.top).abs(), lessThan(1));
    expect(b.left, greaterThan(a.right));
    expect(tester.takeException(), isNull);
  });

  testWidgets('tiles with sublines become rows on one left edge', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      '::: tiles\n'
      'VulniPulse | shield | Echte Push-App für kritische CVEs\n'
      'Vulmon Alerts | search | Gratis-Feed per E-Mail, Slack, RSS\n'
      'n8n + ntfy | chart | Self-hosted, NVD-API und RSS\n'
      ':::',
      720,
    );
    final Rect a = tester.getRect(find.text('VulniPulse'));
    final Rect b = tester.getRect(find.text('Vulmon Alerts'));
    final Rect c = tester.getRect(find.text('n8n + ntfy'));
    expect((a.left - b.left).abs(), lessThan(1));
    expect((b.left - c.left).abs(), lessThan(1));
    expect(b.top, greaterThan(a.bottom));
    expect(c.top, greaterThan(b.bottom));
    // The subline sits under its own label, not floated elsewhere.
    final Rect sub = tester.getRect(
      find.text('Echte Push-App für kritische CVEs'),
    );
    expect((sub.left - a.left).abs(), lessThan(1));
    expect(sub.top, greaterThan(a.bottom - 1));
    expect(sub.bottom, lessThan(b.top));
    expect(find.byType(HugeIcon), findsNWidgets(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('a subline written into the icon slot is kept as text', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      '::: tiles\nVulniPulse | Echte Push-App für CVEs | shield\n:::',
      360,
    );
    expect(find.text('Echte Push-App für CVEs'), findsOneWidget);
    expect(find.byType(HugeIcon), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
