// The smell counts in lib/ never go above tool/ratchet_baseline.json.
// See tool/ratchet.dart for what is counted and how to update the baseline.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/ratchet.dart';

void main() {
  group('countSmells', () {
    test('counts postfix bangs, not negation or !=', () {
      final c = countSmells('''
void f(String? a, List<int>? l, Map<String, int> m) {
  if (!ok && a != null) print(a!.length + l![0] + m['k']!);
  final s = "not! a bang";
  if (a is! String) return;
}
''');
      expect(c['bang'], 3);
    });

    test('counts ignore comments and as dynamic', () {
      final c = countSmells('''
// ignore_for_file: x
// ignore: y
final v = (w as dynamic).z; // "as dynamic" in a comment does not count
''');
      expect(c['ignore'], 2);
      expect(c['as_dynamic'], 1);
    });

    test('debugPrint under kDebugMode is not counted', () {
      final c = countSmells('''
void f() {
  if (kDebugMode) {
    debugPrint('a');
    if (x) { debugPrint('b'); }
  }
  if (kDebugMode) debugPrint('c');
  debugPrint('d');
  try { g(); } catch (e) { debugPrint('e'); }
}
''');
      expect(c['debug_print'], 2);
    });
  });

  test('no smell count in lib/ is above the baseline', () {
    final root = Directory.current.path;
    final increases = compareToBaseline(
      scanRepository(root),
      readBaseline(root),
    );
    expect(
      increases.map((i) => '$i'),
      isEmpty,
      reason:
          'A count went up. Remove the new `// ignore`, `as dynamic`, postfix '
          '`!` or unguarded `debugPrint` (wrap it in `if (kDebugMode)`). If it '
          'is really needed: `dart run tool/ratchet.dart --write` and give the '
          'reason in the commit message. After removing smells, run '
          '`dart run tool/ratchet.dart --update` to lock the lower count in.',
    );
  });
}
