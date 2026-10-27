import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/automations/simple_schedule.dart';
import 'package:chuk_chat/widgets/schedule_picker.dart';

Widget _app(Widget child, {Locale locale = const Locale('en')}) => MaterialApp(
  locale: locale,
  localizationsDelegates: const <LocalizationsDelegate<Object>>[
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(
    body: SingleChildScrollView(
      child: Padding(padding: const EdgeInsets.all(16), child: child),
    ),
  ),
);

Future<TextEditingController> _pump(
  WidgetTester tester,
  String spec, {
  Locale locale = const Locale('en'),
}) async {
  final TextEditingController c = TextEditingController(text: spec);
  addTearDown(c.dispose);
  await tester.pumpWidget(
    _app(
      SchedulePicker(
        key: ValueKey<String>('picker-$spec'),
        controller: c,
        // A Monday, 08:00.
        now: () => DateTime(2026, 10, 19, 8),
        customField: TextField(
          key: const ValueKey<String>('custom-field'),
          controller: c,
        ),
      ),
      locale: locale,
    ),
  );
  await tester.pump();
  await tester.pump();
  return c;
}

void main() {
  group('SimpleSchedule', () {
    test('daily at a time is a cron line', () {
      const SimpleSchedule s = SimpleSchedule(
        mode: SimpleScheduleMode.daily,
        hour: 7,
        minute: 30,
      );
      expect(s.toSpec(), '30 7 * * *');
    });

    test('weekdays: a run is a range, gaps are a list', () {
      expect(
        const SimpleSchedule(
          mode: SimpleScheduleMode.weekdays,
          hour: 9,
          weekdays: kWorkWeek,
        ).toSpec(),
        '0 9 * * 1-5',
      );
      expect(
        const SimpleSchedule(
          mode: SimpleScheduleMode.weekdays,
          hour: 18,
          minute: 5,
          weekdays: <int>{1, 3, 5},
        ).toSpec(),
        '5 18 * * 1,3,5',
      );
      expect(
        const SimpleSchedule(
          mode: SimpleScheduleMode.weekdays,
          weekdays: <int>{0, 6},
        ).toSpec(),
        '0 9 * * 0,6',
      );
      // No day: no spec; the editor refuses it like an empty field.
      expect(
        const SimpleSchedule(
          mode: SimpleScheduleMode.weekdays,
          weekdays: <int>{},
        ).toSpec(),
        '',
      );
    });

    test('every N hours is an interval, clamped to 1..23', () {
      expect(
        const SimpleSchedule(
          mode: SimpleScheduleMode.everyHours,
          everyHours: 3,
        ).toSpec(),
        'every 3h',
      );
      expect(
        const SimpleSchedule(
          mode: SimpleScheduleMode.everyHours,
          everyHours: 40,
        ).toSpec(),
        'every 23h',
      );
    });

    test('reads back what it writes', () {
      for (final String spec in <String>[
        '30 7 * * *',
        '0 9 * * 1-5',
        '5 18 * * 1,3,5',
        'every 3h',
      ]) {
        expect(SimpleSchedule.fromSpec(spec).toSpec(), spec, reason: spec);
      }
      final SimpleSchedule w = SimpleSchedule.fromSpec('0 9 * * 1-5');
      expect(w.mode, SimpleScheduleMode.weekdays);
      expect(w.weekdays, kWorkWeek);
      expect(SimpleSchedule.fromSpec('every 2 h').everyHours, 2);
      // Sunday as 7, and all seven days, are daily.
      expect(SimpleSchedule.fromSpec('0 8 * * 0-6').mode,
          SimpleScheduleMode.daily);
      expect(SimpleSchedule.fromSpec('0 8 * * 7').weekdays, <int>{0});
    });

    test('anything else stays custom, untouched', () {
      for (final String spec in <String>[
        '*/15 * * * *',
        '0 9 1 * *',
        '0 9 * * mon-fri',
        'every 30m',
        'every 1d',
        'at 2026-10-06T09:00',
        'in 2h',
      ]) {
        final SimpleSchedule s = SimpleSchedule.fromSpec(spec);
        expect(s.mode, SimpleScheduleMode.custom, reason: spec);
        expect(s.toSpec(), spec);
      }
    });

    test('empty is the default: every day at 09:00', () {
      expect(SimpleSchedule.fromSpec('').toSpec(), '0 9 * * *');
    });
  });

  group('SchedulePicker', () {
    testWidgets('a new routine starts daily at 09:00 and says when it runs', (
      tester,
    ) async {
      final TextEditingController c = await _pump(tester, '');
      expect(c.text, '0 9 * * *');
      expect(find.text('9:00 AM'), findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('schedule-next-run')),
        findsOneWidget,
      );
      expect(find.textContaining('Next run:'), findsOneWidget);
      expect(find.byKey(const ValueKey<String>('custom-field')), findsNothing);
    });

    testWidgets('the Material time picker sets the time', (tester) async {
      final TextEditingController c = await _pump(tester, '');
      await tester.tap(find.byKey(const ValueKey<String>('schedule-time')));
      await tester.pumpAndSettle();
      expect(find.byType(TimePickerDialog), findsOneWidget);
      // Switch to text entry and type 07:30.
      await tester.tap(find.byIcon(Icons.keyboard_outlined));
      await tester.pumpAndSettle();
      final Finder inputs = find.descendant(
        of: find.byType(TimePickerDialog),
        matching: find.byType(TextField),
      );
      await tester.enterText(inputs.at(0), '7');
      await tester.enterText(inputs.at(1), '30');
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(c.text, '30 7 * * *');
    });

    testWidgets('weekdays: days toggle, Monday to Friday by default', (
      tester,
    ) async {
      final TextEditingController c = await _pump(tester, '');
      await tester.tap(find.text('Weekdays'));
      await tester.pumpAndSettle();
      expect(c.text, '0 9 * * 1-5');
      // Saturday on, Monday off.
      await tester.tap(find.byKey(const ValueKey<String>('schedule-day-6')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey<String>('schedule-day-1')));
      await tester.pump();
      expect(c.text, '0 9 * * 2-6');
    });

    testWidgets('every N hours steps with the buttons', (tester) async {
      final TextEditingController c = await _pump(tester, '');
      await tester.tap(find.text('Hours'));
      await tester.pumpAndSettle();
      expect(c.text, 'every 2h');
      expect(find.text('Every 2 hours'), findsOneWidget);
      await tester.tap(
        find.byKey(const ValueKey<String>('schedule-hours-plus')),
      );
      await tester.pumpAndSettle();
      expect(c.text, 'every 3h');
      for (int i = 0; i < 3; i++) {
        await tester.tap(
          find.byKey(const ValueKey<String>('schedule-hours-minus')),
        );
        await tester.pumpAndSettle();
      }
      expect(c.text, 'every 1h');
      expect(find.text('Every hour'), findsOneWidget);
    });

    testWidgets('an existing cron opens in its shape; custom keeps the text', (
      tester,
    ) async {
      final TextEditingController c = await _pump(tester, '15 6 * * 1,3');
      expect(c.text, '15 6 * * 1,3');
      expect(find.text('6:15 AM'), findsOneWidget);

      final TextEditingController odd = await _pump(tester, 'every 30m');
      expect(odd.text, 'every 30m');
      expect(
        find.byKey(const ValueKey<String>('custom-field')),
        findsOneWidget,
      );
    });

    testWidgets('switching to custom starts from the picked spec', (
      tester,
    ) async {
      final TextEditingController c = await _pump(tester, '0 9 * * 1-5');
      await tester.tap(find.text('Custom'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('custom-field')),
        findsOneWidget,
      );
      expect(c.text, '0 9 * * 1-5');
      // Back to a picked shape: the days survive.
      await tester.tap(find.text('Weekdays'));
      await tester.pumpAndSettle();
      expect(c.text, '0 9 * * 1-5');
    });

    testWidgets('German, 360 dp at 1.3 text scale', (tester) async {
      tester.view.physicalSize = const Size(360, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final TextEditingController c = TextEditingController(
        text: '0 9 * * 1-5',
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(360, 900),
            textScaler: TextScaler.linear(1.3),
          ),
          child: _app(
            SchedulePicker(
              controller: c,
              customField: TextField(controller: c),
            ),
            locale: const Locale('de'),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(find.text('Wochentage'), findsOneWidget);
      expect(find.text('Uhrzeit'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Stunden'));
      await tester.pumpAndSettle();
      expect(find.text('Alle 2 Stunden'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
