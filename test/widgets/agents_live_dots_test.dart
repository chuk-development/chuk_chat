import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/content_block.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/services/agents/agents_chat_core.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/services/agents/agents_run_ledger.dart';
import 'package:chuk_chat/services/storage/chat_origin.dart';
import 'package:chuk_chat/widgets/message_bubble.dart';

import '../support/fake_relay_controller.dart';

/// bead chuk_chat-hfru: while an Agents turn runs, the thread shows the
/// three typing dots and no status words. A tap opens every step, read live
/// from the run ledger, with its arguments, its result and the thinking.
void main() {
  const String key = 'amber-otter-2';
  final AgentsRunLedger ledger = AgentsRunLedger.instance;
  final AgentsRelayLink link = AgentsRelayLink.instance;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    debugAgentsChatCoreOverride = true;
    ChatOrigin.claimAgentsThread(key);
    ledger.reset();
    link.reset();
    final FakeRelayController controller = FakeRelayController();
    controller.set(
      const AgentsRelayState(
        phase: AgentsRelayPhase.paired,
        peerDeviceId: 'host',
      ),
    );
    link.bind(controller);
  });

  tearDown(() {
    ledger.reset();
    link.reset();
    ChatOrigin.reset();
  });

  Widget app(Widget child) => MaterialApp(
    localizationsDelegates: const <LocalizationsDelegate<Object>>[
      AppLocalizations.delegate,
      GlobalMaterialLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
    ],
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );

  MessageBubble running({
    String message = 'Thinking...',
    List<ContentBlock>? blocks,
    bool showToolCalls = false,
  }) => MessageBubble(
    message: message,
    isUser: false,
    chatId: key,
    messengerMode: true,
    showToolCalls: showToolCalls,
    showReasoningTokens: false,
    contentBlocks: blocks,
    isStreamingMessage: true,
    turnStartedAt: DateTime.now().subtract(const Duration(seconds: 15)),
  );

  void seedRun() {
    ledger.begin(key);
    ledger.reasoning(key, 'I will list the inbox first. Then I sort it.');
    ledger.closeTool(
      key,
      'bash',
      arguments: 'ls -la ~/mail',
      result: 'inbox.mbox\narchive.mbox',
    );
    ledger.openTool(key, 'web_search', arguments: 'fastmail api');
  }

  final Finder dots = find.byKey(const ValueKey<String>('agents-live-dots'));

  testWidgets('a running turn shows only the dots, no status words', (
    tester,
  ) async {
    seedRun();
    await tester.pumpWidget(app(running()));
    await tester.pump();

    expect(dots, findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('messenger-typing-pill')),
      findsOneWidget,
    );
    for (final String word in <String>[
      'Thinking',
      'Connecting',
      'Working',
      'Searching',
      'Preparing',
      'Ran bash',
    ]) {
      expect(find.textContaining(word), findsNothing, reason: word);
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the dots stay while the answer is being written', (
    tester,
  ) async {
    seedRun();
    await tester.pumpWidget(
      app(
        running(
          message: '',
          blocks: const <ContentBlock>[
            ContentBlock.reasoning('Sorting by sender.'),
            ContentBlock.text('Here is the first part'),
          ],
          showToolCalls: true,
        ),
      ),
    );
    await tester.pump();

    expect(dots, findsOneWidget);
    expect(find.textContaining('Here is the first part'), findsOneWidget);
    // The rounds are not drawn a second time next to the panel.
    expect(find.textContaining('Thought'), findsNothing);
    expect(find.textContaining('Thinking'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a tap shows every step: phase, thinking, calls, results', (
    tester,
  ) async {
    seedRun();
    await tester.pumpWidget(app(running()));
    await tester.pump();

    await tester.tap(dots);
    await tester.pump();

    // The phase with its clock, now that the reader asked.
    expect(
      find.byKey(const ValueKey<String>('agents-live-phase')),
      findsOneWidget,
    );
    // The thinking, even with "Show thinking" off: opening is the request.
    expect(find.textContaining('I will list the inbox first.'), findsWidgets);
    // The call with its argument and a one-line result.
    expect(find.textContaining('Ran bash'), findsOneWidget);
    expect(find.textContaining('ls -la ~/mail'), findsOneWidget);
    expect(find.text('inbox.mbox'), findsOneWidget);
    // The call still running.
    expect(find.textContaining('fastmail api'), findsOneWidget);

    // A step that arrives while the panel is open shows without a rebuild
    // of the bubble.
    ledger.closeTool(key, 'read_file', arguments: 'notes.md', result: 'ok');
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('notes.md'), findsOneWidget);

    // A second tap folds it back to the dots.
    await tester.tap(dots);
    await tester.pump();
    expect(find.textContaining('Ran bash'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a finished turn keeps the "Worked for" summary, no dots', (
    tester,
  ) async {
    final ToolCall call = ToolCall(
      name: 'bash',
      arguments: <String, dynamic>{'command': 'ls'},
      status: ToolCallStatus.completed,
      result: 'a',
    );
    await tester.pumpWidget(
      app(
        MessageBubble(
          message: '',
          isUser: false,
          chatId: key,
          showToolCalls: true,
          contentBlocks: <ContentBlock>[
            ContentBlock.toolCalls(<ToolCall>[call]),
            const ContentBlock.text('Done.'),
          ],
          workedFor: const Duration(seconds: 13),
        ),
      ),
    );
    await tester.pump();
    expect(dots, findsNothing);
    expect(find.text('Worked for 13s'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
