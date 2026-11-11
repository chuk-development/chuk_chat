// The default echo turn of the API emulator (tool/emulator/src/script.dart).

import 'package:flutter_test/flutter_test.dart';

import '../../tool/emulator/src/script.dart';

String _echo(String message) =>
    defaultTurn(message).single.data['text'] as String;

void main() {
  test('echoes the trimmed message', () {
    expect(_echo('  hello world  '), 'Echo: hello world');
  });

  test('an empty message has its own answer', () {
    expect(_echo('   '), 'Echo: (empty message)');
  });

  // The app puts the send time in front of every user message. The echo
  // must not carry it, or it changes every minute and the integration test
  // (integration_test/app_test.dart) cannot find the answer.
  test('drops the leading [Sent: ...] line', () {
    expect(
      _echo('[Sent: Thu 2026-11-12 00:52]\nHello from the integration test'),
      'Echo: Hello from the integration test',
    );
    expect(_echo('[Sent: Thu 2026-11-12 00:52 UTC+01:00]\nhi'), 'Echo: hi');
  });

  test('keeps a [Sent: ...] text that is not the first line', () {
    expect(_echo('hi\n[Sent: x]'), 'Echo: hi\n[Sent: x]');
  });

  test('a stamp with nothing after it is an empty message', () {
    expect(_echo('[Sent: Thu 2026-11-12 00:52]'), 'Echo: (empty message)');
  });
}
