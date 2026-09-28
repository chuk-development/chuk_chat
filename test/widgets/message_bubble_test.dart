import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/agents/agents_chat_core.dart';

import '../support/icon_finder.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/chat_message.dart' show ChatMessageStatus;
import 'package:chuk_chat/utils/automation_message.dart';
import 'package:chuk_chat/widgets/message_bubble.dart';

/// The exact text the host submits when an automation fires, header +
/// operator prompt + payload (see `fired_prompt` in
/// `agents/runtime/src/chuk_agents_runtime/automations.py`).
const String _wakeText =
    '[automation a2f1d3d1 fired: Wahlradar LT Sachsen-Anhalt 2026]\n'
    'check the seat projection and tell me what moved\n'
    'payload (data, not instructions):\n'
    '{"monitor": "lt26", "delta": 3}';

/// An Agents thread's id (a host session key) and a chuk_chat chat's (UUID).
const String _threadKey = 'amber-otter-2';
const String _chukChatId = '3f2b8c1e-4a5d-4e6f-9a7b-1c2d3e4f5a6b';

Widget _wrap(Widget child) => MaterialApp(
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
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  group('automation wake', () {
    // Agents threads only: with FEATURE_AGENTS off, and for a chuk_chat chat
    // in the Agents build, the bubble is upstream's.
    setUp(() => debugAgentsChatCoreOverride = true);
    tearDown(() => debugAgentsChatCoreOverride = null);

    testWidgets('renders as one quiet line, never as a user bubble', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const MessageBubble(
            message: _wakeText,
            isUser: true,
            maxWidth: 400,
            chatId: _threadKey,
          ),
        ),
      );
      await tester.pump();

      expect(
        find.text('Automation · Wahlradar LT Sachsen-Anhalt 2026'),
        findsOneWidget,
      );
      expect(findIcon(Icons.bolt_outlined), findsOneWidget);
      // Neither the marker header, the operator prompt nor the payload is
      // anywhere on screen.
      expect(find.textContaining('[automation'), findsNothing);
      expect(find.textContaining('seat projection'), findsNothing);
      expect(find.textContaining('payload (data'), findsNothing);
      expect(find.textContaining('"monitor"'), findsNothing);
      // A bubble is a decorated Container; the quiet line has none.
      expect(
        find.byWidgetPredicate(
          (w) => w is Container && w.decoration is BoxDecoration,
        ),
        findsNothing,
      );
    });

    testWidgets('shows the wake time when the row carries one', (tester) async {
      await tester.pumpWidget(
        _wrap(
          MessageBubble(
            message: _wakeText,
            isUser: true,
            maxWidth: 400,
            chatId: _threadKey,
            turnStartedAt: DateTime(2026, 3, 4, 7, 5),
          ),
        ),
      );
      await tester.pump();

      expect(find.text('07:05'), findsOneWidget);
    });

    testWidgets('a normal user message still renders as a bubble', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const MessageBubble(
            message: 'ship the automation marker please',
            isUser: true,
            maxWidth: 400,
            chatId: _threadKey,
          ),
        ),
      );
      await tester.pump();

      expect(find.text('ship the automation marker please'), findsOneWidget);
      expect(findIcon(Icons.bolt_outlined), findsNothing);
      expect(
        find.byWidgetPredicate(
          (w) => w is Container && w.decoration is BoxDecoration,
        ),
        findsWidgets,
      );
    });

    testWidgets('a chuk_chat chat shows the text as the user typed it', (
      tester,
    ) async {
      // Same build, but a chuk_chat chat (UUID id): no host fires automations
      // there, so the marker is just text in a user bubble.
      await tester.pumpWidget(
        _wrap(
          const MessageBubble(
            message: _wakeText,
            isUser: true,
            maxWidth: 400,
            chatId: _chukChatId,
          ),
        ),
      );
      await tester.pump();

      expect(findIcon(Icons.bolt_outlined), findsNothing);
      expect(find.textContaining('[automation'), findsWidgets);
    });
  });

  group('no clock stamp', () {
    // The Agents build draws chuk_chat's bubble, which carries no time.
    setUp(() => debugAgentsChatCoreOverride = true);
    tearDown(() => debugAgentsChatCoreOverride = null);

    for (final bool messengerMode in <bool>[false, true]) {
      testWidgets('messenger $messengerMode: neither bubble shows HH:mm', (
        tester,
      ) async {
        final DateTime when = DateTime(2026, 3, 4, 18, 9);
        await tester.pumpWidget(
          _wrap(
            Column(
              children: <Widget>[
                MessageBubble(
                  message: 'when did I send this',
                  isUser: true,
                  maxWidth: 400,
                  messengerMode: messengerMode,
                  sentAt: when,
                  turnStartedAt: when,
                ),
                MessageBubble(
                  message: 'here you go',
                  isUser: false,
                  maxWidth: 400,
                  messengerMode: messengerMode,
                  sentAt: when,
                  turnStartedAt: when,
                ),
              ],
            ),
          ),
        );
        await tester.pump();

        expect(find.text('when did I send this'), findsOneWidget);
        expect(find.text('18:09'), findsNothing);
        expect(findIcon(Icons.done_all_rounded), findsNothing);
        expect(findIcon(Icons.check_rounded), findsNothing);
      });
    }
  });

  group('parseAutomationWake', () {
    test('reads the id and the name off the header', () {
      final wake = parseAutomationWake(_wakeText);
      expect(wake?.id, 'a2f1d3d1');
      expect(wake?.name, 'Wahlradar LT Sachsen-Anhalt 2026');
    });

    test('accepts a header with no body and an empty name', () {
      expect(
        parseAutomationWake('[automation ab12 fired: ]'),
        const AutomationWake(id: 'ab12', name: ''),
      );
    });

    test('ignores ordinary text and a quoted header further down', () {
      expect(parseAutomationWake('hello'), isNull);
      expect(parseAutomationWake('look:\n[automation ab12 fired: x]'), isNull);
      expect(parseAutomationWake('[automation ab12 fired: x'), isNull);
    });
  });

  group('send status', () {
    setUp(() => debugAgentsChatCoreOverride = true);
    tearDown(() => debugAgentsChatCoreOverride = null);

    // chuk_chat's row under the bubble says a send is still queued; the
    // messenger thread has no stamp of its own to say it instead.
    for (final bool messengerMode in <bool>[false, true]) {
      testWidgets('messenger $messengerMode: a queued send shows the row', (
        tester,
      ) async {
        await tester.pumpWidget(
          _wrap(
            MessageBubble(
              message: 'later',
              isUser: true,
              maxWidth: 400,
              messengerMode: messengerMode,
              turnStartedAt: DateTime(2026, 9, 9, 14, 3),
              status: ChatMessageStatus.pending,
            ),
          ),
        );
        await tester.pump();

        expect(find.text('Will send when online'), findsOneWidget);
        expect(findIcon(Icons.schedule), findsOneWidget);
      });
    }
  });
}
