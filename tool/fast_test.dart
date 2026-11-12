// Runs the whole test suite fast and light: a few bundles instead of one
// compile and one test process per file.
//
// Why: plain `flutter test` compiles the app once per test file (550+ times)
// and starts up to ~14 test processes at once. That is nearly all of its run
// time and CPU; the tests themselves take a few minutes in total. Measured on
// 24 files (2026-11-12): plain 18.5 s wall / 30 s CPU, bundled 8.1 s / 8.7 s.
//
// How:
// 1. The test files are split into [workers] bundles
//    (`test/.bundles/b<n>.dart`, generated, gitignored). A bundle imports each
//    file and runs its `main` in a `group` named after the file, so names and
//    `--name` filters stay as before. Files in `tool/fast_test_isolated.txt`
//    run on their own.
// 2. Each bundle is its own `flutter test --reporter json` call, [workers] at
//    a time. This tool keeps the result per test file and prints progress.
// 3. A bundle with no passing test for [stallSeconds] is stopped. The file
//    it hung in is moved to the "on its own" list; the files it had not
//    finished go on as a new bundle. A bundle that does not load is tried once
//    more as a whole.
// 4. At the end every file that failed or hung in a bundle runs again on its
//    own, exactly like plain `flutter test`; only that result counts. Files
//    that are only green on their own are listed, so they can be fixed or
//    added to the isolated list.
// 5. A lock lets only one full run per checkout go at a time: several agents
//    running the suite at once made every run slow and flaky.
//
// Run it with plain `dart` (not `dart run`, which first runs the package's
// native build hooks and can wait minutes on another build's lock):
//
//   dart tool/fast_test.dart                  # all tests, 4 workers
//   dart tool/fast_test.dart --workers 2      # less CPU and RAM
//   dart tool/fast_test.dart -- --name foo    # extra flutter test args
//   dart tool/fast_test.dart --dry-run        # only write the bundles
//
// Exit code 0 when every test file is green (in its bundle or on its own).
//
// Also needed on a PC that runs T3 Code: scripts/patch_flutter_test_connect.sh
// (T3 Code's port scanner otherwise kills random test files at load).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

const String kBundleDir = 'test/.bundles';
const String kIsolatedList = 'tool/fast_test_isolated.txt';
const String kLockFile = '.dart_tool/fast_test.lock';

/// Files this checkout learned to run alone (hung or leaked in a bundle).
/// Local and gitignored: the list follows the code on this machine.
const String kLearnedList = '.dart_tool/fast_test_learned.txt';

int workers = 4;
int stallSeconds = 90;
int compileSeconds = 900;

/// Totals across all calls, for the progress line.
int totalPassed = 0;
int totalFailed = 0;
final Stopwatch clock = Stopwatch();

Future<void> main(List<String> args) async {
  bool dryRun = false;
  String only = '';
  final List<String> passThrough = <String>[];
  for (int i = 0; i < args.length; i++) {
    final String a = args[i];
    if (a == '--') {
      passThrough.addAll(args.skip(i + 1));
      break;
    } else if ((a == '--workers' || a == '--shards') && i + 1 < args.length) {
      workers = int.parse(args[++i]);
    } else if (a == '--stall' && i + 1 < args.length) {
      stallSeconds = int.parse(args[++i]);
    } else if (a == '--only' && i + 1 < args.length) {
      only = args[++i];
    } else if (a == '--dry-run') {
      dryRun = true;
    } else {
      stderr.writeln('unknown option: $a');
      exit(2);
    }
  }
  if (workers < 1) workers = 1;

  final Set<String> listed = readIsolated(File(kIsolatedList));
  final Set<String> learned = readIsolated(File(kLearnedList));
  final Set<String> isolated = <String>{...listed, ...learned};
  final List<File> all = <File>[
    for (final File f in testFiles(Directory('test')))
      if (only.isEmpty || relPath(f).startsWith(only)) f,
  ];
  final List<File> bundled = <File>[
    for (final File f in all)
      if (!isolated.contains(relPath(f))) f,
  ];
  final List<List<String>> chunks = <List<String>>[
    for (final List<File> g in balance(bundled, workers))
      if (g.isNotEmpty) <String>[for (final File f in g) relPath(f)],
  ];
  final Directory dir = Directory(kBundleDir);
  if (dir.existsSync()) dir.deleteSync(recursive: true);
  dir.createSync(recursive: true);
  stdout.writeln(
    'fast_test: ${bundled.length} files in ${chunks.length} bundles, '
    '${all.length - bundled.length} on their own '
    '(${learned.length} learned), $workers workers',
  );
  if (dryRun) {
    for (int i = 0; i < chunks.length; i++) {
      writeBundle('$kBundleDir/b$i.dart', chunks[i]);
    }
    return;
  }

  final RandomAccessFile lock = await takeLock();
  clock.start();
  final Ticker ticker = Ticker();
  try {
    // ---- Pass 1: bundles ----------------------------------------------
    final Map<String, FileResult> bundleResults = <String, FileResult>{};
    final Set<String> alone = <String>{
      for (final File f in all)
        if (isolated.contains(relPath(f))) relPath(f),
    };
    // The files known to need their own process start at once, in one
    // worker slot next to the bundles, instead of after them.
    final Set<String> startAlone = <String>{...alone};
    final Map<String, FileResult> aloneResults = <String, FileResult>{};
    final List<_Chunk> queue = <_Chunk>[
      if (startAlone.isNotEmpty)
        _Chunk(startAlone.toList()..sort(), plain: true),
      for (final List<String> c in chunks) _Chunk(c),
    ];
    int seq = 0;
    int active = 0;

    Future<void> worker() async {
      while (true) {
        if (queue.isEmpty) {
          if (active == 0) return;
          await Future<void>.delayed(const Duration(milliseconds: 500));
          continue;
        }
        final _Chunk chunk = queue.removeAt(0);
        active++;
        if (chunk.plain) {
          final Call call = await runCall(
            chunk.files,
            passThrough,
            ticker,
            concurrency: 2,
          );
          aloneResults.addAll(call.files);
          active--;
          continue;
        }
        final String path = '$kBundleDir/b${seq++}.dart';
        writeBundle(path, chunk.files);
        final Call call = await runCall(<String>[path], passThrough, ticker);
        call.files.forEach((String k, FileResult v) => bundleResults[k] = v);
        // No test of the bundle reported back: it did not load. A compile
        // error in one file (another agent editing it right now) takes the
        // whole bundle down, so after one plain retry the bundle is halved
        // until the broken file stands alone.
        final bool noResult = call.files.values.every(
          (FileResult r) => r.done == 0,
        );
        if ((call.loadFailed || noResult) &&
            (!call.stalled || call.current.isEmpty)) {
          if (chunk.files.length == 1) {
            alone.addAll(chunk.files);
          } else if (chunk.tries == 0) {
            stdout.writeln(
              'fast_test: a bundle of ${chunk.files.length} did not load; '
              'trying it again.',
            );
            queue.add(_Chunk(chunk.files, tries: 1));
          } else {
            final int half = chunk.files.length ~/ 2;
            stdout.writeln(
              'fast_test: a bundle of ${chunk.files.length} did not load '
              'twice; splitting it.',
            );
            queue
              ..add(_Chunk(chunk.files.sublist(0, half), tries: 1))
              ..add(_Chunk(chunk.files.sublist(half), tries: 1));
          }
        } else if (call.stalled) {
          // Stuck: the file it hung in runs alone, the rest goes on as a new
          // bundle.
          final String hung = call.current;
          if (hung.isNotEmpty) {
            stdout.writeln('fast_test: bundle stuck in $hung; it runs alone.');
            alone.add(hung);
          }
          final List<String> rest = <String>[
            for (final String f in chunk.files)
              if (f != hung && !(call.files[f]?.complete ?? false)) f,
          ];
          if (rest.isNotEmpty) queue.add(_Chunk(rest, tries: chunk.tries));
        }
        active--;
      }
    }

    await Future.wait(<Future<void>>[
      for (int i = 0; i < workers; i++) worker(),
    ]);

    // Per-file results of the bundles, for a look after the run.
    File('.dart_tool/fast_test_last.json').writeAsStringSync(
      const JsonEncoder.withIndent(' ').convert(<String, Object>{
        for (final MapEntry<String, FileResult> e in bundleResults.entries)
          e.key: <String, int>{
            'expected': e.value.expected,
            'done': e.value.done,
            'failed': e.value.failed,
          },
      }),
    );

    // Where each bundle first went wrong: a failure that sets off a chain
    // in the files after it is the one to fix.
    final List<String> firstRed = <String>[
      for (final MapEntry<String, FileResult> e in bundleResults.entries)
        if (e.value.failed > 0) e.key,
    ]..sort();
    if (firstRed.isNotEmpty) {
      stdout.writeln(
        'fast_test: red in the bundles (${firstRed.length} files):',
      );
      for (final String f in firstRed.take(40)) {
        final FileResult r = bundleResults[f]!;
        stdout.writeln(
          '  $f  ${r.failed}/${r.expected}  '
          '${r.errors.isEmpty ? '' : r.errors.first}',
        );
      }
    }

    // ---- Pass 2: on their own -----------------------------------------
    // Pass 2: whatever is not settled yet. Files that already ran alone
    // next to the bundles count with that result.
    final Set<String> retry = <String>{
      for (final String f in alone)
        if (!startAlone.contains(f) || !(aloneResults[f]?.complete ?? false)) f,
    };
    for (final File f in all) {
      final String path = relPath(f);
      if (alone.contains(path)) continue;
      final FileResult? r = bundleResults[path];
      if (r == null || !r.green) retry.add(path);
    }
    Call? second;
    if (retry.isNotEmpty) {
      stdout.writeln(
        'fast_test: ${retry.length} file(s) run on their own '
        '(${alone.length} alone by list or hang, '
        '${retry.length - alone.length} red in the bundles).',
      );
      second = await runCall(
        retry.toList()..sort(),
        passThrough,
        ticker,
        concurrency: workers,
      );
    }

    // ---- Verdict ------------------------------------------------------
    final List<String> red = <String>[];
    final List<String> onlyAlone = <String>[];
    for (final String path in <String>{...retry, ...startAlone}) {
      final FileResult? r = second?.files[path] ?? aloneResults[path];
      if (r != null && r.green) {
        if (!isolated.contains(path)) onlyAlone.add(path);
      } else {
        red.add(path);
      }
    }
    red.sort();
    onlyAlone.sort();
    ticker.stop();

    // Learn: a file that hung or leaked in a bundle starts alone next time,
    // so the next run does not pay for it again. Files gone from the tree
    // drop out of the list.
    final Set<String> exists = <String>{for (final File f in all) relPath(f)};
    final Set<String> nextLearned = <String>{
      for (final String f in learned)
        if (exists.contains(f)) f,
      ...onlyAlone,
      for (final String f in alone)
        if (!listed.contains(f) &&
            ((second?.files[f] ?? aloneResults[f])?.green ?? false))
          f,
    };
    File(kLearnedList)
      ..createSync(recursive: true)
      ..writeAsStringSync(
        '# Written by tool/fast_test.dart: files that hung or leaked state in\n'
        '# a bundle. They run on their own. Delete this file to re-learn.\n'
        '${(nextLearned.toList()..sort()).join('\n')}\n',
      );

    stdout.writeln('\n${'=' * 60}');
    if (onlyAlone.isNotEmpty) {
      stdout.writeln(
        'Only green on their own (they leak or depend on state; fix them or '
        'add them to $kIsolatedList):',
      );
      for (final String p in onlyAlone) {
        stdout.writeln('  $p');
      }
    }
    if (red.isEmpty) {
      stdout.writeln(
        'fast_test: ALL GREEN, $totalPassed tests in '
        '${clock.elapsed.inSeconds} s.',
      );
      exitCode = 0;
    } else {
      stdout.writeln('fast_test: ${red.length} file(s) RED:');
      for (final String p in red) {
        final FileResult? r = second?.files[p] ?? aloneResults[p];
        stdout.writeln('  $p');
        for (final String e
            in r?.errors.take(3) ?? const <String>['no result']) {
          stdout.writeln('      $e');
        }
      }
      stdout.writeln('(${clock.elapsed.inSeconds} s)');
      exitCode = 1;
    }
  } finally {
    ticker.stop();
    await lock.unlock();
    await lock.close();
  }
}

class _Chunk {
  _Chunk(this.files, {this.tries = 0, this.plain = false});
  final List<String> files;
  final int tries;

  /// Run the files as they are, each in its own process (no bundle).
  final bool plain;
}

/// Prints one progress line every 15 s.
class Ticker {
  Ticker() {
    _timer = Timer.periodic(const Duration(seconds: 15), (_) {
      stdout.writeln(
        '  [${clock.elapsed.inSeconds} s] $totalPassed passed, '
        '$totalFailed failed',
      );
    });
  }
  late final Timer _timer;
  void stop() => _timer.cancel();
}

/// The result of one test file.
class FileResult {
  int expected = -1;
  int done = 0;
  int failed = 0;
  final List<String> errors = <String>[];

  /// All its tests reported back.
  bool get complete => expected >= 0 && done >= expected;

  bool get green => complete && failed == 0;
}

/// The result of one `flutter test` call.
class Call {
  final Map<String, FileResult> files = <String, FileResult>{};
  bool stalled = false;
  bool loadFailed = false;

  /// The file of the test that started last.
  String current = '';
}

/// Runs one `flutter test --reporter json` call on [targets].
Future<Call> runCall(
  List<String> targets,
  List<String> passThrough,
  Ticker ticker, {
  int concurrency = 1,
}) async {
  final Call call = Call();
  final Map<int, String> suitePath = <int, String>{};
  final Map<int, String> groupName = <int, String>{};
  final Map<int, String> testFile = <int, String>{};
  final Map<int, String> testName = <int, String>{};
  int passedHere = 0;

  bool inBundle(int suiteId) =>
      (suitePath[suiteId] ?? '').contains('$kBundleDir/');

  String fileFor(int suiteId, List<dynamic> groupIds) {
    if (!inBundle(suiteId)) return suitePath[suiteId] ?? '';
    // In a bundle the first named group is the file's path below test/.
    for (final dynamic g in groupIds) {
      final String name = groupName[g as int] ?? '';
      if (name.isNotEmpty) return 'test/${name.split(' ').first}';
    }
    return '';
  }

  FileResult of(String path) => call.files.putIfAbsent(path, FileResult.new);

  final Process p = await Process.start('flutter', <String>[
    'test',
    '--no-pub',
    '--reporter',
    'json',
    '--concurrency=$concurrency',
    '--timeout=60s',
    ...passThrough,
    ...targets,
  ]);
  unawaited(p.stderr.drain<void>());

  // The watchdog counts passing tests, not events: a hung bundle still sends
  // one timeout failure a minute, which is no progress. Before the first test
  // the compile runs; it gets [compileSeconds].
  DateTime lastPass = DateTime.now();
  final Timer watchdog = Timer.periodic(const Duration(seconds: 5), (_) {
    if (call.stalled) return;
    final int limit = passedHere == 0 ? compileSeconds : stallSeconds;
    if (DateTime.now().difference(lastPass).inSeconds > limit) {
      call.stalled = true;
      // SIGTERM first: flutter test then stops its test processes itself.
      p.kill();
      Timer(const Duration(seconds: 10), () => p.kill(ProcessSignal.sigkill));
    }
  });

  await for (final String line
      in p.stdout.transform(utf8.decoder).transform(const LineSplitter())) {
    if (!line.startsWith('{')) continue;
    final Map<String, dynamic> e;
    try {
      e = jsonDecode(line) as Map<String, dynamic>;
    } on FormatException {
      continue;
    }
    switch (e['type']) {
      case 'suite':
        final Map<String, dynamic> s = e['suite'] as Map<String, dynamic>;
        suitePath[s['id'] as int] = relPath(File(s['path'] as String? ?? ''));
      case 'group':
        final Map<String, dynamic> g = e['group'] as Map<String, dynamic>;
        final String name = g['name'] as String? ?? '';
        groupName[g['id'] as int] = name;
        final int suite = g['suiteID'] as int;
        final int count = g['testCount'] as int? ?? 0;
        if (inBundle(suite)) {
          if (name.isNotEmpty && !name.contains(' ')) {
            of('test/$name').expected = count;
          }
        } else if (g['parentID'] == null) {
          of(suitePath[suite] ?? '').expected = count;
        }
      case 'testStart':
        final Map<String, dynamic> t = e['test'] as Map<String, dynamic>;
        final int id = t['id'] as int;
        final String file = fileFor(
          t['suiteID'] as int,
          t['groupIDs'] as List<dynamic>? ?? const <dynamic>[],
        );
        testFile[id] = file;
        testName[id] = t['name'] as String? ?? '';
        if (file.isNotEmpty) call.current = file;
      case 'error':
        final int id = e['testID'] as int;
        final String file = testFile[id] ?? '';
        final String msg = (e['error'] as String? ?? '').split('\n').first;
        if (file.isNotEmpty) {
          final FileResult r = of(file);
          if (r.errors.length < 5) r.errors.add('${testName[id]}: $msg');
        }
      case 'testDone':
        final int id = e['testID'] as int;
        final String name = testName[id] ?? '';
        final String res = e['result'] as String? ?? 'error';
        if (name.startsWith('loading ')) {
          if (res != 'success') call.loadFailed = true;
          break;
        }
        if (e['hidden'] as bool? ?? false) break;
        final String file = testFile[id] ?? '';
        if (file.isEmpty) break;
        final FileResult r = of(file);
        r.done++;
        if (res == 'success') {
          passedHere++;
          totalPassed++;
          lastPass = DateTime.now();
        } else {
          r.failed++;
          totalFailed++;
        }
    }
  }
  await p.exitCode;
  watchdog.cancel();
  return call;
}

/// Writes one bundle for [files] to [path].
void writeBundle(String path, List<String> files) {
  File(path).writeAsStringSync(
    bundleSource(<File>[for (final String f in files) File(f)]),
  );
}

/// Waits for and takes the per-checkout lock.
Future<RandomAccessFile> takeLock() async {
  final File f = File(kLockFile)..createSync(recursive: true);
  final RandomAccessFile raf = await f.open(mode: FileMode.append);
  try {
    await raf.lock(FileLock.exclusive);
  } on FileSystemException {
    stdout.writeln(
      'fast_test: another full test run is going in this checkout; waiting...',
    );
    await raf.lock(FileLock.blockingExclusive);
  }
  return raf;
}

/// Every `*_test.dart` under [root], sorted, the bundles excluded.
List<File> testFiles(Directory root) {
  final List<File> out = <File>[
    for (final FileSystemEntity e in root.listSync(recursive: true))
      if (e is File &&
          e.path.endsWith('_test.dart') &&
          !relPath(e).startsWith('$kBundleDir/'))
        e,
  ];
  out.sort((File a, File b) => relPath(a).compareTo(relPath(b)));
  return out;
}

/// Paths in [list], one per line; `#` starts a comment.
Set<String> readIsolated(File list) {
  if (!list.existsSync()) return <String>{};
  return <String>{
    for (final String raw in list.readAsLinesSync())
      if (raw.split('#').first.trim() case final String line
          when line.isNotEmpty)
        line,
  };
}

/// [files] spread over [n] groups of about equal size (bytes as the weight:
/// a long file has more tests).
List<List<File>> balance(List<File> files, int n) {
  final List<File> heavyFirst = <File>[...files]
    ..sort((File a, File b) => b.lengthSync().compareTo(a.lengthSync()));
  final List<List<File>> groups = <List<File>>[
    for (int i = 0; i < n; i++) <File>[],
  ];
  final List<int> weight = List<int>.filled(n, 0);
  for (final File f in heavyFirst) {
    int lightest = 0;
    for (int i = 1; i < n; i++) {
      if (weight[i] < weight[lightest]) lightest = i;
    }
    groups[lightest].add(f);
    weight[lightest] += f.lengthSync();
  }
  for (final List<File> g in groups) {
    g.sort((File a, File b) => relPath(a).compareTo(relPath(b)));
  }
  return groups;
}

/// Whether [source] starts the widget test binding. A file that does not
/// gets real HTTP in a bundle, as it would on its own (the binding, once
/// started by any earlier file, answers every request with 400).
bool usesBinding(String source) =>
    source.contains('testWidgets') ||
    source.contains('ensureInitialized') ||
    source.contains('WidgetTester');

/// A bundle: imports each file and runs its `main` inside a group named
/// after the file, so failures still name the file they came from.
String bundleSource(List<File> files) {
  final StringBuffer b = StringBuffer()
    ..writeln('// GENERATED by tool/fast_test.dart. Do not edit.')
    ..writeln("import 'dart:io';")
    ..writeln()
    ..writeln("import 'package:flutter_test/flutter_test.dart';");
  for (int i = 0; i < files.length; i++) {
    final String rel = relPath(files[i]).substring('test/'.length);
    b.writeln("import '../$rel' as t$i;");
  }
  b
    ..writeln()
    ..writeln(
      '/// Goldens resolve next to the test file, not next to the bundle',
    )
    ..writeln('/// (flutter test points the comparator at the started file).')
    ..writeln('void _goldensBeside(String path) {')
    ..writeln('  setUpAll(() {')
    ..writeln('    goldenFileComparator = LocalFileComparator(Uri.file(path));')
    ..writeln('  });')
    ..writeln('}')
    ..writeln()
    ..writeln('/// Real HTTP for a file that never starts the test binding.')
    ..writeln('void _plainHttp() {')
    ..writeln('  HttpOverrides? saved;')
    ..writeln('  setUpAll(() {')
    ..writeln('    saved = HttpOverrides.current;')
    ..writeln('    HttpOverrides.global = null;')
    ..writeln('  });')
    ..writeln('  tearDownAll(() => HttpOverrides.global = saved);')
    ..writeln('}')
    ..writeln()
    ..writeln('void main() {');
  for (int i = 0; i < files.length; i++) {
    final String rel = relPath(files[i]).substring('test/'.length);
    final String abs = files[i].absolute.path.replaceAll(r'\\', '/');
    final bool binding = usesBinding(files[i].readAsStringSync());
    b.writeln("  group('$rel', () {");
    b.writeln("    _goldensBeside('$abs');");
    if (!binding) b.writeln('    _plainHttp();');
    b.writeln('    t$i.main();');
    b.writeln('  });');
  }
  b.writeln('}');
  return b.toString();
}

String relPath(FileSystemEntity f) {
  String p = f.path.replaceAll(r'\', '/');
  final String root = '${Directory.current.path.replaceAll(r'\', '/')}/';
  if (p.startsWith(root)) p = p.substring(root.length);
  return p.startsWith('./') ? p.substring(2) : p;
}
