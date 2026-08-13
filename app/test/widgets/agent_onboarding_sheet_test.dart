import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cowork/services/cowork/schedule_spec.dart';
import 'package:cowork/widgets/agent_onboarding_sheet.dart';

void main() {
  Future<List<AgentDraft>> pumpSheet(WidgetTester tester,
      {VoidCallback? onCancel}) async {
    final drafts = <AgentDraft>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: AgentOnboardingSheet(
            suggestedName: 'amber-otter',
            onSubmit: drafts.add,
            onCancel: onCancel,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return drafts;
  }

  testWidgets('the auto-assigned name is prefilled and can be changed',
      (tester) async {
    final drafts = await pumpSheet(tester);

    expect(find.text('amber-otter'), findsOneWidget);

    await tester.enterText(find.byType(TextField).at(0), 'cobalt-lynx');
    await tester.enterText(find.byType(TextField).at(1), 'watch the build');
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    expect(drafts.single.name, 'cobalt-lynx');
    expect(drafts.single.brief, 'watch the build');
    expect(drafts.single.schedule, isNull);
    expect(drafts.single.attachmentNames, isEmpty);
  });

  testWidgets('a coworker without a job is refused', (tester) async {
    final drafts = await pumpSheet(tester);

    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    expect(find.text('Describe the job it should do.'), findsOneWidget);
    expect(drafts, isEmpty);
  });

  testWidgets('a nameless coworker is refused', (tester) async {
    final drafts = await pumpSheet(tester);

    await tester.enterText(find.byType(TextField).at(0), '  ');
    await tester.enterText(find.byType(TextField).at(1), 'do a thing');
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    expect(find.text('Give the agent a name.'), findsOneWidget);
    expect(drafts, isEmpty);
  });

  testWidgets('a valid schedule previews its next runs and rides along',
      (tester) async {
    final drafts = await pumpSheet(tester);

    await tester.enterText(find.byType(TextField).at(1), 'weekly news');
    // The schedule field is the last one on the form.
    await tester.enterText(find.byType(TextField).last, 'every 2h');
    await tester.pumpAndSettle();

    expect(find.textContaining('every 2 hours'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    expect(drafts.single.schedule!.kind, ScheduleKind.interval);
    expect(drafts.single.schedule!.source, 'every 2h');
  });

  testWidgets('junk in the schedule blocks the create and says why',
      (tester) async {
    final drafts = await pumpSheet(tester);

    await tester.enterText(find.byType(TextField).at(1), 'weekly news');
    await tester.enterText(find.byType(TextField).last, 'every blue moon');
    await tester.pumpAndSettle();

    expect(find.text('Not a schedule this app understands.'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();
    expect(drafts, isEmpty);
  });

  testWidgets('attachments are collected as names and say they are not uploaded',
      (tester) async {
    final drafts = await pumpSheet(tester);

    expect(
      find.text(
        'Listed for the brief only. The app cannot upload them to the host yet.',
      ),
      findsOneWidget,
    );

    await tester.enterText(find.byType(TextField).at(1), 'read the sheet');
    await tester.enterText(find.byType(TextField).at(2), 'prices.xlsx');
    await tester.tap(find.widgetWithText(TextButton, 'Add'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(InputChip, 'prices.xlsx'), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    expect(drafts.single.attachmentNames, <String>['prices.xlsx']);
  });

  testWidgets('cancel is offered when the caller wants it', (tester) async {
    var cancelled = 0;
    await pumpSheet(tester, onCancel: () => cancelled++);

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    expect(cancelled, 1);
  });
}
