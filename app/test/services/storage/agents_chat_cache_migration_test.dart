import 'dart:convert';
import 'dart:io' as io;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/storage/agents_chat_cache_migration.dart';
import 'package:chuk_chat/services/storage/agents_chat_store.dart';
import 'package:chuk_chat/utils/io_helper.dart' as ioh;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late io.Directory tmp;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await ChatStorageService.reset();
    await AgentsChatStore.reset();
    AgentsChatCacheMigration.reset();
    tmp = await io.Directory.systemTemp.createTemp('agents-migration-');
    AgentsChatCacheMigration.chatDirProvider = () async =>
        ioh.Directory(tmp.path);
  });

  tearDown(() async {
    AgentsChatCacheMigration.reset();
    await AgentsChatStore.reset();
    await ChatStorageService.reset();
    if (await tmp.exists()) await tmp.delete(recursive: true);
  });

  io.File writeP2bFile(
    String id,
    List<Map<String, dynamic>> messages, {
    String? customName,
  }) {
    final safe = id.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final file = io.File('${tmp.path}/$safe.json');
    // P2b's index: the migration reads ids from it, as P2b did.
    final index = io.File('${tmp.path}/index.json');
    final ids = index.existsSync()
        ? (jsonDecode(index.readAsStringSync()) as List).cast<String>()
        : <String>[];
    index.writeAsStringSync(jsonEncode(<String>[...ids, id]));
    file.writeAsStringSync(
      jsonEncode(<String, dynamic>{
        'id': id,
        'createdAt': '2026-09-03T23:06:59.000',
        'updatedAt': '2026-09-05T03:26:44.299',
        'isStarred': true,
        'customName': ?customName,
        'messages': messages,
      }),
    );
    return file;
  }

  test("yesterday's P2b file becomes the thread, with its own dates", () async {
    final file = writeP2bFile('host:cowork-host', <Map<String, dynamic>>[
      <String, dynamic>{'role': 'user', 'text': 'plan the launch'},
      <String, dynamic>{'role': 'assistant', 'text': 'done, three steps'},
    ]);
    AgentsChatCacheMigration.hasLocalCopy = (_, _) async => false;

    final n = await AgentsChatCacheMigration.migrateJsonCache('user-7');
    expect(n, 1);

    final chat = ChatStorageService.getChatById('host:cowork-host');
    expect(chat, isNotNull);
    expect(chat!.messages.map((m) => m.text), [
      'plan the launch',
      'done, three steps',
    ]);
    expect(chat.createdAt.year, 2026);
    expect(chat.createdAt.day, 3);
    expect(chat.updatedAt!.day, 5);
    expect(chat.isStarred, isTrue);

    // The file is a backup now, not a source: renamed, never deleted.
    expect(await file.exists(), isFalse);
    expect(io.File('${file.path}.migrated').existsSync(), isTrue);
    // The index is not a thread file and is left alone.
    expect(io.File('${tmp.path}/index.json').existsSync(), isTrue);
  });

  test('a thread SQLite already holds keeps the newer row; the file is '
      'marked migrated', () async {
    final file = writeP2bFile('agent-1', <Map<String, dynamic>>[
      <String, dynamic>{'role': 'user', 'text': 'old'},
    ]);
    var writes = 0;
    AgentsChatCacheMigration.hasLocalCopy = (_, _) async => true;
    AgentsChatCacheMigration.writer =
        (id, rows, {createdAt, updatedAt, isStarred, customName}) async {
          writes++;
          return null;
        };
    final n = await AgentsChatCacheMigration.migrateJsonCache('user-7');
    expect(n, 0);
    expect(writes, 0);
    expect(io.File('${file.path}.migrated').existsSync(), isTrue);
  });

  test(
    'an unreadable file is left where it is; the others still migrate',
    () async {
      writeP2bFile('broken', <Map<String, dynamic>>[]);
      io.File('${tmp.path}/broken.json').writeAsStringSync('{not json');
      writeP2bFile('agent-2', <Map<String, dynamic>>[
        <String, dynamic>{'role': 'user', 'text': 'fine'},
      ]);
      AgentsChatCacheMigration.hasLocalCopy = (_, _) async => false;
      final n = await AgentsChatCacheMigration.migrateJsonCache('user-7');
      expect(n, 1);
      expect(io.File('${tmp.path}/broken.json').existsSync(), isTrue);
      expect(ChatStorageService.getChatById('agent-2'), isNotNull);
    },
  );

  test('no cache directory: nothing to do, no error', () async {
    AgentsChatCacheMigration.chatDirProvider = () async => null;
    expect(await AgentsChatCacheMigration.migrateJsonCache('user-7'), 0);
  });

  test(
    'a cursor without a local copy is dropped; one with a copy stays',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'cowork.replay_cursor.host:cowork-host': 106,
        'cowork.replay_cursor.agent-kept': 12,
        'unrelated.key': 'x',
      });
      AgentsChatCacheMigration.hasLocalCopy = (_, key) async =>
          key == 'agent-kept';
      final dropped = await AgentsChatCacheMigration.dropOrphanCursors(
        'user-7',
      );
      expect(dropped, 1);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('cowork.replay_cursor.host:cowork-host'), isNull);
      expect(prefs.getInt('cowork.replay_cursor.agent-kept'), 12);
      expect(prefs.getString('unrelated.key'), 'x');
    },
  );

  test(
    'the default local-copy probe sees a thread that is in memory',
    () async {
      await AgentsChatStore.replaceThread('agent-mem', <Map<String, dynamic>>[
        <String, dynamic>{'role': 'user', 'text': 'here'},
      ]);
      SharedPreferences.setMockInitialValues(<String, Object>{
        'cowork.replay_cursor.agent-mem': 3,
        'cowork.replay_cursor.agent-gone': 9,
      });
      // No SQLite in a test: memory is the only local copy.
      final dropped = await AgentsChatCacheMigration.dropOrphanCursors(
        'user-7',
      );
      expect(dropped, 1);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('cowork.replay_cursor.agent-mem'), 3);
      expect(prefs.getInt('cowork.replay_cursor.agent-gone'), isNull);
    },
  );
}
