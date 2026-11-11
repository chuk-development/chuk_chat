// "Auto" prices a whole turn and stays on a provider whose prefix cache still
// holds the chat's prompt (lib/services/provider_cache_affinity.dart,
// ProviderResolutionService.cheapestOf).
//
// Prices are per token, shaped like DeepSeek V4.1 Flash on OpenRouter
// (2026-11-11).

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/models/chat_stream_event.dart';
import 'package:chuk_chat/services/provider_cache_affinity.dart';
import 'package:chuk_chat/services/provider_resolution_service.dart';
import 'package:chuk_chat/widgets/model_selection_dropdown.dart'
    show ModelProviderSummary;

const String _model = 'deepseek/deepseek-v4.1-flash-1017';

ModelProviderSummary _p(
  String slug,
  double prompt,
  double completion, {
  double? cacheRead,
  double? tps,
  double? p95,
}) => ModelProviderSummary(
  slug: slug,
  name: slug,
  promptPrice: prompt,
  completionPrice: completion,
  cacheReadPrice: cacheRead,
  throughput: tps,
  latencyP95Ms: p95,
);

final ModelProviderSummary _sail = _p(
  'sail-research/fp4/us',
  0.101e-6,
  0.15e-6,
  cacheRead: 0.006735e-6,
  tps: 76,
);
final ModelProviderSummary _wafer = _p(
  'wafer/us',
  0.038e-6,
  0.5e-6,
  cacheRead: 0.01e-6,
  tps: 137,
);
final ModelProviderSummary _flex = _p(
  'ionstream/flex',
  0.03e-6,
  0.25e-6,
  cacheRead: 0.003e-6,
  tps: 28,
  p95: 17900,
);

void main() {
  late DateTime clock;
  final ProviderCacheAffinity affinity = ProviderCacheAffinity.instance;

  setUp(() {
    affinity.clearForTesting();
    clock = DateTime.utc(2026, 11, 11, 16);
    affinity.now = () => clock;
  });

  tearDown(affinity.clearForTesting);

  void served(String slug, {int prompt = 45000, String model = _model}) {
    affinity.record(
      chatId: 'chat-1',
      modelId: model,
      providerSlug: slug,
      promptTokens: prompt,
      completionTokens: 1000,
    );
  }

  ModelProviderSummary? pick(List<ModelProviderSummary> providers) =>
      ProviderResolutionService.cheapestOf(
        providers,
        warm: affinity.warmFor('chat-1', _model),
      );

  group('a cold chat', () {
    test('input price counts, not output price alone', () {
      // sail has the lowest output price; wafer is cheaper for a turn with
      // a real prompt.
      expect(pick(<ModelProviderSummary>[_sail, _wafer]), _wafer);
    });

    test('a slow flex tier is skipped while a fast provider is left', () {
      expect(pick(<ModelProviderSummary>[_flex, _sail, _wafer]), _wafer);
    });

    test('a slow provider is still picked when it is the only one', () {
      expect(pick(<ModelProviderSummary>[_flex]), _flex);
    });
  });

  group('a warm chat', () {
    test('stays on the provider that holds its prompt in cache', () {
      served(_sail.slug);
      clock = clock.add(const Duration(minutes: 3));
      expect(pick(<ModelProviderSummary>[_sail, _wafer]), _sail);
    });

    test('moves on once the cache has expired', () {
      served(_sail.slug);
      clock = clock.add(const Duration(minutes: 6));
      expect(pick(<ModelProviderSummary>[_sail, _wafer]), _wafer);
    });

    test('a warm cache does not lock in a dear provider', () {
      final ModelProviderSummary dear = _p(
        'baseten/fast',
        3e-6,
        12e-6,
        cacheRead: 0.3e-6,
        tps: 391,
      );
      served(dear.slug);
      expect(pick(<ModelProviderSummary>[dear, _wafer]), _wafer);
    });

    test('a record for another model is ignored', () {
      served(_sail.slug, model: 'z-ai/glm-5.3-flash');
      expect(pick(<ModelProviderSummary>[_sail, _wafer]), _wafer);
    });

    test('no cache-read price means no cache saving', () {
      final ModelProviderSummary noCache = _p('nocache', 0.101e-6, 0.15e-6);
      served(noCache.slug);
      expect(pick(<ModelProviderSummary>[noCache, _wafer]), _wafer);
    });
  });

  group('cache TTL', () {
    test('measured and documented families, default for the rest', () {
      expect(
        ProviderCacheAffinity.cacheTtlFor('fireworks/us'),
        const Duration(minutes: 5),
      );
      expect(
        ProviderCacheAffinity.cacheTtlFor('deepinfra/fp8/flex'),
        const Duration(minutes: 15),
      );
      expect(
        ProviderCacheAffinity.cacheTtlFor('something-new'),
        ProviderCacheAffinity.defaultCacheTtl,
      );
    });

    test('a longer TTL keeps the chat warm longer', () {
      final ModelProviderSummary deepinfra = _p(
        'deepinfra/fp8',
        0.098e-6,
        0.294e-6,
        cacheRead: 0.00294e-6,
        tps: 81,
      );
      served(deepinfra.slug);
      clock = clock.add(const Duration(minutes: 12));
      expect(pick(<ModelProviderSummary>[deepinfra, _wafer]), deepinfra);
    });
  });

  group('the provider Auto runs on now', () {
    test('is known from the meta frame, before the answer is done', () async {
      int changes = 0;
      void listener() => changes++;
      affinity.addListener(listener);
      addTearDown(() => affinity.removeListener(listener));
      final controller = StreamController<ChatStreamEvent>();
      final Future<void> drained = affinity
          .observe(
            controller.stream,
            chatId: 'chat-1',
            modelId: _model,
            requestedProviderSlug: 'wafer/us',
          )
          .drain<void>();
      controller.add(
        const ChatStreamEvent.meta(<String, dynamic>{
          'provider': <String, dynamic>{'slug': 'wafer/us'},
        }),
      );
      await Future<void>.delayed(Duration.zero);
      expect(affinity.currentProviderFor(_model), 'wafer/us');
      expect(changes, 1);
      await controller.close();
      await drained;
    });

    test('expires with the provider cache', () {
      served(_sail.slug);
      expect(affinity.currentProviderFor(_model), _sail.slug);
      clock = clock.add(const Duration(minutes: 6));
      expect(affinity.currentProviderFor(_model), isNull);
    });
  });

  group('observe', () {
    Future<void> run(List<ChatStreamEvent> events, {String? chatId}) => affinity
        .observe(
          Stream<ChatStreamEvent>.fromIterable(events),
          chatId: chatId ?? 'chat-1',
          modelId: _model,
          requestedProviderSlug: 'wafer/us',
        )
        .drain<void>();

    test('records the provider that served, after a failover too', () async {
      await run(<ChatStreamEvent>[
        const ChatStreamEvent.meta(<String, dynamic>{
          'provider': <String, dynamic>{'slug': 'wafer/us'},
        }),
        const ChatStreamEvent.meta(<String, dynamic>{
          'provider': <String, dynamic>{'slug': 'sail-research/fp4/us'},
        }),
        const ChatStreamEvent.content('hi'),
        const ChatStreamEvent.usage(<String, dynamic>{
          'prompt_tokens': 45000,
          'completion_tokens': 900,
        }),
        const ChatStreamEvent.done(),
      ]);
      final ProviderAffinity? warm = affinity.warmFor('chat-1', _model);
      expect(warm?.providerSlug, 'sail-research/fp4/us');
      expect(warm?.promptTokens, 45000);
      expect(warm?.completionTokens, 900);
    });

    test('a request that never finished records nothing', () async {
      await run(<ChatStreamEvent>[
        const ChatStreamEvent.usage(<String, dynamic>{'prompt_tokens': 45000}),
        const ChatStreamEvent.error('Response timed out'),
      ]);
      expect(affinity.warmFor('chat-1', _model), isNull);
    });

    test('events pass through unchanged', () async {
      final List<ChatStreamEvent> out = await affinity
          .observe(
            Stream<ChatStreamEvent>.fromIterable(<ChatStreamEvent>[
              const ChatStreamEvent.content('a'),
              const ChatStreamEvent.done(),
            ]),
            chatId: 'chat-1',
            modelId: _model,
          )
          .toList();
      expect(out, hasLength(2));
      expect(out.first, isA<ContentEvent>());
    });
  });
}
