import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/widgets/agent_markdown.dart';
import 'package:chuk_chat/widgets/chat_document_inline.dart';
import 'package:chuk_chat/widgets/chat_document_view.dart';
import 'package:chuk_chat/widgets/html_artifact_view.dart';

/// An HTML page (docs/PAGES.md) is shown in the web view path, never parsed as
/// markdown, and the thread keeps the compact row for it.
void main() {
  const Map<String, dynamic> page = <String, dynamic>{
    'id': 'btc',
    'title': 'BTC dashboard',
    'kind': 'html',
    'version': 2,
    'text': '<!doctype html><h1>BTC</h1>',
  };

  testWidgets('the reader shows an html page in the html view', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 600,
            child: ChatDocumentView(document: page),
          ),
        ),
      ),
    );
    expect(find.byType(HtmlArtifactView), findsOneWidget);
    expect(find.byType(AgentMarkdown), findsNothing);
    expect(find.textContaining('HTML page'), findsOneWidget);
  });

  test('the thread does not draw an html page inline', () {
    expect(documentIsHtml(page), isTrue);
    expect(inlineDocumentHasContent(page), isFalse);
    expect(
      inlineDocumentHasContent(<String, dynamic>{
        'kind': 'markdown',
        'text': '# Notes',
      }),
      isTrue,
    );
  });
}
