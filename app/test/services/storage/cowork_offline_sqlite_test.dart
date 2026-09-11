import 'dart:convert';
import 'dart:io';

import 'package:cowork/services/chat_storage_service.dart';
import 'package:cowork/services/local_chat_cache_service.dart';
import 'package:cowork/services/storage/cowork_chat_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/kv_cache_test_env.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    directory = await useTempKvCache();
    await ChatStorageService.reset();
    await CoworkChatStore.reset();
  });

  tearDown(() async {
    await CoworkChatStore.reset();
    await ChatStorageService.reset();
    await disposeTempKvCache(directory);
  });

  test('offline thread survives memory reset and SQLite reopen', () async {
    CoworkChatStore.userIdProvider = () => 'offline-user';
    CoworkChatStore.keyLoader = () async => false;
    await CoworkChatStore.replaceThread('offline-thread', [
      {'sender': 'user', 'text': 'Hello'},
      {'sender': 'ai', 'text': 'Partial streamed answer'},
    ]);
    await CoworkChatStore.pending('offline-thread');

    await CoworkChatStore.reset();
    await ChatStorageService.reset();
    await LocalChatCacheService.debugReset();

    expect(File('${directory.path}/chat_cache.db').existsSync(), isTrue);
    final row = await LocalChatCacheService.loadById(
      'offline-user',
      'offline-thread',
    );
    expect(row, isNotNull);
    final payload = jsonDecode(row!['payload'] as String) as Map;
    expect(payload.toString(), contains('Partial streamed answer'));
    expect(await LocalChatCacheService.count('offline-user'), 1);
    expect(
      await LocalChatCacheService.loadById('another-user', 'offline-thread'),
      isNull,
    );
  });

  test('hasThread and loadThread answer with only a remembered user id', () async {
    // Write the thread while a session is live, exactly as a run does.
    CoworkChatStore.userIdProvider = () => 'offline-user';
    CoworkChatStore.keyLoader = () async => false;
    await CoworkChatStore.replaceThread('offline-thread', [
      {'sender': 'user', 'text': 'Where were we'},
      {'sender': 'ai', 'text': 'Right here'},
    ]);
    await CoworkChatStore.pending('offline-thread');
    // What `CoworkChatStorageBootstrap._signedIn` does when the session lands.
    await CoworkChatStore.rememberUser('offline-user');
    await CoworkChatStore.reset();
    await ChatStorageService.reset();

    // The cold start: no Supabase session at all, only what preferences
    // remember. Both entry points must resolve the SAME id — if `hasThread`
    // said yes while the row read used another, the replay would splice a
    // delta onto the wrong base and `saveChat` would REPLACE the history.
    expect(CoworkChatStore.userIdProvider, isNull);
    expect(await CoworkChatStore.resolveCacheUserId(), 'offline-user');
    expect(await CoworkChatStore.hasThread('offline-thread'), isTrue);

    final chat = await CoworkChatStore.loadThread('offline-thread');
    expect(chat, isNotNull);
    expect(chat!.isFullyLoaded, isTrue);
    expect(chat.messages.map((m) => m.text), <String>[
      'Where were we',
      'Right here',
    ]);
    // The thread is in memory now, which is what the chat screen reads.
    expect(ChatStorageService.getChatById('offline-thread'), isNotNull);
  });

  test('with no remembered id at all both entry points fail the same way', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    expect(await CoworkChatStore.resolveCacheUserId(), isNull);
    expect(await CoworkChatStore.hasThread('offline-thread'), isFalse);
    expect(await CoworkChatStore.loadThread('offline-thread'), isNull);
  });
}
