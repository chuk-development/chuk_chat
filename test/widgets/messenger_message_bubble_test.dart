import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/icon_finder.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/chat_message.dart';
import 'package:chuk_chat/services/settings/mobile_chat_preferences.dart';
import 'package:chuk_chat/models/content_block.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/widgets/agent_activity/agent_activity_timeline.dart';
import 'package:chuk_chat/widgets/message_bubble.dart';
import 'package:chuk_chat/widgets/sandbox_artifact_block.dart';
import 'package:chuk_chat/widgets/messenger_typing_indicator.dart';
import 'package:chuk_chat/widgets/markdown_message.dart';

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
  // Agents delivers files as file blocks; decode them as the Agents build
  // does (the default follows FEATURE_AGENTS, which tests leave off).
  ContentBlock.decodesFileBlocks = true;
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('reference menu reacts and copies the original message', (
    tester,
  ) async {
    String? reaction;
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = call.arguments['text'] as String;
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

  // The answer goes through chuk_chat's renderer, trimmed as chuk_chat trims
  // it.
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
            (widget) =>
                widget is MarkdownMessage && widget.text == markdown.trim(),
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
      expect(find.text('Thinking...', findRichText: true), findsNothing);
      expect(find.byType(MessengerTypingIndicator), findsOneWidget);
      await tester.tap(find.byTooltip('Previous answer'));
      expect(previous, isTrue);
    },
  );

  testWidgets('the user bubble is chuk_chat\'s bubble, with no clock', (
    tester,
  ) async {
    BorderRadius radiiOf() {
      final Container container = tester.widget<Container>(
        find
            .byWidgetPredicate(
              (widget) =>
                  widget is Container && widget.decoration is BoxDecoration,
            )
            .first,
      );
      expect(
        container.padding,
        const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      );
      return (container.decoration! as BoxDecoration).borderRadius!
          as BorderRadius;
    }

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
    BorderRadius radii = radiiOf();
    expect(radii.topLeft, const Radius.circular(16));
    expect(radii.topRight, const Radius.circular(16));
    expect(radii.bottomRight, const Radius.circular(16));

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
    radii = radiiOf();
    expect(radii.bottomRight, const Radius.circular(5));
    expect(find.text('12:34'), findsNothing);
    expect(find.text('11:20'), findsNothing);
    expect(findIcon(Icons.done_all), findsNothing);
  });

  testWidgets('outgoing messenger text is at most 80 percent wide', (
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
    expect(tester.getSize(container.first).width, lessThanOrEqualTo(400 * .8));
  });

  testWidgets('an incoming answer draws no bubble behind it', (tester) async {
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
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Container && widget.decoration is BoxDecoration,
      ),
      findsNothing,
    );
    expect(find.text('Ja.', findRichText: true), findsOneWidget);
  });

  testWidgets('a new live turn does not animate in', (tester) async {
    await tester.pumpWidget(
      wrap(
        const MessageBubble(
          message: 'Hallo',
          isUser: false,
          messengerMode: true,
          showToolCalls: false,
          isStreamingMessage: true,
        ),
      ),
    );
    await tester.pump();
    final Offset first = tester.getTopLeft(
      find.text('Hallo', findRichText: true),
    );
    await tester.pump(const Duration(milliseconds: 180));
    expect(tester.getTopLeft(find.text('Hallo', findRichText: true)), first);
    expect(
      find.descendant(
        of: find.byType(MessageBubble),
        matching: find.byType(Opacity),
      ),
      findsNothing,
    );
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
    // No divider any more: the menu is a run of separate tiles, the same
    // surface every dropdown uses (MenuTileGroup). Reply and Copy, with Edit
    // gone (bead cowork-9edt).
    expect(find.byType(Divider), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('context_message_actions')),
        matching: find.byType(Material),
      ),
      findsNWidgets(2),
    );
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

  testWidgets('Show thinking off hides a thought block', (tester) async {
    // The phone thread's "Show thinking" switch: off drops the reasoning the
    // host sends as a content block, and there is nothing else to draw.
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
    expect(find.textContaining('Internal plan'), findsNothing);
    expect(find.textContaining('Worked'), findsNothing);
  });

  testWidgets('a host turn hides the Thinking placeholder beside its blocks', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        const MessageBubble(
          message: 'Thinking...',
          isUser: false,
          messengerMode: true,
          showToolCalls: true,
          showReasoningTokens: false,
          isStreamingMessage: true,
          contentBlocks: [ContentBlock.reasoning('Internal plan')],
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Thinking...', findRichText: true), findsNothing);
    expect(find.textContaining('Internal plan'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('Show thinking on draws a thought block in the timeline', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        const MessageBubble(
          message: '',
          isUser: false,
          messengerMode: true,
          showToolCalls: true,
          showReasoningTokens: true,
          contentBlocks: [ContentBlock.reasoning('Internal plan')],
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(AgentActivityTimeline), findsOneWidget);
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

  testWidgets('an interrupted turn keeps its place even with an empty body', (
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
          onContinueGeneration: () {},
          contentBlocks: [
            ContentBlock.toolCalls([
              ToolCall(name: 'terminal', status: ToolCallStatus.completed),
            ]),
          ],
        ),
      ),
    );
    await tester.pump();
    // A break-off is worth showing: the same turn without it collapses into
    // the quiet line. Here the way to continue stays on screen.
    expect(find.textContaining('Worked'), findsNothing);
    expect(find.text('Continue generation'), findsOneWidget);
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
    expect(find.text('Worked · 1 step'), findsOneWidget);
  });

  testWidgets('details show the work as chuk_chat shows it', (
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
    expect(find.byType(AgentActivityTimeline), findsOneWidget);
    expect(find.text('…'), findsNothing);
  });

  testWidgets('streaming with Activity off keeps the answer and no dots', (
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
    // The answer is readable, so no dots hang under it (bead cowork-i7sd).
    expect(find.byType(MessengerTypingIndicator), findsNothing);
    expect(
      find.textContaining('Hier ist deine Antwort.', findRichText: true),
      findsOneWidget,
    );
  });

  testWidgets('a live thought shows the timeline, not typing dots', (
    tester,
  ) async {
    await tester.pumpWidget(
      wrap(
        const MessageBubble(
          message: '',
          isUser: false,
          messengerMode: true,
          showToolCalls: false,
          showReasoningTokens: true,
          isStreamingMessage: true,
          isReasoningStreaming: true,
          contentBlocks: [ContentBlock.reasoning('Internal plan')],
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(AgentActivityTimeline), findsOneWidget);
    expect(find.byType(MessengerTypingIndicator), findsNothing);
    // The widgets above build no timers that outlive the tree.
    await tester.pumpWidget(const SizedBox());
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
