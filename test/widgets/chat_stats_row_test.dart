import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/chat_turn_stats.dart';
import 'package:chuk_chat/services/prompt_cache_lifetime.dart';
import 'package:chuk_chat/services/provider_cache_affinity.dart';
import 'package:chuk_chat/widgets/chat_stats_row.dart';

Widget _host(Widget child, {double width = 600}) => MaterialApp(
  home: Scaffold(
    body: Center(
      child: SizedBox(width: width, child: child),
    ),
  ),
);

void main() {
  final ChatTurnStats stats = ChatTurnStats.instance;
  setUp(stats.debugReset);

  testWidgets('shows tok/s, cache hit and context share', (tester) async {
    stats.recordTps('c', 31.24);
    stats.recordUsage('c', <String, dynamic>{
      'prompt_tokens': 9000,
      'completion_tokens': 1000,
      'prompt_tokens_details': <String, dynamic>{'cached_tokens': 4500},
    });
    await tester.pumpWidget(
      _host(
        const ChatStatsRow(
          chatId: 'c',
          modelId: 'm',
          contextLimitOverride: 100000,
        ),
      ),
    );
    expect(find.text('31.2 tok/s'), findsOneWidget);
    expect(find.text('Cache hit 50%'), findsOneWidget);
    expect(find.text('10%'), findsOneWidget);
    final Tooltip tip = tester.widget<Tooltip>(
      find.byKey(const ValueKey<String>('chat-stats-context')),
    );
    expect(tip.message, contains('10.0k'));
    expect(tip.message, contains('100k'));
    expect(tip.message, contains('Cached: 4.5k'));
    expect(
      tester.getSize(find.byType(ChatStatsRow)).height,
      kChatStatsRowHeight,
    );
  });

  testWidgets('unknown cache and limit read as a dash', (tester) async {
    stats.recordUsage('c', <String, dynamic>{'prompt_tokens': 10});
    await tester.pumpWidget(
      _host(const ChatStatsRow(chatId: 'c', modelId: '')),
    );
    expect(find.text('— tok/s'), findsOneWidget);
    expect(find.text('Cache hit —'), findsOneWidget);
    expect(find.text('—'), findsOneWidget);
  });

  testWidgets('keeps its height empty when nothing is known', (tester) async {
    await tester.pumpWidget(
      _host(const ChatStatsRow(chatId: 'none', modelId: 'm')),
    );
    expect(find.byKey(const ValueKey<String>('chat-stats-tps')), findsNothing);
    expect(
      tester.getSize(find.byType(ChatStatsRow)).height,
      kChatStatsRowHeight,
    );
  });

  testWidgets('hidden on narrow screens', (tester) async {
    stats.recordTps('c', 10);
    await tester.pumpWidget(
      _host(const ChatStatsRow(chatId: 'c', modelId: 'm'), width: 320),
    );
    expect(find.byKey(const ValueKey<String>('chat-stats-tps')), findsNothing);
    expect(tester.getSize(find.byType(ChatStatsRow)).height, 0);
  });

  group('cache countdown', () {
    final ProviderCacheAffinity affinity = ProviderCacheAffinity.instance;
    late DateTime clock;
    const String chatId = '6f1c2a5e-0d7b-4c3a-9a51-3e2f8b7d1c40';
    const String model = 'deepseek/deepseek-v4.1-flash-1017';

    setUp(() {
      affinity.clearForTesting();
      clock = DateTime(2026, 11, 19, 12);
      affinity.now = () => clock;
      stats.recordUsage(chatId, <String, dynamic>{
        'prompt_tokens': 9000,
        'completion_tokens': 100,
        'prompt_tokens_details': <String, dynamic>{'cached_tokens': 8000},
      });
    });
    tearDown(affinity.clearForTesting);

    void serve(String provider, {String modelId = model}) => affinity.record(
      chatId: chatId,
      modelId: modelId,
      providerSlug: provider,
      promptTokens: 9000,
      completionTokens: 100,
    );

    Future<void> pumpRow(WidgetTester tester, {String? pinned}) =>
        tester.pumpWidget(
          _host(
            ChatStatsRow(
              chatId: chatId,
              modelId: model,
              providerSlug: pinned,
              contextLimitOverride: 100000,
            ),
          ),
        );

    const Key ttlKey = ValueKey<String>('chat-stats-cache-ttl');

    testWidgets('an exact lifetime counts down in seconds', (tester) async {
      serve('groq');
      clock = clock.add(const Duration(minutes: 115, seconds: 30));
      await pumpRow(tester);
      expect(find.text('Cache 4:30 left'), findsOneWidget);
      final Tooltip tip = tester.widget<Tooltip>(find.byKey(ttlKey));
      expect(tip.message, contains('Groq'));
      expect(tip.message, contains('2 h'));

      clock = clock.add(const Duration(minutes: 5));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Cache expired'), findsOneWidget);
    });

    testWidgets('a measured lifetime shows rounded minutes', (tester) async {
      serve('fireworks/fp8');
      clock = clock.add(const Duration(minutes: 2, seconds: 10));
      await pumpRow(tester);
      expect(find.text('Cache ~3 min left'), findsOneWidget);
      final Tooltip tip = tester.widget<Tooltip>(find.byKey(ttlKey));
      expect(tip.message, contains('about 5 min'));

      clock = clock.add(const Duration(minutes: 3));
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Cache likely expired'), findsOneWidget);
    });

    testWidgets('no countdown for a provider with no known lifetime', (
      tester,
    ) async {
      serve('novita');
      await pumpRow(tester);
      expect(find.byKey(ttlKey), findsNothing);
      expect(find.text('Cache hit 89%'), findsOneWidget);
    });

    testWidgets('no countdown when the chat was not served here', (
      tester,
    ) async {
      await pumpRow(tester);
      expect(find.byKey(ttlKey), findsNothing);
    });

    testWidgets('no countdown after a switch of model or pinned provider', (
      tester,
    ) async {
      serve('groq', modelId: 'other/model');
      await pumpRow(tester);
      expect(find.byKey(ttlKey), findsNothing);

      serve('groq');
      await pumpRow(tester, pinned: 'fireworks');
      expect(find.byKey(ttlKey), findsNothing);
      await pumpRow(tester, pinned: 'groq');
      expect(find.byKey(ttlKey), findsOneWidget);
    });
  });

  group('promptCacheLifetimeFor', () {
    test('Anthropic is 1 h for Claude, unknown otherwise', () {
      final lifetime = promptCacheLifetimeFor(
        'anthropic/claude-x',
        'anthropic',
      );
      expect(lifetime?.duration, const Duration(hours: 1));
      expect(lifetime?.isExact, isTrue);
      expect(promptCacheLifetimeFor('other/m', 'anthropic'), isNull);
    });

    test('Alibaba is exact only for Qwen', () {
      expect(
        promptCacheLifetimeFor('qwen/qwen3', 'alibaba')?.duration,
        const Duration(minutes: 5),
      );
      expect(promptCacheLifetimeFor('other/m', 'alibaba'), isNull);
    });

    test('family is read before the slash', () {
      expect(
        promptCacheLifetimeFor('m', 'DeepInfra/fp8')?.duration,
        const Duration(minutes: 30),
      );
      expect(promptCacheLifetimeFor('m', 'baseten'), isNull);
    });
  });

  test('formatCacheRemaining and formatCacheTtl', () {
    expect(formatCacheRemaining(const Duration(seconds: 272)), '4:32');
    expect(formatCacheRemaining(const Duration(seconds: -3)), '0:00');
    expect(formatCacheRemaining(const Duration(minutes: 25)), '25 min');
    expect(formatCacheRemaining(const Duration(minutes: 80)), '1 h 20 min');
    expect(formatCacheTtl(const Duration(hours: 2)), '2 h');
    expect(formatCacheTtl(const Duration(seconds: 20), roundUp: true), '1 min');
    expect(formatCacheTtl(const Duration(seconds: 61), roundUp: true), '2 min');
  });

  test('formatTokenCount', () {
    expect(formatTokenCount(950), '950');
    expect(formatTokenCount(12345), '12.3k');
    expect(formatTokenCount(128000), '128k');
    expect(formatTokenCount(1000000), '1.0M');
  });
}
