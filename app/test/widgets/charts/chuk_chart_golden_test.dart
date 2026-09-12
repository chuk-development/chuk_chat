// The pictures. Regenerate with
//
//   flutter test test/widgets/charts/chuk_chart_golden_test.dart --update-goldens
//
// and then LOOK at test/widgets/charts/goldens/*.png. A chart that passes its
// golden and reads badly is still a broken chart.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chart_fixtures.dart';
import 'chart_test_support.dart';

void main() {
  setUpAll(loadChartFonts);

  testWidgets('the election case, dark', (WidgetTester tester) async {
    await shootChart(tester, kSachsenAnhalt, 'sachsen_anhalt_dark');
  });

  testWidgets('the election case, light', (WidgetTester tester) async {
    await shootChart(
      tester,
      kSachsenAnhalt,
      'sachsen_anhalt_light',
      brightness: Brightness.light,
    );
  });

  testWidgets('the election case, wide window', (WidgetTester tester) async {
    await shootChart(
      tester,
      kSachsenAnhalt,
      'sachsen_anhalt_wide',
      width: 680,
      brightness: Brightness.light,
    );
  });

  testWidgets('gains and losses, negative bars', (WidgetTester tester) async {
    await shootChart(tester, kGainsAndLosses, 'gains_losses_dark');
  });

  testWidgets('gains and losses, light', (WidgetTester tester) async {
    await shootChart(
      tester,
      kGainsAndLosses,
      'gains_losses_light',
      brightness: Brightness.light,
    );
  });

  testWidgets('crypto, one series up and one down', (
    WidgetTester tester,
  ) async {
    await shootChart(tester, kCryptoWeek, 'crypto_line_dark');
  });

  testWidgets('crypto, light', (WidgetTester tester) async {
    await shootChart(
      tester,
      kCryptoWeek,
      'crypto_line_light',
      brightness: Brightness.light,
    );
  });

  testWidgets('grouped bars', (WidgetTester tester) async {
    await shootChart(tester, kGrouped, 'grouped_dark');
  });

  testWidgets('360 dp at text scale 1.3', (WidgetTester tester) async {
    // The message column on a 360 dp phone, minus the bubble's own padding.
    await shootChart(
      tester,
      kSachsenAnhalt,
      'sachsen_anhalt_360_scale13',
      width: 312,
      textScale: 1.3,
    );
  });

  testWidgets('360 dp at text scale 1.3, gains and losses', (
    WidgetTester tester,
  ) async {
    await shootChart(
      tester,
      kGainsAndLosses,
      'gains_losses_360_scale13',
      width: 312,
      textScale: 1.3,
      brightness: Brightness.light,
    );
  });

  testWidgets('a malformed spec', (WidgetTester tester) async {
    await shootChart(tester, kMalformed, 'malformed_dark');
  });

  testWidgets('a malformed spec, light', (WidgetTester tester) async {
    await shootChart(
      tester,
      kMalformed,
      'malformed_light',
      brightness: Brightness.light,
    );
  });

  testWidgets('text that is not a chart at all', (WidgetTester tester) async {
    await shootChart(tester, '{"points": [', 'malformed_raw');
  });
}
