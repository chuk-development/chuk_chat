// Composer widgets at 360 px and desktop width: the queue dock (idea 67),
// the ask_user card in the composer seat (idea 66), the API-key warning and
// the "While busy" setting.

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/services/agents/agents_thread_modes.dart';
import 'package:chuk_chat/services/composer/follow_up_queue.dart';
import 'package:chuk_chat/widgets/composer/busy_mode_setting.dart';
import 'package:chuk_chat/widgets/composer/chat_question_seat.dart';
import 'package:chuk_chat/widgets/composer/queue_dock.dart';
import 'package:chuk_chat/widgets/composer/secret_send_guard.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _pump(WidgetTester tester, double width, Widget child) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
        AppLocalizations.delegate,
      ],
      home: Scaffold(
        body: Align(
          alignment: Alignment.bottomCenter,
          child: SizedBox(width: width - 16, child: child),
        ),
      ),
    ),
  );
  await tester.pump();
}

ToolCall _askUser({
  List<String> options = const <String>['Red', 'Blue (Recommended)', 'Green'],
  bool multiple = false,
}) => ToolCall(
  id: 'ask-1',
  name: 'ask_user',
  arguments: <String, dynamic>{
    'question': 'Which colour?',
    'options': options,
    'multiple': multiple,
  },
  status: ToolCallStatus.completed,
  startedAt: DateTime(2026, 11, 5),
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    ComposerBusySetting.debugReset();
  });

  group('ask_user helpers', () {
    test('request from the call; recommended preselected', () {
      final AgentsQuestionRequest r = askUserRequestFor(_askUser())!;
      expect(r.questions.single.question, 'Which colour?');
      expect(r.questions.single.preselected, <String>['Blue (Recommended)']);
      expect(askUserRequestFor(_askUser(options: <String>['only'])), isNull);
    });

    test('the answer text drops the tag and joins picks', () {
      final AgentsQuestionRequest r = askUserRequestFor(
        _askUser(multiple: true),
      )!;
      expect(
        askUserAnswerText(r, const <AgentsQuestionAnswer>[
          AgentsQuestionAnswer(
            id: 'ask-1',
            selected: <String>['Red', 'Blue (Recommended)'],
            custom: 'and teal',
          ),
        ]),
        'Red, Blue. and teal',
      );
      expect(
        askUserAnswerText(r, const <AgentsQuestionAnswer>[
          AgentsQuestionAnswer(id: 'ask-1'),
        ]),
        isNull,
        reason: 'a skip sends nothing',
      );
    });

    test('options as a JSON string; last completed call wins', () {
      expect(askUserOptions('["a","b"]'), <String>['a', 'b']);
      expect(askUserOptions('nope'), isEmpty);
      expect(lastCompletedAskUser(<ToolCall>[_askUser()], null)?.id, 'ask-1');
    });
  });

  for (final double width in <double>[360, 1280]) {
    testWidgets('question seat at $width px: Enter sends the recommended', (
      WidgetTester tester,
    ) async {
      final List<String> sent = <String>[];
      int skipped = 0;
      await _pump(
        tester,
        width,
        ChatQuestionSeat(
          request: askUserRequestFor(_askUser())!,
          onAnswer: sent.add,
          onSkip: () => skipped++,
        ),
      );
      expect(find.text('Which colour?'), findsOne);
      expect(tester.takeException(), isNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(sent, <String>['Blue']);
      expect(skipped, 0);
    });

    testWidgets('question seat at $width px: Skip gives the seat back', (
      WidgetTester tester,
    ) async {
      final List<String> sent = <String>[];
      int skipped = 0;
      await _pump(
        tester,
        width,
        SingleChildScrollView(
          child: ChatQuestionSeat(
            request: askUserRequestFor(_askUser())!,
            onAnswer: sent.add,
            onSkip: () => skipped++,
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('agents-question-skip')));
      await tester.pump();
      expect(sent, isEmpty);
      expect(skipped, 1);
    });

    testWidgets('queue dock at $width px: edit, steer now, remove', (
      WidgetTester tester,
    ) async {
      final FollowUpQueue queue = FollowUpQueue();
      addTearDown(queue.dispose);
      queue.add('a queued message that is long enough to need ellipsis ' * 3);
      queue.add('steer this', kind: FollowUpKind.steer);
      final List<String> steered = <String>[];
      final List<String> removed = <String>[];
      final Map<String, String> edited = <String, String>{};
      await _pump(
        tester,
        width,
        QueueDock(
          queue: queue,
          onEdit: (String id, String text) => edited[id] = text,
          onRemove: removed.add,
          onSteerNow: steered.add,
        ),
      );
      expect(tester.takeException(), isNull);
      final String firstId = queue.items.first.id;
      // A steer row has no "send now as steer" action; a queued one has.
      expect(find.byKey(const ValueKey('composer-queue-steer')), findsOne);
      await tester.tap(find.byKey(const ValueKey('composer-queue-steer')));
      expect(steered, <String>[firstId]);

      await tester.tap(find.byKey(const ValueKey('composer-queue-edit')).first);
      await tester.pump();
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('composer-queue-edit-field')),
        'shorter',
      );
      await tester.tap(find.byKey(const ValueKey('composer-queue-save')));
      await tester.pump();
      expect(edited[firstId], 'shorter');

      await tester.tap(
        find.byKey(const ValueKey('composer-queue-remove')).last,
      );
      expect(removed, <String>[queue.items.last.id]);
    });

    testWidgets('API-key warning at $width px: Edit keeps, Send anyway sends', (
      WidgetTester tester,
    ) async {
      bool? result;
      await _pump(
        tester,
        width,
        Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () async => result = await confirmSecretSend(
              context,
              'my key sk-ant-api03-${'a' * 90}',
            ),
            child: const Text('send'),
          ),
        ),
      );
      await tester.tap(find.text('send'));
      await tester.pumpAndSettle();
      expect(
        find.text('This message contains what looks like an API key'),
        findsOne,
      );
      await tester.tap(find.byKey(const ValueKey('composer-secret-edit')));
      await tester.pumpAndSettle();
      expect(result, isFalse);

      await tester.tap(find.text('send'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('composer-secret-send')));
      await tester.pumpAndSettle();
      expect(result, isTrue);
    });

    testWidgets('busy setting at $width px switches Queue / Steer', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        width,
        const SingleChildScrollView(child: ComposerBusyModeSetting()),
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Steer'));
      await tester.pump();
      expect(ComposerBusySetting.mode.value, BusySendMode.steer);
      await tester.tap(find.text('Queue'));
      await tester.pump();
      expect(ComposerBusySetting.mode.value, BusySendMode.queue);
    });
  }
}
