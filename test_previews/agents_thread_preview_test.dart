// Headless preview of an Agents thread: the phone messenger view and the
// desktop thread with its action bars. Not part of `flutter test` (this
// folder is outside test/). Writes PNGs with
//
//   PREVIEW_OUT=after flutter test test_previews/agents_thread_preview_test.dart --update-goldens
//
// into _scratch/agents_ui/<PREVIEW_OUT>/ (gitignored). Default: "after".

import 'dart:io';

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/models/chat_message.dart' show ChatMessageStatus;
import 'package:chuk_chat/models/content_block.dart';
import 'package:chuk_chat/platform_specific/chat/handlers/message_actions_handler.dart';
import 'package:chuk_chat/services/agents/agents_chat_core.dart';
import 'package:chuk_chat/widgets/message_bubble.dart';
import 'package:chuk_chat/widgets/message_time_label.dart';
import 'package:chuk_chat/widgets/agent_thread_accent.dart';
import 'package:chuk_chat/widgets/agents_bubble_hover_actions.dart';
import 'package:chuk_chat/platform_specific/chat/chat_ui_helpers.dart';

import '../test/platform_specific/mobile/mobile_support.dart';
import '../test/support/test_app.dart';

final String _out =
    '../_scratch/agents_ui/${Platform.environment['PREVIEW_OUT'] ?? 'after'}';

void main() {
  setUpAll(loadRealFonts);
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  final DateTime now = DateTime(2026, 11, 12, 14, 40);
  debugMessageTimeNow = () => now;

  ThemeData mono(Brightness brightness) => ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: Colors.black,
      brightness: brightness,
      dynamicSchemeVariant: DynamicSchemeVariant.monochrome,
    ),
  );

  final MessageActionsHandler handler = MessageActionsHandler();

  List<MessageBubbleAction> aiActions(
    int i,
    String text, {
    bool failed = false,
    bool agents = true,
  }) => handler.buildActionsForMessage(
    index: i,
    messageText: text,
    isUser: false,
    isStreaming: false,
    onEdit: (_) {},
    onResendMessage: (_) {},
    onBranch: (_) {},
    agentsThread: agents,
    failed: failed,
  );

  List<MessageBubbleAction> userActions(int i, String text) => handler
      .buildUserMessageActions(index: i, messageText: text, onEdit: (_) {});

  List<Widget> thread({required bool messenger, required double width}) {
    const String chatId = 'agent:chief:main';
    final List<(String, bool, DateTime)> rows = <(String, bool, DateTime)>[
      (
        'Morning. What is on today?',
        true,
        now.subtract(const Duration(days: 1, hours: 3)),
      ),
      (
        'Three things are open, and one needs you: the release notes, two PRs and the invoice from Kettle & Co.',
        false,
        now.subtract(const Duration(days: 1, hours: 3)),
      ),
      (
        'I can draft the release notes first if you like.',
        false,
        now.subtract(const Duration(days: 1, hours: 3)),
      ),
      (
        'Ship it, and tell me when the build is green.',
        true,
        now.subtract(const Duration(minutes: 9)),
      ),
      (
        "I'm on it. Building Android and Linux now.",
        false,
        now.subtract(const Duration(minutes: 9)),
      ),
      (
        'The build is green. I merged both PRs and tagged v1.0.112.\n\n- Android: uploaded\n- Linux: uploaded',
        false,
        now.subtract(const Duration(minutes: 8)),
      ),
    ];
    final List<Map<String, String>> raw = <Map<String, String>>[
      for (final r in rows)
        <String, String>{
          'sender': r.$2 ? 'user' : 'ai',
          'sentAt': r.$3.toIso8601String(),
        },
    ];
    final List<Widget> out = <Widget>[];
    for (int i = 0; i < rows.length; i++) {
      final (String text, bool user, DateTime at) = rows[i];
      if (messageOpensTimeDivider(raw, i)) {
        out.add(MessageTimeDivider(when: at));
      }
      final bool starts = i == 0 || rows[i - 1].$2 != user;
      final bool ends = i == rows.length - 1 || rows[i + 1].$2 != user;
      out.add(
        MessageBubble(
          message: text,
          isUser: user,
          chatId: chatId,
          maxWidth: user ? width * 0.75 : width * 0.85,
          messengerMode: messenger,
          sentAt: at,
          turnStartedAt: at,
          startsNewGroup: starts,
          endsGroup: ends,
          actions: user ? const <MessageBubbleAction>[] : aiActions(i, text),
          userMessageActions: user
              ? userActions(i, text)
              : const <MessageBubbleAction>[],
          onReply: () {},
          onReaction: (_) {},
        ),
      );
    }
    // A run that thought and said an interim line before its answer: only
    // the answer is in the bubble, the rest folds into the work block.
    out.add(
      MessageBubble(
        message:
            'Nichts Relevantes – der Posteingang ist leer, keine neuen Mails.',
        isUser: false,
        chatId: chatId,
        maxWidth: width * 0.85,
        messengerMode: messenger,
        startsNewGroup: true,
        workedFor: const Duration(seconds: 13),
        contentBlocks: const <ContentBlock>[
          ContentBlock.reasoning('The user wants a mailbox check.'),
          ContentBlock.text("I'll check the current mailbox state."),
          ContentBlock.reasoning('The inbox is empty.'),
          ContentBlock.text(
            'Nichts Relevantes – der Posteingang ist leer, keine neuen Mails.',
          ),
        ],
      ),
    );
    // The host gave up after its retries (CHAT-64): a quiet line.
    out.add(
      MessageBubble(
        message:
            'The model service did not answer for 30 min (9 retries, last '
            'error: HTTP 503); the task stopped.',
        isUser: false,
        chatId: chatId,
        maxWidth: width * 0.85,
        messengerMode: messenger,
        startsNewGroup: true,
        turnFailed: true,
      ),
    );
    out.add(const SizedBox(height: 24));
    out.add(
      MessageBubble(
        message: 'The provider returned an error. Try again later.',
        isUser: false,
        chatId: '2b7f0c1e-0000-4000-8000-000000000001',
        maxWidth: width,
        sentAt: now.subtract(const Duration(minutes: 1)),
        startsNewGroup: true,
        actions: aiActions(9, 'x', failed: true, agents: false),
        status: ChatMessageStatus.interrupted,
      ),
    );
    return out;
  }

  Future<void> shoot(WidgetTester tester, String name) async {
    debugDisableShadows = false;
    try {
      await tester.pump(const Duration(milliseconds: 1400));
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('$_out/$name.png'),
      );
    } finally {
      debugDisableShadows = true;
    }
  }

  testWidgets('phone thread', (tester) async {
    debugAgentsChatCoreOverride = true;
    addTearDown(() => debugAgentsChatCoreOverride = null);
    await pumpPhone(
      tester,
      AgentThreadAccent(
        agentId: 'chief',
        child: ListView(
          padding: const EdgeInsets.fromLTRB(12, 60, 12, 24),
          children: thread(messenger: true, width: 360),
        ),
      ),
      theme: mono(Brightness.light),
    );
    await shoot(tester, 'thread_phone_light');
  });

  testWidgets('desktop thread', (tester) async {
    debugAgentsChatCoreOverride = true;
    addTearDown(() => debugAgentsChatCoreOverride = null);
    const Size size = Size(1100, 760);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: kTestLocalizationsDelegates,
        debugShowCheckedModeBanner: false,
        theme: mono(Brightness.light),
        home: Scaffold(
          body: AgentThreadAccent(
            agentId: 'chief',
            child: Center(
              child: SizedBox(
                width: 720,
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(0, 40, 0, 24),
                  children: thread(messenger: false, width: 720),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    // Hover the long answer: react, reply and more show beside it.
    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(
      tester.getCenter(find.textContaining('The build is green')),
    );
    await tester.pump(const Duration(milliseconds: 300));
    final Rect more = tester.getRect(
      find.byKey(const ValueKey<String>('bubble-hover-more')).last,
    );
    final Rect bubble = tester.getRect(
      find
          .ancestor(
            of: find.textContaining('The build is green'),
            matching: find.byType(AgentsBubbleHoverActions),
          )
          .first,
    );
    // ignore: avoid_print
    print('CENTRE hover ${more.center.dy} bubble ${bubble.center.dy}');
    await shoot(tester, 'thread_desktop_light');
  });
}
