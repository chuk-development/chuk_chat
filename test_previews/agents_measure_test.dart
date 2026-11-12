// A preview harness outside test/: the test-only members are meant here.
// ignore_for_file: invalid_use_of_visible_for_testing_member

// Measurements for the agent list rows (CHAT-35), printed, not asserted:
//  * the avatar's centre against the row's centre;
//  * the time label's baseline against the name's baseline;
//  * the gap between the time's right edge and the row's right edge.
// Run: flutter test test_previews/agents_measure_test.dart

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/services/agents/roster_pins.dart';
import 'package:chuk_chat/ui/expressive/agent_face.dart';

import '../test/platform_specific/mobile/mobile_support.dart';
import 'agents_list_preview_test.dart' as preview;

double baselineOf(WidgetTester tester, Finder text) {
  final RenderParagraph p = tester.renderObject<RenderParagraph>(text);
  final double local = p.getDryBaseline(
    p.constraints,
    TextBaseline.alphabetic,
  )!;
  return p.localToGlobal(Offset(0, local)).dy;
}

String f(double v) => v.toStringAsFixed(2);

void report(
  WidgetTester tester,
  String where,
  Finder row,
  String name,
  String time,
) {
  Finder inRow(Finder x) => find.descendant(of: row, matching: x);
  final Rect rowRect = tester.getRect(row);
  final Rect face = tester.getRect(inRow(find.byType(AgentFace)));
  final Rect timeRect = tester.getRect(inRow(find.text(time)));
  final double nameBase = baselineOf(tester, inRow(find.text(name)));
  final double timeBase = baselineOf(tester, inRow(find.text(time)));
  // ignore: avoid_print
  print(
    '$where $name: row ${f(rowRect.height)} px, face ${f(face.width)} px; '
    'face centre - row centre = ${f(face.center.dy - rowRect.center.dy)} px; '
    'time baseline - name baseline = ${f(timeBase - nameBase)} px; '
    'row right - time right = ${f(rowRect.right - timeRect.right)} px',
  );
}

void main() {
  setUpAll(loadRealFonts);
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    RosterPins.instance.reset();
    preview.seedPreviews();
  });

  testWidgets('phone rows', (tester) async {
    await pumpPhone(tester, preview.phoneList());
    await tester.pump(const Duration(milliseconds: 1400));
    for (final (String id, String name, String time)
        in <(String, String, String)>[
          ('slmob', 'SLMob', '9:30 AM'),
          ('design', 'Design', 'Yesterday'),
          ('inbox', 'Inbox Triage', 'Mon'),
          ('finance', 'Finance', '31.10.'),
        ]) {
      // The rounded card the row draws (MorphTap), inside the list padding.
      final Finder card = find
          .descendant(
            of: find.byKey(ValueKey<String>('mobile-agent-$id')),
            matching: find.byType(ConstrainedBox),
          )
          .first;
      report(tester, 'phone', card, name, time);
    }
  });

  testWidgets('desktop rows', (tester) async {
    await preview.pumpDesktop(tester, Brightness.light);
    await tester.pump(const Duration(milliseconds: 1400));
    for (final (String id, String name, String time)
        in <(String, String, String)>[
          ('slmob', 'SLMob', '9:30 AM'),
          ('design', 'Design', 'Yesterday'),
          ('finance', 'Finance', '31.10.'),
        ]) {
      report(
        tester,
        'desktop',
        find.byKey(ValueKey<String>('agent-tile-$id')),
        name,
        time,
      );
    }
  });
}
