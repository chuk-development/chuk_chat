// Every page with a header uses FloatingPageScaffold
// (lib/widgets/floating_page_scaffold.dart), so no page can look different.
//
// A text scan of lib/. It fails on:
// - a plain `Scaffold(` that gets an `appBar:` (the header must come from
//   FloatingPageScaffold, which fixes the see-through header and the page
//   colour), and
// - a Material `AppBar(` anywhere but lib/widgets/floating_app_bar.dart.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The files that build the frame itself.
const Set<String> _frameFiles = {
  'lib/widgets/floating_app_bar.dart',
  'lib/widgets/floating_page_scaffold.dart',
};

/// Not migrated yet. Another change moves these pages to
/// FloatingPageScaffold; remove each entry when its page is done.
const Set<String> _notMigratedYet = {
  'lib/pages/messenger_shell.dart',
  // Another session owns this file right now. It already floats its header
  // over the page; only the switch to FloatingPageScaffold is missing.
  'lib/pages/media_manager_page.dart',
};

/// [source] with the text of every comment and string literal replaced by
/// spaces. Offsets and line breaks stay, so line numbers stay right, and a
/// bracket or a word inside a comment or a string no longer counts.
String blankCommentsAndStrings(String source) {
  final out = StringBuffer();
  var i = 0;
  void blank(int end) {
    for (; i < end; i++) {
      out.write(source[i] == '\n' ? '\n' : ' ');
    }
  }

  while (i < source.length) {
    if (source.startsWith('//', i)) {
      final nl = source.indexOf('\n', i);
      blank(nl < 0 ? source.length : nl);
      continue;
    }
    if (source.startsWith('/*', i)) {
      final e = source.indexOf('*/', i + 2);
      blank(e < 0 ? source.length : e + 2);
      continue;
    }
    final c = source[i];
    if (c == "'" || c == '"') {
      final raw = i > 0 && source[i - 1] == 'r';
      if (source.startsWith(c * 3, i)) {
        final e = source.indexOf(c * 3, i + 3);
        blank(e < 0 ? source.length : e + 3);
        continue;
      }
      var j = i + 1;
      while (j < source.length && source[j] != c && source[j] != '\n') {
        if (!raw && source[j] == r'\') j++;
        j++;
      }
      blank(j < source.length ? j + 1 : source.length);
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

/// The index of the bracket that closes the `(` at [open], or -1.
/// [code] must come from [blankCommentsAndStrings].
int _closingParen(String code, int open) {
  var depth = 0;
  for (var i = open; i < code.length; i++) {
    final c = code[i];
    if (c == '(' || c == '[' || c == '{') depth++;
    if (c == ')' || c == ']' || c == '}') {
      depth--;
      if (depth == 0) return i;
    }
  }
  return -1;
}

/// True if the call from [open] to [close] has `appBar:` as one of its own
/// named arguments (not one of a nested call).
bool _hasOwnAppBar(String code, int open, int close) {
  final appBar = RegExp(r'(?<!\w)appBar\s*:');
  var depth = 0;
  for (var i = open; i <= close; i++) {
    final c = code[i];
    if (c == '(' || c == '[' || c == '{') depth++;
    if (c == ')' || c == ']' || c == '}') depth--;
    if (depth == 1 && appBar.matchAsPrefix(code, i) != null) return true;
  }
  return false;
}

int _line(String s, int offset) =>
    '\n'.allMatches(s.substring(0, offset)).length + 1;

/// The problems in one file, as "path:line: reason".
List<String> findHeaderProblems(String path, String source) {
  if (_frameFiles.contains(path)) return const [];
  final code = blankCommentsAndStrings(source);
  final problems = <String>[];
  for (final m in RegExp(r'(?<![\w.])Scaffold\(').allMatches(code)) {
    final open = m.end - 1;
    final close = _closingParen(code, open);
    if (close < 0) continue;
    if (_hasOwnAppBar(code, open, close)) {
      problems.add(
        '$path:${_line(code, m.start)}: Scaffold with an appBar. '
        'Use FloatingPageScaffold.',
      );
    }
  }
  for (final m in RegExp(r'(?<![\w.])AppBar\(').allMatches(code)) {
    problems.add(
      '$path:${_line(code, m.start)}: Material AppBar. '
      'Use FloatingPageScaffold with a FloatingAppBar.',
    );
  }
  return problems;
}

void main() {
  group('findHeaderProblems', () {
    test('finds a Scaffold with a FloatingAppBar', () {
      const src = '''
Widget b() => Scaffold(
  appBar: FloatingAppBar(title: Text('x')),
  body: Text('a)b'),
);
''';
      expect(findHeaderProblems('lib/x.dart', src), hasLength(1));
    });

    test('finds a Material AppBar', () {
      const src = "Widget b() => Scaffold(appBar: AppBar(), body: x);";
      expect(findHeaderProblems('lib/x.dart', src), hasLength(2));
    });

    test('allows FloatingPageScaffold and a Scaffold without appBar', () {
      const src = '''
Widget a() => FloatingPageScaffold(appBar: FloatingAppBar(), body: x);
Widget b() => Scaffold(body: Inner(appBar: y));
// Scaffold(appBar: AppBar()) in a comment does not count.
final s = 'see https://x.com Scaffold(appBar: AppBar())';
''';
      expect(findHeaderProblems('lib/x.dart', src), isEmpty);
    });
  });

  test('every page header in lib/ comes from FloatingPageScaffold', () {
    final problems = <String>[];
    final files = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart'));
    for (final file in files) {
      final path = file.path.replaceAll(r'\', '/');
      if (_notMigratedYet.contains(path)) continue;
      problems.addAll(findHeaderProblems(path, file.readAsStringSync()));
    }
    expect(
      problems,
      isEmpty,
      reason:
          'Build every page with FloatingPageScaffold '
          '(lib/widgets/floating_page_scaffold.dart). It makes the header '
          'float over the page and fixes the page colour.',
    );
  });
}
