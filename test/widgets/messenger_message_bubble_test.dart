import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/icon_finder.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cowork/l10n/app_localizations.dart';
import 'package:cowork/models/chat_message.dart';
import 'package:cowork/services/settings/mobile_chat_preferences.dart';
import 'package:cowork/models/content_block.dart';
import 'package:cowork/models/tool_call.dart';
import 'package:cowork/widgets/agent_activity/agent_activity_timeline.dart';
import 'package:cowork/widgets/message_bubble.dart';
import 'package:cowork/widgets/sandbox_artifact_block.dart';
import 'package:cowork/widgets/messenger_typing_indicator.dart';
import 'package:cowork/widgets/markdown_message.dart';
import 'package:cowork/ui/expressive/message_stamp.dart';

Widget wrap(Widget child) => MaterialApp(
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
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('reference menu reacts and copies the original message', (
    tester,
  ) async {
    String? reaction;
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData')
          copied = call.arguments['text'] as String;
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
      wrap(
        MessageBubble(
          message: 'Original **message**',
          isUser: true,
          messengerMode: true,
          onReply: () {},
          onEditRequested: () {},
          onReaction: (value) => reaction = value,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Original **message**'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('context_reactions')), findsOneWidget);
    expect(find.text('Copy'), findsOneWidget);
    await tester.tap(find.text('👍'));
    await tester.pumpAndSettle();
    expect(reaction, '👍');
    await tester.longPress(find.text('Original **message**'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    expect(copied, 'Original **message**');
  });

  for (final markdown in [
    'Setext heading\n===',
    '~~strikethrough~~',
    '    indented code',
    '**bold** and _emphasis_',
    '- one\n- two',
    '1. first\n2. second',
    '[Spotify](https://open.spotify.com/search/A%20B/tracks)',
    '| Name | Value |\n| --- | --- |\n| A | 1 |',
    '```text\ncode\n```',
    '# Heading',
  ]) {
    testWidgets(
      'assistant always uses Markdown renderer: ${markdown.split('\n').first}',
      (tester) async {
        await tester.pumpWidget(
          wrap(
            MessageBubble(
              message: markdown,
              isUser: false,
              messengerMode: true,
              showToolCalls: false,
            ),
          ),
        );
        await tester.pump();
        expect(
          find.byWidgetPredicate(
            (widget) => widget is MarkdownMessage && widget.text == markdown,
          ),
          findsOneWidget,
        );
        expect(find.byType(MessengerTypingIndicator), findsNothing);
      },
    );
  }

  testWidgets(
    'an answer already on screen carries no second typing indicator',
    (tester) async {
      await tester.pumpWidget(
        wrap(
          const MessageBubble(
            message: 'Die erste Antwort ist schon da.',
            isUser: false,
            messengerMode: true,
            showToolCalls: false,
            isStreamingMessage: true,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 180));
      final answer = find.byKey(const ValueKey('messenger-answer-bubble'));
      expect(tester.getSize(answer).width, 800);
      // Dots mean "nothing to read yet". The first token is on screen, so a
      // second indicator under it would only hang there (bead cowork-i7sd).
      expect(find.byType(MessengerTypingIndicator), findsNothing);
      expect(
        find.textContaining(
          'Die erste Antwort ist schon da.',
          findRichText: true,
        ),
        findsOneWidget,
      );
      await tester.pumpWidget(
        wrap(
          const MessageBubble(
            message: 'Die erste Antwort ist schon da.',
            isUser: false,
            messengerMode: true,
            showToolCalls: false,
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(MessengerTypingIndicator), findsNothing);
    },
  );

  testWidgets(
    'waiting has no empty full-width answer and keeps version controls',
    (tester) async {
      var previous = false;
      await tester.pumpWidget(
        wrap(
          MessageBubble(
            message: 'Thinking...',
            isUser: false,
            messengerMode: true,
            showToolCalls: false,
            isStreamingMessage: true,
            variantCount: 2,
            variantIndex: 1,
            onPrevVariant: () => previous = true,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 180));
      expect(
        find.byKey(const ValueKey('messenger-answer-bubble')),
        findsNothing,
      );
      expect(find.byType(MessengerTypingIndicator), findsOneWidget);
      await tester.tap(find.byTooltip('Previous answer'));
      expect(previous, isTrue);
    },
  );

  testWidgets('compact grouped bubble puts actual time on the last text line', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        MessageBubble(
          message: 'Hallo',
          isUser: true,
          messengerMode: true,
          startsNewGroup: false,
          endsGroup: false,
          sentAt: DateTime(2026, 9, 10, 12, 34),
        ),
      ),
    );
    await tester.pump();
    var container = tester.widget<Container>(
      find
          .byWidgetPredicate(
            (widget) =>
                widget is Container && widget.decoration is BoxDecoration,
          )
          .first,
    );
    final radii =
        (container.decoration! as BoxDecoration).borderRadius! as BorderRadius;
    expect(radii.topLeft, const Radius.circular(22));
    expect(radii.topRight, const Radius.circular(7));
    expect(radii.bottomRight, const Radius.circular(7));
    expect(
      container.padding,
      const EdgeInsets.symmetric(horizontal: 15, vertical: 9),
    );
    expect(find.byType(MessageStamp), findsNothing);

    await tester.pumpWidget(
      wrap(
        MessageBubble(
          message: 'Hallo',
          isUser: true,
          messengerMode: true,
          sentAt: DateTime(2026, 9, 10, 12, 34),
          turnStartedAt: DateTime(2026, 9, 10, 11, 20),
        ),
      ),
    );
    await tester.pump();
    final stamp = find.descendant(
      of: find.byType(Positioned),
      matching: find.byType(MessageStamp),
    );
    expect(tester.widget<MessageStamp>(stamp).time, '12:34');
    final body = find.byWidgetPredicate(
      (widget) => widget is Text && widget.textSpan != null,
    );
    expect(
      tester.getRect(stamp).bottom,
      closeTo(tester.getRect(body).bottom, 0.1),
    );
    expect(tester.getSize(find.byType(MessageBubble)).height, lessThan(65));
    expect(findIcon(Icons.done_all), findsNothing);
  });

  testWidgets('outgoing messenger text is at most 72 percent wide', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      wrap(
        MessageBubble(
          message: List.filled(25, 'Nachricht').join(' '),
          isUser: true,
          messengerMode: true,
          showToolCalls: false,
        ),
      ),
    );
    await tester.pump();
    final container = find.byWidgetPredicate(
      (widget) => widget is Container && widget.decoration is BoxDecoration,
    );
    expect(tester.getSize(container.first).width, lessThanOrEqualTo(400 * .72));
    expect(find.byType(MessageStamp), findsNothing);
  });

  testWidgets('even a short incoming bubble fills the available chat lane', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: MessageBubble(
            message: 'Ja.',
            isUser: false,
            messengerMode: true,
            showToolCalls: false,
          ),
        ),
      ),
    );
    await tester.pump();
    final container = find.byWidgetPredicate(
      (widget) => widget is Container && widget.decoration is BoxDecoration,
    );
    expect(tester.getSize(container.first).width, 800 - 32);
    expect(tester.getTopLeft(container.first).dx, 16);
  });

  testWidgets('only a new live turn enters once and reduced motion opts out', (
    tester,
  ) async {
    Widget message(
      String text, {
      bool live = true,
      bool reduced = false,
      Key? key,
    }) => wrap(
      MediaQuery(
        data: MediaQueryData(disableAnimations: reduced),
        child: MessageBubble(
          key: key,
          message: text,
          isUser: false,
          messengerMode: true,
          showToolCalls: false,
          isStreamingMessage: live,
        ),
      ),
    );
    final entrance = find.byKey(const ValueKey('messenger-message-entrance'));
    await tester.pumpWidget(message('Historie', live: false));
    await tester.pump();
    expect(entrance, findsNothing);
    await tester.pumpWidget(message('Hallo', key: const ValueKey('live')));
    await tester.pump();
    expect(entrance, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 180));
    final before = tester.getTopLeft(find.text('Hallo', findRichText: true));
    await tester.pumpWidget(message('Hallo Welt', key: const ValueKey('live')));
    expect(
      tester.getTopLeft(find.text('Hallo Welt', findRichText: true)),
      before,
    );
    await tester.pumpWidget(
      message('Ohne Bewegung', reduced: true, key: const ValueKey('reduced')),
    );
    await tester.pump();
    expect(entrance, findsNothing);
  });

  testWidgets('user long press offers Reply and Copy, never Edit', (
    tester,
  ) async {
    var edited = false;
    await tester.pumpWidget(
      wrap(
        MessageBubble(
          message: 'Meine Nachricht',
          isUser: true,
          messengerMode: true,
          onEditRequested: () => edited = true,
          onReply: () {},
          userMessageActions: [
            MessageBubbleAction(
              icon: Icons.copy,
              tooltip: 'Nachricht kopieren',
              onPressed: () {},
            ),
          ],
        ),
      ),
    );
    await tester.pump();
    expect(find.byTooltip('Nachricht kopieren'), findsNothing);
    await tester.longPress(find.text('Meine Nachricht'));
    await tester.pumpAndSettle();
    expect(find.text('Reply'), findsOneWidget);
    expect(
      find.byKey(const ValueKey('context_message_preview')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('context_message_preview')),
        matching: find.byWidgetPredicate(
          (widget) =>
              widget is Material && widget.type == MaterialType.transparency,
        ),
      ),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey('context_message_actions')),
      findsOneWidget,
    );
    // One divider now: Reply and Copy, with Edit gone (bead cowork-9edt).
    expect(find.byType(Divider), findsOneWidget);
    expect(find.byTooltip('Nachricht kopieren'), findsNothing);
    // The entry is not there, and the callback behind it is never reached.
    expect(find.text('Edit'), findsNothing);
    expect(find.text('Copy'), findsOneWidget);
    await tester.tap(find.text('Copy'));
    await tester.pumpAndSettle();
    expect(edited, isFalse);
    expect(find.byTooltip('Nachricht kopieren'), findsNothing);
  });

  testWidgets('completed internal-only turn leaves no empty bubble', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        const MessageBubble(
          message: '',
          isUser: false,
          messengerMode: true,
          showToolCalls: false,
          contentBlocks: [ContentBlock.reasoning('Internal plan')],
        ),
      ),
    );
    await tester.pump();
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Container && widget.decoration is BoxDecoration,
      ),
      findsNothing,
    );
  });

  // Every case below used to walk past the hand-kept suppression list in
  // `_buildAiBubble` and draw a bubble whose body rendered nothing — the
  // unexplained empty block on the phone (bead cowork-2rda). The bubble is
  // now decided by what the body actually rendered, so each of them either
  // disappears or becomes the one quiet "Worked" line.

  testWidgets('an internal-only turn leaves no empty bubble with Activity on', (
    tester,
  ) async {
    // The everyday case: Activity on, Thinking off. The reasoning block is
    // filtered out by the Thinking toggle and there is nothing else to draw.
    await tester.pumpWidget(
      wrap(
        const MessageBubble(
          message: '',
          isUser: false,
          messengerMode: true,
          showToolCalls: true,
          showReasoningTokens: false,
          contentBlocks: [ContentBlock.reasoning('Internal plan')],
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('messenger-answer-bubble')), findsNothing);
    expect(find.textContaining('Worked'), findsNothing);
  });

  testWidgets('a failed tool with Activity off says so instead of a blank', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        MessageBubble(
          message: '',
          isUser: false,
          messengerMode: true,
          showToolCalls: false,
          contentBlocks: [
            ContentBlock.toolCalls([
              ToolCall(name: 'terminal', status: ToolCallStatus.error),
            ]),
          ],
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('messenger-answer-bubble')), findsNothing);
    expect(find.text('Worked · 1 step · 1 failed'), findsOneWidget);
  });

  testWidgets('the quiet work line turns the details back on when tapped', (
    tester,
  ) async {
    // Never AWAIT the shared preference object here. It is a singleton, its
    // serialized writer is a future created in whichever test's async zone
    // touched it first, and a widget test's zone dies with the test — so
    // awaiting `setActivity` from a later test, or from a tear-down, waits
    // forever on a microtask no one will ever run, and no test timeout breaks
    // that. Setting the field is synchronous, and the tap only has to reach
    // `notifyListeners`, which `setActivity` does before it writes.
    final MobileChatPreferences prefs = MobileChatPreferences.instance;
    prefs.showActivity = false;
    addTearDown(() => prefs.showActivity = false);
    await tester.pumpWidget(
      wrap(
        MessageBubble(
          message: '',
          isUser: false,
          messengerMode: true,
          showToolCalls: false,
          contentBlocks: [
            ContentBlock.toolCalls([
              ToolCall(name: 'terminal', status: ToolCallStatus.completed),
              ToolCall(name: 'read_file', status: ToolCallStatus.completed),
            ]),
          ],
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Worked · 2 steps'), findsOneWidget);
    await tester.tap(find.text('Worked · 2 steps'));
    await tester.pumpAndSettle();
    // The store round trip behind the flag settles over a few event-loop
    // turns; the flag itself is set before it.
    await tester.pump(const Duration(milliseconds: 50));
    expect(prefs.showActivity, isTrue);
  });

  testWidgets('an interrupted turn keeps its bubble even with an empty body', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        MessageBubble(
          message: '',
          isUser: false,
          messengerMode: true,
          showToolCalls: false,
          status: ChatMessageStatus.interrupted,
          contentBlocks: [
            ContentBlock.toolCalls([
              ToolCall(name: 'terminal', status: ToolCallStatus.completed),
            ]),
          ],
        ),
      ),
    );
    await tester.pump();
    // A break-off is worth showing: the same turn without it collapses.
    expect(
      find.byKey(const ValueKey('messenger-answer-bubble')),
      findsOneWidget,
    );
  });

  testWidgets('an ask_user without options is not a reason for a bubble', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        MessageBubble(
          message: '',
          isUser: false,
          messengerMode: true,
          showToolCalls: false,
          onAskUserAnswer: (_) {},
          contentBlocks: [
            ContentBlock.toolCalls([
              ToolCall(
                name: 'ask_user',
                status: ToolCallStatus.completed,
                arguments: const {'options': <String>[]},
              ),
            ]),
          ],
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('messenger-answer-bubble')), findsNothing);
    expect(find.text('Worked · 1 step'), findsOneWidget);
  });

  testWidgets('reasoning on a content-block row does not keep a blank bubble', (
    tester,
  ) async {
    // `_hasReasoning` is true here, but the content-blocks layout never draws
    // the flat `reasoning` field — only reasoning BLOCKS — so the body is
    // still empty.
    await tester.pumpWidget(
      wrap(
        MessageBubble(
          message: '',
          reasoning: 'Private plan',
          isUser: false,
          messengerMode: true,
          showToolCalls: false,
          showReasoningTokens: true,
          contentBlocks: [
            ContentBlock.toolCalls([
              ToolCall(name: 'terminal', status: ToolCallStatus.completed),
            ]),
          ],
        ),
      ),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('messenger-answer-bubble')), findsNothing);
    expect(find.text('Worked · 1 step'), findsOneWidget);
  });

  testWidgets('details can be enabled without enabling reasoning', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        MessageBubble(
          message: 'Fertig',
          isUser: false,
          messengerMode: true,
          showToolCalls: true,
          showReasoningTokens: false,
          toolCalls: [
            ToolCall(
              name: 'terminal',
              status: ToolCallStatus.completed,
              roundThinking: 'Internal plan',
            ),
          ],
        ),
      ),
    );
    await tester.pump();
    final timeline = tester.widget<AgentActivityTimeline>(
      find.byType(AgentActivityTimeline),
    );
    expect(timeline.steps, hasLength(1));
    expect(find.text('…'), findsNothing);
  });

  testWidgets('quiet streaming hides work and reasoning but keeps answer', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        MessageBubble(
          message: 'Hier ist deine Antwort.',
          reasoning: 'Private reasoning',
          isUser: false,
          messengerMode: true,
          showToolCalls: false,
          isStreamingMessage: true,
          contentBlocks: [
            const ContentBlock.reasoning('Private reasoning'),
            ContentBlock.toolCalls([
              ToolCall(name: 'terminal', status: ToolCallStatus.completed),
            ]),
            const ContentBlock.text('Hier ist deine Antwort.'),
          ],
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(AgentActivityTimeline), findsNothing);
    expect(find.textContaining('Private reasoning'), findsNothing);
    // The answer is readable, so no dots hang under it (bead cowork-i7sd).
    expect(find.byType(MessengerTypingIndicator), findsNothing);
    expect(
      find.textContaining('Hier ist deine Antwort.', findRichText: true),
      findsOneWidget,
    );
  });

  testWidgets('waiting hides placeholder and block reasoning', (tester) async {
    await tester.pumpWidget(
      wrap(
        const MessageBubble(
          message: 'Thinking...',
          isUser: false,
          messengerMode: true,
          showToolCalls: false,
          isReasoningStreaming: true,
          contentBlocks: [ContentBlock.reasoning('Internal plan')],
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(MessengerTypingIndicator), findsOneWidget);
    expect(find.text('Thinking...', findRichText: true), findsNothing);
    expect(find.byType(AgentActivityTimeline), findsNothing);
  });

  testWidgets('tool visibility never hides an interactive choice', (
    tester,
  ) async {
    String? answer;
    await tester.pumpWidget(
      wrap(
        MessageBubble(
          message: 'Welche Variante?',
          isUser: false,
          messengerMode: true,
          showToolCalls: false,
          toolCalls: [
            ToolCall(
              name: 'ask_user',
              status: ToolCallStatus.completed,
              arguments: {
                'options': ['Kurz', 'Ausführlich'],
              },
            ),
          ],
          onAskUserAnswer: (value) => answer = value,
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(AgentActivityTimeline), findsNothing);
    await tester.tap(find.text('1. Kurz'));
    expect(answer, 'Kurz');
  });

  testWidgets('a failed tool does not put a warning under the answer', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        MessageBubble(
          message: 'Der Preis ist 129,90 EUR.',
          isUser: false,
          messengerMode: true,
          showToolCalls: false,
          toolCalls: [ToolCall(name: 'terminal', status: ToolCallStatus.error)],
        ),
      ),
    );
    await tester.pump();
    // The turn answered. One tool call that failed on the way is not a
    // failure the reader has to be told about (bead cowork-wsev).
    expect(
      find.text('Eine Aktion konnte nicht abgeschlossen werden.'),
      findsNothing,
    );
    expect(find.text('Der Preis ist 129,90 EUR.'), findsOneWidget);
  });

  testWidgets('legacy presentation still supports detailed work', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        const MessageBubble(
          message: 'Antwort',
          isUser: false,
          contentBlocks: [ContentBlock.reasoning('Reasoning detail')],
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(AgentActivityTimeline), findsOneWidget);
    expect(find.text('…'), findsNothing);
  });

  testWidgets('file handoff survives hidden technical details', (tester) async {
    await tester.pumpWidget(
      wrap(
        const MessageBubble(
          message: '',
          isUser: false,
          messengerMode: true,
          showToolCalls: false,
          contentBlocks: [
            ContentBlock.sandboxArtifact(
              SandboxArtifactPayload(
                storagePath: 'user/file.enc',
                filename: 'Ergebnis.txt',
                mime: 'text/plain',
                sizeBytes: 12,
              ),
            ),
          ],
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(SandboxArtifactBlock), findsOneWidget);
  });

  testWidgets('message actions are available by long press', (tester) async {
    var replied = false;
    await tester.pumpWidget(
      wrap(
        MessageBubble(
          message: 'Hallo!',
          useSharedSelectionArea: true,
          isUser: false,
          messengerMode: true,
          onReply: () => replied = true,
          actions: [
            MessageBubbleAction(
              icon: Icons.copy,
              tooltip: 'Kopieren',
              onPressed: () {},
            ),
          ],
        ),
      ),
    );
    await tester.pump();
    expect(find.byTooltip('Kopieren'), findsNothing);
    await tester.longPress(find.text('Hallo!', findRichText: true));
    await tester.pumpAndSettle();
    expect(find.text('Edit'), findsNothing);
    expect(find.byTooltip('Kopieren'), findsNothing);
    await tester.tap(find.text('Reply'));
    await tester.pumpAndSettle();
    expect(replied, isTrue);
  });

  testWidgets(
    'interrupted answer keeps continuation and no working indicator',
    (tester) async {
      var continued = false;
      await tester.pumpWidget(
        wrap(
          MessageBubble(
            message: 'Teilantwort',
            isUser: false,
            messengerMode: true,
            status: ChatMessageStatus.interrupted,
            onContinueGeneration: () => continued = true,
          ),
        ),
      );
      await tester.pump();
      expect(find.text('…'), findsNothing);
      await tester.tap(find.text('Continue generation'));
      expect(continued, isTrue);
    },
  );
}
