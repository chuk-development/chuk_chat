import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/models/chat_message.dart';
import 'package:chuk_chat/models/stored_chat.dart';
import 'package:chuk_chat/platform_specific/chat/voice/chat_voice_binding.dart'
    show voiceTurnMessageId;
import 'package:chuk_chat/voice/voice_call_models.dart';
import 'package:chuk_chat/voice/voice_call_store.dart';
import 'package:chuk_chat/voice/voice_transcript_migration.dart';

import '../support/kv_cache_test_env.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;
  late StoredChat? chat;
  late Object? owner;
  late VoiceTranscriptMigration migration;
  late VoiceCallRecord record;
  int writes = 0;
  final at = DateTime.utc(2026, 9, 29);

  setUp(() async {
    tempDir = await useTempKvCache();
    owner = Object();
    writes = 0;
    chat = StoredChat(
      id: 'chat',
      createdAt: at,
      isStarred: false,
      messages: [ChatMessage(role: 'user', text: 'typed')],
    );
    record = VoiceCallRecord(
      chatId: 'chat',
      mode: VoiceCallMode.chat,
      startedAt: at,
      endedAt: at.add(const Duration(minutes: 1)),
      turns: [
        VoiceTurn(role: 'user', text: 'spoken', at: at, isFinal: true),
        VoiceTurn(
          role: 'assistant',
          text: 'cut off',
          at: at.add(const Duration(seconds: 1)),
          isFinal: false,
        ),
      ],
      cards: [
        VoiceCard(
          id: 'card',
          kind: 'weather',
          title: 'Weather',
          at: at,
          data: {'temperature': 20},
        ),
      ],
    );
    migration = VoiceTranscriptMigration(
      getChat: (_) => chat,
      ownership: () => owner,
      updateChat: (_, rows) async {
        writes++;
        chat = chat!.copyWith(
          messages: rows.map(ChatMessage.fromJson).toList(),
        );
        return chat;
      },
    );
    await VoiceCallStore.save(record);
  });
  tearDown(() async => disposeTempKvCache(tempDir));

  test(
    'repeated and concurrent migration is idempotent; cards survive',
    () async {
      final results = await Future.wait([
        migration.migrate('chat'),
        migration.migrate('chat'),
      ]);
      expect(results.every((result) => result != null), isTrue);
      expect(writes, 1);
      expect(chat!.messages.map((m) => m.text), ['typed', 'spoken', 'cut off']);
      expect(
        chat!.messages[1].messageId,
        voiceTurnMessageId(record.turns.first),
      );
      final kept = await VoiceCallStore.forChat('chat');
      expect(kept.single.turns, isEmpty);
      expect(kept.single.cards.single.toJson(), record.cards.single.toJson());
      expect(await migration.migrate('chat'), isNull);
      expect(writes, 1);
      // Simulate interruption after save but before source cleanup.
      await VoiceCallStore.save(record);
      await migration.migrate('chat');
      expect(chat!.messages, hasLength(3));
    },
  );

  test(
    'preserves every typed message field and existing ordinary voice row',
    () async {
      final typed = ChatMessage(
        role: 'user',
        text: 'with metadata',
        reasoning: 'reasoning',
        replyContext: '{"text":"reply"}',
        images: '["image"]',
        imageMetas: '[{"source":"fetched"}]',
        imageCostEur: '0.1',
        imageGeneratedAt: 'yesterday',
        attachments: '[{"name":"file"}]',
        attachedFilesJson: '[{"id":"file"}]',
        toolCalls: '[]',
        contentBlocks: '[]',
        modelId: 'model',
        provider: 'provider',
        status: ChatMessageStatus.pending,
        queueId: 'queue',
        messageId: 'typed',
        sentAt: at.toIso8601String(),
        startedAt: at.toIso8601String(),
        generationMs: '100',
        variants: '["variant"]',
        activeVariant: 0,
      );
      final ordinaryVoice = ChatMessage(
        role: 'user',
        text: 'corrected ordinary row',
        messageId: voiceTurnMessageId(record.turns.first),
        images: '["kept"]',
      );
      chat = chat!.copyWith(messages: [typed, ordinaryVoice]);
      await migration.migrate('chat');
      expect(chat!.messages.first.toJson(), typed.toJson());
      expect(chat!.messages[1].toJson(), ordinaryVoice.toJson());
      expect(chat!.messages, hasLength(3));
    },
  );

  test(
    'failed/null/superseding save leaves legacy transcript for retry',
    () async {
      for (final outcome in ['throw', 'null', 'superseded']) {
        final failing = VoiceTranscriptMigration(
          getChat: (_) => chat,
          ownership: () => owner,
          updateChat: (_, _) async {
            if (outcome == 'throw') throw StateError('offline');
            return outcome == 'null' ? null : chat;
          },
        );
        expect(await failing.migrate('chat'), isNull);
        expect(
          (await VoiceCallStore.forChat('chat')).single.turns
              .map((t) => t.toJson()),
          record.turns.map((t) => t.toJson()),
        );
      }
      expect(await migration.migrate('chat'), isNotNull);
    },
  );

  test('locked key, missing, unloaded or locked chats never write', () async {
    owner = null;
    expect(await migration.migrate('chat'), isNull);
    owner = Object();
    final original = chat;
    chat = null;
    expect(await migration.migrate('chat'), isNull);
    chat = StoredChat.forSidebar(id: 'chat', createdAt: at, isStarred: false);
    expect(await migration.migrate('chat'), isNull);
    chat = original!.copyWith(isLocked: true);
    expect(await migration.migrate('chat'), isNull);
    expect(writes, 0);
    expect(
      (await VoiceCallStore.forChat('chat')).single.turns
          .map((t) => t.toJson()),
      record.turns.map((t) => t.toJson()),
    );
  });

  test(
    'account/key change during save retains source and suppresses reload',
    () async {
      final started = Completer<void>();
      final finish = Completer<void>();
      final delayed = VoiceTranscriptMigration(
        getChat: (_) => chat,
        ownership: () => owner,
        updateChat: (_, rows) async {
          started.complete();
          await finish.future;
          return chat!.copyWith(
            messages: rows.map(ChatMessage.fromJson).toList(),
          );
        },
      );
      final result = delayed.migrate('chat');
      await started.future;
      owner = Object();
      finish.complete();
      expect(await result, isNull);
      expect(
        (await VoiceCallStore.forChat('chat')).single.turns
            .map((t) => t.toJson()),
        record.turns.map((t) => t.toJson()),
      );
    },
  );

  test(
    'cleanup preserves a concurrently corrected turn and all cards',
    () async {
      final corrected = VoiceCallRecord(
        chatId: record.chatId,
        mode: record.mode,
        startedAt: record.startedAt,
        endedAt: record.endedAt,
        turns: [
          record.turns.first.copyWith(text: 'corrected'),
          record.turns.last,
        ],
        cards: record.cards,
      );
      await VoiceCallStore.save(corrected);
      await VoiceCallStore.removeMigratedTurns('chat', [
        record,
      ], stillOwned: () => true);
      final kept = (await VoiceCallStore.forChat('chat')).single;
      expect(kept.turns.single.text, 'corrected');
      expect(kept.cards.single.toJson(), record.cards.single.toJson());
    },
  );
  test('a newer local chat revision keeps the migration source', () async {
    final newer = VoiceTranscriptMigration(
      getChat: (_) => chat,
      ownership: () => owner,
      updateChat: (_, rows) async {
        final saved = chat!.copyWith(
          messages: rows.map(ChatMessage.fromJson).toList(),
        );
        chat = chat!.copyWith(
          messages: [
            ...chat!.messages,
            ChatMessage(role: 'user', text: 'typed during network save'),
          ],
        );
        return saved;
      },
    );
    expect(await newer.migrate('chat'), isNotNull);
    expect((await VoiceCallStore.forChat('chat')).single.turns, hasLength(2));
    await migration.migrate('chat');
    expect(chat!.messages.map((m) => m.text), [
      'typed',
      'typed during network save',
      'spoken',
      'cut off',
    ]);
    expect((await VoiceCallStore.forChat('chat')).single.turns, isEmpty);
  });

  test('transcript-only records are removed after a verified save', () async {
    await VoiceCallStore.deleteForChat('chat');
    await VoiceCallStore.save(
      VoiceCallRecord(
        chatId: 'chat',
        mode: record.mode,
        startedAt: record.startedAt,
        endedAt: record.endedAt,
        turns: record.turns,
      ),
    );
    await migration.migrate('chat');
    expect(await VoiceCallStore.forChat('chat'), isEmpty);
    expect(chat!.messages, hasLength(3));
  });
}
