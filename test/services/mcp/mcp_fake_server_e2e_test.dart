// End to end against a real local MCP + OAuth server over loopback.
//
// The server is agents/runtime/tests/fake_mcp_oauth.py (standard library
// Python): real metadata, real dynamic client registration, PKCE, a token
// endpoint that ROTATES refresh tokens like Fastmail, and a streamable-HTTP
// MCP endpoint. Nothing between McpService and the server is mocked; only the
// browser is driven programmatically (it follows the auto-consent redirect to
// the app's loopback listener) and the host is a small fake that answers the
// way the real host does (`mcp_tools`, `mcp_credentials`). Bead chuk_chat-meoz.
//
// Skipped when python3 is not on PATH.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/services/agents/agents_pairing_store.dart'
    show AgentsSecureKeyValueStore;
import 'package:chuk_chat/services/mcp/mcp_catalogue.dart';
import 'package:chuk_chat/services/mcp/mcp_connection.dart';
import 'package:chuk_chat/services/mcp/mcp_oauth.dart';
import 'package:chuk_chat/services/mcp/mcp_probe_control.dart';
import 'package:chuk_chat/services/mcp/mcp_service.dart';
import 'package:chuk_chat/services/mcp/mcp_store.dart';

import '../../support/mcp_memory_list.dart';

class _MemorySecrets implements AgentsSecureKeyValueStore {
  final Map<String, String> map = <String, String>{};

  @override
  Future<String?> read(String key) async => map[key];

  @override
  Future<void> write(String key, String value) async => map[key] = value;

  @override
  Future<void> delete(String key) async => map.remove(key);
}

/// The real fake server, as a child process.
class _FakeServer {
  _FakeServer._(this._process, this.mcpUrl);

  final Process _process;
  final String mcpUrl;

  String get base => mcpUrl.substring(0, mcpUrl.length - '/mcp'.length);

  static Future<_FakeServer> start() async {
    final process = await Process.start('python3', <String>[
      'agents/runtime/tests/fake_mcp_oauth.py',
      '--port',
      '0',
      '--access-ttl',
      '600',
    ]);
    final line = await process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .first
        .timeout(const Duration(seconds: 10));
    return _FakeServer._(process, line.split(' ').last.trim());
  }

  Future<Map<String, dynamic>> state() async {
    final response = await http.get(Uri.parse('$base/admin/state'));
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  Future<void> revoke() => http.post(Uri.parse('$base/admin/revoke'));

  void stop() => _process.kill();
}

/// The browser: open the authorization URL, let the server's auto-consent
/// redirect go to the app's loopback listener.
Future<bool> _browser(Uri url) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(url);
    request.followRedirects = false;
    final response = await request.close();
    await response.drain<void>();
    final location = response.headers.value('location');
    if (location == null) return false;
    final back = await client.getUrl(Uri.parse(location));
    await (await back.close()).drain<void>();
    return true;
  } finally {
    client.close(force: true);
  }
}

/// A host that answers like the real one: it dials with the forwarded
/// credentials, it is the one side that refreshes, and it reports back.
class _FakeHost implements McpProbeControl {
  _FakeHost(this.server);

  final _FakeServer server;
  final List<List<Map<String, dynamic>>> probes = <List<Map<String, dynamic>>>[];

  /// Set to refresh the forwarded grant on the next probe (the host renewed
  /// it) and hand the new tokens back.
  bool renewOnProbe = false;

  @override
  Future<void> probeMcpServers(List<Map<String, dynamic>> servers) async {
    probes.add(servers);
    final List<Map<String, dynamic>> rows = <Map<String, dynamic>>[];
    for (final Map<String, dynamic> entry in servers) {
      final oauth = Map<String, dynamic>.from(entry['oauth'] as Map? ?? {});
      String access = '${entry['access_token'] ?? ''}';
      if (renewOnProbe) {
        final response = await http.post(
          Uri.parse('${server.base}/token'),
          body: <String, String>{
            'grant_type': 'refresh_token',
            'refresh_token': '${oauth['refresh_token']}',
            'client_id': '${oauth['client_id']}',
          },
        );
        final tokens = jsonDecode(response.body) as Map<String, dynamic>;
        access = '${tokens['access_token']}';
        await McpService.applyRotatedCredentials(<String, dynamic>{
          'id': entry['id'],
          'name': entry['name'],
          'url': entry['url'],
          'access_token': access,
          'oauth': <String, dynamic>{
            ...oauth,
            'refresh_token': tokens['refresh_token'],
            'expires_at': DateTime.now()
                .toUtc()
                .add(const Duration(minutes: 10))
                .toIso8601String(),
          },
        });
      }
      final listed = await _toolsWith(access);
      rows.add(<String, dynamic>{
        'id': entry['id'],
        'name': entry['name'],
        'url': entry['url'],
        'client_id': oauth['client_id'],
        'connected': listed != null,
        'tools': listed ?? const <Object>[],
        if (listed == null) ...<String, dynamic>{
          'error': 'the server refused the sign-in (HTTP 401)',
          'error_kind': 'auth',
        },
      });
    }
    await McpService.applyToolsFrame(<String, dynamic>{'servers': rows});
  }

  Future<List<Map<String, dynamic>>?> _toolsWith(String access) async {
    final response = await http.post(
      Uri.parse(server.mcpUrl),
      headers: <String, String>{
        'content-type': 'application/json',
        'accept': 'application/json, text/event-stream',
        'authorization': 'Bearer $access',
      },
      body: jsonEncode(<String, dynamic>{
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'tools/list',
      }),
    );
    if (response.statusCode != 200) return null;
    final result = (jsonDecode(response.body) as Map)['result'] as Map;
    return <Map<String, dynamic>>[
      for (final tool in result['tools'] as List)
        <String, dynamic>{
          'name': (tool as Map)['name'],
          'description': tool['description'],
        },
    ];
  }
}

void main() {
  final bool hasPython = Process.runSync('which', <String>['python3']).exitCode == 0;
  late _FakeServer server;
  late _FakeHost host;
  late String id;

  setUpAll(() async {
    if (!hasPython) return;
    server = await _FakeServer.start();
  });

  tearDownAll(() {
    if (hasPython) server.stop();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    McpService.resetForTest(
      store: McpStore(secrets: _MemorySecrets(), list: memoryMcpList()),
    );
    McpService.launcher = _browser;
    host = _FakeHost(server);
    McpService.probeControlOverride = host;
    id = slugFor(server.mcpUrl);
  });

  tearDown(McpService.resetForTest);

  Future<void> settle() => Future<void>.delayed(const Duration(milliseconds: 200));

  test('first sign-in: registered as Chuk Chat, signed in at once, confirmed',
      () async {
    final before = (await server.state())['clients'] as List;
    final result = await McpService.connectByUrl(server.mcpUrl);
    expect(result.status, McpConnectStatus.connected);

    // At once: the stored connection carries no error.
    final McpConnection fresh = McpService.connectionFor(id)!;
    expect(fresh.lastError, isNull);

    final record = (await McpService.store.secretsFor(id))!;
    expect(record.credentials.clientName, 'Chuk Chat');
    expect(record.tokens.refreshToken, isNotEmpty);
    expect(record.scope ?? record.tokens.scope, contains('offline_access'));
    final clients = (await server.state())['clients'] as List;
    expect(clients.length, before.length + 1);
    expect((clients.last as Map)['client_name'], 'Chuk Chat');

    // The host was asked right away and confirmed it.
    await settle();
    expect(host.probes, isNotEmpty);
    final confirmed = McpService.connectionFor(id)!;
    expect(confirmed.checkedAt, isNotNull);
    expect(confirmed.errorKind, isNull);
    expect(confirmed.tools.map((t) => t.name), containsAll(<String>['echo', 'whoami']));
    expect(McpService.checking.value, isNot(contains(id)));
  }, skip: !hasPython);

  test('with the host offline the sign-in still reads signed in, not an error',
      () async {
    McpService.probeControlOverride = null; // no host attached
    final result = await McpService.connectByUrl(server.mcpUrl);
    expect(result.status, McpConnectStatus.connected);
    await settle();
    final connection = McpService.connectionFor(id)!;
    expect(connection.lastError, isNull);
    // Not confirmed yet: the list shows "Signed in, checking…".
    expect(connection.checkedAt, isNull);

    // The host comes back and the next probe confirms it.
    McpService.probeControlOverride = host;
    await McpService.probe();
    await settle();
    expect(McpService.connectionFor(id)!.checkedAt, isNotNull);
  }, skip: !hasPython);

  test('a revoked sign-in reads expired; Sign in again fixes it at once',
      () async {
    await McpService.connectByUrl(server.mcpUrl);
    await settle();
    final String oldClient =
        (await McpService.store.secretsFor(id))!.credentials.clientId;

    await server.revoke();
    await McpService.probe();
    await settle();
    expect(McpService.connectionFor(id)!.errorKind, McpErrorKind.auth);

    // A frame for the old sign-in is still in flight while the user signs in
    // again (here: held back and delivered afterwards).
    final staleFrame = <String, dynamic>{
      'servers': <Map<String, dynamic>>[
        <String, dynamic>{
          'id': id,
          'name': McpService.connectionFor(id)!.name,
          'client_id': oldClient,
          'connected': false,
          'tools': <Object>[],
          'error': 'the server refused the sign-in (HTTP 401)',
          'error_kind': 'auth',
        },
      ],
    };

    final again = await McpService.connect(
      id: id,
      name: McpService.connectionFor(id)!.name,
      url: server.mcpUrl,
      addedByHand: true,
      forceSignIn: true,
    );
    expect(again.status, McpConnectStatus.connected);
    // Signed in at once, before any host answer.
    expect(McpService.connectionFor(id)!.lastError, isNull);
    final record = (await McpService.store.secretsFor(id))!;
    expect(record.credentials.clientId, isNot(oldClient));
    expect(record.credentials.clientName, 'Chuk Chat');

    await settle();
    await McpService.applyToolsFrame(staleFrame);
    final after = McpService.connectionFor(id)!;
    expect(after.lastError, isNull, reason: 'a stale frame must not win');
    expect(after.checkedAt, isNotNull);
  }, skip: !hasPython);

  test('a record registered as "Agents" signs in again on connect', () async {
    await McpService.connectByUrl(server.mcpUrl);
    final record = (await McpService.store.secretsFor(id))!;
    await McpService.store.setSecrets(
      id,
      McpSecrets(
        credentials: McpClientCredentials(
          clientId: record.credentials.clientId,
          clientName: 'Agents',
        ),
        tokens: record.tokens,
        issuer: record.issuer,
        authorizationEndpoint: record.authorizationEndpoint,
        tokenEndpoint: record.tokenEndpoint,
        scope: record.scope,
      ),
    );
    var opened = 0;
    McpService.launcher = (Uri url) {
      opened++;
      return _browser(url);
    };

    await McpService.connectByUrl(server.mcpUrl);

    expect(opened, 1);
    expect((await McpService.store.secretsFor(id))!.credentials.clientName,
        'Chuk Chat');
  }, skip: !hasPython);

  test('the device never refreshes while a host renews; it takes the host token',
      () async {
    await McpService.connectByUrl(server.mcpUrl);
    await settle();
    // The access token has lapsed on the device.
    final record = (await McpService.store.secretsFor(id))!;
    await McpService.store.setSecrets(
      id,
      record.withTokens(
        McpTokens(
          accessToken: record.tokens.accessToken,
          refreshToken: record.tokens.refreshToken,
          expiresAt: DateTime.now().subtract(const Duration(minutes: 5)),
        ),
      ),
    );
    McpService.hostRenewsOverride = () async => true;
    host.renewOnProbe = true;
    final refreshesBefore = (await server.state())['refreshes'] as int;
    host.probes.clear();

    final tool = McpService.connectionFor(id)!.toolNameFor('echo');
    final result = await McpService.call(tool, <String, dynamic>{'text': 'hi'});

    expect(host.probes.length, 1, reason: 'one ask to the host');
    expect(result.isError, isFalse, reason: result.text);
    expect(result.text, contains('hi'));
    final state = await server.state();
    // Exactly one refresh, the host's; none from the device; no reuse.
    expect(state['refreshes'], refreshesBefore + 1);
    expect(state['invalid_grants'], 0);
  }, skip: !hasPython);

  test('sign out deletes the tokens and tells the host; sign in again works',
      () async {
    await McpService.connectByUrl(server.mcpUrl);
    await settle();
    host.probes.clear();

    await McpService.disconnect(id);
    await settle();
    expect(McpService.connectionFor(id), isNull);
    expect(await McpService.store.secretsFor(id), isNull);
    // The host heard the remaining set (empty), so it forgets its copy.
    expect(host.probes.single, isEmpty);

    final again = await McpService.connectByUrl(server.mcpUrl);
    expect(again.status, McpConnectStatus.connected);
    await settle();
    final connection = McpService.connectionFor(id)!;
    expect(connection.lastError, isNull);
    expect(connection.checkedAt, isNotNull);
  }, skip: !hasPython);
}
