import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/widgets/agent_markdown.dart';

Widget _host(Widget child, {Brightness brightness = Brightness.light}) {
  return MaterialApp(
    theme: ThemeData(brightness: brightness),
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );
}

void main() {
  testWidgets('renders headings as text without the markdown syntax',
      (tester) async {
    await tester.pumpWidget(_host(const AgentMarkdown('# Report\n\nAll done.')));

    expect(find.text('Report', findRichText: true), findsOneWidget);
    expect(find.textContaining('# Report', findRichText: true), findsNothing);
  });

  testWidgets('renders a fenced code block without the backticks',
      (tester) async {
    const reply = 'Here it is:\n\n```python\nprint("hi")\n```\n';
    await tester.pumpWidget(_host(const AgentMarkdown(reply)));

    expect(find.textContaining('print', findRichText: true), findsWidgets);
    expect(find.textContaining('```', findRichText: true), findsNothing);
  });

  testWidgets('renders list items without the bullet syntax', (tester) async {
    await tester.pumpWidget(_host(const AgentMarkdown('- first\n- second\n')));

    expect(find.textContaining('first', findRichText: true), findsWidgets);
    expect(find.textContaining('- first', findRichText: true), findsNothing);
  });

  testWidgets('a half-streamed reply with an unclosed fence still renders',
      (tester) async {
    // Deltas arrive mid-block; the widget must not throw on partial Markdown.
    await tester.pumpWidget(_host(const AgentMarkdown('Working:\n\n```py\nx = 1')));

    expect(tester.takeException(), isNull);
    expect(find.textContaining('x = 1', findRichText: true), findsWidgets);
  });

  testWidgets('renders in a dark theme too', (tester) async {
    await tester.pumpWidget(
      _host(const AgentMarkdown('# Dark\n\n`code`'), brightness: Brightness.dark),
    );

    expect(tester.takeException(), isNull);
    expect(find.text('Dark', findRichText: true), findsOneWidget);
  });
}
