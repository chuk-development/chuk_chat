// Cancelling a sign-in that is waiting on the browser.
//
// The reader taps Connect, the browser opens, and then they change their mind.
// Before, the only way out was the back button — the connect sat on the
// five-minute callback timeout. A McpConnectCanceler ends that wait at once and
// the connect reports a clean cancel, adding nothing.
//
// This drives the real connect path against a loopback fake that speaks just
// enough of the MCP OAuth handshake to reach the browser wait, then never
// sends a redirect — so only the cancel can end it.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/services/agents/agents_pairing_store.dart'
    show AgentsSecureKeyValueStore;
import 'package:chuk_chat/services/mcp/mcp_service.dart';
import 'package:chuk_chat/services/mcp/mcp_store.dart';

/// In-memory secure storage, so the connect path's "is there already a
/// usable sign-in?" check never reaches a platform channel.
class _MemorySecrets implements AgentsSecureKeyValueStore {
  final Map<String, String> map = <String, String>{};

  @override
  Future<String?> read(String key) async => map[key];

  @override
  Future<void> write(String key, String value) async => map[key] = value;

  @override
  Future<void> delete(String key) async => map.remove(key);
}

void main() {
  late HttpServer server;
  late String endpoint;

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final origin = 'http://127.0.0.1:${server.port}';
    endpoint = '$origin/mcp';

    server.listen((HttpRequest request) async {
      final path = request.uri.path;
      final res = request.response;
      res.headers.contentType = ContentType.json;

      if (path == '/mcp') {
        // Always demand a sign-in, and say where to discover it.
        res.statusCode = 401;
        res.headers.set(
          'www-authenticate',
          'Bearer resource_metadata="$origin/.well-known/oauth-protected-resource", '
              'scope="files:read"',
        );
        res.write(jsonEncode({'error': 'unauthorized'}));
      } else if (path == '/.well-known/oauth-protected-resource') {
        res.write(jsonEncode({
          'resource': endpoint,
          'authorization_servers': [origin],
          'scopes_supported': ['files:read'],
        }));
      } else if (path == '/.well-known/oauth-authorization-server' ||
          path == '/.well-known/openid-configuration') {
        res.write(jsonEncode({
          'issuer': origin,
          'authorization_endpoint': '$origin/authorize',
          'token_endpoint': '$origin/token',
          'registration_endpoint': '$origin/register',
        }));
      } else if (path == '/register') {
        // Echo the redirect back, so the redirect-allowlist guard passes and
        // the flow reaches the browser wait.
        final body = await utf8.decodeStream(request);
        final json = jsonDecode(body) as Map<String, dynamic>;
        res.statusCode = 201;
        res.write(jsonEncode({
          'client_id': 'generated-id',
          'redirect_uris': json['redirect_uris'],
        }));
      } else {
        res.statusCode = 404;
        res.write(jsonEncode({'error': 'not found'}));
      }
      await res.close();
    });

    SharedPreferences.setMockInitialValues(<String, Object>{});
    McpService.resetForTest(store: McpStore(secrets: _MemorySecrets()));
    // The browser "opens" but does nothing, so the redirect never arrives —
    // the wait can only end by cancel or by the timeout.
    McpService.launcher = (_) async => true;
  });

  tearDown(() async {
    McpService.resetForTest();
    await server.close(force: true);
  });

  test('cancelling the sign-in ends the connect as cancelled', () async {
    final canceler = McpConnectCanceler();
    final pending = McpService.connect(
      id: 'fake',
      name: 'Fake',
      url: endpoint,
      canceler: canceler,
    );

    // Let the handshake reach the browser wait, then change our mind.
    await Future<void>.delayed(const Duration(milliseconds: 300));
    canceler.cancel();

    final result = await pending;
    expect(result.status, McpConnectStatus.cancelled);
    expect(McpService.connections.value, isEmpty);
  });
}
