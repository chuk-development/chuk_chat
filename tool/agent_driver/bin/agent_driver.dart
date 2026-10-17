// Agent driver for chuk_chat: an MCP server that lets an AI agent start the
// app against the local E2E stack, tap, type, read the screen and take
// screenshots. See docs/AGENT_DRIVER.md.
//
//   dart run tool/agent_driver/bin/agent_driver.dart
//       MCP server on stdin/stdout (the default).
//   dart run tool/agent_driver/bin/agent_driver.dart --script <walk.json>
//       Runs the tool calls in the file, one after the other, then stops the
//       app. Exit code 1 when a call fails. scripts/verify_ui.sh uses this.
//
// Options for --script:
//   --shots <dir>   Screenshot folder (default _scratch/agent_shots).
//   --headed        Show the window on the desktop (default: xvfb-run).

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../src/app_session.dart';
import '../src/mcp_server.dart';
import '../src/tools.dart';

Future<void> main(List<String> args) async {
  final DriverPaths paths = DriverPaths.fromScript();
  final String? script = _option(args, '--script');
  final String shots = _option(args, '--shots') ?? paths.shots;
  final AppSession session = AppSession(paths);
  final AgentTools tools = AgentTools(
    session,
    shotsDir: p.isAbsolute(shots) ? shots : p.join(paths.repoRoot, shots),
  );

  // Never leave an app behind.
  for (final ProcessSignal s in <ProcessSignal>[
    ProcessSignal.sigint,
    ProcessSignal.sigterm,
  ]) {
    s.watch().listen((_) async {
      await session.stop();
      exit(130);
    });
  }

  if (script != null) {
    final File defines = File(paths.defaultDefines);
    exitCode = await runScript(
      tools,
      File(script),
      headless: !args.contains('--headed'),
      vars: defines.existsSync()
          ? (jsonDecode(defines.readAsStringSync()) as Map).map(
              (Object? k, Object? v) => MapEntry<String, String>('$k', '$v'),
            )
          : const <String, String>{},
    );
    await session.stop();
    exit(exitCode);
  }

  final McpServer server = McpServer(
    tools,
    send: stdout.writeln,
    log: (String l) => stderr.writeln('[agent-driver] $l'),
  );
  final Completer<void> eof = Completer<void>();
  Future<void> last = Future<void>.value();
  stdin
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(
        (String line) => last = server.handleLine(line),
        onDone: eof.complete,
      );
  await eof.future;
  await last;
  await session.stop();
  await stdout.flush();
  exit(0);
}

/// Runs a walk file: a JSON list of `{"tool": "<name>", "args": {...}}`.
/// An `app_start` entry may be left out; the runner adds one at the start.
///
/// `{{KEY}}` in a string argument becomes the value of KEY in [vars] (the
/// defines file), for example `{{E2E_EMAIL}}`. The log shows the arguments
/// before this step, so the test password does not get into the log.
Future<int> runScript(
  AgentTools tools,
  File file, {
  required bool headless,
  Map<String, String> vars = const <String, String>{},
}) async {
  final List<Object?> steps = jsonDecode(file.readAsStringSync()) as List;
  final bool hasStart = steps.any(
    (Object? s) => s is Map && s['tool'] == 'app_start',
  );
  final List<Map<String, Object?>> all = <Map<String, Object?>>[
    if (!hasStart)
      <String, Object?>{
        'tool': 'app_start',
        'args': <String, Object?>{'headless': headless},
      },
    for (final Object? s in steps) (s! as Map).cast<String, Object?>(),
  ];
  int n = 0;
  for (final Map<String, Object?> step in all) {
    n++;
    final String tool = step['tool']! as String;
    final Map<String, Object?> a =
        ((step['args'] as Map?) ?? <String, Object?>{}).cast<String, Object?>();
    if (tool == 'app_start' && !a.containsKey('headless')) {
      a['headless'] = headless;
    }
    final Stopwatch sw = Stopwatch()..start();
    final ToolResult r = await tools.call(tool, substituteVars(a, vars));
    final String head = '[$n/${all.length}] $tool ${jsonEncode(a)}';
    stdout.writeln(
      '$head -> ${r.isError ? 'ERROR' : 'ok'} (${sw.elapsedMilliseconds} ms)',
    );
    final String text = r.text;
    if (text.isNotEmpty && (r.isError || tool != 'read_state')) {
      stdout.writeln('    ${text.replaceAll('\n', '\n    ')}');
    }
    if (r.isError) {
      final ToolResult logs = await tools.call('logs', <String, Object?>{
        'lines': 40,
      });
      stdout.writeln('--- last app log lines ---\n${logs.text}');
      return 1;
    }
  }
  return 0;
}

/// Replaces `{{KEY}}` in the string values of [args] with [vars]`[KEY]`.
/// An unknown key stays as it is.
Map<String, Object?> substituteVars(
  Map<String, Object?> args,
  Map<String, String> vars,
) {
  final RegExp placeholder = RegExp(r'\{\{([A-Z0-9_]+)\}\}');
  return args.map((String k, Object? v) {
    if (v is! String) return MapEntry<String, Object?>(k, v);
    return MapEntry<String, Object?>(
      k,
      v.replaceAllMapped(
        placeholder,
        (Match m) => vars[m.group(1)!] ?? m.group(0)!,
      ),
    );
  });
}

String? _option(List<String> args, String name) {
  final int i = args.indexOf(name);
  if (i < 0 || i + 1 >= args.length) return null;
  return args[i + 1];
}
