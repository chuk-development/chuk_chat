import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/services/usage_logs_service.dart';

/// The KV key of one user's cached usage rows. Keyed by the user id so a
/// sign-in as another account on the same device never reads foreign rows.
String usageLogsCacheKey(String userId) => 'usage_logs_v1:$userId';

/// The billing figures shown next to the usage rows. Every field is nullable:
/// null means "not known", which the page shows differently from 0.
@immutable
class UsageBillingSnapshot {
  const UsageBillingSnapshot({
    this.totalCreditsAllocated,
    this.creditsRemaining,
    this.creditsLastRenewedPeriod,
  });

  final double? totalCreditsAllocated;
  final double? creditsRemaining;
  final DateTime? creditsLastRenewedPeriod;
}

/// What the cache holds for one user: the rows (newest first), the billing
/// figures of the last refresh, and when the rows were last fetched in full.
@immutable
class UsageLogsCacheSnapshot {
  const UsageLogsCacheSnapshot({
    required this.userId,
    required this.entries,
    required this.lastFullSyncAt,
    this.billing = const UsageBillingSnapshot(),
  });

  final String userId;
  final List<UsageLogEntry> entries;
  final DateTime lastFullSyncAt;
  final UsageBillingSnapshot billing;
}

/// Compact JSON form of [UsageLogsCacheSnapshot].
///
/// One row is one array, not one object, and model and provider names go
/// into a string table, so 16k rows stay near 1 MB instead of 3+ MB. Nullable
/// fields stay null in the JSON: an unknown cache count is not a 0.
class UsageLogsCacheCodec {
  const UsageLogsCacheCodec._();

  static const int version = 1;

  static String encode(UsageLogsCacheSnapshot snapshot) {
    final Map<String, int> models = <String, int>{};
    final Map<String, int> providers = <String, int>{};
    final List<List<Object?>> rows = <List<Object?>>[
      for (final UsageLogEntry e in snapshot.entries)
        <Object?>[
          models.putIfAbsent(e.modelId, () => models.length),
          providers.putIfAbsent(e.providerSlug, () => providers.length),
          e.promptTokens,
          e.completionTokens,
          e.totalTokens,
          e.totalCostUsd,
          e.creditsDeductedEur,
          e.createdAt?.microsecondsSinceEpoch,
          e.cacheReadTokens,
          e.cacheWriteTokens,
          e.cacheReadCostUsd,
          e.cacheWriteCostUsd,
          e.promptCostUsd,
          e.completionCostUsd,
        ],
    ];
    final UsageBillingSnapshot b = snapshot.billing;
    return jsonEncode(<String, Object?>{
      'v': version,
      'u': snapshot.userId,
      'f': snapshot.lastFullSyncAt.microsecondsSinceEpoch,
      'b': <Object?>[
        b.totalCreditsAllocated,
        b.creditsRemaining,
        b.creditsLastRenewedPeriod?.microsecondsSinceEpoch,
      ],
      'm': models.keys.toList(growable: false),
      'p': providers.keys.toList(growable: false),
      'r': rows,
    });
  }

  /// Null when [raw] is not a cache of this [version] or belongs to another
  /// user than [expectedUserId]. A broken cache is dropped, never shown.
  static UsageLogsCacheSnapshot? decode(String raw, {String? expectedUserId}) {
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map || decoded['v'] != version) return null;
      final String? userId = decoded['u'] as String?;
      if (userId == null) return null;
      if (expectedUserId != null && userId != expectedUserId) return null;

      final List<String> models = (decoded['m'] as List).cast<String>();
      final List<String> providers = (decoded['p'] as List).cast<String>();
      final List<Object?> rows = decoded['r'] as List<Object?>;
      final List<UsageLogEntry> entries = <UsageLogEntry>[
        for (final Object? row in rows)
          _entryFromRow(row as List, models, providers),
      ];
      final List<Object?> b = (decoded['b'] as List?) ?? const <Object?>[];
      return UsageLogsCacheSnapshot(
        userId: userId,
        entries: entries,
        lastFullSyncAt: _time(decoded['f'])!,
        billing: UsageBillingSnapshot(
          totalCreditsAllocated: b.isNotEmpty ? _dbl(b[0]) : null,
          creditsRemaining: b.length > 1 ? _dbl(b[1]) : null,
          creditsLastRenewedPeriod: b.length > 2 ? _time(b[2]) : null,
        ),
      );
    } catch (_) {
      return null;
    }
  }

  static UsageLogEntry _entryFromRow(
    List row,
    List<String> models,
    List<String> providers,
  ) {
    return UsageLogEntry(
      modelId: models[row[0] as int],
      providerSlug: providers[row[1] as int],
      promptTokens: row[2] as int,
      completionTokens: row[3] as int,
      totalTokens: row[4] as int,
      totalCostUsd: _dbl(row[5])!,
      creditsDeductedEur: _dbl(row[6])!,
      createdAt: _time(row[7]),
      cacheReadTokens: row[8] as int?,
      cacheWriteTokens: row[9] as int?,
      cacheReadCostUsd: _dbl(row[10]),
      cacheWriteCostUsd: _dbl(row[11]),
      promptCostUsd: _dbl(row[12])!,
      completionCostUsd: _dbl(row[13])!,
    );
  }

  static double? _dbl(Object? value) => (value as num?)?.toDouble();

  static DateTime? _time(Object? value) => value == null
      ? null
      : DateTime.fromMicrosecondsSinceEpoch(value as int, isUtc: true);
}

/// Identity of a row for de-duplication: a record, so equality is
/// structural. `usage_logs` rows are fetched without a primary key, so two
/// rows count as the same row when every column matches. Two real rows never share all columns: `created_at`
/// has microsecond precision.
Object usageEntrySignature(UsageLogEntry e) => (
  e.createdAt?.microsecondsSinceEpoch,
  e.modelId,
  e.providerSlug,
  e.promptTokens,
  e.completionTokens,
  e.totalTokens,
  e.totalCostUsd,
  e.creditsDeductedEur,
  e.cacheReadTokens,
  e.cacheWriteTokens,
  e.cacheReadCostUsd,
  e.cacheWriteCostUsd,
  e.promptCostUsd,
  e.completionCostUsd,
);

/// Newest first; rows without a timestamp go last. Stable for equal times.
int _newestFirst(UsageLogEntry a, UsageLogEntry b) {
  final DateTime? x = a.createdAt;
  final DateTime? y = b.createdAt;
  if (x == null && y == null) return 0;
  if (x == null) return 1;
  if (y == null) return -1;
  return y.compareTo(x);
}

/// Removes repeated rows (same signature) and sorts newest first. Range
/// pages fetched in parallel can overlap by a row when a new row is inserted
/// between two requests; this removes that overlap.
List<UsageLogEntry> dedupeUsageEntries(Iterable<UsageLogEntry> entries) {
  final Set<Object> seen = <Object>{};
  final List<UsageLogEntry> out = <UsageLogEntry>[
    for (final UsageLogEntry e in entries)
      if (seen.add(usageEntrySignature(e))) e,
  ];
  mergeSort(out, compare: _newestFirst);
  return out;
}

/// Adds the rows of an incremental fetch to the cached rows. The fetch asks
/// for `created_at >= newest cached created_at`, so the boundary rows come
/// back again; they are dropped here by signature. Result is newest first.
List<UsageLogEntry> mergeUsageEntries(
  List<UsageLogEntry> cached,
  List<UsageLogEntry> incoming,
) {
  if (incoming.isEmpty) return cached;
  // Only cached rows inside the window the fetch covered can repeat, so the
  // signature set holds those few rows, not all 16k.
  final DateTime? oldestIncoming = _oldestTimestamp(incoming);
  final Set<Object> known = <Object>{
    for (final UsageLogEntry e in cached)
      if (e.createdAt == null ||
          oldestIncoming == null ||
          !e.createdAt!.isBefore(oldestIncoming))
        usageEntrySignature(e),
  };
  final List<UsageLogEntry> fresh = <UsageLogEntry>[
    for (final UsageLogEntry e in incoming)
      if (known.add(usageEntrySignature(e))) e,
  ];
  if (fresh.isEmpty) return cached;
  final List<UsageLogEntry> merged = <UsageLogEntry>[...fresh, ...cached];
  mergeSort(merged, compare: _newestFirst);
  return merged;
}

DateTime? _oldestTimestamp(Iterable<UsageLogEntry> entries) {
  DateTime? oldest;
  for (final UsageLogEntry e in entries) {
    final DateTime? t = e.createdAt;
    if (t != null && (oldest == null || t.isBefore(oldest))) oldest = t;
  }
  return oldest;
}

/// The newest `created_at` in [entries], or null when no row has one.
DateTime? newestUsageTimestamp(Iterable<UsageLogEntry> entries) {
  DateTime? newest;
  for (final UsageLogEntry e in entries) {
    final DateTime? t = e.createdAt;
    if (t != null && (newest == null || t.isAfter(newest))) newest = t;
  }
  return newest;
}
