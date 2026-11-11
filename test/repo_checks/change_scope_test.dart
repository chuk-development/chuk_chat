// tool/change_scope.dart picks the tests that cover a set of changed files.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/change_scope.dart';

void main() {
  final root = Directory.current.path;

  test('a changed library selects the tests that import it', () {
    final scope = computeChangeScope(
      root,
      changedOverride: const ['lib/l10n/strings_de.dart'],
    );
    expect(scope.runAll, isFalse);
    expect(scope.tests, contains('test/l10n_parity_test.dart'));
    expect(scope.command, startsWith('flutter test test/'));
  });

  test('a changed test selects itself', () {
    final scope = computeChangeScope(
      root,
      changedOverride: const ['test/repo_checks/change_scope_test.dart'],
    );
    expect(scope.tests, ['test/repo_checks/change_scope_test.dart']);
  });

  test('pubspec.yaml means run everything', () {
    final scope = computeChangeScope(
      root,
      changedOverride: const ['pubspec.yaml'],
    );
    expect(scope.runAll, isTrue);
    expect(scope.command, 'flutter test');
  });

  test('a docs-only change needs no Dart test', () {
    final scope = computeChangeScope(
      root,
      changedOverride: const ['docs/GOTCHAS.md'],
    );
    expect(scope.tests, isEmpty);
    expect(scope.command, startsWith('#'));
  });
}
