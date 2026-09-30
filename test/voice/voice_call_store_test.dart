import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/local_chat_cache_service.dart';
import 'package:chuk_chat/voice/voice_call_models.dart';
import 'package:chuk_chat/voice/voice_call_store.dart';

import '../support/kv_cache_test_env.dart';

VoiceCallRecord _record(String chatId, DateTime start, {String text = 'Hi'}) =>
    VoiceCallRecord(
      chatId: chatId,
      mode: VoiceCallMode.chat,
      startedAt: start,
      endedAt: start.add(const Duration(minutes: 1)),
      turns: <VoiceTurn>[
        VoiceTurn(role: 'user', text: text, at: start, isFinal: true),
      ],
      cards: <VoiceCard>[
        VoiceCard(id: 'c', kind: 'time', title: '12:00', at: start),
      ],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;

  setUp(() async => tempDir = await useTempKvCache());
  tearDown(() async => disposeTempKvCache(tempDir));

  final DateTime t0 = DateTime.utc(2026, 9, 29, 9);

  test('a saved record comes back, oldest first, per chat', () async {
    await VoiceCallStore.save(_record('a', t0.add(const Duration(hours: 1))));
    await VoiceCallStore.save(_record('a', t0, text: 'first'));
    await VoiceCallStore.save(_record('b', t0, text: 'other chat'));

    final List<VoiceCallRecord> a = await VoiceCallStore.forChat('a');
    expect(a, hasLength(2));
    expect(a.first.turns.single.text, 'first');
    expect(a.first.startedAt.isAtSameMomentAs(t0), isTrue);
    expect(a.first.cards.single.title, '12:00');

    final List<VoiceCallRecord> b = await VoiceCallStore.forChat('b');
    expect(b.single.turns.single.text, 'other chat');
    expect(await VoiceCallStore.forChat('none'), isEmpty);
  });

  test('saving the same call twice keeps one copy (the newer)', () async {
    await VoiceCallStore.save(_record('a', t0, text: 'old'));
    await VoiceCallStore.save(_record('a', t0, text: 'new'));
    final List<VoiceCallRecord> a = await VoiceCallStore.forChat('a');
    expect(a.single.turns.single.text, 'new');
  });

  test('concurrent saves do not drop each other', () async {
    await Future.wait(<Future<void>>[
      for (int i = 0; i < 10; i++)
        VoiceCallStore.save(_record('a', t0.add(Duration(minutes: i)))),
    ]);
    expect(await VoiceCallStore.forChat('a'), hasLength(10));
  });

  test('deleteForChat drops only that chat', () async {
    await VoiceCallStore.save(_record('a', t0));
    await VoiceCallStore.save(_record('b', t0));
    await VoiceCallStore.deleteForChat('a');
    expect(await VoiceCallStore.forChat('a'), isEmpty);
    expect(await VoiceCallStore.forChat('b'), hasLength(1));
  });

  test('survives a reopen of the database (an app restart)', () async {
    await VoiceCallStore.save(_record('a', t0));
    // Close the DB handle but keep the file, as a restart would.
    await LocalChatCacheService.debugReset();
    expect(await VoiceCallStore.forChat('a'), hasLength(1));
  });
}
