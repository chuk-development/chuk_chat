// OpenUI fences in an assistant answer: drawn as native views, never as
// code; actions send a chat message; links are filtered; form values
// survive a rebuild. See docs/OPENUI.md, "Chat integration".

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/openui/openui.dart';
import 'package:chuk_chat/widgets/message_bubble.dart';
import 'package:chuk_chat/widgets/openui_message_block.dart';

Finder _rich(String text) => find.textContaining(text, findRichText: true);

Widget _app(Widget child) => MaterialApp(
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

const String _closed =
    'Intro text\n\n'
    '```openui-lang\n'
    'root = Card([t, b])\n'
    't = TextContent("Inside the view")\n'
    'b = Button("Go on")\n'
    '```\n\n'
    'Outro text';

void main() {
  setUp(OpenUiViewMemory.clear);

  testWidgets('a closed fence renders as a view, text around as markdown', (
    tester,
  ) async {
    final sent = <String>[];
    await tester.pumpWidget(
      _app(
        MessageBubble(
          message: _closed,
          isUser: false,
          messageId: 'm1',
          onOpenUiMessage: sent.add,
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(OpenUiView), findsOneWidget);
    expect(_rich('Intro text'), findsOneWidget);
    expect(_rich('Outro text'), findsOneWidget);
    expect(_rich('Inside the view'), findsOneWidget);
    // Never the raw program, never a code block.
    expect(_rich('root = Card'), findsNothing);
    expect(_rich('openui-lang'), findsNothing);
    expect(tester.takeException(), isNull);

    final view = tester.widget<OpenUiView>(find.byType(OpenUiView));
    expect(view.isStreaming, isFalse);

    await tester.tap(find.text('Go on'));
    await tester.pump();
    expect(sent, <String>['Go on']);
  });

  testWidgets('an unclosed fence streams live, without raw code', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const MessageBubble(
          message:
              'Here it comes\n```openui-lang\n'
              'root = Card([t])\nt = TextContent("Partial view")\nu = Te',
          isUser: false,
          isStreamingMessage: true,
          messageId: 'm2',
        ),
      ),
    );
    await tester.pump();

    final view = tester.widget<OpenUiView>(find.byType(OpenUiView));
    expect(view.isStreaming, isTrue);
    expect(_rich('Here it comes'), findsOneWidget);
    expect(_rich('Partial view'), findsOneWidget);
    expect(_rich('root ='), findsNothing);
    expect(_rich('u = Te'), findsNothing);
  });

  testWidgets('a half fence line is hidden while streaming', (tester) async {
    await tester.pumpWidget(
      _app(
        const MessageBubble(
          message: 'Almost there\n```openui',
          isUser: false,
          isStreamingMessage: true,
        ),
      ),
    );
    await tester.pump();
    expect(_rich('Almost there'), findsOneWidget);
    expect(_rich('```'), findsNothing);
    expect(_rich('openui'), findsNothing);
  });

  testWidgets('rich tags keep working next to a fence', (tester) async {
    await tester.pumpWidget(
      _app(
        const MessageBubble(
          message:
              '<image>{"url":"https://example.com/a.jpg","caption":"A caption"}'
              '</image>\n\n```openui-lang\nroot = Card([t])\n'
              't = TextContent("View text")\n```',
          isUser: false,
        ),
      ),
    );
    await tester.pump();
    expect(find.text('A caption'), findsOneWidget);
    expect(_rich('View text'), findsOneWidget);
    expect(find.byType(OpenUiView), findsOneWidget);
  });

  testWidgets('the memory gives a rebuilt view its old form values', (
    tester,
  ) async {
    final entry = OpenUiViewMemory.entry('m3#0');
    entry.forms.form('contact').setValue('name', 'Ada');

    await tester.pumpWidget(
      _app(
        const MessageBubble(message: _closed, isUser: false, messageId: 'm3'),
      ),
    );
    await tester.pump();
    final view = tester.widget<OpenUiView>(find.byType(OpenUiView));
    expect(identical(view.forms, entry.forms), isTrue);
    expect(view.forms!.form('contact').value('name'), 'Ada');

    // A second program in the same message gets its own entry.
    expect(identical(OpenUiViewMemory.entry('m3#1'), entry), isFalse);
  });

  group('ChatOpenUiActionHandler', () {
    test('sends the composed message', () {
      final sent = <String>[];
      final handler = ChatOpenUiActionHandler(onSend: sent.add);
      handler.sendToAssistant(
        'Submit',
        context: 'Book it',
        formValues: const <String, Object?>{'name': 'Ada', 'guests': 2},
      );
      expect(sent, <String>[
        OpenUiActionHandler.composeMessage(
          'Submit',
          context: 'Book it',
          formValues: const <String, Object?>{'name': 'Ada', 'guests': 2},
        ),
      ]);
      expect(sent.single, contains('- name: Ada'));
      expect(sent.single, contains('Context: Book it'));
    });

    test('an empty message is not sent', () {
      final sent = <String>[];
      ChatOpenUiActionHandler(onSend: sent.add).sendToAssistant('  ');
      expect(sent, isEmpty);
    });

    test('opens only http, https, mailto and tel', () async {
      final opened = <Uri>[];
      final handler = ChatOpenUiActionHandler(
        launch: (uri) async => opened.add(uri),
      );
      for (final url in <String>[
        'https://example.com/a',
        'http://example.com',
        'mailto:ada@example.com',
        'tel:+41613174000',
        'javascript:alert(1)',
        'file:///etc/passwd',
        'intent://x#Intent;end',
        'https://',
        'mailto:',
        'not a url',
      ]) {
        handler.openUrl(url);
      }
      await Future<void>.delayed(Duration.zero);
      expect(opened.map((u) => u.toString()), <String>[
        'https://example.com/a',
        'http://example.com',
        'mailto:ada@example.com',
        'tel:+41613174000',
      ]);
    });
  });
}
