// The offered connectors, the ids their tools are named after, and the
// registry search behind them.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:chuk_chat/services/mcp/mcp_catalogue.dart';
import 'package:chuk_chat/services/mcp/mcp_client.dart';
import 'package:chuk_chat/services/mcp/mcp_connection.dart';

void main() {
  group('the catalogue', () {
    test('every entry is an https endpoint', () {
      for (final entry in kMcpCatalogue) {
        expect(
          Uri.parse(entry.url).isScheme('https'),
          isTrue,
          reason: '${entry.name} is not https',
        );
      }
    });

    test('ids are unique, so two connectors cannot shadow each other', () {
      final ids = kMcpCatalogue.map((e) => e.id).toList();
      expect(ids.toSet().length, ids.length);
    });

    test('every entry sits in a category that is shown', () {
      for (final entry in kMcpCatalogue) {
        expect(kMcpCategories, contains(entry.category));
      }
    });

    test('an entry without its own icon falls back to the brand favicon', () {
      const entry = McpCatalogueEntry(
        id: 'x',
        name: 'X',
        url: 'https://mcp.example.com/mcp',
        category: 'Recommended',
      );
      // The brand domain, not the mcp subdomain: that is where a logo is.
      expect(entry.icon, contains('example.com'));
      expect(entry.icon, isNot(contains('mcp.example.com')));
    });

    test('a logo is looked for in more than one place', () {
      final candidates = McpCatalogueEntry.faviconCandidates(
        'https://mcp.figma.com/mcp',
      );
      expect(candidates.length, greaterThan(1));
      expect(candidates.first, contains('figma.com'));
      expect(candidates.toSet().length, candidates.length);
    });

    test('a two-part host is left alone', () {
      expect(McpCatalogueEntry.brandDomain('huggingface.co'), 'huggingface.co');
      expect(McpCatalogueEntry.brandDomain('mcp.linear.app'), 'linear.app');
    });
  });

  group('slugs', () {
    test('a host becomes a short id without the mcp prefix', () {
      expect(slugFor('https://mcp.figma.com/mcp'), 'figma_com');
      expect(slugFor('https://api.githubcopilot.com/mcp/x/all'),
          'githubcopilot_com');
    });

    test('a name becomes a safe id', () {
      expect(slugFor('HyperFrames by HeyGen'), 'hyperframes_by_heygen');
    });

    test('an id is never empty', () {
      expect(slugFor('///'), 'server');
    });
  });

  group('tool names', () {
    const connection = McpConnection(
      id: 'figma',
      name: 'Figma',
      url: 'https://mcp.figma.com/mcp',
    );

    test('are prefixed with the server, so two servers can both offer search', () {
      expect(connection.toolNameFor('search'), 'figma_search');
    });

    test('drop what a tool name may not contain', () {
      expect(connection.toolNameFor('get design/context'),
          'figma_get_design_context');
    });

    test('stay within the 64 characters a tool name may have', () {
      final long = connection.toolNameFor('x' * 100);
      expect(long.length, 64);
    });
  });

  group('registry search', () {
    MockClient client(Object body) => MockClient(
      (_) async => http.Response(
        jsonEncode(body),
        200,
        headers: const {'content-type': 'application/json'},
      ),
    );

    test('returns the servers that can be reached remotely', () async {
      final results = await searchMcpRegistry(
        'linear',
        httpClient: client({
          'servers': [
            {
              'server': {
                'name': 'app.linear/linear',
                'title': 'Linear',
                'description': 'Issues and projects',
                'remotes': [
                  {'type': 'streamable-http', 'url': 'https://mcp.linear.app/mcp'},
                ],
              },
            },
            {
              // Only installable locally — of no use to a phone.
              'server': {
                'name': 'io.github.someone/local-only',
                'packages': [
                  {'registryType': 'pypi', 'identifier': 'x'},
                ],
              },
            },
          ],
        }),
      );

      expect(results, hasLength(1));
      expect(results.single.name, 'Linear');
      expect(results.single.url, 'https://mcp.linear.app/mcp');
    });

    test('refuses a server the publishing domain does not serve', () async {
      final results = await searchMcpRegistry(
        'notion',
        httpClient: client({
          'servers': [
            {
              'server': {
                'name': 'com.notion/mcp',
                'title': 'Notion',
                'remotes': [
                  {'type': 'streamable-http', 'url': 'https://mcp.notion.com/mcp'},
                ],
              },
            },
            {
              // A GitHub account proves nothing about notion.com.
              'server': {
                'name': 'io.github.someone/notion-plus',
                'title': 'Notion Plus',
                'remotes': [
                  {'type': 'streamable-http', 'url': 'https://notion-mcp.xyz/mcp'},
                ],
              },
            },
            {
              // A verified domain, but pointing somewhere else entirely.
              'server': {
                'name': 'com.example/notion-bridge',
                'title': 'Notion Bridge',
                'remotes': [
                  {'type': 'streamable-http', 'url': 'https://collect.evil.tld/mcp'},
                ],
              },
            },
          ],
        }),
      );

      expect(results, hasLength(1));
      expect(results.single.url, 'https://mcp.notion.com/mcp');
      expect(results.single.publisher, 'notion.com');
    });

    test('lets the unverified through when asked to', () async {
      final results = await searchMcpRegistry(
        'notion',
        firstPartyOnly: false,
        httpClient: client({
          'servers': [
            {
              'server': {
                'name': 'io.github.someone/notion-plus',
                'remotes': [
                  {'type': 'streamable-http', 'url': 'https://notion-mcp.xyz/mcp'},
                ],
              },
            },
          ],
        }),
      );

      expect(results, hasLength(1));
    });

    test('shows a server once, not once per published version', () async {
      Map<String, Object?> version(String v) => {
        'server': {
          'name': 'com.notion/mcp',
          'title': 'Notion',
          'version': v,
          'remotes': [
            {'type': 'streamable-http', 'url': 'https://mcp.notion.com/mcp'},
          ],
        },
      };

      final results = await searchMcpRegistry(
        'notion',
        httpClient: client({
          'servers': [version('1.0.0'), version('1.0.1'), version('1.1.0')],
        }),
      );

      expect(results, hasLength(1));
    });

    test('skips what the registry has withdrawn or superseded', () async {
      final results = await searchMcpRegistry(
        'notion',
        httpClient: client({
          'servers': [
            {
              'server': {
                'name': 'com.notion/mcp',
                'remotes': [
                  {'type': 'streamable-http', 'url': 'https://mcp.notion.com/mcp'},
                ],
              },
              '_meta': {
                'io.modelcontextprotocol.registry/official': {
                  'status': 'deleted',
                  'isLatest': true,
                },
              },
            },
            {
              'server': {
                'name': 'com.linear/mcp',
                'remotes': [
                  {'type': 'streamable-http', 'url': 'https://mcp.linear.com/mcp'},
                ],
              },
              '_meta': {
                'io.modelcontextprotocol.registry/official': {
                  'status': 'active',
                  'isLatest': false,
                },
              },
            },
          ],
        }),
      );

      expect(results, isEmpty);
    });

    test('an empty query asks nothing at all', () async {
      expect(await searchMcpRegistry('   '), isEmpty);
    });

    test('a registry that is down is quiet, not fatal', () async {
      final results = await searchMcpRegistry(
        'linear',
        httpClient: MockClient((_) async => http.Response('boom', 500)),
      );
      expect(results, isEmpty);
    });
  });

  test('a connection survives a round trip through storage', () {
    const connection = McpConnection(
      id: 'figma',
      name: 'Figma',
      url: 'https://mcp.figma.com/mcp',
      description: 'Design files',
      tools: [
        McpTool(name: 'get_file', description: 'Read a file', inputSchema: {
          'type': 'object',
        }),
      ],
      addedByHand: true,
    );

    final restored = McpConnection.fromJson(
      jsonDecode(jsonEncode(connection.toJson())) as Map<String, dynamic>,
    );

    expect(restored.id, connection.id);
    expect(restored.addedByHand, isTrue);
    expect(restored.tools.single.name, 'get_file');
  });
}
