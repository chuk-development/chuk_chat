// The connectors our own API server fronts.
//
// GitHub is the case that motivated them: its MCP server takes a plain
// GitHub token but offers no dynamic client registration, so the app cannot
// sign in to it. The device flow already left a token on our server, and
// `/v1/mcp/github` uses that one — the app only has to prove it is the
// signed-in reader, which its ordinary session token does.

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/mcp/mcp_catalogue.dart';
import 'package:chuk_chat/services/mcp/mcp_connection.dart';

void main() {
  group('first-party connectors', () {
    test('GitHub is offered, and points at our own API server', () {
      final github = firstPartyConnectors().firstWhere((e) => e.id == 'github');
      final url = Uri.parse(github.url);

      // A debug build points at the local API server, so http on loopback
      // is the one plaintext address that is allowed here.
      final bool reachable =
          url.isScheme('https') ||
          (url.isScheme('http') &&
              const {'localhost', '127.0.0.1', '10.0.2.2'}.contains(url.host));
      expect(reachable, isTrue, reason: github.url);
      expect(url.path, '/v1/mcp/github');
      // Never GitHub's own MCP host: that one would demand a client id the
      // app does not have.
      expect(url.host, isNot(contains('githubcopilot.com')));
    });

    test('they carry the app session, not a browser sign-in', () {
      for (final entry in firstPartyConnectors()) {
        expect(entry.auth, McpAuth.appSession, reason: entry.name);
      }
    });

    test('the catalogue never carries the app session', () {
      // Catalogue servers are third-party: they sign in through the browser
      // (oauth) or take the reader's own key (apiKey). The app session is
      // reserved for the connectors our own server fronts.
      for (final entry in kMcpCatalogue) {
        expect(entry.auth, isNot(McpAuth.appSession), reason: entry.name);
      }
    });

    test('an api-key entry declares the credentials it needs', () {
      for (final entry in kMcpCatalogue) {
        if (entry.auth == McpAuth.apiKey) {
          expect(
            entry.credentials,
            isNotEmpty,
            reason: '${entry.name} takes a key but names no credential fields',
          );
        } else {
          expect(
            entry.credentials,
            isEmpty,
            reason: '${entry.name} lists credentials but is not an api-key server',
          );
        }
      }
    });

    test('their ids do not collide with a catalogue entry', () {
      final catalogueIds = kMcpCatalogue.map((e) => e.id).toSet();
      for (final entry in firstPartyConnectors()) {
        expect(catalogueIds, isNot(contains(entry.id)));
      }
    });

    test('every one sits in a category that is shown', () {
      for (final entry in firstPartyConnectors()) {
        expect(kMcpCategories, contains(entry.category));
      }
    });
  });

  group('a connection remembers where its token comes from', () {
    test('the auth mode survives a save and a load', () {
      const connection = McpConnection(
        id: 'github',
        name: 'GitHub',
        url: 'https://api.chuk.chat/v1/mcp/github',
        auth: McpAuth.appSession,
      );

      final restored = McpConnection.fromJson(connection.toJson());

      expect(restored.auth, McpAuth.appSession);
    });

    test('a connection stored before this existed reads as OAuth', () {
      final restored = McpConnection.fromJson({
        'id': 'notion',
        'name': 'Notion',
        'url': 'https://mcp.notion.com/mcp',
      });

      expect(restored.auth, McpAuth.oauth);
    });

    test('an unknown auth mode is not taken for the app session', () {
      // Storage is only as trustworthy as the last version that wrote it,
      // and reading a stranger as "use the session token" would send that
      // token to a server we never vetted.
      final restored = McpConnection.fromJson({
        'id': 'x',
        'name': 'X',
        'url': 'https://mcp.example.com/mcp',
        'auth': 'something-else',
      });

      expect(restored.auth, McpAuth.oauth);
    });

    test('copyWith keeps it', () {
      const connection = McpConnection(
        id: 'github',
        name: 'GitHub',
        url: 'https://api.chuk.chat/v1/mcp/github',
        auth: McpAuth.appSession,
      );

      expect(connection.copyWith(name: 'GitHub Enterprise').auth,
          McpAuth.appSession);
    });
  });
}
