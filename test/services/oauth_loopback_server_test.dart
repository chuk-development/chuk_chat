import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:chuk_chat/services/oauth_loopback_server.dart';

const _theme = OAuthResultPageTheme(
  successColor: '#28a745',
  errorColor: '#dc3545',
  background: '#0d1117',
  card: '#161b22',
  border: '#30363d',
  text: '#c9d1d9',
);

/// Ports in the dynamic range, one per test, so a lingering socket from one
/// test cannot make the next one flaky.
OAuthLoopbackServer _server(int port) => OAuthLoopbackServer(
  port: port,
  successTitle: 'Test Connected!',
  theme: _theme,
);

Future<String> _get(Uri uri) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(uri);
    final response = await request.close();
    return await response.transform(const SystemEncoding().decoder).join();
  } finally {
    client.close();
  }
}

void main() {
  test('generateState returns a fresh value each call', () {
    final first = OAuthLoopbackServer.generateState();
    final second = OAuthLoopbackServer.generateState();
    expect(first, isNotEmpty);
    expect(first, isNot(second));
  });

  test('awaiting the code before start is a StateError', () {
    expect(() => _server(45001).code, throwsStateError);
  });

  test('a matching callback completes with the code', () async {
    final server = _server(45002);
    await server.start(expectedState: 'abc');
    addTearDown(server.stop);

    final body = await _get(
      Uri.parse('${server.redirectUri}?code=xyz&state=abc'),
    );

    expect(await server.code, 'xyz');
    expect(body, contains('Test Connected!'));
  });

  test('a mismatched state fails the code future', () async {
    final server = _server(45003);
    await server.start(expectedState: 'abc');
    addTearDown(server.stop);

    final pending = expectLater(server.code, throwsA(isA<Exception>()));
    final body = await _get(
      Uri.parse('${server.redirectUri}?code=xyz&state=wrong'),
    );

    expect(body, contains('Security Error'));
    await pending;
  });

  test('a provider error fails the code future', () async {
    final server = _server(45004);
    await server.start(expectedState: 'abc');
    addTearDown(server.stop);

    final pending = expectLater(server.code, throwsA(isA<Exception>()));
    final body = await _get(
      Uri.parse('${server.redirectUri}?error=access_denied&state=abc'),
    );

    expect(body, contains('Authorization Failed'));
    await pending;
  });

  test('a callback without a code answers 400 and keeps waiting', () async {
    final server = _server(45005);
    await server.start(expectedState: 'abc');
    addTearDown(server.stop);

    final body = await _get(Uri.parse('${server.redirectUri}?state=abc'));
    expect(body, contains('Missing authorization code'));

    await _get(Uri.parse('${server.redirectUri}?code=late&state=abc'));
    expect(await server.code, 'late');
  });

  test('start twice rebinds the same port', () async {
    final server = _server(45006);
    await server.start(expectedState: 'one');
    await server.start(expectedState: 'two');
    addTearDown(server.stop);

    await _get(Uri.parse('${server.redirectUri}?code=second&state=two'));
    expect(await server.code, 'second');
  });
}
