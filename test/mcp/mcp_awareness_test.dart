import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/models/client_tool.dart';
import 'package:chuk_chat/services/mcp/mcp_availability.dart';
import 'package:chuk_chat/services/mcp/mcp_catalogue.dart';
import 'package:chuk_chat/services/mcp/mcp_connection.dart';
import 'package:chuk_chat/services/mcp/mcp_service.dart';
import 'package:chuk_chat/services/tool_executor.dart';
import 'package:chuk_chat/services/tool_prompt_builder.dart';
import 'package:chuk_chat/services/tool_registry.dart';
import 'package:chuk_chat/tool_handlers/find_tools_handler.dart' as find_tools;

McpConnection _connection(String id) =>
    McpConnection(id: id, name: id, url: 'https://mcp.$id.com/mcp');

void main() {
  // The awareness list reads McpService.connections, a static in-memory
  // notifier. Reset it around every test so one test's connections do not
  // leak into the next.
  setUp(() => McpService.connections.value = const <McpConnection>[]);
  tearDown(() => McpService.connections.value = const <McpConnection>[]);

  group('unconnectedCatalogueEntries', () {
    test('lists catalogue servers that are not connected', () {
      final ids = unconnectedCatalogueEntries().map((e) => e.id).toSet();
      expect(ids, contains('notion'));
      expect(ids, contains('github')); // first-party connector
    });

    test('drops a server once it is connected', () {
      McpService.connections.value = [_connection('notion')];
      final ids = unconnectedCatalogueEntries().map((e) => e.id).toSet();
      expect(ids, isNot(contains('notion')));
      expect(ids, contains('linear'));
    });
  });

  group('catalogueEntryById', () {
    test('finds a catalogue entry by id', () {
      expect(catalogueEntryById('notion')?.name, 'Notion');
      expect(catalogueEntryById('github')?.name, 'GitHub');
    });

    test('returns null for an unknown id', () {
      expect(catalogueEntryById('does-not-exist'), isNull);
    });
  });

  group('catalogue polish', () {
    test('brandDomain strips ai and mail service subdomains', () {
      expect(McpCatalogueEntry.brandDomain('ai.todoist.net'), 'todoist.net');
      expect(
        McpCatalogueEntry.brandDomain('mail.superhuman.com'),
        'superhuman.com',
      );
    });

    test('Registry is always the last shown category', () {
      expect(kMcpCategories.last, 'Registry');
    });
  });

  group('## MCP SERVERS awareness block', () {
    final builder = ToolPromptBuilder(discoveryMode: true);
    final notion = catalogueEntryById('notion')!;

    test('is omitted when every server is connected', () {
      final prompt = builder.buildToolProtocolSection(
        tools: const [],
        unconnectedMcpServers: const [],
      );
      expect(prompt, isNot(contains('## MCP SERVERS')));
    });

    test('is emitted, names-only, when a server is not connected', () {
      final prompt = builder.buildToolProtocolSection(
        tools: const [],
        unconnectedMcpServers: [notion],
        connectedMcpServerNames: const ['Linear'],
      );
      expect(prompt, contains('## MCP SERVERS'));
      // The id and the connected name are present…
      expect(prompt, contains('notion'));
      expect(prompt, contains('Linear'));
      // …but never the per-server description (names-only, ~170 tokens).
      expect(prompt, isNot(contains(notion.description)));
      expect(prompt, contains('request_mcp_server'));
    });

    test('reports "none" when nothing is connected', () {
      final prompt = builder.buildToolProtocolSection(
        tools: const [],
        unconnectedMcpServers: [notion],
        connectedMcpServerNames: const [],
      );
      expect(prompt, contains('Connected (their tools are available via '
          'find_tools): none'));
    });
  });

  group('request_mcp_server executor', () {
    late ToolExecutor executor;

    setUp(() {
      executor = ToolExecutor();
      executor.registerTool(
        builtinTools.firstWhere((t) => t.name == 'request_mcp_server'),
      );
    });

    test('returns the MCP_CONNECT_REQUEST marker for a valid, unconnected id',
        () async {
      final result = await executor.execute('request_mcp_server', {
        'id': 'notion',
      });
      expect(result.isError, isFalse);
      expect(result.output, contains('MCP_CONNECT_REQUEST: notion'));
      expect(result.output, contains('Connect button'));
    });

    test('errors on an unknown id', () async {
      final result = await executor.execute('request_mcp_server', {
        'id': 'nope-not-real',
      });
      expect(result.isError, isTrue);
      expect(result.output, contains('no catalogue MCP server'));
    });

    test('errors when the id is already connected', () async {
      McpService.connections.value = [_connection('notion')];
      final result = await executor.execute('request_mcp_server', {
        'id': 'notion',
      });
      expect(result.isError, isTrue);
      expect(result.output, contains('already connected'));
    });

    test('errors when id is missing', () async {
      final result = await executor.execute('request_mcp_server', const {});
      expect(result.isError, isTrue);
      expect(result.output, contains('"id" parameter required'));
    });
  });

  group('find_tools unconnected-server hint', () {
    String run(String query, List<McpCatalogueEntry> unconnected) {
      return find_tools.executeFindTools(
        args: {'query': query},
        tools: const <String, ClientTool>{},
        getDescription: (name) => name,
        isAvailable: (name) => true,
        unconnectedMcpServers: unconnected,
      );
    }

    test('appends an AVAILABLE (NOT CONNECTED) line when the query matches',
        () {
      final out = run('notion', [catalogueEntryById('notion')!]);
      expect(out, contains('AVAILABLE (NOT CONNECTED): Notion'));
      expect(out, contains('request_mcp_server(id="notion")'));
    });

    test('adds nothing when no unconnected server matches', () {
      final out = run('notion', const []);
      expect(out, isNot(contains('AVAILABLE (NOT CONNECTED)')));
    });
  });
}
