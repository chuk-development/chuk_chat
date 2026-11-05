// Word ceilings for the standing docs (scripts/doc_budgets.json).
//
// These docs are read by every agent in every session, so each word costs
// context on every run. When one goes over its ceiling, see the "Word
// budgets" section of docs/AGENTS.md.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Whitespace-separated tokens, the way `wc -w` counts them.
int countWords(String text) =>
    text.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).length;

void main() {
  final manifest = jsonDecode(
    File('scripts/doc_budgets.json').readAsStringSync(),
  ) as Map<String, dynamic>;
  final budgets = (manifest['budgets'] as Map<String, dynamic>).map(
    (k, v) => MapEntry(k, v as int),
  );

  test('the budget manifest is not empty', () {
    expect(budgets, isNotEmpty);
  });

  for (final entry in budgets.entries) {
    test('${entry.key} stays within ${entry.value} words', () {
      final file = File(entry.key);
      expect(
        file.existsSync(),
        isTrue,
        reason:
            '${entry.key} is in scripts/doc_budgets.json but does not '
            'exist. Remove the entry or restore the file.',
      );
      final words = countWords(file.readAsStringSync());
      expect(
        words,
        lessThanOrEqualTo(entry.value),
        reason:
            '${entry.key} has $words words, the budget is ${entry.value}. '
            '1) Move content that belongs in another tier (see the tier '
            'table in docs/AGENTS.md) and leave a one-line link. '
            '2) Condense what belongs here. 3) Only if the words really '
            'need the room: raise the ceiling in scripts/doc_budgets.json '
            'and give the reason in the commit message.',
      );
    });
  }
}
