import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chuk_chat/services/local_chat_cache_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/services/token_activity_stats.dart';
import 'package:chuk_chat/services/usage_logs_cache.dart';

export 'package:chuk_chat/services/usage_logs_cache.dart'
    show UsageBillingSnapshot;

class UsageLogEntry {
  const UsageLogEntry({
    required this.modelId,
    required this.providerSlug,
    required this.promptTokens,
    required this.completionTokens,
    required this.totalTokens,
    required this.totalCostUsd,
    required this.creditsDeductedEur,
    required this.createdAt,
    this.cacheReadTokens,
    this.cacheWriteTokens,
    this.cacheReadCostUsd,
    this.cacheWriteCostUsd,
    this.promptCostUsd = 0,
    this.completionCostUsd = 0,
  });

  final String modelId;
  final String providerSlug;
  final int promptTokens;
  final int completionTokens;
  final int totalTokens;
  final double totalCostUsd;
  final double creditsDeductedEur;
  final DateTime? createdAt;

  /// Cache read / write counts and costs. Null when the provider did not
  /// report them: unknown is not the same as 0 and is shown as "—".
  final int? cacheReadTokens;
  final int? cacheWriteTokens;
  final double? cacheReadCostUsd;
  final double? cacheWriteCostUsd;
  final double promptCostUsd;
  final double completionCostUsd;

  int get textTokens => promptTokens + completionTokens;

  /// Read + write, null when neither is known.
  int? get cachedTokens => sumKnownInts([cacheReadTokens, cacheWriteTokens]);

  bool get isMediaRequest =>
      promptTokens == 0 && completionTokens == 0 && totalTokens > 0;

  factory UsageLogEntry.fromMap(Map<String, dynamic> row) {
    final int promptTokens = _parseInt(row['prompt_tokens']);
    final int completionTokens = _parseInt(row['completion_tokens']);
    final int parsedTotalTokens = _parseInt(row['total_tokens']);
    final int totalTokens = parsedTotalTokens > 0
        ? parsedTotalTokens
        : promptTokens + completionTokens;

    return UsageLogEntry(
      modelId: (row['model_id'] as String?) ?? 'unknown-model',
      providerSlug: (row['provider_slug'] as String?) ?? 'unknown-provider',
      promptTokens: promptTokens,
      completionTokens: completionTokens,
      totalTokens: totalTokens,
      totalCostUsd: _parseDouble(row['total_cost_usd']),
      creditsDeductedEur: _parseDouble(row['credits_deducted_eur']),
      createdAt: _parseDateTime(row['created_at']),
      cacheReadTokens: _parseNullableInt(row['cache_read_tokens']),
      cacheWriteTokens: _parseNullableInt(row['cache_write_tokens']),
      cacheReadCostUsd: _parseNullableDouble(row['cache_read_cost_usd']),
      cacheWriteCostUsd: _parseNullableDouble(row['cache_write_cost_usd']),
      promptCostUsd: _parseDouble(row['prompt_cost_usd']),
      completionCostUsd: _parseDouble(row['completion_cost_usd']),
    );
  }
}

class UsageModelSummary {
  const UsageModelSummary({
    required this.modelId,
    required this.primaryProvider,
    required this.requestCount,
    required this.textTokens,
    required this.mediaRequestCount,
    required this.totalCostUsd,
    required this.totalCreditsEur,
    this.totalPromptCostUsd = 0,
    this.totalCompletionCostUsd = 0,
  });

  final String modelId;
  final String primaryProvider;
  final int requestCount;
  final int textTokens;
  final int mediaRequestCount;
  final double totalCostUsd;
  final double totalCreditsEur;
  final double totalPromptCostUsd;
  final double totalCompletionCostUsd;
}

class UsageOverview {
  const UsageOverview({
    required this.entries,
    required this.modelSummaries,
    required this.totalRequests,
    required this.totalPromptTokens,
    required this.totalCompletionTokens,
    required this.totalTextTokens,
    required this.totalMediaRequests,
    required this.totalCostUsd,
    required this.totalCreditsEur,
    required this.totalCreditsAllocated,
    required this.creditsRemaining,
    required this.creditsLastRenewedPeriod,
    this.totalCacheReadTokens,
    this.totalCacheWriteTokens,
    this.totalCacheReadCostUsd,
    this.totalCacheWriteCostUsd,
    this.totalPromptCostUsd = 0,
    this.totalCompletionCostUsd = 0,
  });

  final List<UsageLogEntry> entries;
  final List<UsageModelSummary> modelSummaries;

  final int totalRequests;
  final int totalPromptTokens;
  final int totalCompletionTokens;
  final int totalTextTokens;
  final int totalMediaRequests;
  final double totalCostUsd;
  final double totalCreditsEur;

  /// Sums over the entries that report the value; null when none does.
  final int? totalCacheReadTokens;
  final int? totalCacheWriteTokens;
  final double? totalCacheReadCostUsd;
  final double? totalCacheWriteCostUsd;

  final double totalPromptCostUsd;
  final double totalCompletionCostUsd;

  final double? totalCreditsAllocated;
  final double? creditsRemaining;
  final DateTime? creditsLastRenewedPeriod;

  double? get creditsUsedThisPeriod {
    final double? allocated = totalCreditsAllocated;
    final double? remaining = creditsRemaining;
    if (allocated == null || remaining == null) {
      return null;
    }
    return (allocated - remaining).clamp(0.0, allocated).toDouble();
  }
}

class UsageLogsService {
  const UsageLogsService._();

  /// Rows per request. Supabase caps a response at 1000 rows by default
  /// (`max_rows`); a lower server cap is detected from the first page.
  static const int _kPageSize = 1000;

  /// Range requests in flight at once on a first load without a cache.
  static const int _kMaxConcurrentPages = 8;

  /// A cache older than this is refetched in full, in the background, while
  /// the page already shows it. Rows are append-only in practice, so the
  /// incremental path is right almost always; the full pass only catches
  /// rare edits or deletes on the server (refunds, account clean-up).
  /// Pull-to-refresh also forces a full pass.
  static const Duration fullResyncInterval = Duration(days: 7);

  /// The incremental fetch starts this far before the newest cached row.
  /// `created_at` is set when a transaction starts, so a row can become
  /// visible after a newer one; the overlap catches it, and the duplicate
  /// boundary rows are removed by signature.
  static const Duration _kIncrementalOverlap = Duration(minutes: 10);

  /// Above this many rows the totals are built on a background isolate;
  /// below it the isolate start costs more than it saves. The cache string
  /// threshold is the same row count at about 100 characters per row.
  /// Timings: `test/services/usage_logs_cache_test.dart`.
  static const int _kIsolateThreshold = 2000;
  static const int _kIsolateThresholdChars = _kIsolateThreshold * 100;

  static const String _kColumns =
      'model_id,provider_slug,prompt_tokens,completion_tokens,total_tokens,total_cost_usd,credits_deducted_eur,created_at,cache_read_tokens,cache_write_tokens,cache_read_cost_usd,cache_write_cost_usd,prompt_cost_usd,completion_cost_usd';

  /// Per-user copy of the last refresh in this process. Keyed by user id, so
  /// it never serves another account's rows.
  static final Map<String, UsageLogsCacheSnapshot> _memory =
      <String, UsageLogsCacheSnapshot>{};

  /// The last built details per user, so a second open in the same session
  /// (or an open after [prefetch]) shows them with no work at all.
  static final Map<String, UsageDetails> _lastDetails =
      <String, UsageDetails>{};
  static final Map<String, Future<UsageDetails>> _inFlight =
      <String, Future<UsageDetails>>{};
  static Future<void> _writeTail = Future<void>.value();

  /// The details built from the local cache only (no network), or null when
  /// there is no cache for the signed-in user. The page shows this on open
  /// and then calls [loadDetails] to refresh. Decoding and the totals run on
  /// a background isolate.
  static Future<UsageDetails?> loadCachedDetails() async {
    final String? userId = _currentUserId();
    if (userId == null) return null;
    final UsageDetails? last = _lastDetails[userId];
    if (last != null) return last;
    if (kIsWeb) return null;
    try {
      final String? raw = await LocalChatCacheService.kvGet(
        usageLogsCacheKey(userId),
      );
      if (raw == null || raw.isEmpty) return null;
      final _Decoded? decoded = raw.length > _kIsolateThresholdChars
          ? await compute(_decodeAndBuild, (raw, userId))
          : _decodeAndBuild((raw, userId));
      if (decoded == null) return null;
      // A refresh may have finished while the cache was being read.
      _memory.putIfAbsent(userId, () => decoded.snapshot);
      _lastDetails.putIfAbsent(userId, () => decoded.details);
      return decoded.details;
    } catch (error) {
      if (kDebugMode) {
        debugPrint(
          'UsageLogsService: cache read failed (${error.runtimeType})',
        );
      }
      return null;
    }
  }

  /// [loadCachedDetails] without the activity panel.
  static Future<UsageOverview?> loadCachedOverview() async =>
      (await loadCachedDetails())?.overview;

  /// Fetches the usage rows and billing figures.
  ///
  /// With a cache: only rows from the newest cached row on are fetched
  /// (normally one small request). Without one, or when [forceFullSync] is
  /// set, or the last full pass is older than [fullResyncInterval]: every
  /// row, in parallel range requests. The result is written back to the
  /// cache. Calls for the same user while one is running share its result.
  static Future<UsageDetails> loadDetails({bool forceFullSync = false}) {
    final String? userId = _currentUserId();
    if (userId == null) {
      return Future<UsageDetails>.error(
        const UsageLogsServiceException('User is not signed in.'),
      );
    }
    final Future<UsageDetails>? running = _inFlight[userId];
    if (running != null) {
      if (!forceFullSync) return running;
      return running
          .then<void>((_) {}, onError: (_) {})
          .then((_) => loadDetails(forceFullSync: true));
    }
    final Future<UsageDetails> future = _refresh(userId, forceFullSync);
    _inFlight[userId] = future;
    future.then<void>((_) {}, onError: (_) {}).whenComplete(() {
      if (identical(_inFlight[userId], future)) _inFlight.remove(userId);
    });
    return future;
  }

  /// [loadDetails] without the activity panel.
  static Future<UsageOverview> loadOverview({
    bool forceFullSync = false,
  }) async => (await loadDetails(forceFullSync: forceFullSync)).overview;

  /// Starts a background refresh so the usage page opens warm. Errors are
  /// dropped here; the page shows them when it loads.
  static void prefetch() {
    if (_currentUserId() == null) return;
    unawaited(loadDetails().then<void>((_) {}, onError: (_) {}));
  }

  /// The signed-in user's id; null when signed out or when Supabase is not
  /// set up (tests, a build without credentials).
  static String? _currentUserId() {
    if (!SupabaseService.isInitialized) return null;
    return SupabaseService.auth.currentUser?.id;
  }

  static Future<UsageDetails> _refresh(String userId, bool forceFull) async {
    try {
      final Future<UsageBillingSnapshot> billingFuture = _loadBillingSnapshot(
        userId,
      );
      final UsageLogsCacheSnapshot? cached = forceFull
          ? null
          : await _readSnapshot(userId);
      final DateTime now = DateTime.now().toUtc();
      final DateTime? newest = cached == null
          ? null
          : newestUsageTimestamp(cached.entries);

      final bool incremental =
          cached != null &&
          newest != null &&
          !cached.lastFullSyncAt.isAfter(now) &&
          now.difference(cached.lastFullSyncAt) < fullResyncInterval;

      final List<UsageLogEntry> rows;
      final DateTime lastFullSyncAt;
      if (incremental) {
        final List<UsageLogEntry> incoming = await _fetchSince(
          userId,
          newest.subtract(_kIncrementalOverlap),
        );
        rows = mergeUsageEntries(cached.entries, incoming);
        lastFullSyncAt = cached.lastFullSyncAt;
      } else {
        rows = await _fetchAll(userId);
        lastFullSyncAt = now;
      }

      final UsageBillingSnapshot billing = await billingFuture;
      // A full fetch still has the page overlap in it; the dedupe runs in
      // the same background pass as the totals.
      final UsageDetails details = await buildDetailsAsync(
        rows,
        billing,
        dedupe: !incremental,
      );
      final UsageLogsCacheSnapshot snapshot = UsageLogsCacheSnapshot(
        userId: userId,
        entries: details.overview.entries,
        lastFullSyncAt: lastFullSyncAt,
        billing: billing,
      );
      _memory[userId] = snapshot;
      _lastDetails[userId] = details;
      _scheduleWrite(snapshot);
      return details;
    } on PostgrestException catch (error) {
      throw UsageLogsServiceException(error.message);
    } on UsageLogsServiceException {
      rethrow;
    } catch (error) {
      throw UsageLogsServiceException('Failed to load usage details: $error');
    }
  }

  static Future<UsageLogsCacheSnapshot?> _readSnapshot(String userId) async {
    final UsageLogsCacheSnapshot? memory = _memory[userId];
    if (memory != null || kIsWeb) return memory;
    try {
      final String? raw = await LocalChatCacheService.kvGet(
        usageLogsCacheKey(userId),
      );
      if (raw == null || raw.isEmpty) return null;
      return raw.length > _kIsolateThresholdChars
          ? await compute(_decodeOnly, (raw, userId))
          : _decodeOnly((raw, userId));
    } catch (_) {
      return null;
    }
  }

  /// Writes are chained so an older snapshot can never land after a newer
  /// one. Web keeps only the in-memory copy: there the KV store is
  /// SharedPreferences, which must not hold megabytes.
  static void _scheduleWrite(UsageLogsCacheSnapshot snapshot) {
    if (kIsWeb) return;
    _writeTail = _writeTail.then((_) async {
      try {
        final String raw = snapshot.entries.length > _kIsolateThreshold
            ? await compute(UsageLogsCacheCodec.encode, snapshot)
            : UsageLogsCacheCodec.encode(snapshot);
        await LocalChatCacheService.kvSet(
          usageLogsCacheKey(snapshot.userId),
          raw,
        );
      } catch (error) {
        if (kDebugMode) {
          debugPrint(
            'UsageLogsService: cache write failed (${error.runtimeType})',
          );
        }
      }
    });
  }

  static PostgrestFilterBuilder<PostgrestList> _baseQuery(String userId) =>
      SupabaseService.client
          .from('usage_logs')
          .select(_kColumns)
          .eq('user_id', userId);

  static List<UsageLogEntry> _parseRows(Object? data) => (data as List)
      .cast<Map<String, dynamic>>()
      .map(UsageLogEntry.fromMap)
      .toList();

  /// Rows with `created_at >= since`, newest first. Normally one request.
  static Future<List<UsageLogEntry>> _fetchSince(
    String userId,
    DateTime since,
  ) async {
    final List<UsageLogEntry> out = <UsageLogEntry>[];
    int start = 0;
    while (true) {
      final PostgrestList rows = await _baseQuery(userId)
          .gte('created_at', since.toUtc().toIso8601String())
          .order('created_at', ascending: false)
          .range(start, start + _kPageSize - 1);
      out.addAll(_parseRows(rows));
      if (rows.length < _kPageSize || rows.isEmpty) break;
      start += rows.length;
    }
    return out;
  }

  /// Every row of the user, newest first, possibly with a repeated row
  /// where two pages overlapped.
  ///
  /// The first page also asks for the exact row count; the remaining pages
  /// then run [_kMaxConcurrentPages] at a time instead of one after another.
  /// 15.8k rows: 1 + 2 rounds of requests instead of 32.
  static Future<List<UsageLogEntry>> _fetchAll(String userId) async {
    final PostgrestResponse<PostgrestList> first = await _baseQuery(userId)
        .order('created_at', ascending: false)
        .range(0, _kPageSize - 1)
        .count(CountOption.exact);
    final List<Map<String, dynamic>> firstRows = first.data;
    final int total = first.count;
    // A server `max_rows` below our page size shows up as a short first page
    // while the count says there is more.
    final int pageSize =
        firstRows.length < _kPageSize && total > firstRows.length
        ? firstRows.length
        : _kPageSize;

    final List<int> offsets = <int>[
      if (pageSize > 0)
        for (int o = firstRows.length; o < total; o += pageSize) o,
    ];
    final List<PostgrestList?> pages = List<PostgrestList?>.filled(
      offsets.length,
      null,
    );
    int next = 0;
    Future<void> worker() async {
      while (next < offsets.length) {
        final int index = next++;
        final int start = offsets[index];
        pages[index] = await _baseQuery(userId)
            .order('created_at', ascending: false)
            .range(start, start + pageSize - 1);
      }
    }

    await Future.wait(<Future<void>>[
      for (int i = 0; i < _kMaxConcurrentPages && i < offsets.length; i++)
        worker(),
    ]);

    final List<UsageLogEntry> entries = <UsageLogEntry>[
      ..._parseRows(firstRows),
      for (final PostgrestList? page in pages) ..._parseRows(page),
    ];

    // Rows inserted during the fetch push older rows past `total`. A full
    // last page means there may be more: read on until a short page.
    final int lastLength = pages.isEmpty
        ? firstRows.length
        : (pages.last?.length ?? 0);
    if (pageSize > 0 && lastLength == pageSize) {
      int start = (offsets.isEmpty
          ? firstRows.length
          : offsets.last + pageSize);
      while (true) {
        final PostgrestList rows = await _baseQuery(userId)
            .order('created_at', ascending: false)
            .range(start, start + pageSize - 1);
        entries.addAll(_parseRows(rows));
        if (rows.length < pageSize) break;
        start += pageSize;
      }
    }

    // Not yet de-duplicated: [_refresh] does that on the background pass.
    return entries;
  }

  static Future<UsageBillingSnapshot> _loadBillingSnapshot(
    String userId,
  ) async {
    double? totalCreditsAllocated;
    DateTime? creditsLastRenewedPeriod;
    double? creditsRemaining;

    await Future.wait<void>(<Future<void>>[
      () async {
        try {
          final billing = await SupabaseService.client
              .from('user_billing')
              .select('total_credits_allocated,credits_last_renewed_period')
              .eq('user_id', userId)
              .maybeSingle();

          if (billing != null) {
            totalCreditsAllocated = _parseNullableDouble(
              billing['total_credits_allocated'],
            );
            creditsLastRenewedPeriod = _parseDateTime(
              billing['credits_last_renewed_period'],
            );
          }
        } on PostgrestException {
          // Keep usage page functional even if billing snapshot is unavailable.
        }
      }(),
      () async {
        try {
          final result = await SupabaseService.client.rpc(
            'get_credits_remaining',
            params: {'p_user_id': userId},
          );
          creditsRemaining = _parseNullableDouble(result);
        } on PostgrestException {
          // Keep usage page functional even if rpc is unavailable.
        }
      }(),
    ]);

    return UsageBillingSnapshot(
      totalCreditsAllocated: totalCreditsAllocated,
      creditsRemaining: creditsRemaining,
      creditsLastRenewedPeriod: creditsLastRenewedPeriod,
    );
  }

  /// The overview and the activity panel of [entries], on a background
  /// isolate when the list is large. [TokenActivityStatsService.build] alone
  /// takes about 300 ms at 16k rows (debug VM), far over a frame. `compute`
  /// works on every platform (on web it runs inline). With [dedupe], page
  /// overlap is removed first and the rows come back newest first.
  static Future<UsageDetails> buildDetailsAsync(
    List<UsageLogEntry> entries,
    UsageBillingSnapshot billing, {
    bool dedupe = false,
  }) async {
    if (entries.length < _kIsolateThreshold) {
      return _buildDetails((entries, billing, dedupe));
    }
    return compute(_buildDetails, (entries, billing, dedupe));
  }

  /// Pure: the totals and per-model summaries of [entries].
  static UsageOverview buildOverview(
    List<UsageLogEntry> entries,
    UsageBillingSnapshot billing,
  ) {
    final List<UsageModelSummary> modelSummaries = _buildModelSummaries(
      entries,
    );

    int totalPromptTokens = 0;
    int totalCompletionTokens = 0;
    int totalTextTokens = 0;
    int totalMediaRequests = 0;
    double totalCostUsd = 0;
    double totalCreditsEur = 0;
    final int? totalCacheReadTokens = sumKnownInts(
      entries.map((e) => e.cacheReadTokens),
    );
    final int? totalCacheWriteTokens = sumKnownInts(
      entries.map((e) => e.cacheWriteTokens),
    );
    final double? totalCacheReadCostUsd = sumKnownDoubles(
      entries.map((e) => e.cacheReadCostUsd),
    );
    final double? totalCacheWriteCostUsd = sumKnownDoubles(
      entries.map((e) => e.cacheWriteCostUsd),
    );
    double totalPromptCostUsd = 0;
    double totalCompletionCostUsd = 0;

    for (final entry in entries) {
      totalPromptTokens += entry.promptTokens;
      totalCompletionTokens += entry.completionTokens;
      totalTextTokens += entry.textTokens;
      if (entry.isMediaRequest) {
        totalMediaRequests += 1;
      }
      totalCostUsd += entry.totalCostUsd;
      totalCreditsEur += entry.creditsDeductedEur;
      totalPromptCostUsd += entry.promptCostUsd;
      totalCompletionCostUsd += entry.completionCostUsd;
    }

    return UsageOverview(
      entries: entries,
      modelSummaries: modelSummaries,
      totalRequests: entries.length,
      totalPromptTokens: totalPromptTokens,
      totalCompletionTokens: totalCompletionTokens,
      totalTextTokens: totalTextTokens,
      totalMediaRequests: totalMediaRequests,
      totalCostUsd: totalCostUsd,
      totalCreditsEur: totalCreditsEur,
      totalCacheReadTokens: totalCacheReadTokens,
      totalCacheWriteTokens: totalCacheWriteTokens,
      totalCacheReadCostUsd: totalCacheReadCostUsd,
      totalCacheWriteCostUsd: totalCacheWriteCostUsd,
      totalPromptCostUsd: totalPromptCostUsd,
      totalCompletionCostUsd: totalCompletionCostUsd,
      totalCreditsAllocated: billing.totalCreditsAllocated,
      creditsRemaining: billing.creditsRemaining,
      creditsLastRenewedPeriod: billing.creditsLastRenewedPeriod,
    );
  }

  /// Drops the in-process copy (tests).
  @visibleForTesting
  static void debugClearMemory() {
    _memory.clear();
    _lastDetails.clear();
    _inFlight.clear();
  }

  static List<UsageModelSummary> _buildModelSummaries(
    List<UsageLogEntry> entries,
  ) {
    final Map<String, _MutableModelSummary> byModel =
        <String, _MutableModelSummary>{};

    for (final entry in entries) {
      final summary = byModel.putIfAbsent(
        entry.modelId,
        () => _MutableModelSummary(entry.modelId),
      );
      summary.requestCount += 1;
      summary.textTokens += entry.textTokens;
      if (entry.isMediaRequest) {
        summary.mediaRequestCount += 1;
      }
      summary.totalCostUsd += entry.totalCostUsd;
      summary.totalCreditsEur += entry.creditsDeductedEur;
      summary.totalPromptCostUsd += entry.promptCostUsd;
      summary.totalCompletionCostUsd += entry.completionCostUsd;
      summary.providerHits[entry.providerSlug] =
          (summary.providerHits[entry.providerSlug] ?? 0) + 1;
    }

    final List<UsageModelSummary> summaries = byModel.values
        .map(
          (item) => UsageModelSummary(
            modelId: item.modelId,
            primaryProvider: item.primaryProvider,
            requestCount: item.requestCount,
            textTokens: item.textTokens,
            mediaRequestCount: item.mediaRequestCount,
            totalCostUsd: item.totalCostUsd,
            totalCreditsEur: item.totalCreditsEur,
            totalPromptCostUsd: item.totalPromptCostUsd,
            totalCompletionCostUsd: item.totalCompletionCostUsd,
          ),
        )
        .toList(growable: false);

    summaries.sort((a, b) {
      final int creditCompare = b.totalCreditsEur.compareTo(a.totalCreditsEur);
      if (creditCompare != 0) {
        return creditCompare;
      }
      return b.textTokens.compareTo(a.textTokens);
    });

    return summaries;
  }
}

/// The usage overview plus the token-activity panel, built in one pass so
/// they always describe the same rows.
@immutable
class UsageDetails {
  const UsageDetails({required this.overview, required this.activity});

  final UsageOverview overview;
  final TokenActivityStats activity;
}

class _Decoded {
  const _Decoded(this.snapshot, this.details);

  final UsageLogsCacheSnapshot snapshot;
  final UsageDetails details;
}

// Top-level so `compute` can run them on a background isolate.
UsageLogsCacheSnapshot? _decodeOnly((String, String) args) =>
    UsageLogsCacheCodec.decode(args.$1, expectedUserId: args.$2);

_Decoded? _decodeAndBuild((String, String) args) {
  final UsageLogsCacheSnapshot? snapshot = _decodeOnly(args);
  if (snapshot == null) return null;
  return _Decoded(
    snapshot,
    _buildDetails((snapshot.entries, snapshot.billing, false)),
  );
}

UsageDetails _buildDetails(
  (List<UsageLogEntry>, UsageBillingSnapshot, bool) args,
) {
  final List<UsageLogEntry> entries = args.$3
      ? dedupeUsageEntries(args.$1)
      : args.$1;
  return UsageDetails(
    overview: UsageLogsService.buildOverview(entries, args.$2),
    activity: TokenActivityStatsService.build(entries),
  );
}

class UsageLogsServiceException implements Exception {
  const UsageLogsServiceException(this.message);

  final String message;

  @override
  String toString() => message;
}

class _MutableModelSummary {
  _MutableModelSummary(this.modelId);

  final String modelId;
  final Map<String, int> providerHits = <String, int>{};

  int requestCount = 0;
  int textTokens = 0;
  int mediaRequestCount = 0;
  double totalCostUsd = 0;
  double totalCreditsEur = 0;
  double totalPromptCostUsd = 0;
  double totalCompletionCostUsd = 0;

  String get primaryProvider {
    if (providerHits.isEmpty) {
      return 'unknown-provider';
    }

    String bestProvider = providerHits.keys.first;
    int bestHits = providerHits[bestProvider] ?? 0;

    providerHits.forEach((provider, hits) {
      if (hits > bestHits) {
        bestProvider = provider;
        bestHits = hits;
      }
    });

    return bestProvider;
  }
}

/// The sum of the known values; null when every value is null (unknown).
int? sumKnownInts(Iterable<int?> values) {
  int? sum;
  for (final value in values) {
    if (value != null) sum = (sum ?? 0) + value;
  }
  return sum;
}

/// The sum of the known values; null when every value is null (unknown).
double? sumKnownDoubles(Iterable<double?> values) {
  double? sum;
  for (final value in values) {
    if (value != null) sum = (sum ?? 0) + value;
  }
  return sum;
}

int? _parseNullableInt(dynamic value) {
  if (value == null) return null;
  if (value is String && int.tryParse(value) == null) return null;
  return _parseInt(value);
}

int _parseInt(dynamic value) {
  if (value is int) {
    return value;
  }
  if (value is num) {
    return value.toInt();
  }
  if (value is String) {
    return int.tryParse(value) ?? 0;
  }
  return 0;
}

double _parseDouble(dynamic value) {
  if (value is double) {
    return value;
  }
  if (value is num) {
    return value.toDouble();
  }
  if (value is String) {
    return double.tryParse(value) ?? 0;
  }
  return 0;
}

double? _parseNullableDouble(dynamic value) {
  if (value == null) {
    return null;
  }
  return _parseDouble(value);
}

DateTime? _parseDateTime(dynamic value) {
  if (value is DateTime) {
    return value;
  }
  if (value is String) {
    return DateTime.tryParse(value);
  }
  return null;
}
