// The composer on the real chat screens, desktop and phone:
// - empty, it is one row of 48 px; with a long draft it stops at 144 px;
// - the band under it is opaque from its top down to the screen edge, so no
//   message text shows around it, under it or through the disclaimer;
// - scrolled to the end, the last message and its sources pill sit above
//   that band.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/models/chat_message.dart';
import 'package:chuk_chat/models/stored_chat.dart';
import 'package:chuk_chat/platform_specific/chat/chat_ui_desktop.dart';
import 'package:chuk_chat/platform_specific/chat/chat_ui_mobile.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/chat_storage_state.dart';
import 'package:chuk_chat/services/multiplex_session.dart';
import 'package:chuk_chat/widgets/composer/composer_bottom_band.dart';

import '../../support/test_app.dart';

const String _chatId = 'composer-layout-chat';

const String _toolCalls =
    '[{"id":"t1","name":"web_search","arguments":{"query":"Berlin"},'
    '"result":"1. Berlin\\n   https://de.wikipedia.org/wiki/Berlin\\n'
    '2. Visit Berlin\\n   https://www.visitberlin.de/en",'
    '"status":"completed","startedAt":"2026-11-20T10:00:00.000Z",'
    '"completedAt":"2026-11-20T10:00:02.000Z"}]';

void _silenceRecorder(WidgetTester tester) {
  const MethodChannel record = MethodChannel('com.llfbandit.record/messages');
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    record,
    (MethodCall call) async => null,
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      record,
      null,
    ),
  );
}

void _seedChat() {
  ChatStorageState.chatsById[_chatId] = StoredChat(
    id: _chatId,
    createdAt: DateTime.utc(2026, 11, 20),
    isStarred: false,
    messages: <ChatMessage>[
      for (int i = 0; i < 6; i++) ...<ChatMessage>[
        ChatMessage(role: 'user', text: 'Question $i'),
        ChatMessage(
          role: 'assistant',
          text: 'Answer $i. ${"A sentence about the city. " * 12}',
          toolCalls: i == 5 ? _toolCalls : null,
        ),
      ],
    ],
  );
}

Future<void> _pump(WidgetTester tester, {required bool phone}) async {
  _silenceRecorder(tester);
  tester.view.physicalSize = phone
      ? const Size(412, 915)
      : const Size(1440, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  _seedChat();
  await tester.pumpWidget(
    testApp(
      Scaffold(
        body: phone
            ? ChukChatUIMobile(
                onToggleSidebar: () {},
                selectedChatId: _chatId,
                onChatIdChanged: (_) {},
                isSidebarExpanded: false,
                showReasoningTokens: false,
                showModelInfo: false,
                showTps: false,
                autoSendVoiceTranscription: false,
              )
            : ChukChatUIDesktop(
                onToggleSidebar: () {},
                selectedChatId: _chatId,
                onChatIdChanged: (_) {},
                isSidebarExpanded: false,
                isCompactMode: false,
                showReasoningTokens: false,
                showModelInfo: false,
                showTps: false,
              ),
      ),
    ),
  );
  for (int i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _scrollToEnd(WidgetTester tester) async {
  final Finder list = find.byWidgetPredicate(
    (w) =>
        w is CustomScrollView &&
        w.center == const ValueKey<String>('chat-transcript-center'),
  );
  expect(list, findsOneWidget);
  final ScrollableState s = tester.state<ScrollableState>(
    find.descendant(of: list, matching: find.byType(Scrollable)).first,
  );
  // Twice: the rows measure themselves and the extent can grow once.
  for (int i = 0; i < 2; i++) {
    s.position.jumpTo(s.position.maxScrollExtent);
    for (int j = 0; j < 4; j++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }
}

Future<void> _tearDown(WidgetTester tester) async {
  await MultiplexSession.shutdown();
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 3));
  ChatStorageState.chatsById.remove(_chatId);
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await ChatStorageService.reset();
  });

  for (final bool phone in <bool>[false, true]) {
    final String where = phone ? 'phone' : 'desktop';
    final Key boxKey = ValueKey<String>(
      phone ? 'mobile-composer-box' : 'desktop-composer-box',
    );

    testWidgets('$where: the empty composer is one 48 px row', (tester) async {
      await _pump(tester, phone: phone);
      final Size box = tester.getSize(find.byKey(boxKey));
      expect(box.height, inInclusiveRange(46, 50));
      await _tearDown(tester);
    });

    testWidgets('$where: a long draft grows the box up to 144 px', (
      tester,
    ) async {
      await _pump(tester, phone: phone);
      final Finder field = find.descendant(
        of: find.byKey(boxKey),
        matching: find.byType(TextField),
      );
      await tester.enterText(field, 'one\ntwo');
      await tester.pump();
      final double two = tester.getSize(find.byKey(boxKey)).height;
      expect(two, greaterThan(50));
      await tester.enterText(
        field,
        List<String>.generate(30, (i) => 'line $i').join('\n'),
      );
      await tester.pump();
      // The phone adds one row of buttons under a wrapped draft.
      expect(
        tester.getSize(find.byKey(boxKey)).height,
        lessThanOrEqualTo(phone ? 144 + 2 + 38 : 144),
      );
      await _tearDown(tester);
    });

    if (phone) {
      testWidgets('phone: a wrapped draft takes the full width', (
        tester,
      ) async {
        await _pump(tester, phone: true);
        final Finder field = find.descendant(
          of: find.byKey(boxKey),
          matching: find.byType(TextField),
        );
        const Key twoRows = ValueKey<String>('mobile-composer-two-rows');
        await tester.enterText(field, 'Short');
        await tester.pump();
        expect(find.byKey(twoRows), findsNothing);
        final double narrow = tester.getSize(field).width;

        await tester.enterText(
          field,
          'A longer question that does not fit on one line of the phone',
        );
        await tester.pump();
        expect(find.byKey(twoRows), findsOneWidget);
        final Rect box = tester.getRect(find.byKey(boxKey));
        final Rect wide = tester.getRect(field);
        expect(wide.width, greaterThan(narrow + 100));
        expect(wide.width, greaterThan(box.width - 20));
        // The buttons sit under the text.
        final Rect send = tester.getRect(
          find.byKey(const ValueKey<String>('composer-send-target')),
        );
        expect(send.top, greaterThanOrEqualTo(wide.bottom));
        // The field kept its state through the move.
        expect(
          tester.widget<TextField>(field).controller?.text,
          startsWith('A longer'),
        );

        await tester.enterText(field, 'Short again');
        await tester.pump();
        expect(find.byKey(twoRows), findsNothing);
        await _tearDown(tester);
      });
    }

    testWidgets('$where: the transcript ends above the composer band', (
      tester,
    ) async {
      await _pump(tester, phone: phone);
      await _scrollToEnd(tester);
      final Size screen = tester.view.physicalSize;
      final Rect box = tester.getRect(find.byKey(boxKey));
      final Rect band = tester.getRect(
        find.byKey(const ValueKey<String>('composer-bottom-band')),
      );
      // Opaque from the composer's top to the bottom edge.
      expect(band.bottom, screen.height);
      expect(
        band.top + ComposerBottomBand.fadeHeight,
        lessThanOrEqualTo(box.top + 0.5),
      );
      // The last answer and its sources pill end above the band.
      final Rect pill = tester.getRect(
        find.byKey(const ValueKey<String>('sources-pill')),
      );
      expect(pill.bottom, lessThanOrEqualTo(band.top + 0.5));
      final Rect lastAnswer = tester.getRect(
        find.textContaining('Answer 5.', findRichText: true).last,
      );
      expect(lastAnswer.bottom, lessThanOrEqualTo(band.top));
      await _tearDown(tester);
    });
  }
}
