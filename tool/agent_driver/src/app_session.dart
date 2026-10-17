// Starts and stops the app for the agent driver, and talks to its VM service.
//
// The app runs as `flutter run -d linux -t test_driver/main_agent.dart
// --machine`, in its own process group (setsid), with the isolated
// environment of isolation.dart. With `headless` (the default), it runs
// under xvfb-run, so no window opens on the desktop of the user.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

import 'isolation.dart';
import 'machine_events.dart';

/// What the tools need from a running app. [AppSession] is the real one;
/// tests use a fake.
abstract class AppControl {
  bool get running;

  Future<Map<String, Object?>> start({
    required bool headless,
    required bool fresh,
    String? definesFile,
  });

  Future<Map<String, Object?>> stop();

  Map<String, Object?> status();

  List<String> logs(int lines);

  /// Sends one Flutter Driver command. Returns the `response` field. Throws
  /// [DriverCommandError] when the driver reports an error.
  Future<Object?> driver(Map<String, String> params);

  /// Calls a service extension of the app (for example
  /// `ext.chuk.agent.state`) and returns the decoded result.
  Future<Map<String, Object?>> extension(
    String method, [
    Map<String, String> args = const <String, String>{},
  ]);

  Future<Map<String, Object?>> hotReload({required bool fullRestart});
}

class DriverCommandError implements Exception {
  DriverCommandError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Paths of the driver, all inside the repository.
class DriverPaths {
  DriverPaths(this.repoRoot);

  /// Finds the repository root from the location of this script.
  factory DriverPaths.fromScript() {
    String dir = p.dirname(p.fromUri(Platform.script));
    while (true) {
      if (File(p.join(dir, 'pubspec.yaml')).existsSync() &&
          Directory(p.join(dir, 'tool', 'agent_driver')).existsSync()) {
        return DriverPaths(dir);
      }
      final String parent = p.dirname(dir);
      if (parent == dir) return DriverPaths(Directory.current.path);
      dir = parent;
    }
  }

  final String repoRoot;

  String get scratch => p.join(repoRoot, '_scratch');
  String get home => p.join(scratch, 'agent_home');
  String get shots => p.join(scratch, 'agent_shots');
  String get pidFile => p.join(scratch, 'agent_driver', 'app.pgid');
  String get logFile => p.join(scratch, 'agent_driver', 'app.log');
  String get defaultDefines => p.join(scratch, 'e2e.defines.json');
  String get entry => p.join('test_driver', 'main_agent.dart');
}

class AppSession implements AppControl {
  AppSession(this.paths, {this.startTimeout = const Duration(minutes: 10)});

  final DriverPaths paths;
  final Duration startTimeout;

  Process? _process;
  VmService? _vm;
  String? _isolateId;
  String? _appId;
  String? _wsUri;
  int _nextId = 1;
  final List<String> _log = <String>[];
  IOSink? _logSink;
  final Map<int, Completer<Map<String, Object?>>> _pending =
      <int, Completer<Map<String, Object?>>>{};
  Completer<void>? _started;

  @override
  bool get running => _process != null;

  @override
  Future<Map<String, Object?>> start({
    required bool headless,
    required bool fresh,
    String? definesFile,
  }) async {
    if (running) {
      throw StateError('The app runs already. Call app_stop first.');
    }
    await _killStaleGroup();

    final String defines = definesFile == null
        ? paths.defaultDefines
        : p.isAbsolute(definesFile)
        ? definesFile
        : p.join(paths.repoRoot, definesFile);
    final File definesF = File(defines);
    if (!definesF.existsSync()) {
      throw IsolationError(
        'No defines file at $defines. Start the stack: '
        'E2E_EMULATOR_PORT=8797 scripts/e2e_stack.sh up',
      );
    }
    checkLocalDefines(
      (jsonDecode(definesF.readAsStringSync()) as Map).cast<String, Object?>(),
    );

    final AppHome home = AppHome(paths.home);
    final Map<String, String> env = isolatedEnvironment(
      base: Platform.environment,
      home: home,
      scratchDir: paths.scratch,
    );
    home.prepare(fresh: fresh);

    final List<String> flutterArgs = <String>[
      'flutter',
      'run',
      '-d',
      'linux',
      '-t',
      paths.entry,
      '--dart-define-from-file=$defines',
      '--machine',
    ];
    final List<String> cmd = <String>[
      'setsid',
      if (headless) ...<String>[
        'xvfb-run',
        '-a',
        '-s',
        '-screen 0 1440x900x24',
      ],
      ...flutterArgs,
    ];

    Directory(p.dirname(paths.logFile)).createSync(recursive: true);
    _log.clear();
    _logSink = File(paths.logFile).openWrite();
    _started = Completer<void>();
    final Process proc = await Process.start(
      cmd.first,
      cmd.sublist(1),
      workingDirectory: paths.repoRoot,
      environment: env,
      includeParentEnvironment: false,
    );
    _process = proc;
    File(paths.pidFile).writeAsStringSync('${proc.pid}');

    proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLine);
    proc.stderr
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((String l) => _record('[stderr] $l'));
    unawaited(
      proc.exitCode.then((int code) {
        _record('[driver] flutter run exited with code $code');
        if (!(_started?.isCompleted ?? true)) {
          _started!.completeError(
            StateError(
              'flutter run exited with code $code before the app '
              'started. Last log lines:\n${logs(30).join('\n')}',
            ),
          );
        }
        _reset();
      }),
    );

    try {
      await _started!.future.timeout(startTimeout);
    } on TimeoutException {
      await stop();
      throw StateError('The app did not start in ${startTimeout.inSeconds} s.');
    }
    await _connectVm();
    // The app has endless animations (spinners). With frame sync on, every
    // driver command would wait for them to stop.
    await driver(<String, String>{
      'command': 'set_frame_sync',
      'enabled': 'false',
    });
    return status();
  }

  void _onLine(String line) {
    final MachineEvent? e = parseMachineLine(line);
    if (e == null) {
      final String t = line.trim();
      if (t.startsWith('[{') && t.contains('"id"')) {
        _onResponse(t);
      } else {
        _record(line);
      }
      return;
    }
    switch (e.event) {
      case 'app.start':
        _appId = e.appId;
      case 'app.debugPort':
        _wsUri = e.params['wsUri'] as String?;
      case 'app.started':
        if (!(_started?.isCompleted ?? true)) _started!.complete();
      case 'app.log':
        _record('[app] ${e.params['log']}');
      case 'app.progress':
        final Object? msg = e.params['message'];
        if (msg != null) _record('[progress] $msg');
      case 'daemon.logMessage':
        _record('[flutter] ${e.params['message']}');
      default:
        break;
    }
  }

  void _onResponse(String t) {
    try {
      final Object? decoded = jsonDecode(t);
      if (decoded is List && decoded.isNotEmpty && decoded.first is Map) {
        final Map<String, Object?> m = (decoded.first as Map)
            .cast<String, Object?>();
        final Object? id = m['id'];
        if (id is int) _pending.remove(id)?.complete(m);
      }
    } on FormatException {
      _record(t);
    }
  }

  void _record(String line) {
    _log.add(line);
    if (_log.length > 2000) _log.removeRange(0, _log.length - 2000);
    _logSink?.writeln(line);
  }

  Future<void> _connectVm() async {
    final String? uri = _wsUri;
    if (uri == null) throw StateError('flutter run gave no VM service URI.');
    final VmService vm = await vmServiceConnectUri(uri);
    _vm = vm;
    final DateTime end = DateTime.now().add(const Duration(seconds: 60));
    while (DateTime.now().isBefore(end)) {
      final VM info = await vm.getVM();
      for (final IsolateRef ref in info.isolates ?? <IsolateRef>[]) {
        final Isolate iso = await vm.getIsolate(ref.id!);
        final List<String> ext = iso.extensionRPCs ?? <String>[];
        if (ext.contains('ext.flutter.driver') &&
            ext.contains('ext.chuk.agent.screenshot')) {
          _isolateId = ref.id;
          return;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    throw StateError(
      'The app has no driver extension. Is the entry point '
      '${paths.entry}?',
    );
  }

  @override
  Future<Object?> driver(Map<String, String> params) async {
    final Response r = await _vmOrThrow().callServiceExtension(
      'ext.flutter.driver',
      isolateId: _isolateId,
      args: params,
    );
    final Map<String, Object?> json = r.json ?? <String, Object?>{};
    if (json['isError'] == true) {
      throw DriverCommandError(_firstLines('${json['response']}', 6));
    }
    return json['response'];
  }

  @override
  Future<Map<String, Object?>> extension(
    String method, [
    Map<String, String> args = const <String, String>{},
  ]) async {
    try {
      final Response r = await _vmOrThrow().callServiceExtension(
        method,
        isolateId: _isolateId,
        args: args,
      );
      final Map<String, Object?> json = Map<String, Object?>.of(
        r.json ?? <String, Object?>{},
      )..remove('type');
      return json;
    } on RPCError catch (e) {
      throw DriverCommandError('$method: ${e.details ?? e.message}');
    }
  }

  VmService _vmOrThrow() {
    final VmService? vm = _vm;
    if (vm == null || _isolateId == null) {
      throw StateError('The app does not run. Call app_start first.');
    }
    return vm;
  }

  @override
  Future<Map<String, Object?>> hotReload({required bool fullRestart}) async {
    final Process? proc = _process;
    if (proc == null || _appId == null) {
      throw StateError('The app does not run. Call app_start first.');
    }
    final int id = _nextId++;
    final Completer<Map<String, Object?>> done =
        Completer<Map<String, Object?>>();
    _pending[id] = done;
    proc.stdin.writeln(
      machineCommand(id, 'app.restart', <String, Object?>{
        'appId': _appId,
        'fullRestart': fullRestart,
        'pause': false,
      }),
    );
    final Map<String, Object?> res = await done.future.timeout(
      const Duration(minutes: 2),
    );
    if (fullRestart) {
      // A restart makes a new isolate with new extensions.
      _isolateId = null;
      final VmService? old = _vm;
      _vm = null;
      await old?.dispose();
      await _connectVm();
      await driver(<String, String>{
        'command': 'set_frame_sync',
        'enabled': 'false',
      });
    }
    return <String, Object?>{
      'result': res['result'],
      if (res['error'] != null) 'error': res['error'],
    };
  }

  @override
  Future<Map<String, Object?>> stop() async {
    final Process? proc = _process;
    if (proc == null) {
      final bool killed = await _killStaleGroup();
      return <String, Object?>{
        'stopped': killed,
        'note': killed ? 'killed a stale app' : 'no app was running',
      };
    }
    if (_appId != null) {
      try {
        proc.stdin.writeln(
          machineCommand(_nextId++, 'app.stop', <String, Object?>{
            'appId': _appId,
          }),
        );
      } on Object {
        // stdin is closed: the process is going away already.
      }
    }
    final int code = await proc.exitCode.timeout(
      const Duration(seconds: 10),
      onTimeout: () => -1,
    );
    if (code == -1) _killGroup(proc.pid);
    await proc.exitCode.timeout(
      const Duration(seconds: 5),
      onTimeout: () => -1,
    );
    _killGroup(proc.pid); // xvfb-run and the app, if still there.
    _reset();
    _deletePidFile();
    return <String, Object?>{'stopped': true};
  }

  void _reset() {
    final VmService? vm = _vm;
    _vm = null;
    _isolateId = null;
    _process = null;
    _appId = null;
    _wsUri = null;
    for (final Completer<Map<String, Object?>> c in _pending.values) {
      if (!c.isCompleted) c.completeError(StateError('The app stopped.'));
    }
    _pending.clear();
    unawaited(vm?.dispose());
    unawaited(_logSink?.close());
    _logSink = null;
  }

  /// Kills the process group in the pid file, when it still runs. This is a
  /// run that a crashed driver left behind.
  Future<bool> _killStaleGroup() async {
    final File f = File(paths.pidFile);
    if (!f.existsSync()) return false;
    final int? pgid = int.tryParse(f.readAsStringSync().trim());
    _deletePidFile();
    if (pgid == null || !_groupAlive(pgid) || !_isOurGroup(pgid)) {
      return false;
    }
    _killGroup(pgid);
    await Future<void>.delayed(const Duration(seconds: 1));
    return true;
  }

  /// True when a process in group [pgid] runs our entry point. The pid file
  /// can outlive the driver (a crash, a reboot), and the kernel can give the
  /// same number to an unrelated process group later.
  bool _isOurGroup(int pgid) {
    final ProcessResult r = Process.runSync('pgrep', <String>[
      '-g',
      '$pgid',
      '-f',
      paths.entry,
    ]);
    return r.exitCode == 0;
  }

  bool _groupAlive(int pgid) {
    final ProcessResult r = Process.runSync('kill', <String>['-0', '-$pgid']);
    return r.exitCode == 0;
  }

  void _killGroup(int pgid) {
    Process.runSync('kill', <String>['-TERM', '-$pgid']);
  }

  void _deletePidFile() {
    final File f = File(paths.pidFile);
    if (f.existsSync()) f.deleteSync();
  }

  @override
  Map<String, Object?> status() => <String, Object?>{
    'running': running,
    if (_process != null) 'pgid': _process!.pid,
    if (_wsUri != null) 'vmServiceUri': _wsUri,
    'home': paths.home,
    'log': paths.logFile,
  };

  @override
  List<String> logs(int lines) => _log.length <= lines
      ? List<String>.of(_log)
      : _log.sublist(_log.length - lines);

  static String _firstLines(String s, int n) {
    final List<String> lines = s.split('\n');
    return lines.length <= n ? s : '${lines.take(n).join('\n')}\n…';
  }
}
