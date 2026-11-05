// What Home looks like on a 360 dp phone, light and dark, with a realistic
// dashboard, plus the empty state and edit mode.
//
// Regenerate with
//
//   flutter test test/widgets/dashboard/dashboard_golden_test.dart \
//     --update-goldens
//
// and then LOOK at the PNGs in test/widgets/dashboard/goldens/.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'dashboard_test_support.dart';

const Key _shot = ValueKey<String>('dash-shot');

void main() {
  setUpAll(loadChartFonts);

  for (final Brightness b in Brightness.values) {
    final String mode = b == Brightness.dark ? 'dark' : 'light';

    testWidgets('populated, $mode', (WidgetTester tester) async {
      final FakeDashboardHost host = FakeDashboardHost();
      host.show(<Map<String, dynamic>>[
        ...realisticDashboard(),
        noteWidget(),
        chartWidget(),
      ]);
      await pumpDashboard(tester, host, brightness: b, height: 2700);
      await expectLater(
        find.byKey(_shot),
        matchesGoldenFile('goldens/dashboard_populated_$mode.png'),
      );
    });

    testWidgets('empty, $mode', (WidgetTester tester) async {
      final FakeDashboardHost host = FakeDashboardHost(attached: false);
      host.show(<Map<String, dynamic>>[]);
      await pumpDashboard(tester, host, brightness: b, height: 800);
      await expectLater(
        find.byKey(_shot),
        matchesGoldenFile('goldens/dashboard_empty_$mode.png'),
      );
    });
  }

  testWidgets('edit mode, light', (WidgetTester tester) async {
    final FakeDashboardHost host = FakeDashboardHost();
    host.show(realisticDashboard());
    await pumpDashboard(tester, host, height: 900);
    await tester.tap(find.byKey(const ValueKey<String>('dash-edit')));
    await tester.pumpAndSettle();
    await expectLater(
      find.byKey(_shot),
      matchesGoldenFile('goldens/dashboard_edit_light.png'),
    );
  });

  testWidgets('wide window, light', (WidgetTester tester) async {
    final FakeDashboardHost host = FakeDashboardHost();
    host.show(<Map<String, dynamic>>[
      ...realisticDashboard(),
      noteWidget(),
      chartWidget(),
    ]);
    await pumpDashboard(tester, host, width: 1100, height: 1400);
    await expectLater(
      find.byKey(_shot),
      matchesGoldenFile('goldens/dashboard_wide_light.png'),
    );
  });
}
