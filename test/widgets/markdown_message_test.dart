import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/widgets/markdown_message.dart';

void main() {
  Widget buildMarkdown(String text) {
    return MaterialApp(
      home: Scaffold(
        body: MarkdownMessage(
          text: text,
          textColor: Colors.black,
          backgroundColor: Colors.white,
          wrapWithSelectionArea: false,
        ),
      ),
    );
  }

  testWidgets('renders dollar amounts as literal text', (tester) async {
    const text =
        r'He sued Gawker and won a $140 million verdict, later settled for $31 million.';

    await tester.pumpWidget(buildMarkdown(text));

    expect(find.textContaining(r'$140 million', findRichText: true), findsOne);
    expect(find.textContaining(r'$31 million', findRichText: true), findsOne);
    expect(find.byType(Math), findsNothing);
  });

  testWidgets('still renders explicit escaped inline math', (tester) async {
    await tester.pumpWidget(buildMarkdown(r'The identity is \(x + y\).'));

    expect(find.byType(Math), findsOneWidget);
  });

  testWidgets('renders a table with dollar amounts without math spans', (
    tester,
  ) async {
    const text =
        '| App | Price |\n'
        '|---|---|\n'
        r'| SnapCalorie | $29/month, $149/year |'
        '\n'
        r'| Premium | $12.5/month |';

    await tester.pumpWidget(buildMarkdown(text));

    // Cell text stays literal — no dollar pair swallowed into a math span.
    expect(find.byType(Table), findsOneWidget);
    expect(
      find.textContaining(r'$29/month, $149/year', findRichText: true),
      findsOne,
    );
    expect(find.textContaining(r'$12.5/month', findRichText: true), findsOne);
    expect(find.byType(Math), findsNothing);
  });
}
