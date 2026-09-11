import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cowork/services/cowork/cowork_pairing_store.dart'
    show CoworkSecureKeyValueStore;
import 'package:cowork/services/mcp/mcp_connection.dart';
import 'package:cowork/services/mcp/mcp_service.dart';
import 'package:cowork/services/mcp/mcp_store.dart';

class _MemorySecrets implements CoworkSecureKeyValueStore {
  final Map<String, String> map = <String, String>{};

  @override
  Future<String?> read(String key) async => map[key];

  @override
  Future<void> write(String key, String value) async => map[key] = value;

  @override
  Future<void> delete(String key) async => map.remove(key);
}

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    McpService.resetForTest(store: McpStore(secrets: _MemorySecrets()));
  });

  test('a tools frame fills in what the host discovered', () async {
    await McpService.store.upsert(
      const McpConnection(
        id: 'github',
        name: 'GitHub',
        url: 'https://api.githubcopilot.com/mcp/',
      ),
    );

    final applied = await McpService.applyToolsFrame(<String, dynamic>{
      'type': 'mcp_tools',
      'session_key': 's1',
      'servers': <Map<String, dynamic>>[
        {
          'id': 'github',
          'name': 'GitHub',
          'connected': true,
          'tools': [
            {'name': 'list_issues', 'description': 'Issues of a repository'},
            {'name': 'create_pull_request', 'description': ''},
          ],
        },
      ],
    });

    expect(applied, 1);
    final stored = await McpService.store.load();
    expect(stored.single.tools.map((t) => t.name), [
      'list_issues',
      'create_pull_request',
    ]);
  });

  test('a connector this device does not have is ignored', () async {
    final applied = await McpService.applyToolsFrame(<String, dynamic>{
      'servers': <Map<String, dynamic>>[
        {
          'id': 'nope',
          'name': 'Unknown',
          'tools': [
            {'name': 'x'},
          ],
        },
      ],
    });
    expect(applied, 0);
    expect(await McpService.store.load(), isEmpty);
  });

  test('the same answer twice is written once', () async {
    await McpService.store.upsert(
      const McpConnection(
        id: 'plane',
        name: 'Plane',
        url: 'https://mcp.plane.so/mcp',
      ),
    );
    final Map<String, dynamic> frame = <String, dynamic>{
      'servers': <Map<String, dynamic>>[
        {
          'id': 'plane',
          'tools': [
            {'name': 'workitem'},
          ],
        },
      ],
    };
    // The first answer is news even when the tools match what was stored: it
    // is what turns "not checked" into "checked".
    expect(await McpService.applyToolsFrame(frame), 1);
    expect(await McpService.applyToolsFrame(frame), 0);
    expect((await McpService.store.load()).single.checkedAt, isNotNull);
  });

  test('an unreachable server keeps its error until it answers again', () async {
    await McpService.store.upsert(
      const McpConnection(id: 'canva', name: 'Canva', url: 'https://c/mcp'),
    );
    await McpService.applyToolsFrame(<String, dynamic>{
      'servers': <Map<String, dynamic>>[
        {'id': 'canva', 'connected': false, 'tools': [], 'error': '401'},
      ],
    });
    expect((await McpService.store.load()).single.lastError, '401');

    await McpService.applyToolsFrame(<String, dynamic>{
      'servers': <Map<String, dynamic>>[
        {
          'id': 'canva',
          'connected': true,
          'tools': [
            {'name': 'export-design'},
          ],
        },
      ],
    });
    final McpConnection healed = (await McpService.store.load()).single;
    expect(healed.lastError, isNull);
    expect(healed.tools.single.name, 'export-design');
  });

  test('a server the host could not reach keeps no stale tools', () async {
    await McpService.store.upsert(
      const McpConnection(
        id: 'canva',
        name: 'Canva',
        url: 'https://mcp.canva.com/mcp',
        tools: <McpTool>[McpTool(name: 'export-design')],
      ),
    );
    final applied = await McpService.applyToolsFrame(<String, dynamic>{
      'servers': <Map<String, dynamic>>[
        {'id': 'canva', 'connected': false, 'tools': [], 'error': '401'},
      ],
    });
    expect(applied, 1);
    expect((await McpService.store.load()).single.tools, isEmpty);
  });
}
