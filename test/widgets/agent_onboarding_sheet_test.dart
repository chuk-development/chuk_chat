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

  // Find a form field by its label, so the test does not break when the field
  // order changes (it did when the Role field was added between Name and Job).
  Finder field(String label) => find.widgetWithText(TextField, label);

  testWidgets('the auto-assigned name is prefilled and can be changed',
      (tester) async {
    final drafts = await pumpSheet(tester);

    expect(find.text('amber-otter'), findsOneWidget);

    await tester.enterText(field('Name'), 'cobalt-lynx');
    await tester.enterText(field('Job'), 'watch the build');
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    expect(drafts.single.name, 'cobalt-lynx');
    expect(drafts.single.brief, 'watch the build');
    expect(drafts.single.schedule, isNull);
    expect(drafts.single.attachmentNames, isEmpty);
  });

  testWidgets('an optional role rides along and is trimmed', (tester) async {
    final drafts = await pumpSheet(tester);

    await tester.enterText(field('Name'), 'cobalt-lynx');
    await tester.enterText(field('Role (optional)'), '  researcher  ');
    await tester.enterText(field('Job'), 'watch the build');
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    expect(drafts.single.role, 'researcher');
  });

  testWidgets('a blank role is left null, not an empty string', (tester) async {
    final drafts = await pumpSheet(tester);

    await tester.enterText(field('Name'), 'cobalt-lynx');
    await tester.enterText(field('Job'), 'watch the build');
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    expect(drafts.single.role, isNull);
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

    await tester.enterText(field('Name'), '  ');
    await tester.enterText(field('Job'), 'do a thing');
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    expect(find.text('Give the agent a name.'), findsOneWidget);
    expect(drafts, isEmpty);
  });

  testWidgets('a valid schedule previews its next runs and rides along',
      (tester) async {
    final drafts = await pumpSheet(tester);

    await tester.enterText(field('Job'), 'weekly news');
    await tester.enterText(field('Schedule (optional)'), 'every 2h');
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

    await tester.enterText(field('Job'), 'weekly news');
    await tester.enterText(field('Schedule (optional)'), 'every blue moon');
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

    await tester.enterText(field('Job'), 'read the sheet');
    await tester.enterText(field('File name'), 'prices.xlsx');
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
