// Maps the changed files to the tests that cover them and prints the
// `flutter test` command for exactly those tests.
//
// Changed files = committed since the merge base with the base ref
// (default `origin/master`) + staged + unstaged + untracked.
//
// A test is selected when
// * it is itself a changed `_test.dart` file;
// * it sits at the mirrored path: `lib/a/b.dart` -> `test/a/b_test.dart`;
// * it imports a changed library, directly
//   (`package:chuk_chat/a/b.dart`, or a relative import).
//
// The scoped run is for the edit loop. It does not replace the full
// `flutter test` + CodeRabbit gate before a push (see CLAUDE.md and
// `.agents/skills/pre-push-checks/SKILL.md`).
//
//   dart run tool/change_scope.dart              # vs origin/master
//   dart run tool/change_scope.dart --base HEAD~3
//   dart run tool/change_scope.dart --json       # machine-readable
//
// Exit code 0 always; prints `flutter test` with no paths when a change
// cannot be scoped (pubspec, analysis options, test helpers) so the caller
// runs everything.

import 'dart:convert';
import 'dart:io';

/// Files that change what every test sees; any of them means "run all".
const List<String> kRunAllTriggers = <String>[
  'pubspec.yaml',
  'pubspec.lock',
  'analysis_options.yaml',
  'test/flutter_test_config.dart',
];

/// Test directories whose helpers are shared by many tests.
const List<String> kSharedTestDirs = <String>['test/helpers/', 'test/support/'];

class ChangeScope {
  ChangeScope({
    required this.base,
    required this.mergeBase,
    required this.changed,
    required this.tests,
    required this.runAll,
    required this.reasons,
  });

  final String base;
  final String? mergeBase;
  final List<String> changed;
  final List<String> tests;
  final bool runAll;
  final List<String> reasons;

  String get command => runAll || tests.isEmpty && changed.any(_affectsDart)
      ? 'flutter test'
      : tests.isEmpty
      ? '# no Dart test covers this change'
      : 'flutter test ${tests.join(' ')}';

  Map<String, Object?> toJson() => <String, Object?>{
    'base': base,
    'mergeBase': mergeBase,
    'changed': changed,
    'tests': tests,
    'runAll': runAll,
    'reasons': reasons,
    'command': command,
  };
}

bool _affectsDart(String path) => path.endsWith('.dart');

List<String> _git(String root, List<String> args) {
  final r = Process.runSync('git', args, workingDirectory: root);
  if (r.exitCode != 0) return const <String>[];
  return (r.stdout as String)
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.isNotEmpty)
      .toList();
}

/// Changed paths relative to [root].
({String? mergeBase, List<String> files}) changedFiles(
  String root,
  String base,
) {
  final mb = _git(root, ['merge-base', base, 'HEAD']);
  final mergeBase = mb.isEmpty ? null : mb.first;
  final files = <String>{
    if (mergeBase != null)
      ..._git(root, ['diff', '--name-only', mergeBase, 'HEAD']),
    ..._git(root, ['diff', '--name-only', '--cached']),
    ..._git(root, ['diff', '--name-only']),
    ..._git(root, ['ls-files', '--others', '--exclude-standard']),
  };
  return (mergeBase: mergeBase, files: files.toList()..sort());
}

final RegExp _importRe = RegExp(
  r'''^\s*(?:import|export|part)\s+['"]([^'"]+)['"]''',
  multiLine: true,
);

/// The repository paths [testFile] imports, resolved from `package:chuk_chat/`
/// and relative URIs.
Set<String> _importsOf(String root, String testFile) {
  final src = File('$root/$testFile').readAsStringSync();
  final dir = testFile.substring(0, testFile.lastIndexOf('/'));
  final out = <String>{};
  for (final m in _importRe.allMatches(src)) {
    final uri = m.group(1)!;
    if (uri.startsWith('package:chuk_chat/')) {
      out.add('lib/${uri.substring('package:chuk_chat/'.length)}');
    } else if (!uri.contains(':')) {
      out.add(_normalize('$dir/$uri'));
    }
  }
  return out;
}

String _normalize(String path) {
  final out = <String>[];
  for (final seg in path.split('/')) {
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      if (out.isNotEmpty) out.removeLast();
    } else {
      out.add(seg);
    }
  }
  return out.join('/');
}

ChangeScope computeChangeScope(
  String root, {
  String base = 'origin/master',
  List<String>? changedOverride,
}) {
  final String? mergeBase;
  final List<String> changed;
  if (changedOverride != null) {
    mergeBase = null;
    changed = changedOverride;
  } else {
    final c = changedFiles(root, base);
    mergeBase = c.mergeBase;
    changed = c.files;
  }

  final reasons = <String>[];
  var runAll = false;
  for (final f in changed) {
    if (kRunAllTriggers.contains(f)) {
      runAll = true;
      reasons.add('$f changes what every test sees');
    } else if (kSharedTestDirs.any(f.startsWith)) {
      runAll = true;
      reasons.add('$f is a shared test helper');
    }
  }

  final allTests =
      Directory('$root/test').existsSync()
            ? Directory('$root/test')
                  .listSync(recursive: true)
                  .whereType<File>()
                  .map((f) => f.path.substring(root.length + 1))
                  .where((p) => p.endsWith('_test.dart'))
                  .toList()
            : <String>[]
        ..sort();

  final changedSet = changed.toSet();
  final selected = <String>{};
  for (final f in changed) {
    if (f.startsWith('test/') &&
        f.endsWith('_test.dart') &&
        File('$root/$f').existsSync()) {
      selected.add(f);
    }
    if (f.startsWith('lib/') && f.endsWith('.dart')) {
      final mirrored = 'test/${f.substring(4, f.length - 5)}_test.dart';
      if (File('$root/$mirrored').existsSync()) selected.add(mirrored);
    }
  }
  for (final t in allTests) {
    if (selected.contains(t)) continue;
    if (_importsOf(root, t).any(changedSet.contains)) selected.add(t);
  }

  return ChangeScope(
    base: base,
    mergeBase: mergeBase,
    changed: changed,
    tests: selected.toList()..sort(),
    runAll: runAll,
    reasons: reasons,
  );
}

void main(List<String> args) {
  var base = 'origin/master';
  final i = args.indexOf('--base');
  if (i >= 0 && i + 1 < args.length) base = args[i + 1];
  final scope = computeChangeScope(Directory.current.path, base: base);

  if (args.contains('--json')) {
    stdout.writeln(const JsonEncoder.withIndent('  ').convert(scope.toJson()));
    return;
  }
  stdout.writeln(
    'change_scope: ${scope.changed.length} changed file(s) vs $base'
    '${scope.mergeBase == null ? ' (no merge base found)' : ''}',
  );
  for (final r in scope.reasons) {
    stdout.writeln('  run all: $r');
  }
  if (!scope.runAll) {
    stdout.writeln('  ${scope.tests.length} test file(s) cover the change');
  }
  stdout.writeln(scope.command);
}
