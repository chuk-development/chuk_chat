// Checks that the repository paths the docs name still exist.
//
// Scope: `CLAUDE.md`, `docs/*.md` and the live notes under `docs/notes/`
// (`docs/notes/archived/` is frozen history and may name files that are
// gone). Two kinds of reference are checked:
//
// * a backticked span that looks like a repository path, for example
//   `lib/services/encryption_service.dart` or `docs/GOTCHAS.md:12`. Only
//   spans whose first segment exists at the repository root are checked,
//   so `api_server/main.py` (another repository) or `host/x.py` (a path
//   relative to some subtree) are skipped;
// * a relative Markdown link target, `[text](../FILE.md#anchor)`.
//
// Fenced code blocks are skipped. A path that is gitignored (`.env`,
// `build/...`, `_scratch/...`) counts as existing: it is generated locally.
//
// Run from the repository root:
//
//   dart run tool/verify_doc_refs.dart
//
// Exceptions, each with a reason, live in `tool/verify_doc_refs_allow.json`.
// Exit code 1 lists every broken reference as `file:line: path`.
// `test/repo_checks/doc_refs_test.dart` runs the same check under
// `flutter test`.

import 'dart:convert';
import 'dart:io';

/// One reference that does not resolve.
class BrokenDocRef {
  const BrokenDocRef(this.file, this.line, this.target);

  /// Doc file, relative to the repository root.
  final String file;

  /// 1-based line number.
  final int line;

  /// The path as written in the doc.
  final String target;

  @override
  String toString() => '$file:$line: $target';
}

/// Docs that are checked, relative to [root].
List<String> docFilesToCheck(String root) {
  final files = <String>['CLAUDE.md'];
  final docs = Directory('$root/docs');
  if (docs.existsSync()) {
    for (final e in docs.listSync()) {
      if (e is File && e.path.endsWith('.md')) {
        files.add(_rel(root, e.path));
      }
    }
  }
  for (final status in const ['proposed', 'implemented', 'rejected']) {
    final dir = Directory('$root/docs/notes/$status');
    if (!dir.existsSync()) continue;
    for (final e in dir.listSync(recursive: true)) {
      if (e is File && e.path.endsWith('.md')) files.add(_rel(root, e.path));
    }
  }
  final readme = File('$root/docs/notes/README.md');
  if (readme.existsSync()) files.add('docs/notes/README.md');
  files.sort();
  return files.toSet().toList();
}

String _rel(String root, String path) =>
    path.startsWith('$root/') ? path.substring(root.length + 1) : path;

final RegExp _backtickSpan = RegExp(r'`([^`\n]+)`');
final RegExp _mdLink = RegExp(r'\]\(([^)\s]+)(?:\s+"[^"]*")?\)');
final RegExp _pathLike = RegExp(r'^[A-Za-z0-9_.\-/]+$');

/// Strips `:12`, `:12-30`, `#anchor` and trailing punctuation from [raw].
String _cleanPath(String raw) {
  var s = raw.trim();
  final hash = s.indexOf('#');
  if (hash >= 0) s = s.substring(0, hash);
  s = s.replaceFirst(RegExp(r':[0-9][0-9,\-]*$'), '');
  while (s.isNotEmpty && '.,;:)'.contains(s[s.length - 1])) {
    s = s.substring(0, s.length - 1);
  }
  return s;
}

/// Whether [span] (a backticked span, cleaned) should be treated as a
/// repository path.
bool _looksLikeRepoPath(String span, Set<String> rootEntries) {
  if (span.isEmpty || !_pathLike.hasMatch(span)) return false;
  if (span.startsWith('/') || span.contains('..')) return false;
  final first = span.split('/').first;
  if (!rootEntries.contains(first)) return false;
  // A bare root entry (`lib`, `CLAUDE.md`) exists by construction.
  // Require a slash or a file extension, so words like `test` are not
  // treated as paths.
  return span.contains('/') || span.contains('.');
}

/// Names (files and directories) at the repository root.
Set<String> _rootEntries(String root) =>
    Directory(root)
        .listSync()
        .map((e) => e.path.substring(root.length + 1))
        .where((n) => n != '.git')
        .toSet();

bool _existsOrIgnored(String root, String rel, Map<String, bool> cache) {
  return cache.putIfAbsent(rel, () {
    final path = '$root/$rel';
    if (FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound) {
      return true;
    }
    // Keep a trailing slash: a `dir/` pattern only matches a path git
    // knows to be a directory.
    final r = Process.runSync('git', [
      'check-ignore',
      '-q',
      '--no-index',
      rel,
    ], workingDirectory: root);
    return r.exitCode == 0;
  });
}

/// The allow list: docs whose backticked paths are not checked, and
/// backticked paths that are allowed everywhere.
({Set<String> files, Set<String> targets}) _loadAllow(String root) {
  final f = File('$root/tool/verify_doc_refs_allow.json');
  if (!f.existsSync()) return (files: <String>{}, targets: <String>{});
  final json = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
  Set<String> keys(String k) =>
      ((json[k] as Map<String, dynamic>?) ?? const {}).keys.toSet();
  return (files: keys('files'), targets: keys('targets'));
}

/// Every broken reference in the checked docs under [root].
List<BrokenDocRef> findBrokenDocRefs(String root) {
  final allow = _loadAllow(root);
  final rootEntries = _rootEntries(root);
  final cache = <String, bool>{};
  final broken = <BrokenDocRef>[];
  for (final rel in docFilesToCheck(root)) {
    final file = File('$root/$rel');
    if (!file.existsSync()) continue;
    final dir = rel.contains('/') ? rel.substring(0, rel.lastIndexOf('/')) : '';
    var inFence = false;
    final lines = file.readAsLinesSync();
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.trimLeft().startsWith('```')) {
        inFence = !inFence;
        continue;
      }
      if (inFence) continue;

      for (final m in _backtickSpan.allMatches(line)) {
        if (allow.files.contains(rel)) break;
        final path = _cleanPath(m.group(1)!);
        if (!_looksLikeRepoPath(path, rootEntries)) continue;
        if (allow.targets.contains(path)) continue;
        if (!_existsOrIgnored(root, path, cache)) {
          broken.add(BrokenDocRef(rel, i + 1, path));
        }
      }

      for (final m in _mdLink.allMatches(line)) {
        final target = m.group(1)!;
        if (target.contains('://') ||
            target.startsWith('mailto:') ||
            target.startsWith('#') ||
            target.contains('<') ||
            target.startsWith('...')) {
          continue;
        }
        final path = _cleanPath(target);
        if (path.isEmpty) continue;
        final resolved = _normalize(dir.isEmpty ? path : '$dir/$path');
        if (resolved == null || !_existsOrIgnored(root, resolved, cache)) {
          broken.add(BrokenDocRef(rel, i + 1, target));
        }
      }
    }
  }
  return broken;
}

/// Resolves `.` and `..` segments; null if the path leaves the repository.
String? _normalize(String path) {
  final out = <String>[];
  for (final seg in path.split('/')) {
    if (seg.isEmpty || seg == '.') continue;
    if (seg == '..') {
      if (out.isEmpty) return null;
      out.removeLast();
    } else {
      out.add(seg);
    }
  }
  return out.join('/');
}

void main(List<String> args) {
  final root = Directory.current.path;
  final broken = findBrokenDocRefs(root);
  if (broken.isEmpty) {
    stdout.writeln('verify_doc_refs: all references resolve.');
    return;
  }
  stderr.writeln('verify_doc_refs: ${broken.length} broken reference(s):');
  for (final b in broken) {
    stderr.writeln('  $b');
  }
  stderr.writeln(
    'Fix the path in the doc, or restore the file. Frozen history belongs '
    'in docs/notes/archived/, which is not checked.',
  );
  exitCode = 1;
}
