import 'package:chuk_chat/widgets/chuk_table.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('isTableDelimiterRow', () {
    test('accepts standard and aligned delimiter rows', () {
      expect(isTableDelimiterRow('| --- | --- |'), isTrue);
      expect(isTableDelimiterRow('|:---|:--:|---:|'), isTrue);
      expect(isTableDelimiterRow('--- | ---'), isTrue);
    });

    test('rejects rows that are not delimiters', () {
      expect(isTableDelimiterRow('| a | b |'), isFalse);
      expect(isTableDelimiterRow('| --- | x |'), isFalse);
      expect(isTableDelimiterRow('plain text'), isFalse);
    });
  });

  group('splitTableRow', () {
    test('drops surrounding pipes, keeps interior empties', () {
      expect(splitTableRow('| a | b | c |'), <String>['a', 'b', 'c']);
      expect(splitTableRow('| a |  | c |'), <String>['a', '', 'c']);
    });

    test('respects escaped pipes', () {
      expect(splitTableRow(r'| a \| b | c |'), <String>[r'a \| b', 'c']);
    });
  });

  group('parseTable', () {
    test('parses header, alignments and rows', () {
      final ParsedTable? t = parseTable(<String>[
        '| Pro | Max 5x | Max 20x |',
        '| :--- | :---: | ---: |',
        '| 20 \$/Monat | 100 \$/Monat | 200 \$/Monat |',
        '| 1x | 5x | 20x |',
      ]);
      expect(t, isNotNull);
      expect(t!.columnCount, 3);
      expect(t.header, <String>['Pro', 'Max 5x', 'Max 20x']);
      expect(t.alignments, <TextAlign>[
        TextAlign.left,
        TextAlign.center,
        TextAlign.right,
      ]);
      expect(t.rows.length, 2);
      expect(t.rows.first, <String>['20 \$/Monat', '100 \$/Monat', '200 \$/Monat']);
    });

    test('normalises ragged rows to the column count', () {
      final ParsedTable? t = parseTable(<String>[
        '| a | b | c |',
        '| --- | --- | --- |',
        '| 1 | 2 |',
        '| 1 | 2 | 3 | 4 |',
      ]);
      expect(t, isNotNull);
      expect(t!.rows[0], <String>['1', '2', '']);
      expect(t.rows[1], <String>['1', '2', '3']);
    });

    test('returns null when the second line is not a delimiter', () {
      expect(
        parseTable(<String>['| a | b |', '| c | d |']),
        isNull,
      );
    });
  });
}
