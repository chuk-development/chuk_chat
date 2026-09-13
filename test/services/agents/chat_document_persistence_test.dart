import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/models/content_block.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/chat_storage_sync.dart';
import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/storage/agents_chat_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await ChatStorageService.reset();
    await AgentsChatStore.reset();
  });

  tearDown(() async {
    await AgentsChatStore.reset();
    await ChatStorageService.reset();
  });

  test(
    'host read stays saved after transcript replacement without losing live messages',
    () async {
      const session = 'document-chat';
      final doc = <String, dynamic>{
        'id': 'results',
        'session_key': session,
        'kind': 'table',
        'title': 'Results',
        'version': 2,
        'columns': ['Party'],
        'rows': [
          {'Party': 'A'},
        ],
      };
      await AgentsChatStore.replaceThread(session, [
        {'sender': 'user', 'text': 'Latest live message'},
      ]);
      await AgentsChatStore.saveDocumentSnapshot(session, doc);
      var chat = (await AgentsChatStore.loadThread(session))!;
      expect(chat.messages.first.text, 'Latest live message');
      expect(chat.messages.length, 2);
      await AgentsChatStore.saveDocumentSnapshot(session, {
        ...doc,
        'version': 1,
      });
      expect((await AgentsChatStore.loadThread(session))!.messages.length, 2);
      await AgentsChatStore.replaceThread(session, [
        {'sender': 'user', 'text': 'Compacted transcript'},
      ]);
      chat = (await AgentsChatStore.loadThread(session))!;
      expect(chat.messages.first.text, 'Compacted transcript');
      final blocks = jsonDecode(chat.messages.last.contentBlocks!) as List;
      expect(blocks.single['sandboxArtifact']['document'], doc);
      await AgentsChatStore.saveDocumentSnapshot('another-chat', doc);
      expect(await AgentsChatStore.loadThread('another-chat'), isNull);
    },
  );

  final documents = <Map<String, dynamic>>[
    {
      'id': 'songs',
      'title': 'Songs',
      'kind': 'table',
      'version': 3,
      'columns': ['Reel', 'Song', 'Artist', 'Spotify'],
      'rows': [
        {
          'Reel': 'https://www.instagram.com/reels/example/',
          'Song': 'Детка, я потерял контроль',
          'Artist': 'Afad Zeynalov',
          'Spotify': 'https://open.spotify.com/search/Afad%20Zeynalov',
        },
      ],
    },
    {
      'id': 'election',
      'title': 'Election results (test fixture)',
      'kind': 'bar_chart',
      'version': 7,
      'caption': 'Four largest parties; test data',
      'source_url': 'https://example.org/results',
      'retrieved_at': '2026-09-06T18:00:00Z',
      'rows': [
        {'label': 'Party A', 'value': 30.4, 'color': '#112233'},
        {'label': 'Party B', 'value': 25.1, 'color': '#445566'},
        {'label': 'Party C', 'value': 19.0, 'color': '#778899'},
        {'label': 'Party D', 'value': 9.2, 'color': '#AABBCC'},
      ],
    },
  ];

  for (final document in documents) {
    test(
      '${document['kind']} survives encrypted cloud payload without a blob',
      () async {
        final key = await AesGcm.with256bits().newSecretKey();
        Map<String, dynamic>? uploaded;
        String? cachedPayload;
        AgentsChatStore.userIdProvider = () => 'document-test-user';
        AgentsChatStore.keyLoader = () async => true;
        // Exercise production encryption, using an isolated key instead of the
        // user's secure storage. Only the network and local cache are replaced.
        AgentsChatStore.encryptor = (plain) =>
            EncryptionService.encryptWithKey(plain, key, 1);
        AgentsChatStore.localCacheWriter = (_, row) async {
          cachedPayload = row['payload'] as String;
        };
        AgentsChatStore.outboxRead = (_) async => null;
        AgentsChatStore.outboxWrite = (_, _) async {};
        AgentsChatStore.outboxDelete = (_) async {};
        AgentsChatStore.cloudUpsert = (_, row) async {
          uploaded = Map<String, dynamic>.from(row);
          return row;
        };

        // There is deliberately no artifact file or blob service in this test.
        final block = ContentBlock.sandboxArtifact(
          SandboxArtifactPayload(
            storagePath: 'cowork://blob/not-present-on-this-device',
            filename: '${document['id']}.json',
            mime: 'application/vnd.cowork.document+json',
            sizeBytes: utf8.encode(jsonEncode(document)).length,
            document: document,
          ),
        );
        await AgentsChatStore.replaceThread('document-test-chat', [
          {
            'sender': 'ai',
            'text': '',
            'contentBlocks': jsonEncode([block.toJson()]),
          },
        ]);
        await AgentsChatStore.pending('document-test-chat');

        expect(uploaded, isNotNull);
        expect(AgentsChatStore.isDirty('document-test-chat'), isFalse);
        expect(uploaded!['user_id'], 'document-test-user');
        expect(uploaded!.containsKey('payload'), isFalse);
        expect(jsonEncode(uploaded), isNot(contains(document['title'])));

        // Discard the writer's in-memory state. Decode only the captured cloud
        // ciphertext through the same reader used by chat storage/sync.
        await AgentsChatStore.reset();
        await ChatStorageService.reset();
        final plaintext = await EncryptionService.tryDecryptWithKey(
          uploaded!['encrypted_payload'] as String,
          key,
        );
        expect(plaintext, cachedPayload);
        final restored = await deserializePayloadAsync(plaintext!);
        final blocks =
            jsonDecode(restored.messages.single.contentBlocks!) as List;
        final recovered = ContentBlock.fromJson(
          Map<String, dynamic>.from(blocks.single as Map),
        );
        expect(recovered.sandboxArtifact!.document, equals(document));
        expect(
          recovered.sandboxArtifact!.storagePath,
          'cowork://blob/not-present-on-this-device',
        );
      },
    );
  }
}
