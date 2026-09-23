// Behaviour, not pixels: what the widget does with a bad spec, how it keeps
// labels legible when the column gets narrow, and that the entrance plays
// once.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/widgets/charts/chart_painter.dart';
import 'package:chuk_chat/widgets/charts/chuk_chart.dart';

import 'chart_fixtures.dart';
import 'chart_test_support.dart';

void main() {
  setUpAll(loadChartFonts);

  group('rendering', () {
    testWidgets('the election case draws a chart, not a fallback', (
      WidgetTester tester,
    ) async {
      await pumpChart(
        tester,
        chukChartFromJson(kSachsenAnhalt, animate: false),
      );
      expect(find.byType(ChukChart), findsOneWidget);
      expect(find.byType(ChukChartFallback), findsNothing);
      expect(find.byType(CustomPaint), findsWidgets);
      expect(find.text('Landtagswahl Sachsen-Anhalt'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a malformed spec falls back quietly', (
      WidgetTester tester,
    ) async {
      await pumpChart(tester, chukChartFromJson(kMalformed, animate: false));
      expect(find.byType(ChukChartFallback), findsOneWidget);
      expect(
        find.text('Entry 1 (Q1) is not a number (and 2 more).'),
        findsOneWidget,
      );
      expect(find.text('Umsatz nach Quartal'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('every hopeless input renders something, never an exception', (
      WidgetTester tester,
    ) async {
      for (final Object? bad in <Object?>[
        null,
        '',
        '{not json',
        42,
        <String, Object?>{'points': <Object?>[]},
        <String, Object?>{'series': <Object?>[]},
        <String, Object?>{'kind': 'line', 'points': 'nope'},
      ]) {
        await pumpChart(tester, chukChartFromJson(bad, animate: false));
        expect(find.byType(ChukChartFallback), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
    });

    testWidgets('a one-point chart does not divide by zero', (
      WidgetTester tester,
    ) async {
      await pumpChart(
        tester,
        chukChartFromJson(<String, Object?>{
          'kind': 'line',
          'points': <Map<String, Object?>>[
            <String, Object?>{'label': 'now', 'value': 7},
          ],
        }, animate: false),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('all values equal still draws a plot', (
      WidgetTester tester,
    ) async {
      await pumpChart(
        tester,
        chukChartFromJson(<String, Object?>{
          'points': <double>[5, 5, 5],
        }, animate: false),
      );
      expect(find.byType(ChukChartFallback), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the legend names the series', (WidgetTester tester) async {
      await pumpChart(tester, chukChartFromJson(kCryptoWeek, animate: false));
      expect(find.text('BTC'), findsOneWidget);
      expect(find.text('ETH ×20'), findsOneWidget);
    });

    testWidgets('the source and the stamp are printed', (
      WidgetTester tester,
    ) async {
      await pumpChart(
        tester,
        chukChartFromJson(kSachsenAnhalt, animate: false),
      );
      expect(
        find.text('Landeswahlleiter Sachsen-Anhalt  ·  2026-09-12 20:15'),
        findsOneWidget,
      );
    });

    testWidgets('it describes itself to a screen reader', (
      WidgetTester tester,
    ) async {
      final SemanticsHandle handle = tester.ensureSemantics();
      await pumpChart(
        tester,
        chukChartFromJson(kSachsenAnhalt, animate: false),
      );
      expect(
        find.bySemanticsLabel(RegExp(r'AfD 43,8 %')),
        findsOneWidget,
      );
      handle.dispose();
    });
  });

  group('legibility at 360 dp', () {
    testWidgets('nothing overflows at 360 dp and text scale 1.3', (
      WidgetTester tester,
    ) async {
      for (final Object? spec in <Object?>[
        kSachsenAnhalt,
        kGainsAndLosses,
        kCryptoWeek,
        kGrouped,
        kMalformed,
      ]) {
        await pumpChart(
          tester,
          chukChartFromJson(spec, animate: false),
          width: 312,
          textScale: 1.3,
        );
        expect(tester.takeException(), isNull);
      }
    });

    test('ten party labels tilt on a phone and lie flat on a wide window', () {
      final ChartSpec spec = ChartSpec.parse(kSachsenAnhalt);
      final ChartGeometry narrow = ChukChartPainter.measure(
        spec,
        width: 288,
        textScaler: const TextScaler.linear(1.3),
        fontFamily: 'Roboto',
      );
      final ChartGeometry wide = ChukChartPainter.measure(
        spec,
        width: 700,
        textScaler: TextScaler.noScaling,
        fontFamily: 'Roboto',
      );
      expect(narrow.labelLayout, ChartLabelLayout.tilted);
      expect(narrow.labelStride, 1, reason: 'ten labels still all fit tilted');
      expect(wide.labelLayout, ChartLabelLayout.flat);
    });

    test('a very dense category axis thins its labels instead of stacking '
        'them on top of each other', () {
      final ChartSpec spec = ChartSpec.parse(<String, Object?>{
        'points': <Object?>[
          for (int i = 0; i < 60; i++)
            <String, Object?>{'label': 'week $i', 'value': i % 7},
        ],
      });
      final ChartGeometry g = ChukChartPainter.measure(
        spec,
        width: 312,
        textScaler: const TextScaler.linear(1.3),
        fontFamily: 'Roboto',
      );
      expect(g.labelLayout, ChartLabelLayout.tilted);
      expect(g.labelStride, greaterThan(1));
    });

    test('the plot grows with the column but stays inside sane bounds', () {
      final ChartSpec spec = ChartSpec.parse(kSachsenAnhalt);
      for (final double w in <double>[200, 312, 400, 900, 2000]) {
        final ChartGeometry g = ChukChartPainter.measure(
          spec,
          width: w,
          textScaler: TextScaler.noScaling,
          fontFamily: 'Roboto',
        );
        expect(g.plotHeight, inInclusiveRange(120, 280));
        expect(g.axisWidth, lessThanOrEqualTo(w * 0.32 + 0.01));
        expect(g.totalHeight, greaterThan(g.plotHeight));
      }
    });

    test('the axis always encloses every value and the reference line', () {
      final ChartSpec spec = ChartSpec.parse(kSachsenAnhalt);
      final ChartGeometry g = ChukChartPainter.measure(
        spec,
        width: 360,
        textScaler: TextScaler.noScaling,
        fontFamily: 'Roboto',
      );
      expect(g.min, lessThanOrEqualTo(0));
      expect(g.max, greaterThanOrEqualTo(43.8));
      expect(g.min, lessThanOrEqualTo(5));

      final ChartSpec delta = ChartSpec.parse(kGainsAndLosses);
      final ChartGeometry gd = ChukChartPainter.measure(
        delta,
        width: 360,
        textScaler: TextScaler.noScaling,
        fontFamily: 'Roboto',
      );
      expect(gd.min, lessThanOrEqualTo(-19.8));
      expect(gd.max, greaterThanOrEqualTo(22.4));
    });

    test('a price line is not forced down to zero', () {
      final ChartGeometry g = ChukChartPainter.measure(
        ChartSpec.parse(kCryptoWeek),
        width: 360,
        textScaler: TextScaler.noScaling,
        fontFamily: 'Roboto',
      );
      expect(g.min, greaterThan(50000));
    });
  });

  group('the reference label', () {
    // The spec the thread block renders: the same election, capped at the six
    // strongest parties, which is where the label used to land on the last
    // bar.
    final Map<String, Object?> topSix = <String, Object?>{
      ...kSachsenAnhalt,
      'points': (kSachsenAnhalt['points']! as List<Object?>).take(6).toList(),
    };

    final List<List<Object>> cases = <List<Object>>[
      <Object>['election, 366 dp', kSachsenAnhalt, 366.0, 1.0],
      <Object>['election, 360 dp at 1.3', kSachsenAnhalt, 312.0, 1.3],
      <Object>['election, wide', kSachsenAnhalt, 680.0, 1.0],
      <Object>['election, six bars', topSix, 312.0, 1.0],
      <Object>['election, six bars at 1.3', topSix, 312.0, 1.3],
      <Object>['a rule high in the plot', kHighReference, 366.0, 1.0],
      <Object>['a rule high in the plot, narrow', kHighReference, 312.0, 1.3],
      <Object>['a rule below zero', kGainsAndLossesWithRule, 366.0, 1.0],
      <Object>[
        'a rule below zero, narrow',
        kGainsAndLossesWithRule,
        312.0,
        1.3,
      ],
    ];

    testWidgets('never covers a bar, a number or a category', (
      WidgetTester tester,
    ) async {
      for (final List<Object> c in cases) {
        final String name = c[0] as String;
        await pumpChart(
          tester,
          chukChartFromJson(c[1], animate: false, fontFamily: 'Roboto'),
          width: c[2] as double,
          textScale: c[3] as double,
        );
        final ChukChartPainter painter = _painterOf(tester);
        final Rect? chip = painter.debugReferenceLabelBox;
        expect(chip, isNotNull, reason: '$name: the rule lost its label');
        expect(
          painter.debugBoxes,
          isNotEmpty,
          reason: '$name: nothing was measured to dodge',
        );
        for (final ChartBox box in painter.debugBoxes) {
          if (box.kind == ChartBoxKind.tick) continue;
          expect(
            box.rect.overlaps(chip!),
            isFalse,
            reason: '$name: the chip $chip covers $box',
          );
        }
        // It keeps its plate, so it never ends up as bare words on the rule.
        expect(
          painter.debugReferenceLabelPlated,
          isTrue,
          reason: '$name: the label had to give up its plate',
        );
        expect(chip!.left, greaterThanOrEqualTo(0.0), reason: name);
        expect(tester.takeException(), isNull, reason: name);
      }
    });

    testWidgets('keeps its words where they fit and drops to the number '
        'where they do not', (WidgetTester tester) async {
      await pumpChart(
        tester,
        chukChartFromJson(kSachsenAnhalt, animate: false, fontFamily: 'Roboto'),
        width: 680,
      );
      expect(_painterOf(tester).debugReferenceLabelText, '5 %-Hürde');

      await pumpChart(
        tester,
        chukChartFromJson(kSachsenAnhalt, animate: false, fontFamily: 'Roboto'),
        width: 312,
        textScale: 1.3,
      );
      expect(_painterOf(tester).debugReferenceLabelText, '5 %');
    });

    testWidgets('stays where it is while the chart grows in', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Material(
            child: SizedBox(
              width: 360,
              child: ChukChart(
                spec: ChartSpec.parse(kSachsenAnhalt),
                fontFamily: 'Roboto',
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      final Rect? early = _painterOf(tester).debugReferenceLabelBox;
      await tester.pump(kChukChartEntrance);
      expect(_painterOf(tester).debugReferenceLabelBox, early);
      await tester.pumpAndSettle();
    });
  });

  group('the entrance', () {
    testWidgets('plays once and does not replay on a rebuild', (
      WidgetTester tester,
    ) async {
      await pumpChart(
        tester,
        const _Rebuildable(),
        brightness: Brightness.light,
      );
      // pumpChart settles, so the entrance is over.
      final _RebuildableState state = tester.state(find.byType(_Rebuildable));
      final ChukChartPainter before = _painterOf(tester);
      expect(before.progress, 1.0);

      state.bump();
      await tester.pump();
      expect(_painterOf(tester).progress, 1.0);
    });

    testWidgets('starts from the baseline', (WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Material(
            child: SizedBox(
              width: 360,
              child: ChukChart(spec: ChartSpec.parse(kSachsenAnhalt)),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(_painterOf(tester).progress, lessThan(0.2));
      await tester.pump(kChukChartEntrance);
      expect(_painterOf(tester).progress, 1.0);
      await tester.pumpAndSettle();
    });
  });
}

ChukChartPainter _painterOf(WidgetTester tester) {
  final Iterable<CustomPaint> paints = tester.widgetList<CustomPaint>(
    find.descendant(
      of: find.byType(ChukChart),
      matching: find.byType(CustomPaint),
    ),
  );
  return paints
      .map((CustomPaint p) => p.painter)
      .whereType<ChukChartPainter>()
      .first;
}

/// A host that rebuilds its chart without changing the spec.
class _Rebuildable extends StatefulWidget {
  const _Rebuildable();

  @override
  State<_Rebuildable> createState() => _RebuildableState();
}

class _RebuildableState extends State<_Rebuildable> {
  int _n = 0;

  void bump() => setState(() => _n++);

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    children: <Widget>[
      Text('rebuild $_n'),
      ChukChart(
        spec: ChartSpec.parse(kSachsenAnhalt),
        fontFamily: 'Roboto',
      ),
    ],
  );
}
