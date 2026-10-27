// Widget tests for the ask_user card: single choice chips and the
// multi-select card (letter badges, several picks, one confirm).

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/utils/ask_user_args.dart';
import 'package:chuk_chat/widgets/ask_user_card.dart';

Future<void> _pump(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: ThemeData(useMaterial3: true),
      home: Scaffold(
        body: SingleChildScrollView(child: SizedBox(width: 360, child: child)),
      ),
    ),
  );
}

void main() {
  testWidgets('single choice: a tap sends that option', (
    WidgetTester tester,
  ) async {
    final List<String> sent = <String>[];
    await _pump(
      tester,
      AskUserCard(options: const <String>['Ja', 'Nein'], onSelect: sent.add),
    );
    expect(find.text('1. Ja'), findsOneWidget);
    await tester.tap(find.text('2. Nein'));
    expect(sent, <String>['Nein']);
  });

  testWidgets('multi select: letters, toggles, confirm sends picks in order', (
    WidgetTester tester,
  ) async {
    final List<String> sent = <String>[];
    await _pump(
      tester,
      AskUserCard(
        question: 'Which sections should the update cover?',
        options: const <String>['Roadmap', 'Metrics', 'Hiring'],
        multiSelect: true,
        onSelect: sent.add,
      ),
    );
    expect(
      find.text('Which sections should the update cover?'),
      findsOneWidget,
    );
    expect(find.text('Choose all that apply'), findsOneWidget);
    expect(find.text('A'), findsOneWidget);
    expect(find.text('B'), findsOneWidget);
    expect(find.text('C'), findsOneWidget);

    // Nothing picked: confirm is disabled.
    await tester.tap(find.text('Confirm'));
    expect(sent, isEmpty);

    await tester.tap(find.text('Hiring'));
    await tester.tap(find.text('Roadmap'));
    await tester.tap(find.text('Metrics'));
    await tester.tap(find.text('Metrics')); // and off again
    await tester.pump();
    await tester.tap(find.text('Confirm'));
    expect(sent, <String>['Roadmap, Hiring']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('multi select: German strings under a de locale', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('de'),
        supportedLocales: const <Locale>[Locale('de'), Locale('en')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: Scaffold(
          body: AskUserCard(
            options: const <String>['A1', 'B1'],
            multiSelect: true,
            onSelect: (_) {},
          ),
        ),
      ),
    );
    expect(find.text('Wähle alles Passende'), findsOneWidget);
    expect(find.text('Bestätigen'), findsOneWidget);
  });

  test('askUserIsMultiple reads bools and "true" strings only', () {
    expect(askUserIsMultiple(true), isTrue);
    expect(askUserIsMultiple('true'), isTrue);
    expect(askUserIsMultiple(' TRUE '), isTrue);
    expect(askUserIsMultiple(false), isFalse);
    expect(askUserIsMultiple('yes'), isFalse);
    expect(askUserIsMultiple(null), isFalse);
    expect(askUserIsMultiple(1), isFalse);
  });
}
