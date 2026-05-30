import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chuk_chat/services/supabase_service.dart';

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
    this.cacheReadTokens = 0,
    this.cacheWriteTokens = 0,
    this.cacheReadCostUsd = 0,
    this.cacheWriteCostUsd = 0,
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
  final int cacheReadTokens;
  final int cacheWriteTokens;
  final double cacheReadCostUsd;
  final double cacheWriteCostUsd;
  final double promptCostUsd;
  final double completionCostUsd;

  int get textTokens => promptTokens + completionTokens;

  int get cachedTokens => cacheReadTokens + cacheWriteTokens;

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
      cacheReadTokens: _parseInt(row['cache_read_tokens']),
      cacheWriteTokens: _parseInt(row['cache_write_tokens']),
      cacheReadCostUsd: _parseDouble(row['cache_read_cost_usd']),
      cacheWriteCostUsd: _parseDouble(row['cache_write_cost_usd']),
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
    this.totalCacheReadTokens = 0,
    this.totalCacheWriteTokens = 0,
    this.totalCacheReadCostUsd = 0,
    this.totalCacheWriteCostUsd = 0,
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

  final int totalCacheReadTokens;
  final int totalCacheWriteTokens;
  final double totalCacheReadCostUsd;
  final double totalCacheWriteCostUsd;

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

  static const int _kBatchSize = 500;

  static Future<UsageOverview> loadOverview() async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw const UsageLogsServiceException('User is not signed in.');
    }

    try {
      final results = await Future.wait<dynamic>([
        _loadUsageEntries(user.id),
        _loadBillingSnapshot(user.id),
      ]);

      final List<UsageLogEntry> entries = (results[0] as List<UsageLogEntry>)
          .toList(growable: false);
      final _UsageBillingSnapshot billing = results[1] as _UsageBillingSnapshot;

      final List<UsageModelSummary> modelSummaries = _buildModelSummaries(
        entries,
      );

      int totalPromptTokens = 0;
      int totalCompletionTokens = 0;
      int totalTextTokens = 0;
      int totalMediaRequests = 0;
      double totalCostUsd = 0;
      double totalCreditsEur = 0;
      int totalCacheReadTokens = 0;
      int totalCacheWriteTokens = 0;
      double totalCacheReadCostUsd = 0;
      double totalCacheWriteCostUsd = 0;
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
        totalCacheReadTokens += entry.cacheReadTokens;
        totalCacheWriteTokens += entry.cacheWriteTokens;
        totalCacheReadCostUsd += entry.cacheReadCostUsd;
        totalCacheWriteCostUsd += entry.cacheWriteCostUsd;
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
    } on PostgrestException catch (error) {
      throw UsageLogsServiceException(error.message);
    } catch (error) {
      throw UsageLogsServiceException('Failed to load usage details: $error');
    }
  }

  static Future<List<UsageLogEntry>> _loadUsageEntries(String userId) async {
    final List<UsageLogEntry> entries = <UsageLogEntry>[];
    int start = 0;

    while (true) {
      final int end = start + _kBatchSize - 1;

      final response = await SupabaseService.client
          .from('usage_logs')
          .select(
            'model_id,provider_slug,prompt_tokens,completion_tokens,total_tokens,total_cost_usd,credits_deducted_eur,created_at,cache_read_tokens,cache_write_tokens,cache_read_cost_usd,cache_write_cost_usd,prompt_cost_usd,completion_cost_usd',
          )
          .eq('user_id', userId)
          .order('created_at', ascending: false)
          .range(start, end);

      final rows = (response as List).cast<Map<String, dynamic>>();
      entries.addAll(rows.map(UsageLogEntry.fromMap));

      if (rows.length < _kBatchSize) {
        break;
      }
      start += _kBatchSize;
    }

    return entries;
  }

  static Future<_UsageBillingSnapshot> _loadBillingSnapshot(
    String userId,
  ) async {
    double? totalCreditsAllocated;
    DateTime? creditsLastRenewedPeriod;
    double? creditsRemaining;

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

    try {
      final result = await SupabaseService.client.rpc(
        'get_credits_remaining',
        params: {'p_user_id': userId},
      );
      creditsRemaining = _parseNullableDouble(result);
    } on PostgrestException {
      // Keep usage page functional even if rpc is unavailable.
    }

    return _UsageBillingSnapshot(
      totalCreditsAllocated: totalCreditsAllocated,
      creditsRemaining: creditsRemaining,
      creditsLastRenewedPeriod: creditsLastRenewedPeriod,
    );
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

class UsageLogsServiceException implements Exception {
  const UsageLogsServiceException(this.message);

  final String message;

  @override
  String toString() => message;
}

class _UsageBillingSnapshot {
  const _UsageBillingSnapshot({
    required this.totalCreditsAllocated,
    required this.creditsRemaining,
    required this.creditsLastRenewedPeriod,
  });

  final double? totalCreditsAllocated;
  final double? creditsRemaining;
  final DateTime? creditsLastRenewedPeriod;
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
