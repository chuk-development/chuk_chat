import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/mcp/mcp_redirect_io.dart';

void main() {
  test('the redirect URI is a localhost URL on an ephemeral port', () async {
    final listener = await McpRedirectListener.start();
    addTearDown(listener.close);

    final uri = listener.redirectUri;
    expect(uri.scheme, 'http');
    expect(uri.host, 'localhost');
    expect(uri.path, '/mcp/callback');
    expect(uri.port, isNot(equals(0)));
  });

  test('a callback that arrives on either loopback name completes the wait',
      () async {
    final listener = await McpRedirectListener.start();
    addTearDown(listener.close);
    final done = listener.callback;

    // The browser is sent to `localhost` — which the OS may resolve to
    // 127.0.0.1 or ::1. The listener binds both, so either dial is caught.
    final client = HttpClient();
    final request = await client.getUrl(
      Uri.parse('http://localhost:${listener.redirectUri.port}'
          '/mcp/callback?code=abc&state=s1'),
    );
    final response = await request.close();
    await response.drain<void>();
    client.close();

    final callback = await done.timeout(const Duration(seconds: 5));
    expect(callback.queryParameters['code'], 'abc');
    expect(callback.queryParameters['state'], 's1');
  });

  test('the served page is the small "you can go back" one', () async {
    final listener = await McpRedirectListener.start();
    addTearDown(listener.close);

    final client = HttpClient();
    final request = await client.getUrl(
      Uri.parse('http://localhost:${listener.redirectUri.port}'
          '/mcp/callback?code=x'),
    );
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    client.close();
    await listener.callback;

    expect(body, contains('go back to Chuk Chat'));
  });
}
