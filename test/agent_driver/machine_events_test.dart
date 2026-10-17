// Parser for `flutter run --machine` output.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../../tool/agent_driver/src/machine_events.dart';

void main() {
  test('parses a daemon event', () {
    final MachineEvent? e = parseMachineLine(
      '[{"event":"app.debugPort","params":{"appId":"a1",'
      '"wsUri":"ws://127.0.0.1:4000/abc=/ws"}}]',
    );
    expect(e, isNotNull);
    expect(e!.event, 'app.debugPort');
    expect(e.appId, 'a1');
    expect(e.params['wsUri'], 'ws://127.0.0.1:4000/abc=/ws');
  });

  test('ignores plain text, responses and broken JSON', () {
    expect(parseMachineLine('Launching lib/main.dart on Linux...'), isNull);
    expect(parseMachineLine('[{"id":1,"result":{"code":0}}]'), isNull);
    expect(parseMachineLine('[{"event":'), isNull);
  });

  test('encodes a daemon command', () {
    final List<Object?> decoded = jsonDecode(
      machineCommand(3, 'app.restart', <String, Object?>{
        'appId': 'a1',
        'fullRestart': false,
      }),
    ) as List<Object?>;
    expect(decoded.single, <String, Object?>{
      'id': 3,
      'method': 'app.restart',
      'params': <String, Object?>{'appId': 'a1', 'fullRestart': false},
    });
  });
}
