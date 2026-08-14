import 'package:flutter/material.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/usage_logs_service.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';

const List<String> _kMonthNames = <String>[
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

class UsageDetailsPage extends StatefulWidget {
  const UsageDetailsPage({super.key});

  @override
  State<UsageDetailsPage> createState() => _UsageDetailsPageState();
}

class _UsageDetailsPageState extends State<UsageDetailsPage> {
  static const String _kScopeAllTime = 'all-time';
  static const String _kScopeBillingPeriod = 'billing-period';

  UsageOverview? _overview;
  bool _isLoading = true;
  String? _errorMessage;
  DateTime? _lastUpdatedAt;
  String _selectedScopeKey = _kScopeAllTime;

  @override
  void initState() {
    super.initState();
    _loadUsageOverview();
  }

  Future<void> _loadUsageOverview() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final overview = await UsageLogsService.loadOverview();
      if (!mounted) return;

      _syncSelectedScope(overview);
      setState(() {
        _overview = overview;
        _isLoading = false;
        _lastUpdatedAt = DateTime.now();
      });
    } on UsageLogsServiceException catch (error) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = error.message;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _errorMessage = 'Failed to load usage details: $error';
      });
    }
  }

  void _syncSelectedScope(UsageOverview overview) {
    final options = _buildScopeOptions(overview);

    final bool exists = options.any(
      (option) => option.key == _selectedScopeKey,
    );
    if (exists) {
      return;
    }

    final _UsageScopeOption? billingOption = _firstScopeByType(
      options,
      _UsageScopeType.billingPeriod,
    );
    final _UsageScopeOption? monthOption = _firstScopeByType(
      options,
      _UsageScopeType.calendarMonth,
    );

    if (billingOption != null) {
      _selectedScopeKey = billingOption.key;
      return;
    }
    if (monthOption != null) {
      _selectedScopeKey = monthOption.key;
      return;
    }
    _selectedScopeKey = _kScopeAllTime;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = AppLocalizations.of(context)!;
    final ColorScheme cs = theme.colorScheme;

    final UsageOverview? overview = _overview;

    if (_isLoading && overview == null) {
      return Scaffold(
        backgroundColor: cs.surface,
        appBar: _appBar(context),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (overview == null) {
      return Scaffold(
        backgroundColor: cs.surface,
        appBar: _appBar(context),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _errorMessage ?? l.unableToLoadUsage,
                  style: theme.textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 20),
                FilledButton(
                  onPressed: _loadUsageOverview,
                  child: Text(l.retry),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final List<_UsageScopeOption> scopeOptions = _buildScopeOptions(overview);
    final _UsageScopeOption selectedScope = _selectedScope(scopeOptions);
    final _UsageSlice usageSlice = _buildSlice(selectedScope, overview.entries);

    return Scaffold(
      backgroundColor: cs.surface,
      appBar: _appBar(context),
      body: RefreshIndicator(
        onRefresh: _loadUsageOverview,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_isLoading) ...[
                      LinearProgressIndicator(
                        minHeight: 2,
                        color: cs.primary,
                        backgroundColor: theme.m3.surfaceContainerHigh,
                      ),
                      const SizedBox(height: 12),
                    ],
                    if (_errorMessage != null) ...[
                      _buildInlineWarning(context, _errorMessage!),
                      const SizedBox(height: 16),
                    ],

                    // Period first: everything below is a reading of the
                    // window the reader picks here, so the control belongs
                    // above the numbers, not under a decorative header.
                    _SectionLabel(l.period.toUpperCase()),
                    _buildScopeSelector(context, scopeOptions),
                    const SizedBox(height: 24),

                    _SectionLabel(l.totals.toUpperCase()),
                    _buildSummaryCard(context, usageSlice),
                    const SizedBox(height: 24),

                    if (selectedScope.type == _UsageScopeType.billingPeriod &&
                        _hasCreditProgress(overview)) ...[
                      const _SectionLabel('BILLING'),
                      _buildBillingCard(context, overview, selectedScope),
                      const SizedBox(height: 24),
                    ],

                    const _SectionLabel('BY MODEL'),
                    _buildModelSummaryCard(context, usageSlice),
                    const SizedBox(height: 24),

                    _SectionLabel(
                      'REQUESTS · ${_formatCount(usageSlice.requests)}',
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(4, 0, 4, 12),
                      child: Text(
                        _lastUpdatedAt == null
                            ? l.mediaRequestsNote
                            : '${l.mediaRequestsNote} · '
                                'updated ${_formatDateTime(_lastUpdatedAt)}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.m3.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (usageSlice.entries.isEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                  child: _Panel(
                    child: Text(
                      l.noRequestsFound,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.m3.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate((context, index) {
                    return _buildRequestCard(
                      context,
                      usageSlice.entries[index],
                    );
                  }, childCount: usageSlice.entries.length),
                ),
              ),
          ],
        ),
      ),
    );
  }

  PreferredSizeWidget _appBar(BuildContext context) {
    final theme = Theme.of(context);
    return AppBar(
      title: Text(AppLocalizations.of(context)!.usageDetails),
      centerTitle: false,
      backgroundColor: theme.colorScheme.surface,
      elevation: 0,
      scrolledUnderElevation: 0,
    );
  }

  bool _hasCreditProgress(UsageOverview overview) {
    final double? allocated = overview.totalCreditsAllocated;
    return allocated != null &&
        allocated > 0 &&
        overview.creditsRemaining != null &&
        overview.creditsUsedThisPeriod != null;
  }

  Widget _buildScopeSelector(
    BuildContext context,
    List<_UsageScopeOption> scopeOptions,
  ) {
    // A horizontal strip, not a Wrap inside a card: the month list grows
    // every month, and a Wrap turned it into a four-row block of chips
    // that pushed the actual numbers off the first screen.
    return SizedBox(
      height: 40,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 2),
        itemCount: scopeOptions.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final option = scopeOptions[index];
          final bool isSelected = option.key == _selectedScopeKey;
          return ChoiceChip(
            label: Text(option.label),
            selected: isSelected,
            showCheckmark: false,
            onSelected: (_) {
              setState(() => _selectedScopeKey = option.key);
            },
          );
        },
      ),
    );
  }

  Widget _buildSummaryCard(BuildContext context, _UsageSlice usageSlice) {
    final theme = Theme.of(context);
    final m3 = theme.m3;

    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Spent',
            style: theme.textTheme.labelMedium?.copyWith(
              color: m3.onSurfaceVariant,
              letterSpacing: 0.4,
            ),
          ),
          const SizedBox(height: 4),
          // The euro figure is what the reader came for, so it is the
          // largest thing on the page rather than one tile among six.
          Text(
            _formatEurSmart(usageSlice.totalCreditsEur),
            style: theme.textTheme.displaySmall?.copyWith(
              color: theme.colorScheme.primary,
              fontWeight: FontWeight.w700,
              height: 1.05,
            ),
          ),
          const SizedBox(height: 18),
          _StatGrid(
            rows: [
              ('Requests', _formatCount(usageSlice.requests)),
              ('Text tokens', _formatCount(usageSlice.textTokens)),
              if (usageSlice.mediaRequests > 0)
                ('Media requests', _formatCount(usageSlice.mediaRequests)),
              if (usageSlice.cacheReadTokens > 0)
                (
                  AppLocalizations.of(context)!.cachedTokens,
                  _formatCount(usageSlice.cacheReadTokens),
                ),
              ('Provider cost', _formatUsd(usageSlice.totalCostUsd)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildBillingCard(
    BuildContext context,
    UsageOverview overview,
    _UsageScopeOption selectedScope,
  ) {
    final theme = Theme.of(context);
    final m3 = theme.m3;
    final accent = theme.colorScheme.primary;

    final double allocated = overview.totalCreditsAllocated!;
    final double remaining = overview.creditsRemaining!;
    final double used = overview.creditsUsedThisPeriod!;
    final double progress = (used / allocated).clamp(0.0, 1.0);

    return _Panel(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (selectedScope.start != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Text(
                'Since ${_formatDate(selectedScope.start)}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: m3.onSurfaceVariant,
                ),
              ),
            ),
          ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 6,
              backgroundColor: m3.surfaceContainerHighest,
              valueColor: AlwaysStoppedAnimation<Color>(accent),
            ),
          ),
          const SizedBox(height: 14),
          _StatGrid(
            rows: [
              ('Allocated', _formatEur(allocated)),
              ('Used', _formatEurSmart(used)),
              ('Remaining', _formatEurSmart(remaining)),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildModelSummaryCard(BuildContext context, _UsageSlice usageSlice) {
    final theme = Theme.of(context);
    final m3 = theme.m3;
    final accent = theme.colorScheme.primary;

    if (usageSlice.models.isEmpty) {
      return _Panel(
        child: Text(
          'No model activity in this period.',
          style: theme.textTheme.bodyMedium?.copyWith(
            color: m3.onSurfaceVariant,
          ),
        ),
      );
    }

    final List<Widget> rows = <Widget>[];
    for (int i = 0; i < usageSlice.models.length; i++) {
      final _ModelSliceSummary summary = usageSlice.models[i];
      if (i > 0) {
        rows.add(Divider(height: 24, color: m3.outlineVariant));
      }

      final List<String> detail = <String>[
        '${_formatCount(summary.requestCount)} requests',
        if (summary.textTokens > 0)
          '${_formatCount(summary.textTokens)} tokens',
        if (summary.mediaRequests > 0)
          '${_formatCount(summary.mediaRequests)} media',
        summary.primaryProvider,
      ];

      rows.add(
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    summary.modelId,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                      color: theme.colorScheme.onSurface,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  Text(
                    detail.join(' · '),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: m3.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Text(
              _formatEurSmart(summary.totalCreditsEur),
              style: theme.textTheme.bodyMedium?.copyWith(
                color: accent,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      );
    }

    return _Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows),
    );
  }

  Widget _buildRequestCard(BuildContext context, UsageLogEntry entry) {
    final theme = Theme.of(context);
    final m3 = theme.m3;
    final accent = theme.colorScheme.primary;

    final List<String> detail = <String>[
      entry.providerSlug,
      if (entry.isMediaRequest)
        'media'
      else
        '${_formatCount(entry.promptTokens)} in · '
            '${_formatCount(entry.completionTokens)} out',
      if (entry.cacheReadTokens > 0)
        '${_formatCount(entry.cacheReadTokens)} cached',
      _formatDateTime(entry.createdAt),
    ];

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: m3.surfaceContainer,
        borderRadius: kBorderRadiusField,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              entry.isMediaRequest
                  ? Icons.perm_media_outlined
                  : Icons.chat_bubble_outline,
              size: 16,
              color: m3.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.modelId,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.onSurface,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 3),
                Text(
                  detail.join(' · '),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: m3.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                _formatEurSmart(entry.creditsDeductedEur),
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: accent,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                _formatUsd(entry.totalCostUsd),
                style: theme.textTheme.bodySmall?.copyWith(
                  color: m3.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildInlineWarning(BuildContext context, String message) {
    final theme = Theme.of(context);
    final m3 = theme.m3;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: m3.warningContainer,
        borderRadius: kBorderRadiusField,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.warning_amber_rounded, size: 18, color: m3.warning),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              message,
              style: theme.textTheme.bodySmall?.copyWith(
                color: m3.onWarningContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }

  List<_UsageScopeOption> _buildScopeOptions(UsageOverview overview) {
    final List<_UsageScopeOption> options = <_UsageScopeOption>[
      const _UsageScopeOption(
        key: _kScopeAllTime,
        label: 'All Time',
        type: _UsageScopeType.allTime,
      ),
    ];

    if (overview.creditsLastRenewedPeriod != null) {
      options.add(
        _UsageScopeOption(
          key: _kScopeBillingPeriod,
          label: 'Current Billing Period',
          type: _UsageScopeType.billingPeriod,
          start: overview.creditsLastRenewedPeriod!.toLocal(),
          end: null,
        ),
      );
    }

    final Map<String, DateTime> monthMap = <String, DateTime>{};
    for (final entry in overview.entries) {
      final DateTime? createdAt = entry.createdAt;
      if (createdAt == null) {
        continue;
      }

      final DateTime local = createdAt.toLocal();
      final DateTime monthStart = DateTime(local.year, local.month);
      final String monthKey =
          'month-${monthStart.year}-${_twoDigits(monthStart.month)}';

      monthMap.putIfAbsent(monthKey, () => monthStart);
    }

    final List<DateTime> monthStarts = monthMap.values.toList(growable: false)
      ..sort((a, b) => b.compareTo(a));

    for (final monthStart in monthStarts) {
      options.add(
        _UsageScopeOption(
          key: 'month-${monthStart.year}-${_twoDigits(monthStart.month)}',
          label: _formatMonthYear(monthStart),
          type: _UsageScopeType.calendarMonth,
          start: monthStart,
          end: DateTime(monthStart.year, monthStart.month + 1),
        ),
      );
    }

    return options;
  }

  _UsageScopeOption _selectedScope(List<_UsageScopeOption> options) {
    for (final option in options) {
      if (option.key == _selectedScopeKey) {
        return option;
      }
    }
    return options.first;
  }

  _UsageScopeOption? _firstScopeByType(
    List<_UsageScopeOption> options,
    _UsageScopeType type,
  ) {
    for (final option in options) {
      if (option.type == type) {
        return option;
      }
    }
    return null;
  }

  _UsageSlice _buildSlice(
    _UsageScopeOption option,
    List<UsageLogEntry> allEntries,
  ) {
    final List<UsageLogEntry> scopedEntries = allEntries
        .where((entry) => _matchesScope(option, entry))
        .toList(growable: false);

    int requestCount = 0;
    int textTokens = 0;
    int mediaRequests = 0;
    double totalCreditsEur = 0;
    double totalCostUsd = 0;
    int cacheReadTokens = 0;

    final Map<String, _MutableModelSliceSummary> byModel =
        <String, _MutableModelSliceSummary>{};

    for (final entry in scopedEntries) {
      requestCount += 1;
      textTokens += entry.textTokens;
      if (entry.isMediaRequest) {
        mediaRequests += 1;
      }
      totalCreditsEur += entry.creditsDeductedEur;
      totalCostUsd += entry.totalCostUsd;
      cacheReadTokens += entry.cacheReadTokens;

      final summary = byModel.putIfAbsent(
        entry.modelId,
        () => _MutableModelSliceSummary(modelId: entry.modelId),
      );
      summary.requestCount += 1;
      summary.textTokens += entry.textTokens;
      if (entry.isMediaRequest) {
        summary.mediaRequests += 1;
      }
      summary.totalCreditsEur += entry.creditsDeductedEur;
      summary.totalCostUsd += entry.totalCostUsd;
      summary.providerHits[entry.providerSlug] =
          (summary.providerHits[entry.providerSlug] ?? 0) + 1;
    }

    final List<_ModelSliceSummary> modelSummaries =
        byModel.values.map((item) => item.freeze()).toList(growable: false)
          ..sort((a, b) {
            final int byCredits = b.totalCreditsEur.compareTo(
              a.totalCreditsEur,
            );
            if (byCredits != 0) {
              return byCredits;
            }
            return b.requestCount.compareTo(a.requestCount);
          });

    return _UsageSlice(
      entries: scopedEntries,
      requests: requestCount,
      textTokens: textTokens,
      mediaRequests: mediaRequests,
      totalCreditsEur: totalCreditsEur,
      totalCostUsd: totalCostUsd,
      cacheReadTokens: cacheReadTokens,
      models: modelSummaries,
    );
  }

  bool _matchesScope(_UsageScopeOption option, UsageLogEntry entry) {
    if (option.type == _UsageScopeType.allTime) {
      return true;
    }

    final DateTime? createdAt = entry.createdAt?.toLocal();
    if (createdAt == null || option.start == null) {
      return false;
    }

    if (createdAt.isBefore(option.start!)) {
      return false;
    }

    if (option.end != null && !createdAt.isBefore(option.end!)) {
      return false;
    }

    return true;
  }

  String _formatMonthYear(DateTime dateTime) {
    final DateTime local = dateTime.toLocal();
    return '${_kMonthNames[local.month - 1]} ${local.year}';
  }

  String _formatCount(int value) {
    final String raw = value.toString();
    return raw.replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
  }

  String _formatDate(DateTime? dateTime) {
    if (dateTime == null) {
      return 'Unknown';
    }
    final DateTime local = dateTime.toLocal();
    return '${_twoDigits(local.day)}.${_twoDigits(local.month)}.${local.year}';
  }

  String _formatDateTime(DateTime? dateTime) {
    if (dateTime == null) {
      return 'Unknown time';
    }
    final DateTime local = dateTime.toLocal();
    return '${_twoDigits(local.day)}.${_twoDigits(local.month)}.${local.year} '
        '${_twoDigits(local.hour)}:${_twoDigits(local.minute)}';
  }

  static String _twoDigits(int value) {
    return value.toString().padLeft(2, '0');
  }

  /// Two decimals reads as money; four only when the amount would round to
  /// zero. A page full of `\u20ac0.0034` is unreadable, and `\u20ac0.00` is a lie.
  String _formatEurSmart(double value) {
    if (value != 0 && value.abs() < 0.01) {
      return _formatEur(value, decimals: 4);
    }
    return _formatEur(value);
  }

  String _formatEur(double value, {int decimals = 2}) {
    return 'EUR ${value.toStringAsFixed(decimals)}';
  }

  String _formatUsd(double value, {int decimals = 4}) {
    return 'USD ${value.toStringAsFixed(decimals)}';
  }
}

enum _UsageScopeType { allTime, billingPeriod, calendarMonth }

class _UsageScopeOption {
  const _UsageScopeOption({
    required this.key,
    required this.label,
    required this.type,
    this.start,
    this.end,
  });

  final String key;
  final String label;
  final _UsageScopeType type;
  final DateTime? start;
  final DateTime? end;
}

class _UsageSlice {
  const _UsageSlice({
    required this.entries,
    required this.requests,
    required this.textTokens,
    required this.mediaRequests,
    required this.totalCreditsEur,
    required this.totalCostUsd,
    required this.models,
    this.cacheReadTokens = 0,
  });

  final List<UsageLogEntry> entries;
  final int requests;
  final int textTokens;
  final int mediaRequests;
  final double totalCreditsEur;
  final double totalCostUsd;
  final int cacheReadTokens;
  final List<_ModelSliceSummary> models;
}

class _ModelSliceSummary {
  const _ModelSliceSummary({
    required this.modelId,
    required this.primaryProvider,
    required this.requestCount,
    required this.textTokens,
    required this.mediaRequests,
    required this.totalCreditsEur,
    required this.totalCostUsd,
  });

  final String modelId;
  final String primaryProvider;
  final int requestCount;
  final int textTokens;
  final int mediaRequests;
  final double totalCreditsEur;
  final double totalCostUsd;
}

class _MutableModelSliceSummary {
  _MutableModelSliceSummary({required this.modelId});

  final String modelId;
  final Map<String, int> providerHits = <String, int>{};

  int requestCount = 0;
  int textTokens = 0;
  int mediaRequests = 0;
  double totalCreditsEur = 0;
  double totalCostUsd = 0;

  _ModelSliceSummary freeze() {
    String provider = 'unknown-provider';
    int providerHitsCount = -1;

    providerHits.forEach((name, hits) {
      if (hits > providerHitsCount) {
        provider = name;
        providerHitsCount = hits;
      }
    });

    return _ModelSliceSummary(
      modelId: modelId,
      primaryProvider: provider,
      requestCount: requestCount,
      textTokens: textTokens,
      mediaRequests: mediaRequests,
      totalCreditsEur: totalCreditsEur,
      totalCostUsd: totalCostUsd,
    );
  }
}

/// Uppercase section label — the same rhythm the subscription and settings
/// screens use, so this page stops looking like a different app.
class _SectionLabel extends StatelessWidget {
  final String label;
  const _SectionLabel(this.label);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.4,
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}

/// Flat rounded surface. No border, no gradient, no elevation — the page
/// used all three at once and every card fought the one above it.
class _Panel extends StatelessWidget {
  final Widget child;
  const _Panel({required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Theme.of(context).m3.surfaceContainer,
        borderRadius: kBorderRadiusCard,
      ),
      child: child,
    );
  }
}

/// Label/value pairs on baseline-aligned rows. Replaces the boxed metric
/// tiles in a Wrap, which produced a ragged edge and a different tile
/// count per screen width.
class _StatGrid extends StatelessWidget {
  final List<(String, String)> rows;
  const _StatGrid({required this.rows});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m3 = theme.m3;
    final List<Widget> children = <Widget>[];

    for (int i = 0; i < rows.length; i++) {
      if (i > 0) children.add(const SizedBox(height: 10));
      final (String label, String value) = rows[i];
      children.add(
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Expanded(
              child: Text(
                label,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: m3.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Text(
              value,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface,
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      );
    }

    return Column(children: children);
  }
}
