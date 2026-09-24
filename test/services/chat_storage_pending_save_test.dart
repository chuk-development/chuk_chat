// Regression: a timed-out chat save took every later save down with it.
//
// Live, 2026-09-23: a tool turn saves the chat once per round. When one
// `encrypted_chats` update hit its 15 s timeout, each update queued behind it
// re-threw that same TimeoutException instead of writing its own, newer
// messages, and the failed save's completer — with no one listening — also
// surfaced as "Unhandled Exception: TimeoutException" in the log.

import 'dart:async';

import 'package:chuk_chat/models/stored_chat.dart';
import 'package:chuk_chat/services/chat_storage_crud.dart';
import 'package:chuk_chat/services/chat_storage_state.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const chatId = '00000000-0000-4000-8000-000000000001';
  final messages = <Map<String, dynamic>>[
    {'sender': 'user', 'text': 'Wie ist das Wetter gerade in Kiel?'},
  ];

  tearDown(() => ChatStorageState.pendingSaves.remove(chatId));

  test(
    'an update queued behind a failed save still runs its own write',
    () async {
      // The earlier save for this chat failed with a timeout.
      final earlier = Completer<StoredChat?>()..future.ignore();
      ChatStorageState.pendingSaves[chatId] = earlier;
      earlier.completeError(
        TimeoutException('earlier save', const Duration(seconds: 15)),
      );

      // There is no Supabase client in a test, so the queued update's own
      // write fails too — but with its OWN error, which proves it ran instead
      // of re-throwing the earlier one.
      Object? error;
      try {
        await ChatStorageCrud.updateChat(chatId, messages);
      } catch (e) {
        error = e;
      }
      expect(error, isNotNull);
      expect(error, isNot(isA<TimeoutException>()));
    },
  );

  test('a failed update with no waiter is not an unhandled error', () async {
    final uncaught = <Object>[];
    Object? callerError;
    await runZonedGuarded(() async {
      try {
        await ChatStorageCrud.updateChat(chatId, messages);
      } catch (e) {
        callerError = e;
      }
      // Let any stray error of the internal completer reach the zone.
      await Future<void>.delayed(Duration.zero);
    }, (error, _) => uncaught.add(error));

    expect(callerError, isNotNull, reason: 'the caller still gets the error');
    expect(uncaught, isEmpty);
    expect(ChatStorageState.pendingSaves.containsKey(chatId), isFalse);
  });

  group('Disk IO: fewer whole-payload rewrites', () {
    final stored = StoredChat(
      id: chatId,
      messages: const [],
      createdAt: DateTime.utc(2026, 9, 24),
      isStarred: false,
    );

    setUp(() => ChatStorageState.chatsById[chatId] = stored);
    tearDown(() {
      ChatStorageState.chatsById.remove(chatId);
      ChatStorageState.latestUpdate.remove(chatId);
      ChatStorageState.lastWrite.remove(chatId);
    });

    test('a skipped update reports the newer write\'s outcome', () async {
      final earlier = Completer<StoredChat?>()..future.ignore();
      ChatStorageState.pendingSaves[chatId] = earlier;

      final older = ChatStorageCrud.updateChat(chatId, messages)..ignore();
      final newer = ChatStorageCrud.updateChat(chatId, messages)..ignore();
      earlier.complete(null);

      // Only the newer update writes, and fails (no Supabase in a test). The
      // older one did not write, so its caller must see that failure too
      // rather than a success for messages that were never saved.
      Object? newerError;
      Object? olderError;
      try {
        await newer;
      } catch (e) {
        newerError = e;
      }
      try {
        await older;
      } catch (e) {
        olderError = e;
      }
      expect(newerError, isNotNull);
      expect(olderError, same(newerError));
      expect(ChatStorageState.latestUpdate.containsKey(chatId), isFalse);
    });
  });
}
