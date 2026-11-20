// The UI library (lib/ui/components/) is the one place that draws page
// headers and the interactive surface of a list item. docs/DESIGN.md §2.2.
//
// A text scan of lib/. It fails on:
// - a `SliverAppBar(` or a `BackdropFilter(` outside the library: a page
//   header comes from FloatingAppBar on PageHeaderBackdrop, and
// - more `InkWell(`, `InkResponse(` or `ListTile(` calls in a file than the
//   baseline allows. A list row uses StateSurface, which paints rest, hover,
//   focus, press and selection in one shape. A file that drew its own ink
//   is in the baseline; the baseline may only shrink.
//
// After a migration the count in a file goes down, and this test asks to
// lower the baseline too, so the allowlist cannot grow back silently:
//   UI_LIBRARY_WRITE=1 flutter test test/repo_checks/ui_library_test.dart
// writes the current counts. Use it only to lower numbers.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'floating_page_scaffold_test.dart' show blankCommentsAndStrings;

const String _baselinePath = 'test/repo_checks/ui_library_baseline.json';

/// The library itself, and the chrome widgets it is built from.
const Set<String> _libraryFiles = <String>{
  'lib/ui/components/page_header.dart',
  'lib/ui/components/state_surface.dart',
  'lib/widgets/floating_app_bar.dart',
};

/// Uses of a blur that are not a page header: a menu that blurs the chat
/// behind it, the assistant overlay.
const Set<String> _blurAllowed = <String>{
  'lib/assistant/assistant_overlay.dart',
  'lib/widgets/messenger_context_menu.dart',
};

final RegExp _ownInk = RegExp(r'(?<![\w.])(InkWell|InkResponse|ListTile)\(');
final RegExp _sliverAppBar = RegExp(r'(?<![\w.])SliverAppBar\(');
final RegExp _blur = RegExp(r'(?<![\w.])BackdropFilter\(');

int _line(String s, int offset) =>
    '\n'.allMatches(s.substring(0, offset)).length + 1;

/// The header problems in one file, as "path:line: reason".
List<String> findHeaderCopies(String path, String source) {
  if (_libraryFiles.contains(path)) return const <String>[];
  final String code = blankCommentsAndStrings(source);
  return <String>[
    for (final RegExpMatch m in _sliverAppBar.allMatches(code))
      '$path:${_line(code, m.start)}: SliverAppBar. Use FloatingPageScaffold '
          'with a FloatingAppBar.',
    if (!_blurAllowed.contains(path))
      for (final RegExpMatch m in _blur.allMatches(code))
        '$path:${_line(code, m.start)}: BackdropFilter. A header uses '
            'PageHeaderBackdrop (through FloatingAppBar or TopVeil).',
  ];
}

/// How many own ink surfaces (InkWell, InkResponse, ListTile) [source] builds.
int countOwnInk(String path, String source) {
  if (_libraryFiles.contains(path)) return 0;
  return _ownInk.allMatches(blankCommentsAndStrings(source)).length;
}

Map<String, int> _scan() {
  final Map<String, int> counts = <String, int>{};
  final List<File> files =
      Directory('lib')
          .listSync(recursive: true)
          .whereType<File>()
          .where((File f) => f.path.endsWith('.dart'))
          .toList()
        ..sort((File a, File b) => a.path.compareTo(b.path));
  for (final File file in files) {
    final String path = file.path.replaceAll(r'\', '/');
    final int n = countOwnInk(path, file.readAsStringSync());
    if (n > 0) counts[path] = n;
  }
  return counts;
}

void main() {
  group('scanner', () {
    test('counts InkWell, InkResponse and ListTile, not comments', () {
      const String src = '''
Widget a() => InkWell(onTap: f, child: ListTile(title: x));
// InkWell( in a comment does not count
final s = 'InkResponse(';
Widget b() => InkResponse(onTap: f);
Widget c() => StateSurface(borderRadius: r, child: x);
''';
      expect(countOwnInk('lib/x.dart', src), 3);
      expect(countOwnInk('lib/ui/components/state_surface.dart', src), 0);
    });

    test('finds a SliverAppBar and a BackdropFilter', () {
      const String src = '''
Widget a() => SliverAppBar(title: x);
Widget b() => BackdropFilter(filter: f, child: x);
''';
      expect(findHeaderCopies('lib/x.dart', src), hasLength(2));
      expect(
        findHeaderCopies('lib/widgets/messenger_context_menu.dart', src),
        hasLength(1),
      );
    });
  });

  test('no page builds its own header material', () {
    final List<String> problems = <String>[];
    for (final File file
        in Directory('lib')
            .listSync(recursive: true)
            .whereType<File>()
            .where((File f) => f.path.endsWith('.dart'))) {
      final String path = file.path.replaceAll(r'\', '/');
      problems.addAll(findHeaderCopies(path, file.readAsStringSync()));
    }
    expect(problems, isEmpty);
  });

  test('own ink surfaces in lib/ only go down (baseline ratchet)', () {
    final Map<String, int> now = _scan();
    final File baselineFile = File(_baselinePath);
    if (Platform.environment['UI_LIBRARY_WRITE'] == '1') {
      baselineFile.writeAsStringSync(
        '${const JsonEncoder.withIndent('  ').convert(now)}\n',
      );
    }
    final Map<String, dynamic> raw =
        jsonDecode(baselineFile.readAsStringSync()) as Map<String, dynamic>;
    final Map<String, int> baseline = <String, int>{
      for (final MapEntry<String, dynamic> e in raw.entries)
        e.key: (e.value as num).toInt(),
    };
    final List<String> above = <String>[];
    final List<String> below = <String>[];
    for (final String path in <String>{...now.keys, ...baseline.keys}) {
      final int n = now[path] ?? 0;
      final int allowed = baseline[path] ?? 0;
      if (n > allowed) above.add('$path: $n (allowed $allowed)');
      if (n < allowed) below.add('$path: $n (baseline $allowed)');
    }
    expect(
      above,
      isEmpty,
      reason:
          'A list row draws its own ink. Use StateSurface '
          '(lib/ui/components/state_surface.dart): one shape for rest, '
          'hover, focus, press and selection.',
    );
    expect(
      below,
      isEmpty,
      reason:
          'Good: a file lost an own ink surface. Lower the baseline: '
          'UI_LIBRARY_WRITE=1 flutter test test/repo_checks/ui_library_test.dart',
    );
  });
}
