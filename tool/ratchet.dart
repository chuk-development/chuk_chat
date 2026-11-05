// Ratchet for code smells in lib/: counts may go down, never up.
//
// Counted per file (generated `*.g.dart` files are skipped):
//
// * `ignore`      — `// ignore:` and `// ignore_for_file:` comments;
// * `as_dynamic`  — `as dynamic` casts;
// * `bang`        — postfix null assertions (`x!`, `f()!`, `a[i]!`), counted
//                   on the code with comments and string literals removed;
// * `debug_print` — `debugPrint(` calls that are not inside an
//                   `if (kDebugMode)` block or statement (best effort: an
//                   early `if (!kDebugMode) return;` is not recognised, the
//                   baseline carries those).
//
// The baseline is `tool/ratchet_baseline.json`.
// `test/repo_checks/ratchet_test.dart` fails when any count is above it;
// a new file starts at zero.
//
// From the repository root:
//
//   dart run tool/ratchet.dart            # check, list every increase
//   dart run tool/ratchet.dart --update   # shrink the baseline to the
//                                         # current counts (never raises)
//   dart run tool/ratchet.dart --write    # write the current counts as they
//                                         # are, raises included; say why in
//                                         # the commit message
//
// Run `--update` after removing smells, so the lower count is locked in.

import 'dart:convert';
import 'dart:io';

/// Metric names, in report order.
const List<String> kRatchetMetrics = <String>[
  'ignore',
  'as_dynamic',
  'bang',
  'debug_print',
];

const String kRatchetBaselinePath = 'tool/ratchet_baseline.json';

/// Counts per metric for one Dart source.
Map<String, int> countSmells(String source) {
  final ignore = RegExp(r'//\s*ignore(_for_file)?\s*:')
      .allMatches(source)
      .length;
  final code = stripCommentsAndStrings(source);
  final asDynamic = RegExp(r'\bas\s+dynamic\b').allMatches(code).length;
  // `is!` is a type test, not a null assertion.
  final bang = RegExp(r'[A-Za-z0-9_)\]]!(?!=)')
      .allMatches(code.replaceAll(RegExp(r'\bis!'), 'is '))
      .length;
  return <String, int>{
    'ignore': ignore,
    'as_dynamic': asDynamic,
    'bang': bang,
    'debug_print': _unguardedDebugPrints(code),
  };
}

/// [source] with comments removed and every string literal replaced by
/// `""`. Interpolations inside strings are dropped with the string; good
/// enough for counting.
String stripCommentsAndStrings(String source) {
  final out = StringBuffer();
  var i = 0;
  final n = source.length;
  while (i < n) {
    final c = source[i];
    final next = i + 1 < n ? source[i + 1] : '';
    if (c == '/' && next == '/') {
      while (i < n && source[i] != '\n') {
        i++;
      }
      continue;
    }
    if (c == '/' && next == '*') {
      var depth = 1;
      i += 2;
      while (i < n && depth > 0) {
        if (source.startsWith('/*', i)) {
          depth++;
          i += 2;
        } else if (source.startsWith('*/', i)) {
          depth--;
          i += 2;
        } else {
          if (source[i] == '\n') out.write('\n');
          i++;
        }
      }
      continue;
    }
    final raw = c == 'r' && (next == '"' || next == "'");
    if (c == '"' || c == "'" || raw) {
      final start = raw ? i + 1 : i;
      final q = source[start];
      final triple = source.startsWith('$q$q$q', start);
      final delim = triple ? '$q$q$q' : q;
      i = start + delim.length;
      while (i < n) {
        if (!raw && source[i] == r'\') {
          i += 2;
          continue;
        }
        if (source.startsWith(delim, i)) {
          i += delim.length;
          break;
        }
        if (!triple && source[i] == '\n') break;
        if (source[i] == '\n') out.write('\n');
        i++;
      }
      out.write('""');
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

/// `debugPrint(` calls in [code] (comments and strings already stripped)
/// that are neither in a block opened under a `kDebugMode` condition nor in
/// a statement that mentions `kDebugMode`.
int _unguardedDebugPrints(String code) {
  final stack = <bool>[false];
  var statementStart = 0;
  var count = 0;
  var i = 0;
  while (i < code.length) {
    final c = code[i];
    if (c == '{') {
      final head = code.substring(statementStart, i);
      stack.add(stack.last || head.contains('kDebugMode'));
      statementStart = i + 1;
    } else if (c == '}') {
      if (stack.length > 1) stack.removeLast();
      statementStart = i + 1;
    } else if (c == ';') {
      statementStart = i + 1;
    } else if (c == 'd' && code.startsWith('debugPrint(', i)) {
      final before = i == 0 ? '' : code[i - 1];
      final isIdentifierPart = RegExp(r'[A-Za-z0-9_.]').hasMatch(before);
      if (!isIdentifierPart &&
          !stack.last &&
          !code.substring(statementStart, i).contains('kDebugMode')) {
        count++;
      }
      i += 'debugPrint('.length;
      continue;
    }
    i++;
  }
  return count;
}

/// Current counts for every non-generated Dart file under `lib/`, keyed by
/// repository-relative path. Files with all counts at zero are left out.
Map<String, Map<String, int>> scanRepository(String root) {
  final result = <String, Map<String, int>>{};
  final files =
      Directory('$root/lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .where((f) => !f.path.endsWith('.g.dart'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  for (final f in files) {
    final rel = f.path.substring(root.length + 1);
    final counts = countSmells(f.readAsStringSync());
    counts.removeWhere((_, v) => v == 0);
    if (counts.isNotEmpty) result[rel] = counts;
  }
  return result;
}

Map<String, Map<String, int>> readBaseline(String root) {
  final f = File('$root/$kRatchetBaselinePath');
  if (!f.existsSync()) return <String, Map<String, int>>{};
  final json = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  final files = json['files'] as Map<String, dynamic>;
  return <String, Map<String, int>>{
    for (final e in files.entries)
      e.key: <String, int>{
        for (final m in (e.value as Map<String, dynamic>).entries)
          m.key: m.value as int,
      },
  };
}

void writeBaseline(String root, Map<String, Map<String, int>> files) {
  final totals = <String, int>{for (final m in kRatchetMetrics) m: 0};
  for (final counts in files.values) {
    counts.forEach((k, v) => totals[k] = (totals[k] ?? 0) + v);
  }
  final sorted = Map.fromEntries(
    files.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
  );
  final json = <String, Object>{
    '_comment':
        'Generated by tool/ratchet.dart. Counts may only go down; run '
        '`dart run tool/ratchet.dart --update` after removing smells.',
    'totals': totals,
    'files': sorted,
  };
  File(
    '$root/$kRatchetBaselinePath',
  ).writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(json)}\n');
}

/// One count above the baseline.
class RatchetIncrease {
  const RatchetIncrease(this.file, this.metric, this.baseline, this.current);
  final String file;
  final String metric;
  final int baseline;
  final int current;

  @override
  String toString() => '$file: $metric $baseline -> $current';
}

List<RatchetIncrease> compareToBaseline(
  Map<String, Map<String, int>> current,
  Map<String, Map<String, int>> baseline,
) {
  final out = <RatchetIncrease>[];
  for (final e in current.entries) {
    final base = baseline[e.key] ?? const <String, int>{};
    for (final m in e.value.entries) {
      final b = base[m.key] ?? 0;
      if (m.value > b) out.add(RatchetIncrease(e.key, m.key, b, m.value));
    }
  }
  return out;
}

void main(List<String> args) {
  final root = Directory.current.path;
  final current = scanRepository(root);
  final baseline = readBaseline(root);

  if (args.contains('--write')) {
    writeBaseline(root, current);
    stdout.writeln('ratchet: wrote current counts to $kRatchetBaselinePath');
    return;
  }
  if (args.contains('--update')) {
    final shrunk = <String, Map<String, int>>{};
    for (final e in baseline.entries) {
      final now = current[e.key];
      if (now == null) continue;
      final counts = <String, int>{};
      for (final m in e.value.entries) {
        final c = now[m.key] ?? 0;
        final v = c < m.value ? c : m.value;
        if (v > 0) counts[m.key] = v;
      }
      if (counts.isNotEmpty) shrunk[e.key] = counts;
    }
    writeBaseline(root, shrunk);
    stdout.writeln('ratchet: baseline shrunk to the current counts.');
    return;
  }

  final increases = compareToBaseline(current, baseline);
  if (increases.isEmpty) {
    stdout.writeln('ratchet: no count went up.');
    return;
  }
  stderr.writeln('ratchet: ${increases.length} count(s) went up:');
  for (final i in increases) {
    stderr.writeln('  $i');
  }
  stderr.writeln(
    'Remove the new ignore / as dynamic / ! / unguarded debugPrint. Only if '
    'it really is needed: dart run tool/ratchet.dart --write, and say why in '
    'the commit message.',
  );
  exitCode = 1;
}
