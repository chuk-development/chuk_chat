import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/message_feedback_store.dart';
import 'package:chuk_chat/services/prompt_cache/prompt_context.dart';
import 'package:chuk_chat/widgets/message_bubble.dart';

Widget _wrap(Widget child) => MaterialApp(
  // The test engine has no Vulkan shaders for the M3 ink sparkle.
  theme: ThemeData(splashFactory: InkRipple.splashFactory),
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

MessageBubble _answer({String? feedbackId = 'answer-1'}) => MessageBubble(
  message: 'Here is the answer.',
  isUser: false,
  maxWidth: 600,
  feedbackId: feedbackId,
  actions: <MessageBubbleAction>[
    MessageBubbleAction(icon: Icons.copy, tooltip: 'Copy', onPressed: () {}),
  ],
);

void main() {
  final List<MessageFeedback> sent = <MessageFeedback>[];
  final List<String> removed = <String>[];

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    MessageFeedbackStore.instance.resetForTest();
    sent.clear();
    removed.clear();
    MessageFeedbackStore.sendToBackend = (fb) async => sent.add(fb);
    MessageFeedbackStore.removeFromBackend = (id) async => removed.add(id);
  });

  tearDown(() {
    MessageFeedbackStore.sendToBackend = null;
    MessageFeedbackStore.removeFromBackend = null;
  });

  for (final double width in <double>[360, 1280]) {
    testWidgets('at $width px: the verdict names the chat by its hash and '
        'can be removed again', (tester) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _wrap(
          MessageBubble(
            message: 'Here is the answer.',
            isUser: false,
            maxWidth: width - 40,
            feedbackId: 'answer-1',
            feedbackModelId: 'z-ai/glm-5.3-flash',
            modelProvider: 'orcarouter',
            chatId: 'chat-42',
            actions: <MessageBubbleAction>[
              MessageBubbleAction(
                icon: Icons.copy,
                tooltip: 'Copy',
                onPressed: () {},
              ),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('feedback-up')));
      await tester.pumpAndSettle();
      // A first verdict has nothing to remove.
      expect(
        find.byKey(const ValueKey<String>('feedback-remove')),
        findsNothing,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey<String>('feedback-submit')),
      );
      await tester.tap(find.byKey(const ValueKey<String>('feedback-submit')));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      final MessageFeedback fb = sent.single;
      expect(fb.chatHash, chatIdHash('chat-42'));
      expect(fb.modelId, 'z-ai/glm-5.3-flash');
      expect(fb.provider, 'orcarouter');
      expect(fb.toBackendBody()?['rating'], 'positive');
      expect(fb.toBackendBody()?.containsKey('text'), isFalse);

      // Open it again: "Remove rating" takes it back here and on the server.
      await tester.tap(find.byKey(const ValueKey<String>('feedback-up')));
      await tester.pumpAndSettle();
      final Finder remove = find.byKey(
        const ValueKey<String>('feedback-remove'),
      );
      await tester.ensureVisible(remove);
      await tester.tap(remove);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(MessageFeedbackStore.instance.peek('answer-1'), isNull);
      expect(removed, <String>['answer-1']);
    });
  }

  testWidgets('a finished answer carries thumbs in its action bar', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(_answer()));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('feedback-up')), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('feedback-down')), findsOneWidget);
    expect(find.byTooltip('Good answer'), findsOneWidget);
    expect(find.byTooltip('Bad answer'), findsOneWidget);
  });

  testWidgets('no thumbs without a lasting message id', (tester) async {
    await tester.pumpWidget(_wrap(_answer(feedbackId: null)));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey<String>('feedback-up')), findsNothing);
  });

  testWidgets('the sheet offers 7 reasons and a note; submit stores it', (
    tester,
  ) async {
    await tester.pumpWidget(_wrap(_answer()));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('feedback-down')));
    await tester.pumpAndSettle();

    expect(find.text('What went wrong?'), findsOneWidget);
    for (final FeedbackCategory c in FeedbackCategory.values) {
      expect(
        find.byKey(ValueKey<String>('feedback-chip-${c.id}')),
        findsOneWidget,
      );
    }
    expect(find.byType(FilterChip), findsNWidgets(7));

    await tester.tap(
      find.byKey(const ValueKey<String>('feedback-chip-service-stability')),
    );
    await tester.tap(find.byKey(const ValueKey<String>('feedback-chip-other')));
    await tester.enterText(
      find.byKey(const ValueKey<String>('feedback-note')),
      'it stopped halfway',
    );
    await tester.ensureVisible(
      find.byKey(const ValueKey<String>('feedback-submit')),
    );
    await tester.tap(find.byKey(const ValueKey<String>('feedback-submit')));
    await tester.pumpAndSettle();

    expect(find.text('What went wrong?'), findsNothing);
    final MessageFeedback? fb = MessageFeedbackStore.instance.peek('answer-1');
    expect(fb, isNotNull);
    expect(fb!.rating, FeedbackRating.down);
    expect(fb.categories, <FeedbackCategory>[
      FeedbackCategory.serviceStability,
      FeedbackCategory.other,
    ]);
    expect(fb.note, 'it stopped halfway');

    // The chosen thumb now sits on the filled capsule.
    final Semantics down = tester.widget<Semantics>(
      find
          .ancestor(
            of: find.byKey(const ValueKey<String>('feedback-down')),
            matching: find.byType(Semantics),
          )
          .first,
    );
    expect(down.properties.selected, isTrue);
  });

  testWidgets('close dismisses without storing', (tester) async {
    await tester.pumpWidget(_wrap(_answer()));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey<String>('feedback-up')));
    await tester.pumpAndSettle();
    expect(find.text('What went well?'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey<String>('feedback-close')));
    await tester.pumpAndSettle();
    expect(find.text('What went well?'), findsNothing);
    expect(MessageFeedbackStore.instance.peek('answer-1'), isNull);
  });
}
