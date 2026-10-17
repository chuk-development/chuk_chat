// Command-line entry point of the chuk API emulator.
//
//   dart run tool/emulator/bin/chuk_emulator.dart --port 8787
//
// Options:
//   --port <n>            Port to listen on (default 8787, 0 = any free port).
//   --host <address>      Address to bind (default 127.0.0.1). Use 0.0.0.0 to
//                         reach it from a phone or an Android emulator.
//   --chunk-delay-ms <n>  Pause between streamed chat frames (default 30).
//   --script <file>       JSON script to queue at start (same body as
//                         POST /__emulator/script).
//   --quiet               Do not print each request.
//
// See docs/API_EMULATOR.md.

import 'dart:convert';
import 'dart:io';

import '../emulator.dart';

Future<void> main(List<String> args) async {
  var port = 8787;
  var host = '127.0.0.1';
  var chunkDelayMs = 30;
  var quiet = false;
  String? scriptPath;

  for (var i = 0; i < args.length; i++) {
    String next() {
      if (i + 1 >= args.length) {
        stderr.writeln('Missing value for ${args[i]}');
        exit(64);
      }
      return args[++i];
    }

    switch (args[i]) {
      case '--port':
        port = int.parse(next());
      case '--host':
        host = next();
      case '--chunk-delay-ms':
        chunkDelayMs = int.parse(next());
      case '--script':
        scriptPath = next();
      case '--quiet':
        quiet = true;
      case '-h':
      case '--help':
        stdout.writeln(
          'Usage: dart run tool/emulator/bin/chuk_emulator.dart '
          '[--port 8787] [--host 127.0.0.1] [--chunk-delay-ms 30] '
          '[--script file.json] [--quiet]',
        );
        return;
      default:
        stderr.writeln('Unknown option: ${args[i]}');
        exit(64);
    }
  }

  final emulator = await startEmulator(
    port: port,
    address: host,
    chunkDelay: Duration(milliseconds: chunkDelayMs),
    quiet: quiet,
  );
  if (scriptPath != null) {
    final body = jsonDecode(await File(scriptPath).readAsString());
    emulator.enqueueTurns(parseScript(body));
  }

  final shown = host == '0.0.0.0' ? '127.0.0.1' : host;
  stdout.writeln(
    'chuk API emulator listening on http://$shown:${emulator.port}',
  );
  stdout.writeln(
    'Run the app with --dart-define=API_BASE_URL=http://$shown:${emulator.port}',
  );

  ProcessSignal.sigint.watch().listen((_) async {
    await emulator.close();
    exit(0);
  });
}
