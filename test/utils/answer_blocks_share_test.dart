import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/utils/answer_blocks_parser.dart';

void main() {
  group('::: share', () {
    test('is a block kind', () {
      final segs = splitAnswerBlocks(
        '::: share Owners\nA | 50 %\nB | 50 %\n:::',
      );
      expect(segs.single, isA<AnswerBlockSegment>());
      expect((segs.single as AnswerBlockSegment).kind, AnswerBlockKind.share);
    });

    test('adds the missing rest so the parts make 100 %', () {
      final ShareSpec spec = parseShare('Nvidia', <String>[
        'BlackRock | 7,43 % | ~1,81 Mrd. Aktien',
        'Vanguard | 7,31 %',
        'Fidelity | ~4,3 %',
        'State Street | 4,19 %',
        'Jensen Huang | 3,58 %',
      ])!;
      expect(spec.rows, hasLength(6));
      expect(spec.restIndex, 5);
      expect(spec.rows.last.label, 'Rest');
      expect(spec.rows.last.valueText, '73,19 %');
      expect(spec.rows.last.value, closeTo(73.19, 0.001));
      expect(spec.fraction(0), closeTo(0.0743, 0.0001));
      expect(spec.rows.first.sub, '~1,81 Mrd. Aktien');
    });

    test('a named rest row moves to the end and nothing is added', () {
      final ShareSpec spec = parseShare('', <String>[
        'Streubesitz | 73,2 %',
        'BlackRock | 7,4 %',
        'rest: ignored here',
      ])!;
      expect(spec.rows.map((r) => r.label), <String>[
        'BlackRock',
        'Streubesitz',
      ]);
      expect(spec.restIndex, 1);
    });

    test('rest: names the added row; total: sets the whole', () {
      final ShareSpec spec = parseShare('', <String>[
        'rest: Free float',
        'total: 200',
        'A | 50',
        'B | 50',
      ])!;
      expect(spec.total, 200);
      expect(spec.rows.last.label, 'Free float');
      expect(spec.rows.last.valueText, '100');
      expect(spec.fraction(0), 0.25);
    });

    test('a full 100 % gets no rest', () {
      final ShareSpec spec = parseShare('', <String>[
        'A | 60 %',
        'B | 39.8 %',
      ])!;
      expect(spec.restIndex, -1);
      expect(spec.rows, hasLength(2));
    });

    test('fewer than two numbers is not a share', () {
      expect(parseShare('', <String>['A | lots', 'B | 10 %']), isNull);
    });
  });
}
