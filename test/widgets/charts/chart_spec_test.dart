// What the parser accepts, what it repairs, and what it refuses to throw on.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cowork/widgets/charts/chart_spec.dart';

import 'chart_fixtures.dart';

void main() {
  group('ChartSpec.parse', () {
    test('reads the election case as one bar series', () {
      final ChartSpec spec = ChartSpec.parse(kSachsenAnhalt);
      expect(spec.unusable, isFalse);
      expect(spec.kind, ChartKind.bar);
      expect(spec.series, hasLength(1));
      expect(spec.series.single.points, hasLength(10));
      expect(spec.series.single.points.first.label, 'AfD');
      expect(spec.series.single.points.first.value, 43.8);
      expect(spec.series.single.points.first.color, const Color(0xFF009EE0));
      expect(spec.referenceLine?.value, 5);
      expect(spec.referenceLine?.label, '5 %-Hürde');
      expect(spec.unit, '%');
      expect(spec.problems, isEmpty);
    });

    test('formats with the German comma and the unit', () {
      final ChartSpec spec = ChartSpec.parse(kSachsenAnhalt);
      expect(spec.format(43.8), '43,8 %');
      expect(spec.format(5), '5,0 %');
    });

    test('a currency sign leads, a percent trails', () {
      final ChartSpec spec = ChartSpec.parse(kCryptoWeek);
      expect(spec.format(61200), r'$61200');
      expect(spec.format(-12), r'-$12');
    });

    test('signs a delta', () {
      final ChartSpec spec = ChartSpec.parse(kGainsAndLosses);
      expect(spec.kind, ChartKind.columnDelta);
      expect(spec.hasNegative, isTrue);
      expect(spec.format(22.4, signed: true), '+22,4 %');
      expect(spec.format(-19.8, signed: true), '-19,8 %');
    });

    test('reads several series', () {
      final ChartSpec spec = ChartSpec.parse(kCryptoWeek);
      expect(spec.kind, ChartKind.line);
      expect(spec.series, hasLength(2));
      expect(spec.series.first.name, 'BTC');
      expect(spec.series.first.resolvedDirection, ChartDirection.up);
      expect(spec.series.last.resolvedDirection, ChartDirection.down);
      expect(spec.categories, hasLength(7));
    });

    test('auto direction reads the numbers when nothing was said', () {
      final ChartSpec up = ChartSpec.parse(<String, Object?>{
        'kind': 'line',
        'points': <double>[1, 2, 3],
      });
      final ChartSpec down = ChartSpec.parse(<String, Object?>{
        'kind': 'line',
        'points': <double>[3, 2, 1],
      });
      expect(up.series.single.resolvedDirection, ChartDirection.up);
      expect(down.series.single.resolvedDirection, ChartDirection.down);
    });

    test('sorts descending on request, and the rest follow', () {
      final ChartSpec spec = ChartSpec.parse(<String, Object?>{
        'sort': 'desc',
        'points': <Map<String, Object?>>[
          <String, Object?>{'label': 'a', 'value': 1},
          <String, Object?>{'label': 'b', 'value': 9},
          <String, Object?>{'label': 'c', 'value': 5},
        ],
      });
      expect(
        spec.series.single.points.map((ChartPoint p) => p.label).toList(),
        <String>['b', 'c', 'a'],
      );
    });

    test('takes the shorthand shapes model output really uses', () {
      // A bare list of points.
      expect(
        ChartSpec.parse(<Object?>[
          <String, Object?>{'label': 'x', 'value': 2},
        ]).unusable,
        isFalse,
      );
      // Label/value pairs.
      final ChartSpec pairs = ChartSpec.parse(<String, Object?>{
        'points': <Object?>[
          <Object?>['Mo', 1],
          <Object?>['Di', 2],
        ],
      });
      expect(pairs.categories, <String>['Mo', 'Di']);
      // A plain map.
      final ChartSpec map = ChartSpec.parse(<String, Object?>{
        'points': <String, Object?>{'AfD': 43.8, 'CDU': 17.2},
      });
      expect(map.categories, <String>['AfD', 'CDU']);
      // Bare numbers with x_labels.
      final ChartSpec bare = ChartSpec.parse(<String, Object?>{
        'labels': <String>['Q1', 'Q2'],
        'points': <double>[3, 4],
      });
      expect(bare.categories, <String>['Q1', 'Q2']);
      // A JSON string.
      expect(
        ChartSpec.parse('{"points":[{"label":"a","value":1}]}').unusable,
        isFalse,
      );
    });

    test('reads the many ways a model writes a number', () {
      final ChartSpec spec = ChartSpec.parse(<String, Object?>{
        'points': <Map<String, Object?>>[
          <String, Object?>{'label': 'a', 'value': '43,8'},
          <String, Object?>{'label': 'b', 'value': '12 %'},
          <String, Object?>{'label': 'c', 'value': r'$1,240.50'},
          <String, Object?>{'label': 'd', 'value': '1.240,50'},
          <String, Object?>{'label': 'e', 'value': -3},
        ],
      });
      expect(
        spec.series.single.points.map((ChartPoint p) => p.value).toList(),
        <double>[43.8, 12, 1240.50, 1240.50, -3],
      );
    });

    test('parses every colour form and refuses invented ones', () {
      expect(parseChartColor('#FF5722'), const Color(0xFFFF5722));
      expect(parseChartColor('FF5722'), const Color(0xFFFF5722));
      expect(parseChartColor('#80FF5722'), const Color(0x80FF5722));
      expect(parseChartColor('#f52'), const Color(0xFFFF5522));
      expect(parseChartColor('blue'), isNull);
      expect(parseChartColor(null), isNull);
      expect(parseChartColor(0xFF112233), const Color(0xFF112233));
    });

    test('an unknown kind still draws as bars', () {
      expect(
        ChartSpec.parse(<String, Object?>{
          'kind': 'sunburst',
          'points': <double>[1, 2],
        }).kind,
        ChartKind.bar,
      );
    });
  });

  group('a bad spec is quiet, never an exception', () {
    test('nothing at all', () {
      final ChartSpec spec = ChartSpec.parse(null);
      expect(spec.unusable, isTrue);
      expect(spec.problems, isNotEmpty);
    });

    test('broken JSON keeps the text for the fallback', () {
      final ChartSpec spec = ChartSpec.parse('{not json');
      expect(spec.unusable, isTrue);
      expect(spec.rawFallbackText, contains('not json'));
      expect(spec.problems.first, contains('JSON'));
    });

    test('points that are not numbers are reported one by one', () {
      final ChartSpec spec = ChartSpec.parse(kMalformed);
      expect(spec.unusable, isTrue);
      expect(spec.problems, hasLength(3));
      expect(spec.problems.first, 'entry 1 (Q1) is not a number');
      expect(spec.title, 'Umsatz nach Quartal');
    });

    test('a partly bad spec keeps the good points', () {
      final ChartSpec spec = ChartSpec.parse(<String, Object?>{
        'points': <Object?>[
          <String, Object?>{'label': 'a', 'value': 1},
          <String, Object?>{'label': 'b', 'value': 'nope'},
        ],
      });
      expect(spec.unusable, isFalse);
      expect(spec.series.single.points, hasLength(1));
      expect(spec.problems, hasLength(1));
    });

    test('a wrong type anywhere is a problem, not a crash', () {
      for (final Object? bad in <Object?>[
        42,
        'plain text',
        <String, Object?>{'points': 'nope'},
        <String, Object?>{'series': 7},
        <String, Object?>{'points': <Object?>[], 'axis': 'wide'},
        <String, Object?>{
          'points': <double>[1],
          'reference_line': <String, Object?>{'label': 'no value'},
        },
      ]) {
        expect(() => ChartSpec.parse(bad), returnsNormally);
      }
    });

    test('decimals are inferred and capped at two', () {
      expect(
        ChartSpec.parse(<String, Object?>{
          'points': <double>[1, 2, 3],
        }).effectiveDecimals,
        0,
      );
      expect(
        ChartSpec.parse(<String, Object?>{
          'points': <double>[1.5, 2],
        }).effectiveDecimals,
        1,
      );
      expect(
        ChartSpec.parse(<String, Object?>{
          'points': <double>[1.23456],
        }).effectiveDecimals,
        2,
      );
    });
  });
}
