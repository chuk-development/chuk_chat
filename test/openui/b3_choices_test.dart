// B3 tests: Select, DatePicker, Slider, CheckBoxGroup, RadioGroup,
// SwitchGroup, Chips and OptionCards. Each value goes into the form
// state, defaults are sent, and the rules show errors.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'openui_test_helper.dart';

Finder _rich(String text) => find.textContaining(text, findRichText: true);

/// A form called "f" with one control, and a Send button.
String _form(String input, {String state = ''}) =>
    '${state}root = Card([f])\n'
    'f = Form("f", Button("Send"), [FormControl("Field", $input)])\n';

Future<Map<String, Object?>?> _submit(
  WidgetTester tester,
  RecordingOpenUiHandler h,
) async {
  await tester.tap(find.text('Send'));
  await tester.pumpAndSettle();
  return h.messages.isEmpty ? null : h.messages.last.formValues;
}

String _iso(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

void main() {
  group('Select', () {
    const items =
        '[SelectItem("engineer", "Engineer"), SelectItem("designer", '
        '"Designer"), SelectItem("pm", "PM")]';

    testWidgets('shows the placeholder, picks an item, sends it', (
      tester,
    ) async {
      final h = await pumpOpenUi(
        tester,
        _form('Select("role", $items, "Pick a role", {required: true})'),
      );
      expect(find.text('Pick a role'), findsOneWidget);
      expect(await _submit(tester, h), isNull);
      expect(find.text('This field is required'), findsOneWidget);

      await tester.tap(find.text('Pick a role'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Designer').last);
      await tester.pumpAndSettle();
      expect(find.text('Designer'), findsOneWidget);
      expect(find.text('This field is required'), findsNothing);
      expect(await _submit(tester, h), <String, Object?>{'role': 'designer'});
    });

    testWidgets('a binding gives the start value', (tester) async {
      final h = await pumpOpenUi(
        tester,
        _form(
          'Select("role", $items, null, {required: true}, \$role)',
          state: '\$role = "pm"\n',
        ),
      );
      expect(find.text('PM'), findsOneWidget);
      expect(await _submit(tester, h), <String, Object?>{'role': 'pm'});
    });
  });

  group('DatePicker', () {
    testWidgets('picks a single date', (tester) async {
      final h = await pumpOpenUi(
        tester,
        _form('DatePicker("day", "single", {required: true})'),
      );
      expect(find.text('Pick a date'), findsOneWidget);
      // The picker opens on today. Take the date before and after, so
      // the test also holds when it runs across midnight.
      final before = _iso(DateTime.now());
      await tester.tap(find.text('Pick a date'));
      await tester.pumpAndSettle();
      expect(find.byType(DatePickerDialog), findsOneWidget);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      final after = _iso(DateTime.now());
      final values = await _submit(tester, h);
      expect(values?.keys, ['day']);
      expect(values?['day'], anyOf(before, after));
    });

    testWidgets('shows a bound range', (tester) async {
      final h = await pumpOpenUi(
        tester,
        _form(
          'DatePicker("trip", "range", null, \$trip)',
          state: '\$trip = {from: "2026-03-02", to: "2026-03-05"}\n',
        ),
      );
      expect(find.text('Mar 2, 2026 – Mar 5, 2026'), findsOneWidget);
      expect(await _submit(tester, h), <String, Object?>{
        'trip': <String, Object?>{'from': '2026-03-02', 'to': '2026-03-05'},
      });
    });

    testWidgets('opens the range picker', (tester) async {
      await pumpOpenUi(tester, _form('DatePicker("trip", "range")'));
      await tester.tap(find.text('Pick a date range'));
      await tester.pumpAndSettle();
      expect(find.byType(DateRangePickerDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('Slider', () {
    testWidgets('sends its default and a dragged value', (tester) async {
      final h = await pumpOpenUi(
        tester,
        _form(
          'Slider("budget", "discrete", 500, 10000, 500, [2500], "Budget")',
        ),
      );
      expect(find.text('Budget'), findsOneWidget);
      expect(find.text('2500'), findsOneWidget);
      expect(await _submit(tester, h), <String, Object?>{
        'budget': <num>[2500],
      });
      await tester.drag(find.byType(Slider), const Offset(120, 0));
      await tester.pumpAndSettle();
      final values = (await _submit(tester, h))!['budget']! as List<Object?>;
      final v = values.single! as num;
      expect(v, greaterThan(2500));
      expect(v % 500, 0);
    });

    testWidgets('two default values make a range slider', (tester) async {
      final h = await pumpOpenUi(
        tester,
        _form('Slider("age", "continuous", 0, 100, 1, [20, 40])'),
      );
      expect(find.byType(RangeSlider), findsOneWidget);
      expect(find.text('20 – 40'), findsOneWidget);
      expect(await _submit(tester, h), <String, Object?>{
        'age': <num>[20, 40],
      });
    });

    testWidgets('bad bounds do not throw', (tester) async {
      await pumpOpenUi(
        tester,
        _form('Slider("x", "continuous", 10, 5, -1, ["a"])'),
      );
      expect(find.byType(Slider), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('CheckBoxGroup', () {
    const items =
        '[CheckBoxItem("Email", "Weekly digest", "email", true), '
        'CheckBoxItem("SMS", "", "sms")]';

    testWidgets('sends the defaults, then the toggled state', (tester) async {
      final h = await pumpOpenUi(
        tester,
        _form('CheckBoxGroup("notify", $items)'),
      );
      expect(find.text('Weekly digest'), findsOneWidget);
      expect(await _submit(tester, h), <String, Object?>{
        'notify': <String, bool>{'email': true, 'sms': false},
      });
      await tester.tap(find.text('SMS'));
      await tester.tap(find.text('Email'));
      await tester.pumpAndSettle();
      expect(await _submit(tester, h), <String, Object?>{
        'notify': <String, bool>{'email': false, 'sms': true},
      });
    });

    testWidgets('required needs one checked item', (tester) async {
      final h = await pumpOpenUi(
        tester,
        _form(
          'CheckBoxGroup("notify", [CheckBoxItem("A", "", "a"), '
          'CheckBoxItem("B", "", "b")], {required: true})',
        ),
      );
      expect(await _submit(tester, h), isNull);
      expect(find.text('At least one option is required'), findsOneWidget);
      await tester.tap(find.text('B'));
      await tester.pumpAndSettle();
      expect(find.text('At least one option is required'), findsNothing);
      expect(await _submit(tester, h), <String, Object?>{
        'notify': <String, bool>{'a': false, 'b': true},
      });
    });
  });

  group('RadioGroup', () {
    testWidgets('default, change, binding', (tester) async {
      final h = await pumpOpenUi(
        tester,
        '\$size = "m"\n'
        'root = Card([f, shown])\n'
        'shown = TextContent("size=" + \$size)\n'
        'f = Form("f", Button("Send"), [FormControl("Size", '
        'RadioGroup("size", [RadioItem("Small", "", "s"), '
        'RadioItem("Medium", "Fits most", "m"), RadioItem("Large", "", "l")], '
        '"s", {required: true}, \$size))])\n',
      );
      expect(_rich('size=m'), findsOneWidget);
      await tester.tap(find.text('Large'));
      await tester.pumpAndSettle();
      expect(_rich('size=l'), findsOneWidget);
      expect(await _submit(tester, h), <String, Object?>{'size': 'l'});
    });

    testWidgets('defaultValue goes into the form', (tester) async {
      final h = await pumpOpenUi(
        tester,
        _form(
          'RadioGroup("plan", [RadioItem("Free", "", "free"), '
          'RadioItem("Pro", "", "pro")], "pro")',
        ),
      );
      expect(await _submit(tester, h), <String, Object?>{'plan': 'pro'});
    });
  });

  group('SwitchGroup', () {
    testWidgets('toggles a switch', (tester) async {
      final h = await pumpOpenUi(
        tester,
        _form(
          'SwitchGroup("prefs", [SwitchItem("Dark mode", "Easier at night", '
          '"dark"), SwitchItem("Sounds", null, "sound", true)], "card")',
        ),
      );
      expect(find.byType(Switch), findsNWidgets(2));
      await tester.tap(find.text('Dark mode'));
      await tester.pumpAndSettle();
      expect(await _submit(tester, h), <String, Object?>{
        'prefs': <String, bool>{'dark': true, 'sound': true},
      });
    });
  });

  group('Chips', () {
    const items =
        '[ChipItem("hotel", "Hotel"), ChipItem("hostel", "Hostel"), '
        'ChipItem("camp", "Camping", null, true)]';

    testWidgets('multiple: default, add, remove; disabled ignores taps', (
      tester,
    ) async {
      final h = await pumpOpenUi(
        tester,
        _form('Chips("stay", "multiple", $items, {}, ["hotel"])'),
      );
      expect(await _submit(tester, h), <String, Object?>{
        'stay': <String>['hotel'],
      });
      await tester.tap(find.text('Hostel'));
      await tester.tap(find.text('Hotel'));
      await tester.tap(find.text('Camping'));
      await tester.pumpAndSettle();
      expect(await _submit(tester, h), <String, Object?>{
        'stay': <String>['hostel'],
      });
    });

    testWidgets('single: one at a time; required', (tester) async {
      final h = await pumpOpenUi(
        tester,
        _form('Chips("stay", "single", $items, {required: true})'),
      );
      expect(await _submit(tester, h), isNull);
      expect(find.text('This field is required'), findsOneWidget);
      await tester.tap(find.text('Hotel'));
      await tester.tap(find.text('Hostel'));
      await tester.pumpAndSettle();
      expect(await _submit(tester, h), <String, Object?>{'stay': 'hostel'});
    });

    testWidgets('single: tapping the default clears it', (tester) async {
      final h = await pumpOpenUi(
        tester,
        _form('Chips("stay", "single", $items, null, "hotel")'),
      );
      await tester.tap(find.text('Hotel'));
      await tester.pumpAndSettle();
      expect(await _submit(tester, h), <String, Object?>{'stay': ''});
    });
  });

  group('OptionCards', () {
    const items =
        '[OptionCard("beach", "Beach", "Sun and sand"), '
        'OptionCard("city", "City", "Museums and food"), '
        'OptionCard("hike", "Hiking", null, null, true)]';

    testWidgets('single selection goes into the form', (tester) async {
      final h = await pumpOpenUi(
        tester,
        _form('OptionCards("style", "single", $items, {required: true})'),
      );
      expect(find.text('Sun and sand'), findsOneWidget);
      expect(await _submit(tester, h), isNull);
      expect(find.text('This field is required'), findsOneWidget);
      await tester.tap(find.text('City'));
      await tester.pumpAndSettle();
      expect(await _submit(tester, h), <String, Object?>{'style': 'city'});
    });

    testWidgets('multiple selection', (tester) async {
      final h = await pumpOpenUi(
        tester,
        _form('OptionCards("style", "multiple", $items, null, ["beach"])'),
      );
      await tester.tap(find.text('City'));
      await tester.tap(find.text('Hiking'));
      await tester.pumpAndSettle();
      expect(await _submit(tester, h), <String, Object?>{
        'style': <String>['beach', 'city'],
      });
    });
  });
}
