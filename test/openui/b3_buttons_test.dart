// B3 tests: Buttons, IconButton, FollowUpBlock, and the layout of a
// full form at phone and desktop width, in dark and light, at text
// scale 1.3, and while it streams.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/openui/openui.dart';

import 'openui_test_helper.dart';

/// Every B3 component in one program.
const String _all = '''
root = Card([title, f, icons, followUps])
title = TextContent("Plan a trip", "large-heavy")
f = Form("trip", Buttons([go, reset], "row"), [where, when, who, kind, budget, stay, extras, notes, prefs, pace])
where = FormControl("Destination", Input("destination", "e.g. Tokyo, Japan, or leave it blank", "text", {required: true}), "A city or a country")
when = FormControl("Dates", DatePicker("dates", "range", {required: true}))
who = FormControl("Travellers", Select("travellers", [SelectItem("1", "Just me"), SelectItem("2", "Two people"), SelectItem("4", "A family of four with a very long label that must not overflow")], "Select number of travellers", {required: true}))
kind = FormControl("Trip style", OptionCards("style", "single", [OptionCard("beach", "Beach and relaxation", "Sun, sand and long lazy afternoons by the sea"), OptionCard("city", "City break", "Urban exploration"), OptionCard("hike", "Adventure", "Hiking, trekking and outdoor activities")]))
budget = FormControl("Budget", Slider("budget", "discrete", 500, 10000, 500, [2500], "Budget (USD)"))
stay = FormControl("Stay", Chips("accommodation", "multiple", [ChipItem("hotel", "Hotel"), ChipItem("hostel", "Hostel"), ChipItem("apartment", "Apartment"), ChipItem("camp", "Camping under the stars")], {}, ["hotel"]))
extras = FormControl("Extras", CheckBoxGroup("extras", [CheckBoxItem("Travel insurance", "Covers delays and lost luggage, also for very long trips abroad", "insurance"), CheckBoxItem("Car", "", "car")]))
notes = FormControl("Notes", TextArea("notes", "Anything else?", 3))
prefs = FormControl("Pace", RadioGroup("pace", [RadioItem("Relaxed", "Two things a day", "slow"), RadioItem("Packed", "From dawn to dusk", "fast")], "slow"))
pace = SwitchGroup("flags", [SwitchItem("Direct flights only", "No layovers", "direct"), SwitchItem("Window seat", null, "window", true)], "card")
go = Button("Plan my trip")
reset = Button("Not now", Action([@ToAssistant("not now")]), "secondary")
icons = Buttons([IconButton("Share", Icon("share")), IconButton("Like", Icon("heart"), Action([@ToAssistant("liked")]), "primary", "small", "circle")], "row")
followUps = FollowUpBlock([FollowUpItem("Show me cheaper options"), FollowUpItem("What is the weather like in spring there, and do I need a visa?")])
''';

Future<RecordingOpenUiHandler> _pump(
  WidgetTester tester,
  String source, {
  double width = OpenUiTokens.chatColumnWidth,
  Brightness brightness = Brightness.dark,
  double textScale = 1,
  bool isStreaming = false,
  bool settle = true,
}) async {
  final h = RecordingOpenUiHandler();
  tester.view.physicalSize = const Size(900, 3200);
  tester.view.devicePixelRatio = 1;
  tester.platformDispatcher.textScaleFactorTestValue = textScale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(
    openUiTestApp(
      OpenUiView(source: source, isStreaming: isStreaming, actionHandler: h),
      brightness: brightness,
      width: width,
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
  return h;
}

void main() {
  group('Buttons', () {
    testWidgets('a row and a column draw every button', (tester) async {
      await pumpOpenUi(
        tester,
        'root = Card([Buttons([Button("A"), Button("B")]), '
        'Buttons([Button("C"), Button("D")], "column")])\n',
      );
      for (final l in <String>['A', 'B', 'C', 'D']) {
        expect(find.text(l), findsOneWidget);
      }
      // A column stretches its buttons to the same width.
      expect(
        tester.getSize(find.text('C')).width,
        tester.getSize(find.text('D')).width,
      );
    });

    testWidgets('an empty group draws nothing and does not throw', (
      tester,
    ) async {
      await pumpOpenUi(tester, 'root = Card([Buttons([])])\n');
      expect(tester.takeException(), isNull);
    });
  });

  group('IconButton', () {
    testWidgets('without action it sends its name', (tester) async {
      final h = await pumpOpenUi(
        tester,
        'root = Card([IconButton("Share", Icon("share"))])\n',
      );
      await tester.tap(find.byTooltip('Share'));
      await tester.pumpAndSettle();
      expect(h.messages.single.text, 'Share');
    });

    testWidgets('with an action it runs the action', (tester) async {
      final h = await pumpOpenUi(
        tester,
        'root = Card([IconButton("Open", Icon("link"), '
        'Action([@OpenUrl("https://x.y")]), "tertiary", "large")])\n',
      );
      await tester.tap(find.byTooltip('Open'));
      await tester.pumpAndSettle();
      expect(h.urls, <String>['https://x.y']);
      expect(h.messages, isEmpty);
    });

    testWidgets('keeps its size when the icon is missing', (tester) async {
      await pumpOpenUi(
        tester,
        'root = Card([IconButton("Big", null, null, "primary", "large")])\n',
      );
      final box = tester.getSize(
        find.descendant(
          of: find.byTooltip('Big'),
          matching: find.byType(PhysicalShape),
        ),
      );
      expect(box, const Size(56, 56));
    });
  });

  group('FollowUpBlock', () {
    testWidgets('a tap sends the text as a user message', (tester) async {
      final h = await pumpOpenUi(
        tester,
        'root = Card([FollowUpBlock([a, b, FollowUpItem("")])])\n'
        'a = FollowUpItem("Tell me more about Python")\n'
        'b = FollowUpItem("Compare it with Go")\n',
      );
      expect(find.text('Tell me more about Python'), findsOneWidget);
      await tester.tap(find.text('Compare it with Go'));
      await tester.pumpAndSettle();
      expect(h.messages.single.text, 'Compare it with Go');
      expect(h.messages.single.formValues, isNull);
    });

    testWidgets('items wait while their statement streams', (tester) async {
      final h = await pumpOpenUi(
        tester,
        'root = Card([FollowUpBlock([FollowUpItem("One"), '
        'FollowUpItem("Two is still being wri',
        isStreaming: true,
        settle: false,
      );
      if (find.text('One').evaluate().isNotEmpty) {
        await tester.tap(find.text('One'), warnIfMissed: false);
        await tester.pump();
      }
      expect(h.messages, isEmpty);
      expect(tester.takeException(), isNull);
    });
  });

  group('layout', () {
    for (final brightness in Brightness.values) {
      for (final width in <double>[328, 720]) {
        testWidgets(
          'every component, ${brightness.name}, width $width, text 1.3',
          (tester) async {
            await _pump(
              tester,
              _all,
              width: width,
              brightness: brightness,
              textScale: 1.3,
            );
            expect(tester.takeException(), isNull);
            expect(find.text(OpenUiView.failureText), findsNothing);
            expect(find.text('Plan my trip'), findsOneWidget);
            expect(find.text('Show me cheaper options'), findsOneWidget);
            expect(find.byType(Switch), findsNWidgets(2));
            expect(find.byType(Checkbox), findsNWidgets(2));
          },
        );
      }
    }

    testWidgets('option cards use more columns on a wide view', (tester) async {
      double cardWidth() => tester
          .getSize(
            find
                .ancestor(
                  of: find.text('City break'),
                  matching: find.byType(SizedBox),
                )
                .first,
          )
          .width;
      await _pump(tester, _all, width: 328);
      final narrow = cardWidth();
      await _pump(tester, _all, width: 720);
      final wide = cardWidth();
      expect(narrow, lessThan(328 / 2));
      expect(wide, lessThan(720 / 2.5));
    });

    testWidgets('the full sample submits every value', (tester) async {
      final h = await _pump(tester, _all);
      await tester.enterText(
        find.widgetWithText(TextField, 'e.g. Tokyo, Japan, or leave it blank'),
        'Lisbon',
      );
      await tester.tap(find.text('Plan my trip'));
      await tester.pumpAndSettle();
      // Dates, travellers and the trip style are required and empty.
      expect(h.messages, isEmpty);
      expect(find.text('This field is required'), findsNWidgets(2));

      await tester.tap(find.text('Not now'));
      await tester.pumpAndSettle();
      final values = h.messages.single.formValues!;
      expect(values['destination'], 'Lisbon');
      expect(values['budget'], <num>[2500]);
      expect(values['accommodation'], <String>['hotel']);
      expect(values['extras'], <String, bool>{
        'insurance': false,
        'car': false,
      });
      expect(values['pace'], 'slow');
      // A field straight in the fields list (no FormControl) counts too.
      expect(values['flags'], <String, bool>{'direct': false, 'window': true});
    });

    testWidgets('every prefix of the sample streams without an exception', (
      tester,
    ) async {
      for (var i = 0; i <= _all.length; i += 41) {
        await _pump(
          tester,
          _all.substring(0, i),
          isStreaming: true,
          settle: false,
        );
        expect(tester.takeException(), isNull, reason: 'prefix $i');
      }
      await _pump(tester, _all);
      expect(tester.takeException(), isNull);
    });

    testWidgets('fields are read-only while the view streams', (tester) async {
      await _pump(tester, _all, isStreaming: true, settle: false);
      await tester.pump(const Duration(milliseconds: 50));
      final field = tester.widget<TextField>(
        find.widgetWithText(TextField, 'Anything else?'),
      );
      expect(field.enabled, isFalse);
    });
  });
}
