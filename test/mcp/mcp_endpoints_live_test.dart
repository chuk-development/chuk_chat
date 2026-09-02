// Every connector in the catalogue, against the real server.
//
// This is the test that catches what a mock cannot: an endpoint that moved,
// a server that stopped speaking Streamable HTTP, or one that never offered
// dynamic client registration — which is what "Connect" needs, since no
// client id is baked into the app.
//
// It talks to the internet, so it is off by default. Run it on purpose:
//
//     flutter test test/mcp/mcp_endpoints_live_test.dart --dart-define=MCP_LIVE=true
//
// Without the define every case is skipped and the suite stays offline.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import 'package:chuk_chat/services/mcp/mcp_catalogue.dart';
import 'package:chuk_chat/services/mcp/mcp_client.dart';
import 'package:chuk_chat/services/mcp/mcp_oauth.dart';

const bool _live = bool.fromEnvironment('MCP_LIVE');

/// What a live probe found out about one server.
class _Probe {
  const _Probe({required this.open, this.challenge});

  /// True when the server answered initialize without a token.
  final bool open;

  /// The `WWW-Authenticate` challenge, when it asked for one.
  final String? challenge;
}

Future<_Probe> _probe(String url, http.Client client) async {
  final request = http.Request('POST', Uri.parse(url))
    ..headers.addAll({
      'content-type': 'application/json',
      'accept': 'application/json, text/event-stream',
      'mcp-protocol-version': kMcpProtocolVersion,
    })
    ..body = jsonEncode({
      'jsonrpc': '2.0',
      'id': 1,
      'method': 'initialize',
      'params': {
        'protocolVersion': kMcpProtocolVersion,
        'capabilities': <String, dynamic>{},
        'clientInfo': {'name': 'Chuk Chat', 'version': '1.0'},
      },
    });

  final response = await client.send(request).timeout(
    const Duration(seconds: 25),
  );
  await response.stream.drain<void>();

  if (response.statusCode == 200) return const _Probe(open: true);
  if (response.statusCode == 401 || response.statusCode == 403) {
    return _Probe(open: false, challenge: response.headers['www-authenticate']);
  }
  fail('$url answered ${response.statusCode} to initialize');
}

void main() {
  late http.Client client;

  setUpAll(() {
    // Some servers answer 403 to an unknown user agent, so the probe looks
    // like an ordinary HTTP client rather than a bare Dart one.
    final io = HttpClient()..userAgent = 'ChukChat/1.0 (MCP connector test)';
    client = IOClient(io);
  });

  tearDownAll(() => client.close());

  for (final entry in kMcpCatalogue) {
    group(entry.name, () {
      test('answers initialize, open or with a sign-in challenge', () async {
        final probe = await _probe(entry.url, client);
        if (!probe.open) {
          expect(
            probe.challenge,
            isNotNull,
            reason: '${entry.name} refuses without saying how to sign in',
          );
        }
      }, skip: !_live ? 'set --dart-define=MCP_LIVE=true' : null);

      test('can be connected without credentials of our own', () async {
        final probe = await _probe(entry.url, client);
        if (probe.open) return; // Nothing to sign in to.

        final oauth = McpOAuth(httpClient: client);
        final server = await oauth.discover(
          Uri.parse(entry.url),
          wwwAuthenticate: probe.challenge,
        );

        // Without dynamic client registration the app has no client id for
        // this server, so "Connect" cannot work — the catalogue must not
        // offer it. GitHub is the known example.
        expect(
          server.registrationEndpoint,
          isNotNull,
          reason:
              '${entry.name} does not register clients dynamically, so it '
              'cannot be connected from the catalogue',
        );
      }, skip: !_live ? 'set --dart-define=MCP_LIVE=true' : null);

      // The trap Namecheap fell into: the server registers a client but hands
      // back a fixed redirect-URI allowlist (a few first-party apps) and drops
      // the loopback address we listen on. The browser then redirects to the
      // server's own error page, and the app waits on a callback that never
      // comes. register() turns that into a thrown McpAuthException, so this
      // case fails here — automatically — for any offered server that gates
      // its redirects, before it ever ships in the catalogue.
      test('honours our loopback redirect in dynamic registration', () async {
        final probe = await _probe(entry.url, client);
        if (probe.open) return; // Nothing to sign in to.

        final oauth = McpOAuth(httpClient: client);
        final server = await oauth.discover(
          Uri.parse(entry.url),
          wwwAuthenticate: probe.challenge,
        );
        if (server.registrationEndpoint == null) return; // other test covers it

        // A stand-in for the real listener's address: a loopback URI the
        // server has never seen, exactly like the one at connect time.
        final redirect = Uri.parse('http://127.0.0.1:52765/mcp/callback');
        await expectLater(
          oauth.register(
            server,
            redirect,
            scope: server.scopesSupported.join(' '),
          ),
          completes,
          reason:
              '${entry.name} does not honour our loopback redirect, so the '
              'sign-in cannot complete from this app',
        );
      }, skip: !_live ? 'set --dart-define=MCP_LIVE=true' : null);
    });
  }
}
