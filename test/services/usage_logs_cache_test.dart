import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/token_activity_stats.dart';
import 'package:chuk_chat/services/usage_logs_cache.dart';
import 'package:chuk_chat/services/usage_logs_service.dart';

UsageLogEntry _entry(
  DateTime? createdAt, {
  String model = 'm',
  int prompt = 10,
  int? cacheRead,
  double? cacheReadCost,
}) {
  return UsageLogEntry(
    modelId: model,
    providerSlug: 'p',
    promptTokens: prompt,
    completionTokens: 5,
    totalTokens: prompt + 5,
    totalCostUsd: 0.001,
    creditsDeductedEur: 0.002,
    createdAt: createdAt,
    cacheReadTokens: cacheRead,
    cacheReadCostUsd: cacheReadCost,
  );
}

DateTime _t(int minute) => DateTime.utc(2026, 11, 1, 12, minute);

/// [count] synthetic rows, newest first, spread over about a year.
List<UsageLogEntry> _synthetic(int count) {
  final DateTime start = DateTime.utc(2026, 11, 11);
  const List<String> models = <String>[
    'deepseek/deepseek-v4-flash-0731',
    'z-ai/glm-5.3-flash',
    'moonshotai/kimi-k2',
    'openai/gpt-image-1',
  ];
  return <UsageLogEntry>[
    for (int i = 0; i < count; i++)
      UsageLogEntry(
        modelId: models[i % models.length],
        providerSlug: i.isEven ? 'fireworks' : 'orcarouter',
        promptTokens: 1000 + i % 977,
        completionTokens: 200 + i % 311,
        totalTokens: 1200 + i % 977 + i % 311,
        totalCostUsd: 0.000123 * (i % 50),
        creditsDeductedEur: 0.000456 * (i % 50),
        createdAt: start.subtract(Duration(minutes: 33 * i, microseconds: i)),
        cacheReadTokens: i % 3 == 0 ? null : i % 500,
        cacheWriteTokens: i % 5 == 0 ? null : 0,
        cacheReadCostUsd: i % 3 == 0 ? null : 0.00001 * (i % 7),
        cacheWriteCostUsd: null,
        promptCostUsd: 0.0001 * (i % 9),
        completionCostUsd: 0.0002 * (i % 9),
      ),
  ];
}

void main() {
  group('cache key', () {
    test('is per user', () {
      expect(usageLogsCacheKey('a'), isNot(usageLogsCacheKey('b')));
      expect(usageLogsCacheKey('a'), contains('a'));
    });

    test('decode refuses a cache of another user', () {
      final String raw = UsageLogsCacheCodec.encode(
        UsageLogsCacheSnapshot(
          userId: 'alice',
          entries: <UsageLogEntry>[_entry(_t(1))],
          lastFullSyncAt: _t(2),
        ),
      );
      expect(UsageLogsCacheCodec.decode(raw, expectedUserId: 'bob'), isNull);
      expect(
        UsageLogsCacheCodec.decode(raw, expectedUserId: 'alice'),
        isNotNull,
      );
    });
  });

  group('codec', () {
    test('round-trips every field and keeps nulls as null', () {
      final List<UsageLogEntry> entries = <UsageLogEntry>[
        UsageLogEntry(
          modelId: 'model-a',
          providerSlug: 'prov-a',
          promptTokens: 12,
          completionTokens: 34,
          totalTokens: 46,
          totalCostUsd: 0.5,
          creditsDeductedEur: 0.25,
          createdAt: DateTime.utc(2026, 11, 1, 10, 0, 0, 123, 456),
          cacheReadTokens: 0,
          cacheWriteTokens: 7,
          cacheReadCostUsd: 0,
          cacheWriteCostUsd: 0.125,
          promptCostUsd: 0.2,
          completionCostUsd: 0.3,
        ),
        const UsageLogEntry(
          modelId: 'model-b',
          providerSlug: 'prov-b',
          promptTokens: 0,
          completionTokens: 0,
          totalTokens: 9,
          totalCostUsd: 0,
          creditsDeductedEur: 1,
          createdAt: null,
        ),
      ];
      final UsageLogsCacheSnapshot snapshot = UsageLogsCacheSnapshot(
        userId: 'u1',
        entries: entries,
        lastFullSyncAt: DateTime.utc(2026, 11, 10),
        billing: UsageBillingSnapshot(
          totalCreditsAllocated: 20,
          creditsRemaining: null,
          creditsLastRenewedPeriod: DateTime.utc(2026, 11, 1),
        ),
      );

      final UsageLogsCacheSnapshot? back = UsageLogsCacheCodec.decode(
        UsageLogsCacheCodec.encode(snapshot),
      );
      expect(back, isNotNull);
      expect(back!.userId, 'u1');
      expect(back.lastFullSyncAt, DateTime.utc(2026, 11, 10));
      expect(back.billing.totalCreditsAllocated, 20);
      expect(back.billing.creditsRemaining, isNull);
      expect(back.billing.creditsLastRenewedPeriod, DateTime.utc(2026, 11, 1));
      expect(back.entries, hasLength(2));
      for (int i = 0; i < entries.length; i++) {
        expect(
          usageEntrySignature(back.entries[i]),
          usageEntrySignature(entries[i]),
        );
      }

      final UsageLogEntry a = back.entries[0];
      expect(
        a.createdAt!.microsecondsSinceEpoch,
        entries[0].createdAt!.microsecondsSinceEpoch,
      );
      // Known zero stays zero.
      expect(a.cacheReadTokens, 0);
      expect(a.cacheReadCostUsd, 0);
      expect(a.cacheWriteCostUsd, 0.125);
      expect(a.totalCostUsd, isA<double>());

      // Unknown stays unknown, never becomes 0.
      final UsageLogEntry b = back.entries[1];
      expect(b.createdAt, isNull);
      expect(b.cacheReadTokens, isNull);
      expect(b.cacheWriteTokens, isNull);
      expect(b.cacheReadCostUsd, isNull);
      expect(b.cacheWriteCostUsd, isNull);
      expect(b.cachedTokens, isNull);
      expect(b.isMediaRequest, isTrue);
      expect(b.creditsDeductedEur, 1.0);
    });

    test('drops garbage and other versions instead of throwing', () {
      expect(UsageLogsCacheCodec.decode('not json'), isNull);
      expect(UsageLogsCacheCodec.decode('{"v":99,"u":"x"}'), isNull);
      expect(UsageLogsCacheCodec.decode('[]'), isNull);
      expect(UsageLogsCacheCodec.decode('{"v":1,"u":"x","r":[[1]]}'), isNull);
    });
  });

  group('merge and dedupe', () {
    test('incremental rows land on top, boundary rows are not doubled', () {
      final List<UsageLogEntry> cached = <UsageLogEntry>[
        _entry(_t(30)),
        _entry(_t(20)),
        _entry(_t(10)),
      ];
      // The fetch asks for created_at >= (newest - overlap), so the two
      // newest cached rows come back unchanged next to two new rows.
      final List<UsageLogEntry> incoming = <UsageLogEntry>[
        _entry(_t(50)),
        _entry(_t(40)),
        _entry(_t(30)),
        _entry(_t(20)),
      ];
      final List<UsageLogEntry> merged = mergeUsageEntries(cached, incoming);
      expect(merged.map((e) => e.createdAt!.minute).toList(), <int>[
        50,
        40,
        30,
        20,
        10,
      ]);
    });

    test('a late-committed row older than the newest one is kept', () {
      final List<UsageLogEntry> cached = <UsageLogEntry>[
        _entry(_t(30)),
        _entry(_t(10)),
      ];
      final List<UsageLogEntry> merged = mergeUsageEntries(
        cached,
        <UsageLogEntry>[_entry(_t(30)), _entry(_t(25))],
      );
      expect(merged.map((e) => e.createdAt!.minute).toList(), <int>[
        30,
        25,
        10,
      ]);
    });

    test('rows at the same time but with different content both stay', () {
      final List<UsageLogEntry> merged = mergeUsageEntries(
        <UsageLogEntry>[_entry(_t(5), model: 'a')],
        <UsageLogEntry>[_entry(_t(5), model: 'b'), _entry(_t(5), model: 'a')],
      );
      expect(merged.map((e) => e.modelId).toSet(), <String>{'a', 'b'});
      expect(merged, hasLength(2));
    });

    test('no incoming rows returns the cache as is', () {
      final List<UsageLogEntry> cached = <UsageLogEntry>[_entry(_t(1))];
      expect(identical(mergeUsageEntries(cached, const []), cached), isTrue);
    });

    test('dedupe removes page overlap and puts null times last', () {
      final List<UsageLogEntry> out = dedupeUsageEntries(<UsageLogEntry>[
        _entry(null),
        _entry(_t(3)),
        _entry(_t(9)),
        _entry(_t(3)),
      ]);
      expect(out, hasLength(3));
      expect(out[0].createdAt, _t(9));
      expect(out[1].createdAt, _t(3));
      expect(out[2].createdAt, isNull);
    });

    test('newestUsageTimestamp skips rows without a time', () {
      expect(newestUsageTimestamp(<UsageLogEntry>[_entry(null)]), isNull);
      expect(
        newestUsageTimestamp(<UsageLogEntry>[_entry(_t(2)), _entry(_t(7))]),
        _t(7),
      );
    });
  });

  group('buildOverview', () {
    test('cache totals are null when no row reports them', () {
      final UsageOverview o = UsageLogsService.buildOverview(<UsageLogEntry>[
        _entry(_t(1)),
        _entry(_t(2)),
      ], const UsageBillingSnapshot());
      expect(o.totalRequests, 2);
      expect(o.totalPromptTokens, 20);
      expect(o.totalCacheReadTokens, isNull);
      expect(o.creditsUsedThisPeriod, isNull);
    });

    test('isolate path gives the same totals as the inline path', () async {
      final List<UsageLogEntry> entries = _synthetic(5000);
      const UsageBillingSnapshot billing = UsageBillingSnapshot(
        totalCreditsAllocated: 20,
        creditsRemaining: 5,
      );
      final UsageOverview inline = UsageLogsService.buildOverview(
        entries,
        billing,
      );
      // Doubled rows (page overlap) must be removed on the isolate pass.
      final UsageDetails details = await UsageLogsService.buildDetailsAsync(
        <UsageLogEntry>[...entries, ...entries.take(1000)],
        billing,
        dedupe: true,
      );
      final UsageOverview viaIsolate = details.overview;
      expect(details.activity.isEmpty, isFalse);
      expect(viaIsolate.totalRequests, inline.totalRequests);
      expect(viaIsolate.totalTextTokens, inline.totalTextTokens);
      expect(viaIsolate.totalCacheReadTokens, inline.totalCacheReadTokens);
      expect(viaIsolate.totalCreditsEur, closeTo(inline.totalCreditsEur, 1e-9));
      expect(viaIsolate.modelSummaries.length, inline.modelSummaries.length);
      expect(viaIsolate.creditsUsedThisPeriod, 15);
    });
  });

  // CHAT-16: timings at the owner's row count. Printed, not asserted, so a
  // slow CI machine does not fail the suite.
  test('timings at 16k rows', () async {
    final List<UsageLogEntry> entries = _synthetic(16000);
    final UsageLogsCacheSnapshot snapshot = UsageLogsCacheSnapshot(
      userId: 'u',
      entries: entries,
      lastFullSyncAt: DateTime.utc(2026, 11, 11),
    );

    int timeMs(void Function() body, {int runs = 5}) {
      body(); // warm up
      final Stopwatch sw = Stopwatch()..start();
      for (int i = 0; i < runs; i++) {
        body();
      }
      return sw.elapsedMilliseconds ~/ runs;
    }

    late String raw;
    final int encodeMs = timeMs(
      () => raw = UsageLogsCacheCodec.encode(snapshot),
    );
    final int decodeMs = timeMs(() => UsageLogsCacheCodec.decode(raw));
    final int overviewMs = timeMs(
      () =>
          UsageLogsService.buildOverview(entries, const UsageBillingSnapshot()),
    );
    final int statsMs = timeMs(() => TokenActivityStatsService.build(entries));
    final int dedupeMs = timeMs(() => dedupeUsageEntries(entries));

    final Stopwatch sw = Stopwatch()..start();
    await UsageLogsService.buildDetailsAsync(
      entries,
      const UsageBillingSnapshot(),
      dedupe: true,
    );
    final int isolateRoundTripMs = sw.elapsedMilliseconds;

    final List<UsageLogEntry> incoming = <UsageLogEntry>[
      UsageLogEntry(
        modelId: 'new',
        providerSlug: 'p',
        promptTokens: 1,
        completionTokens: 1,
        totalTokens: 2,
        totalCostUsd: 0,
        creditsDeductedEur: 0,
        createdAt: DateTime.utc(2026, 11, 11, 1),
      ),
      ...entries.take(3),
    ];
    final int mergeMs = timeMs(() => mergeUsageEntries(entries, incoming));

    debugPrint(
      'usage 16k: json ${(raw.length / 1024).round()} KiB, '
      'encode ${encodeMs}ms, decode ${decodeMs}ms, '
      'overview ${overviewMs}ms, stats ${statsMs}ms, '
      'dedupe ${dedupeMs}ms, incremental merge ${mergeMs}ms, '
      'dedupe+overview+stats via isolate ${isolateRoundTripMs}ms',
    );
    expect(UsageLogsCacheCodec.decode(raw)!.entries, hasLength(16000));
  });
}
