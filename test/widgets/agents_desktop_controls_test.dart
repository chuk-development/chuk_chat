// Keyboard and screen-reader reach of the Agents desktop controls
// (docs/DESIGN.md §14): the bar button and the hover toolbar on a message.
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/widgets/agents_desktop/desktop_controls.dart';
import 'package:chuk_chat/widgets/agents_desktop/message_hover_actions.dart';
import 'package:chuk_chat/widgets/message_bubble.dart' show MessageBubbleAction;

Widget _app(Widget child) => MaterialApp(
  home: Scaffold(body: Center(child: child)),
);

void main() {
  group('DeskIconButton', () {
    testWidgets('Tab focuses it, Enter and Space press it, a ring shows', (
      tester,
    ) async {
      var presses = 0;
      await tester.pumpWidget(
        _app(
          DeskIconButton(
            icon: Icons.add,
            tooltip: 'Add',
            onPressed: () => presses++,
          ),
        ),
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      final BoxDecoration box =
          tester
                  .widget<AnimatedContainer>(find.byType(AnimatedContainer))
                  .decoration!
              as BoxDecoration;
      expect(box.border, isNotNull);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(presses, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(presses, 2);

      // The pointer still presses it, and a click draws no ring.
      await tester.tap(find.byType(DeskIconButton));
      await tester.pumpAndSettle();
      expect(presses, 3);
    });

    testWidgets('a disabled button is no focus stop and presses nothing', (
      tester,
    ) async {
      await tester.pumpWidget(
        _app(
          const DeskIconButton(
            icon: Icons.add,
            tooltip: 'Add',
            onPressed: null,
          ),
        ),
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      final BoxDecoration box =
          tester
                  .widget<AnimatedContainer>(find.byType(AnimatedContainer))
                  .decoration!
              as BoxDecoration;
      expect(box.border, isNull);
    });
  });

  group('MessageHoverActions', () {
    Future<List<String>> pumpMessage(WidgetTester tester) async {
      final List<String> log = <String>[];
      await tester.pumpWidget(
        _app(
          SizedBox(
            width: 400,
            child: MessageHoverActions(
              actions: <MessageBubbleAction>[
                MessageBubbleAction(
                  icon: Icons.copy,
                  tooltip: 'Copy',
                  onPressed: () => log.add('copy'),
                ),
                MessageBubbleAction(
                  icon: Icons.refresh,
                  tooltip: 'Retry',
                  onPressed: () => log.add('retry'),
                ),
                MessageBubbleAction(
                  icon: Icons.call_split,
                  tooltip: 'Branch',
                  isEnabled: false,
                  onPressed: () => log.add('branch'),
                ),
              ],
              child: const SizedBox(height: 80, child: Text('all set')),
            ),
          ),
        ),
      );
      return log;
    }

    const Key toolbar = ValueKey<String>('message-hover-toolbar');

    testWidgets('keyboard focus on the message shows the toolbar, Tab walks '
        'into it and Enter presses', (tester) async {
      final List<String> log = await pumpMessage(tester);
      expect(find.byKey(toolbar), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(find.byKey(toolbar), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('message-focus-ring')),
        findsOneWidget,
      );

      // Into the first button; the toolbar stays while the focus is inside.
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(find.byKey(toolbar), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(log, <String>['copy']);
    });

    testWidgets('the enabled actions are custom semantics actions', (
      tester,
    ) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      final List<String> log = await pumpMessage(tester);

      final SemanticsNode node = tester.getSemantics(find.text('all set'));
      SemanticsNode? withActions = node;
      while (withActions != null &&
          !withActions.getSemanticsData().hasAction(
            SemanticsAction.customAction,
          )) {
        withActions = withActions.parent;
      }
      expect(withActions, isNotNull);
      final List<String> labels = <String>[
        for (final int id
            in withActions!.getSemanticsData().customSemanticsActionIds ??
                const <int>[])
          CustomSemanticsAction.getAction(id)!.label!,
      ];
      expect(labels, containsAll(<String>['Copy', 'Retry']));
      expect(labels, isNot(contains('Branch')));

      final int retry = withActions
          .getSemanticsData()
          .customSemanticsActionIds!
          .firstWhere(
            (int id) => CustomSemanticsAction.getAction(id)!.label == 'Retry',
          );
      tester.binding.pipelineOwner.semanticsOwner!.performAction(
        withActions.id,
        SemanticsAction.customAction,
        retry,
      );
      await tester.pump();
      expect(log, <String>['retry']);
      handle.dispose();
    });
  });
}
