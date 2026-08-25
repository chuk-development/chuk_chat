// The pure pieces of cross-device MCP sync: the blob codec that travels
// between devices, and the reconcile decision that says what to add, re-key
// and forget. No network, no globals — real constructors only.

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/services/mcp/mcp_client.dart';
import 'package:chuk_chat/services/mcp/mcp_connection.dart';
import 'package:chuk_chat/services/mcp/mcp_sync_service.dart';

McpSyncBlob _remoteBlob(String id, {String? accessToken, McpAuth auth = McpAuth.oauth}) {
  final connection = McpConnection(
    id: id,
    name: id,
    url: 'https://example.com/$id',
    auth: auth,
  );
  return McpSyncBlob(
    connection: connection,
    secrets: accessToken == null
        ? null
        : {
            'credentials': {'client_id': 'c-$id'},
            'tokens': {'access_token': accessToken},
            'issuer': 'https://issuer/$id',
          },
  );
}

void main() {
  group('the sync blob', () {
    test('drops the cached tools on the way out and comes back empty', () {
      final connection = McpConnection(
        id: 'github',
        name: 'GitHub',
        url: 'https://mcp.example.com/github',
        description: 'code host',
        iconUrl: 'https://example.com/icon.png',
        addedByHand: true,
        auth: McpAuth.oauth,
        tools: const [
          McpTool(name: 'search', description: 'find', inputSchema: {'type': 'object'}),
          McpTool(name: 'issues', description: 'list', inputSchema: {}),
        ],
      );

      final blob = McpSyncBlob.fromConnection(connection, {
        'tokens': {'access_token': 'abc'},
      });

      // Tools never travel — they are fetched live on the receiver.
      expect(blob.connection.tools, isEmpty);

      final round = McpSyncBlob.fromJson(blob.toJson());
      expect(round.connection.id, 'github');
      expect(round.connection.name, 'GitHub');
      expect(round.connection.url, 'https://mcp.example.com/github');
      expect(round.connection.description, 'code host');
      expect(round.connection.iconUrl, 'https://example.com/icon.png');
      expect(round.connection.addedByHand, isTrue);
      expect(round.connection.auth, McpAuth.oauth);
      expect(round.connection.tools, isEmpty);
      expect(round.accessToken, 'abc');
    });

    test('an app-session connector round-trips with no secret', () {
      final connection = McpConnection(
        id: 'first-party',
        name: 'Chuk',
        url: 'https://api.chuk.chat/mcp',
        auth: McpAuth.appSession,
      );
      final blob = McpSyncBlob.fromConnection(connection, null);

      final round = McpSyncBlob.fromJson(blob.toJson());
      expect(round.secrets, isNull);
      expect(round.accessToken, isNull);
      expect(round.connection.auth, McpAuth.appSession);
    });

    test('reads the access token out of a secrets map, or null', () {
      expect(accessTokenOf(null), isNull);
      expect(accessTokenOf({'tokens': {}}), isNull);
      expect(accessTokenOf({'tokens': {'access_token': ''}}), isNull);
      expect(accessTokenOf({'tokens': {'access_token': 't'}}), 't');
    });

    test('reads the token expiry out of a secrets map, or null', () {
      expect(expiresAtOf(null), isNull);
      expect(expiresAtOf({'tokens': {}}), isNull);
      expect(
        expiresAtOf({'tokens': {'expires_at': '2030-01-01T00:00:00Z'}}),
        DateTime.parse('2030-01-01T00:00:00Z'),
      );
    });

    test('a blob with no connection key decodes to an empty id', () {
      // fromJson falls back to an empty map, so the id is empty. The pull
      // guards on the row name, so such a blob is dropped rather than re-added
      // under the wrong key.
      final round = McpSyncBlob.fromJson({'secrets': null});
      expect(round.connection.id, isEmpty);
    });
  });

  group('reconcile', () {
    test('adds a remote connection that is not here yet', () {
      final plan = reconcileMcpSync(
        localIds: {'a'},
        knownSyncedIds: {'a'},
        remoteIds: {'a', 'b'},
        localAccessTokens: const {},
        remoteAccessTokens: const {},
      );
      expect(plan.toAdd, {'b'});
      expect(plan.toRemove, isEmpty);
      expect(plan.toUpdate, isEmpty);
      expect(plan.nextKnownSyncedIds, {'a', 'b'});
    });

    test('propagates a remote deletion of a previously synced connection', () {
      final plan = reconcileMcpSync(
        localIds: {'a', 'b'},
        knownSyncedIds: {'a', 'b'},
        remoteIds: {'a'},
        localAccessTokens: const {},
        remoteAccessTokens: const {},
      );
      expect(plan.toRemove, {'b'});
      expect(plan.toAdd, isEmpty);
      expect(plan.nextKnownSyncedIds, {'a'});
    });

    test('never deletes a local-only connection that was never synced', () {
      // 'local' was added here but never pushed / seen on the server.
      final plan = reconcileMcpSync(
        localIds: {'a', 'local'},
        knownSyncedIds: {'a'},
        remoteIds: {'a'},
        localAccessTokens: const {},
        remoteAccessTokens: const {},
      );
      expect(plan.toRemove, isEmpty);
      expect(plan.nextKnownSyncedIds, {'a'});
    });

    test('does not delete a just-pushed connection before the server confirms', () {
      // Device pushed 'x'; the pull snapshot has not caught up yet, so 'x' is
      // local but not in the confirmed knownSyncedIds and not in remoteIds.
      final plan = reconcileMcpSync(
        localIds: {'x'},
        knownSyncedIds: <String>{},
        remoteIds: <String>{},
        localAccessTokens: const {},
        remoteAccessTokens: const {},
      );
      expect(plan.toRemove, isEmpty);
      expect(plan.toAdd, isEmpty);
      expect(plan.nextKnownSyncedIds, isEmpty);
    });

    test('flags a token rotation as an update, not an add', () {
      final plan = reconcileMcpSync(
        localIds: {'a'},
        knownSyncedIds: {'a'},
        remoteIds: {'a'},
        localAccessTokens: {'a': 'old'},
        remoteAccessTokens: {'a': 'new'},
      );
      expect(plan.toUpdate, {'a'});
      expect(plan.toAdd, isEmpty);
      expect(plan.toRemove, isEmpty);
    });

    test('an unchanged token is not an update', () {
      final plan = reconcileMcpSync(
        localIds: {'a'},
        knownSyncedIds: {'a'},
        remoteIds: {'a'},
        localAccessTokens: {'a': 'same'},
        remoteAccessTokens: {'a': 'same'},
      );
      expect(plan.toUpdate, isEmpty);
    });

    test('a newer remote token wins over the local one', () {
      final plan = reconcileMcpSync(
        localIds: {'a'},
        knownSyncedIds: {'a'},
        remoteIds: {'a'},
        localAccessTokens: {'a': 'old'},
        remoteAccessTokens: {'a': 'new'},
        localTokenExpiries: {'a': DateTime.parse('2030-01-01T00:00:00Z')},
        remoteTokenExpiries: {'a': DateTime.parse('2030-06-01T00:00:00Z')},
      );
      expect(plan.toUpdate, {'a'});
    });

    test('an older remote token does not clobber a fresher local one', () {
      // The other device pushed a token that is already staler than ours (ours
      // was refreshed locally and not yet pushed). It must not overwrite.
      final plan = reconcileMcpSync(
        localIds: {'a'},
        knownSyncedIds: {'a'},
        remoteIds: {'a'},
        localAccessTokens: {'a': 'fresh'},
        remoteAccessTokens: {'a': 'stale'},
        localTokenExpiries: {'a': DateTime.parse('2030-06-01T00:00:00Z')},
        remoteTokenExpiries: {'a': DateTime.parse('2030-01-01T00:00:00Z')},
      );
      expect(plan.toUpdate, isEmpty);
    });

    test('an unknown local expiry lets the differing remote token win', () {
      final plan = reconcileMcpSync(
        localIds: {'a'},
        knownSyncedIds: {'a'},
        remoteIds: {'a'},
        localAccessTokens: {'a': 'old'},
        remoteAccessTokens: {'a': 'new'},
        localTokenExpiries: {'a': null},
        remoteTokenExpiries: {'a': null},
      );
      expect(plan.toUpdate, {'a'});
    });

    test('a remote token adopts onto a connection that stored none', () {
      final plan = reconcileMcpSync(
        localIds: {'a'},
        knownSyncedIds: {'a'},
        remoteIds: {'a'},
        localAccessTokens: {'a': null},
        remoteAccessTokens: {'a': 'tok'},
      );
      expect(plan.toUpdate, {'a'});
    });

    test('a remote token with no expiry does not win over a dated local one', () {
      final plan = reconcileMcpSync(
        localIds: {'a'},
        knownSyncedIds: {'a'},
        remoteIds: {'a'},
        localAccessTokens: {'a': 'local'},
        remoteAccessTokens: {'a': 'remote'},
        localTokenExpiries: {'a': DateTime.parse('2030-01-01T00:00:00Z')},
        remoteTokenExpiries: const {'a': null},
      );
      expect(plan.toUpdate, isEmpty);
    });

    test('an app-session connector with no remote token is not an update', () {
      final plan = reconcileMcpSync(
        localIds: {'a'},
        knownSyncedIds: {'a'},
        remoteIds: {'a'},
        localAccessTokens: {'a': null},
        remoteAccessTokens: {'a': null},
      );
      expect(plan.toUpdate, isEmpty);
      expect(plan.toAdd, isEmpty);
      expect(plan.toRemove, isEmpty);
    });

    test('handles a mixed pass: add, update, remove and a survivor together', () {
      final plan = reconcileMcpSync(
        localIds: {'keep', 'rotate', 'gone', 'localonly'},
        knownSyncedIds: {'keep', 'rotate', 'gone'},
        remoteIds: {'keep', 'rotate', 'new'},
        localAccessTokens: {'keep': 't', 'rotate': 'old'},
        remoteAccessTokens: {'keep': 't', 'rotate': 'new'},
      );
      expect(plan.toAdd, {'new'});
      expect(plan.toUpdate, {'rotate'});
      expect(plan.toRemove, {'gone'});
      expect(plan.nextKnownSyncedIds, {'keep', 'rotate', 'new'});
      // 'localonly' is left completely alone.
      expect(plan.toRemove, isNot(contains('localonly')));
    });

    test('the blob from a remote row carries its auth type through', () {
      final blob = _remoteBlob('svc', accessToken: 'tok', auth: McpAuth.appSession);
      final round = McpSyncBlob.fromJson(blob.toJson());
      expect(round.connection.auth, McpAuth.appSession);
      expect(round.accessToken, 'tok');
    });
  });

  group('pending-delete tombstone lifecycle', () {
    setUp(() {
      TestWidgetsFlutterBinding.ensureInitialized();
      SharedPreferences.setMockInitialValues({});
      McpSyncService.resetForTests();
    });

    Future<List<String>> pending() async {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getStringList(McpSyncService.pendingDeleteKeyForTest) ??
          const [];
    }

    test('mark adds a tombstone; clear removes it and bumps the epoch', () async {
      final e1 = await McpSyncService.markPendingDelete('a');
      expect(await pending(), contains('a'));

      await McpSyncService.clearPendingDelete('a');
      expect(await pending(), isEmpty);

      final e2 = await McpSyncService.markPendingDelete('a');
      // A fresh arm after a reconnect must carry a newer epoch.
      expect(e2, greaterThan(e1));
    });

    test(
      'a stale-epoch delete does not clear the tombstone of a later disconnect',
      () async {
        // disconnect #1 arms the tombstone and starts a background delete.
        final epoch1 = await McpSyncService.markPendingDelete('a');
        // reconnect clears it, then disconnect #2 re-arms it.
        await McpSyncService.clearPendingDelete('a');
        await McpSyncService.markPendingDelete('a');

        // delete #1 lands late with its stale epoch: it must step aside without
        // touching the second disconnect's tombstone. (The epoch guard trips
        // before any network call, so no backend is needed here.)
        await McpSyncService.deleteIfStillPending('a', epoch1);

        expect(await pending(), contains('a'));
      },
    );

    test('clearing an id leaves other tombstones intact', () async {
      await McpSyncService.markPendingDelete('a');
      await McpSyncService.markPendingDelete('b');
      await McpSyncService.clearPendingDelete('a');
      final live = await pending();
      expect(live, contains('b'));
      expect(live, isNot(contains('a')));
    });

    test('concurrent marks do not lose an update (lost-update race)', () async {
      // Start both without awaiting between them, so their load-modify-save
      // windows overlap. The async lock must serialise them; without it one
      // write clobbers the other and a tombstone is silently dropped.
      final f1 = McpSyncService.markPendingDelete('a');
      final f2 = McpSyncService.markPendingDelete('b');
      await Future.wait([f1, f2]);
      expect(await pending(), containsAll(<String>['a', 'b']));
    });
  });

  group('metadataDiffers', () {
    McpConnection base() => const McpConnection(
      id: 'x',
      name: 'X',
      url: 'https://example.com/x',
      description: 'desc',
      iconUrl: 'https://example.com/i.png',
      addedByHand: false,
      auth: McpAuth.oauth,
    );

    test('identical metadata does not differ', () {
      expect(metadataDiffers(base(), base()), isFalse);
    });

    test('a different tool list alone does not count as a metadata change', () {
      final withTools = base().copyWith(
        tools: const [McpTool(name: 't', description: 'd', inputSchema: {})],
      );
      expect(metadataDiffers(base(), withTools), isFalse);
    });

    test('each synced field is detected', () {
      expect(metadataDiffers(base(), base().copyWith(name: 'Y')), isTrue);
      expect(metadataDiffers(base(), base().copyWith(iconUrl: 'https://z/z.png')),
          isTrue);
      // name/iconUrl are covered by copyWith; the rest need a full rebuild.
      const differentUrl = McpConnection(id: 'x', name: 'X', url: 'https://other/x');
      expect(metadataDiffers(base(), differentUrl), isTrue);
      const differentAuth = McpConnection(
        id: 'x',
        name: 'X',
        url: 'https://example.com/x',
        description: 'desc',
        iconUrl: 'https://example.com/i.png',
        auth: McpAuth.appSession,
      );
      expect(metadataDiffers(base(), differentAuth), isTrue);
      const differentByHand = McpConnection(
        id: 'x',
        name: 'X',
        url: 'https://example.com/x',
        description: 'desc',
        iconUrl: 'https://example.com/i.png',
        addedByHand: true,
      );
      expect(metadataDiffers(base(), differentByHand), isTrue);
      const differentDesc = McpConnection(
        id: 'x',
        name: 'X',
        url: 'https://example.com/x',
        description: 'other',
        iconUrl: 'https://example.com/i.png',
      );
      expect(metadataDiffers(base(), differentDesc), isTrue);
    });
  });
}
