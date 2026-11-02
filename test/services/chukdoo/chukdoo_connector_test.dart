// The built-in Chukdoo connector: local + encrypted cloud copy, tool
// registration, executor routing, and the revoke path. No network: the
// chukdoo RPCs are answered by a MockClient, the cloud copy by an in-memory
// mirror shared between two "installs".

import 'dart:async';
import 'dart:convert';

import 'package:chukdoo_core/chukdoo_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:chuk_chat/models/client_tool.dart';
import 'package:chuk_chat/services/agents/agents_pairing_store.dart'
    show AgentsSecureKeyValueStore;
import 'package:chuk_chat/services/chukdoo/chukdoo_config.dart';
import 'package:chuk_chat/services/chukdoo/chukdoo_connector.dart';
import 'package:chuk_chat/services/chukdoo/chukdoo_connector_sync.dart';
import 'package:chuk_chat/services/chukdoo/chukdoo_tool_bridge.dart';
import 'package:chuk_chat/services/tool_executor.dart';
import 'package:chuk_chat/tool_handlers/find_tools_handler.dart' as find_tools;

class _Memory implements AgentsSecureKeyValueStore {
  final Map<String, String> map = <String, String>{};

  @override
  Future<String?> read(String key) async => map[key];

  @override
  Future<void> write(String key, String value) async => map[key] = value;

  @override
  Future<void> delete(String key) async => map.remove(key);
}

/// Secure storage whose writes wait until [release].
class _SlowMemory extends _Memory {
  final List<Completer<void>> _waiting = <Completer<void>>[];

  void release() {
    for (final c in _waiting) {
      c.complete();
    }
    _waiting.clear();
  }

  @override
  Future<void> write(String key, String value) async {
    final c = Completer<void>();
    _waiting.add(c);
    await c.future;
    await super.write(key, value);
  }
}

/// A cloud whose reads wait until [release].
class _SlowCloud implements ChukdooMirror {
  _SlowCloud(this.inner);

  final ChukdooMirror inner;
  final Completer<void> _gate = Completer<void>();

  void release() => _gate.complete();

  @override
  Future<ChukdooMirrorRead> load() async {
    await _gate.future;
    return inner.load();
  }

  @override
  Future<bool> save(Map<String, dynamic> payload) => inner.save(payload);
}

/// The cloud row, shared by every "install" in a test. Stores the JSON
/// round trip, like the real mirror does after decrypting.
class _Cloud implements ChukdooMirror {
  String? row;
  bool failReads = false;
  bool failWrites = false;
  bool unreadable = false;
  int saves = 0;

  @override
  Future<ChukdooMirrorRead> load() async {
    if (unreadable) return const ChukdooMirrorRead.failed(unreadable: true);
    if (failReads) return const ChukdooMirrorRead.failed();
    final r = row;
    if (r == null) return const ChukdooMirrorRead.empty();
    return ChukdooMirrorRead.row(
      Map<String, dynamic>.from(jsonDecode(r) as Map),
    );
  }

  @override
  Future<bool> save(Map<String, dynamic> payload) async {
    if (failWrites) return false;
    saves++;
    row = jsonEncode(payload);
    return true;
  }
}

ChukdooCredentials _creds({String token = 'cdk_test'}) => ChukdooCredentials(
  supabaseUrl: 'https://chukdoo.invalid',
  anonKey: 'anon',
  userId: '0b5f6c1e-3a52-4d7e-9a0b-6f2c1d8e4a77',
  deviceId: 'd1',
  deviceToken: token,
  dataKey: 'AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8=',
  deviceName: 'Chuk Chat',
  pairedAt: DateTime.utc(2026, 11, 2),
);

/// Answers the chukdoo device RPCs. [unauthorized] makes every call fail the
/// way a revoked token does.
class _Rpc {
  bool unauthorized = false;
  bool gateway401 = false;
  final List<String> calls = <String>[];

  late final MockClient client = MockClient((request) async {
    final fn = request.url.pathSegments.last;
    calls.add(fn);
    if (gateway401) return http.Response('{"message":"Invalid API key"}', 401);
    if (unauthorized) {
      return http.Response(
        jsonEncode({'message': 'invalid device token', 'code': '28000'}),
        401,
      );
    }
    switch (fn) {
      case 'device_pull':
        return http.Response('[]', 200);
      case 'device_unpair':
        return http.Response('{"ok":true}', 200);
      default:
        return http.Response('{}', 200);
    }
  });
}

void main() {
  late _Cloud cloud;
  late _Rpc rpc;
  var now = DateTime.utc(2026, 11, 2, 12);

  ChukdooConnector install({_Memory? secrets, String? user = 'user-1'}) {
    return ChukdooConnector.resetForTest(
      secrets: secrets ?? _Memory(),
      mirror: cloud,
      currentUserId: () => user,
      toolsFactory: (c) => ChukdooTools.fromCredentials(
        c,
        httpClient: rpc.client,
      ),
      clock: () => now,
    );
  }

  setUp(() {
    cloud = _Cloud();
    rpc = _Rpc();
    now = DateTime.utc(2026, 11, 2, 12);
  });

  group('store and sync', () {
    test('connect writes the local copy and the cloud copy', () async {
      final secrets = _Memory();
      final a = install(secrets: secrets);
      await a.connectWith(_creds());

      expect(a.state.value.connected, isTrue);
      expect(secrets.map.keys, ['chukdoo_connector_v1_user-1']);
      expect(cloud.row, contains('cdk_test'));
    });

    test('another install of the account picks the connector up', () async {
      final a = install();
      await a.connectWith(_creds());

      final b = install();
      await b.load();
      expect(b.state.value.connected, isFalse);
      await b.pull(force: true);
      expect(b.state.value.connected, isTrue);
      expect(b.state.value.credentials!.deviceToken, 'cdk_test');
      expect(b.specs, isNotEmpty);
    });

    test('the local copy survives a restart', () async {
      final secrets = _Memory();
      await install(secrets: secrets).connectWith(_creds());
      cloud.failReads = true; // offline start

      final again = install(secrets: secrets);
      await again.pull(force: true);
      expect(again.state.value.connected, isTrue);
    });

    test('disconnect removes it on every install and revokes the device',
        () async {
      final a = install();
      await a.connectWith(_creds());
      now = now.add(const Duration(minutes: 1));
      await a.disconnect();
      expect(a.state.value.connected, isFalse);
      expect(a.state.value.revoked, isFalse);
      expect(rpc.calls, contains('device_unpair'));

      final bSecrets = _Memory();
      // B was connected before A disconnected.
      bSecrets.map['chukdoo_connector_v1_user-1'] = jsonEncode(
        ChukdooRecord.connected(_creds(), DateTime.utc(2026, 11, 2, 12))
            .toJson(),
      );
      final b = install(secrets: bSecrets);
      await b.load();
      expect(b.state.value.connected, isTrue);
      await b.pull(force: true);
      expect(b.state.value.connected, isFalse);
    });

    test('a failed cloud read changes nothing', () async {
      final a = install();
      await a.connectWith(_creds());
      cloud.failReads = true;
      await a.pull(force: true);
      expect(a.state.value.connected, isTrue);
    });

    test('a connect that never reached the cloud is pushed on the next pull',
        () async {
      final a = install();
      await a.connectWith(_creds());
      cloud.row = null; // the save got lost
      await a.pull(force: true);
      expect(cloud.row, contains('cdk_test'));
    });

    test('sign-out drops the local copy, the cloud copy stays', () async {
      final secrets = _Memory();
      final a = install(secrets: secrets);
      await a.connectWith(_creds());
      await a.forgetLocal('user-1');
      expect(secrets.map, isEmpty);
      expect(a.state.value.connected, isFalse);
      expect(cloud.row, contains('cdk_test'));
    });

    test('password change: remirror seals the snapshot again, or throws',
        () async {
      final a = install();
      await a.connectWith(_creds());
      final snapshot = a.recordSnapshot();
      expect(snapshot, isNotNull);
      cloud.row = null;
      await a.remirror(snapshot);
      expect(cloud.row, contains('cdk_test'));

      cloud.failWrites = true;
      await expectLater(a.remirror(snapshot), throwsStateError);
      await a.remirror(snapshot, strict: false); // rollback path
      await a.remirror(null); // nothing to seal
    });

    test('password change waits for a cloud read that works', () async {
      final a = install();
      await a.connectWith(_creds());
      expect(await a.pullForRekey(), isTrue);
      cloud.failReads = true;
      expect(await a.pullForRekey(), isFalse);
      cloud.failReads = false;
      // A row sealed under another key cannot block it forever.
      cloud.unreadable = true;
      expect(await a.pullForRekey(), isTrue);
      expect(a.recordSnapshot(), isNotNull);
    });

    test('a write that lands after sign-out leaves nothing behind', () async {
      final secrets = _SlowMemory();
      String? user = 'user-1';
      final a = ChukdooConnector.resetForTest(
        secrets: secrets,
        mirror: cloud,
        currentUserId: () => user,
        toolsFactory: (c) => ChukdooTools.fromCredentials(
          c,
          httpClient: rpc.client,
        ),
      );
      final connecting = a.connectWith(_creds());
      user = null;
      await a.forgetLocal('user-1');
      secrets.release();
      await expectLater(connecting, throwsA(isA<ChukdooPairingCancelled>()));
      expect(secrets.map, isEmpty);
      expect(a.state.value.connected, isFalse);
    });

    test('a pull that outlives a sign-out stores nothing', () async {
      await install().connectWith(_creds()); // user-1's cloud row
      String? user = 'user-1';
      final slowCloud = _SlowCloud(cloud);
      final b = ChukdooConnector.resetForTest(
        secrets: _Memory(),
        mirror: slowCloud,
        currentUserId: () => user,
      );
      final pulling = b.pull(force: true);
      await Future<void>.delayed(Duration.zero);
      await b.forgetLocal('user-1');
      user = 'user-2';
      slowCloud.release();
      await pulling;
      expect(b.state.value.connected, isFalse);
    });

    test('the record survives a JSON round trip', () {
      final record = ChukdooRecord.connected(_creds(), now);
      final back = ChukdooRecord.tryParse(
        jsonDecode(jsonEncode(record.toJson())),
      )!;
      expect(back.credentials!.dataKey, _creds().dataKey);
      expect(back.updatedAt, now);
      final ended = ChukdooRecord.tryParse(
        ChukdooRecord.ended(ChukdooEndReason.revoked, now).toJson(),
      )!;
      expect(ended.credentials, isNull);
      expect(ended.ended, ChukdooEndReason.revoked);
      expect(ChukdooRecord.tryParse('nonsense'), isNull);
      expect(
        ChukdooRecord.tryParse({'v': 2, 'updated_at': now.toIso8601String()}),
        isNull,
      );
    });
  });

  group('tools', () {
    test('registered on connect, removed on disconnect', () async {
      final connector = install();
      final executor = ToolExecutor();
      watchChukdooConnector(executor);
      syncChukdooTools(executor);
      bool hasChukdoo() =>
          executor.allRegisteredTools.any((t) => t.type == ToolType.chukdoo);
      expect(hasChukdoo(), isFalse);

      await connector.connectWith(_creds());
      expect(hasChukdoo(), isTrue);
      final listTodos = executor.tools['chukdoo_list_todos'];
      expect(listTodos, isNotNull);
      expect(listTodos!.parameters['type'], 'object');
      expect(connector.isReadOnlyTool('chukdoo_list_todos'), isTrue);
      expect(connector.isReadOnlyTool('chukdoo_create_todo'), isFalse);

      // Hard deletes stay out until there is an approval step.
      expect(executor.tools['chukdoo_delete_note'], isNull);
      expect(
        (await connector.callTool('chukdoo_delete_todo', {'id': 'x'})).isError,
        isTrue,
      );
      expect(rpc.calls, isNot(contains('device_delete')));
      final updateNote = executor.tools['chukdoo_update_note']!;
      expect(
        (updateNote.parameters['properties'] as Map).containsKey('content'),
        isFalse,
      );
      expect(
        (await connector.callTool('chukdoo_update_note', {
          'id': 'n1',
          'content': '',
        })).isError,
        isTrue,
      );

      await connector.disconnect();
      expect(hasChukdoo(), isFalse);
    });

    test('find_tools finds them by everyday words', () async {
      final connector = install();
      final executor = ToolExecutor();
      watchChukdooConnector(executor);
      await connector.connectWith(_creds());

      final out = find_tools.executeFindTools(
        args: {'query': 'aufgaben'},
        tools: executor.tools,
        getDescription: executor.getToolDescription,
        isAvailable: executor.isToolAvailable,
      );
      expect(out, contains('chukdoo_list_todos'));
    });

    test('the executor routes a call to the chukdoo tools', () async {
      final connector = install();
      final executor = ToolExecutor();
      watchChukdooConnector(executor);
      await connector.connectWith(_creds());

      final result = await executor.execute('chukdoo_list_todos', {
        'filter': 'all',
      });
      expect(result.isError, isFalse, reason: result.output);
      expect(rpc.calls, contains('device_pull'));
      expect(jsonDecode(result.output), isA<Map<String, dynamic>>());
    });

    test('bad input comes back to the model as an error', () async {
      final connector = install();
      final executor = ToolExecutor();
      watchChukdooConnector(executor);
      await connector.connectWith(_creds());

      final result = await executor.execute('chukdoo_create_todo', {});
      expect(result.isError, isTrue);
      expect(result.output, startsWith('Error:'));
      expect(connector.state.value.connected, isTrue);
    });

    test('a revoked device ends the connector everywhere', () async {
      final connector = install();
      final executor = ToolExecutor();
      watchChukdooConnector(executor);
      await connector.connectWith(_creds());
      rpc.unauthorized = true;
      now = now.add(const Duration(minutes: 1));

      final result = await executor.execute('chukdoo_list_todos', {});
      expect(result.isError, isTrue);
      expect(result.output, contains('removed in the Chukdoo app'));
      expect(connector.state.value.connected, isFalse);
      expect(connector.state.value.revoked, isTrue);
      expect(
        executor.allRegisteredTools.any((t) => t.type == ToolType.chukdoo),
        isFalse,
      );
      // The tombstone reached the cloud, so the other installs follow.
      expect(ChukdooRecord.tryParse(jsonDecode(cloud.row!))!.ended,
          ChukdooEndReason.revoked);
    });

    test('a stale token does not wipe a newer pairing', () async {
      final b = install();
      await b.connectWith(_creds(token: 'cdk_old'));
      final executor = ToolExecutor();
      watchChukdooConnector(executor);
      syncChukdooTools(executor);
      // Another install disconnected (revoking cdk_old) and paired again.
      now = now.add(const Duration(minutes: 5));
      cloud.row = jsonEncode(
        ChukdooRecord.connected(_creds(token: 'cdk_new'), now).toJson(),
      );
      rpc.unauthorized = true;

      final result = await executor.execute('chukdoo_list_todos', {});
      expect(result.isError, isTrue);
      expect(b.state.value.credentials?.deviceToken, 'cdk_new');
      expect(
        ChukdooRecord.tryParse(jsonDecode(cloud.row!))!.credentials
            ?.deviceToken,
        'cdk_new',
      );
    });

    test('a 401 without a working cloud read ends nothing', () async {
      final connector = install();
      final executor = ToolExecutor();
      watchChukdooConnector(executor);
      await connector.connectWith(_creds());
      rpc.unauthorized = true;
      cloud.failReads = true;

      final result = await executor.execute('chukdoo_list_todos', {});
      expect(result.isError, isTrue);
      expect(connector.state.value.connected, isTrue);
      expect(ChukdooRecord.tryParse(jsonDecode(cloud.row!))!.credentials,
          isNotNull);
    });

    test('a gateway 401 is not a revoke', () async {
      final connector = install();
      await connector.connectWith(_creds());
      rpc.gateway401 = true;
      final result = await connector.callTool('chukdoo_list_todos', {});
      expect(result.isError, isTrue);
      expect(connector.state.value.connected, isTrue);
    });

    test('a call while not connected says how to connect', () async {
      final connector = install();
      final result = await connector.callTool('chukdoo_list_todos', {});
      expect(result.isError, isTrue);
      expect(result.text, contains('Settings > Connectors'));
    });
  });

  group('pairing', () {
    test('start opens a request and shows the code; cancel stops it',
        () async {
      final calls = <String>[];
      final client = MockClient((request) async {
        final fn = request.url.pathSegments.last;
        calls.add(fn);
        if (fn == 'pairing_open') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          expect(body['device_kind'], ChukdooConnector.deviceKind);
          expect(body['device_name'], ChukdooConnector.deviceName);
          return http.Response(
            jsonEncode({
              'expires_at': DateTime.now()
                  .add(const Duration(minutes: 10))
                  .toUtc()
                  .toIso8601String(),
            }),
            200,
          );
        }
        return http.Response('{"status":"pending"}', 200);
      });
      ChukdooConfig.debugOverride(
        url: 'https://chukdoo.invalid',
        anonKey: 'anon',
      );
      addTearDown(ChukdooConfig.debugOverride);
      final connector = ChukdooConnector.resetForTest(
        secrets: _Memory(),
        mirror: cloud,
        currentUserId: () => 'user-1',
        httpClientFactory: () => client,
      );
      final pairing = await connector.startPairing();
      expect(pairing.displayCode, matches(RegExp(r'^[0-9A-Z]{5}-[0-9A-Z]{5}$')));
      expect(calls, ['pairing_open']);

      pairing.cancel();
      await expectLater(pairing.done, throwsA(isA<ChukdooPairingCancelled>()));
      expect(connector.state.value.connected, isFalse);
    });

    test('an approval never lands in another account', () async {
      final connector = install();
      await expectLater(
        connector.connectWith(_creds(), owner: 'user-2'),
        throwsA(isA<ChukdooPairingCancelled>()),
      );
      expect(connector.state.value.connected, isFalse);
      expect(cloud.row, isNull);
    });

    test('no signed-in user, no pairing', () async {
      final connector = install(user: null);
      await expectLater(
        connector.startPairing(),
        throwsA(isA<ChukdooPairingFailed>()),
      );
    });
  });
}
