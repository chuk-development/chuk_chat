// Connecting a server that takes the reader's own key on its URL, not a
// browser sign-in — Browserbase and its kind.
//
// The secret must reach the request URL and never the stored connection row.

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/mcp/mcp_catalogue.dart';
import 'package:chuk_chat/services/mcp/mcp_connection.dart';
import 'package:chuk_chat/services/mcp/mcp_service.dart';

void main() {
  group('api-key endpoint', () {
    test('the credentials land on the request URL as query parameters', () {
      final url = McpService.endpointWithCredentialsForTest(
        Uri.parse('https://mcp.browserbase.com/mcp'),
        const {'browserbaseApiKey': 'bb_live_secret', 'browserbaseProjectId': 'p1'},
      );
      expect(url.queryParameters['browserbaseApiKey'], 'bb_live_secret');
      expect(url.queryParameters['browserbaseProjectId'], 'p1');
      expect(url.host, 'mcp.browserbase.com');
      expect(url.path, '/mcp');
    });

    test('credentials already on the base URL are kept', () {
      final url = McpService.endpointWithCredentialsForTest(
        Uri.parse('https://mcp.example.com/mcp?region=eu'),
        const {'apiKey': 'k'},
      );
      expect(url.queryParameters['region'], 'eu');
      expect(url.queryParameters['apiKey'], 'k');
    });
  });

  group('browserbase catalogue entry', () {
    final entry = kMcpCatalogue.firstWhere((e) => e.id == 'browserbase');

    test('is an api-key server with a plain, secret-free base URL', () {
      expect(entry.auth, McpAuth.apiKey);
      expect(entry.url, 'https://mcp.browserbase.com/mcp');
      expect(Uri.parse(entry.url).query, isEmpty);
    });

    test('names an obscured key and a plain project id', () {
      expect(entry.credentials, hasLength(2));
      final key = entry.credentials.firstWhere((f) => f.key == 'browserbaseApiKey');
      final project =
          entry.credentials.firstWhere((f) => f.key == 'browserbaseProjectId');
      expect(key.secret, isTrue);
      expect(project.secret, isFalse);
    });
  });

  group('McpConnection persistence', () {
    test('an api-key connection round-trips its auth type', () {
      const connection = McpConnection(
        id: 'browserbase',
        name: 'Browserbase',
        url: 'https://mcp.browserbase.com/mcp',
        auth: McpAuth.apiKey,
      );
      final restored = McpConnection.fromJson(connection.toJson());
      expect(restored.auth, McpAuth.apiKey);
      // The stored row is the plain base URL — no key rode along in it.
      expect(restored.url, 'https://mcp.browserbase.com/mcp');
    });
  });
}
