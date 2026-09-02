import 'package:flutter/material.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/token_activity_stats.dart';
import 'package:chuk_chat/services/usage_logs_service.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/expressive_settings.dart';

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
  TokenActivityStats? _activityStats;
  HeatmapMode _heatmapMode = HeatmapMode.daily;
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
      // The heatmap and both streaks come from this one fetch so they can
      // never disagree with each other. This panel is deliberately all-time
      // and does not follow the period chip — a "longest streak within June"
      // would be a meaningless number.
      final stats = TokenActivityStatsService.build(overview.entries);
      setState(() {
        _overview = overview;
        _activityStats = stats;
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
                    ExpressiveSectionHeader(l.period),
                    _buildScopeSelector(context, scopeOptions),

                    ExpressiveSectionHeader(l.totals),
                    _buildSummaryCard(context, usageSlice),

                    if (_activityStats != null &&
                        !_activityStats!.isEmpty) ...[
                      const ExpressiveSectionHeader('Token activity'),
                      _buildTokenActivitySection(context, _activityStats!),
                    ],

                    if (selectedScope.type == _UsageScopeType.billingPeriod &&
                        _hasCreditProgress(overview)) ...[
                      const ExpressiveSectionHeader('Billing'),
                      _buildBillingCard(context, overview, selectedScope),
                    ],

                    const ExpressiveSectionHeader('By model'),
                    _buildModelSummaryCard(context, usageSlice),

                    ExpressiveSectionHeader(
                      'Requests · ${_formatCount(usageSlice.requests)}',
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
                  child: ExpressiveCard(
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

    return ExpressiveCard(
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

  Widget _buildTokenActivitySection(
    BuildContext context,
    TokenActivityStats stats,
  ) {
    final theme = Theme.of(context);
    final m3 = theme.m3;

    final List<DailyTokenPoint> series = TokenActivityStatsService.denseSeries(
      stats,
    );
    final List<int> values = TokenActivityStatsService.heatmapValues(
      series,
      _heatmapMode,
    );

    return ExpressiveCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Streaks cover all of your history. The heatmap shows about the '
            'last year of daily use and does not follow the period picker.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: m3.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: _StreakTile(
                  label: 'Current streak',
                  value: stats.currentStreak,
                  icon: Icons.local_fire_department_outlined,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _StreakTile(
                  label: 'Longest streak',
                  value: stats.longestStreak,
                  icon: Icons.emoji_events_outlined,
                ),
              ),
            ],
          ),
          const SizedBox(height: 18),
          _buildHeatmapModeSelector(context),
          const SizedBox(height: 14),
          // The grid can be wider than the screen; it scrolls inside its own
          // horizontal viewport so the page body never scrolls sideways.
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            reverse: true,
            child: _TokenActivityHeatmap(
              series: series,
              values: values,
              mode: _heatmapMode,
            ),
          ),
          const SizedBox(height: 14),
          _buildHeatmapLegend(context),
          const SizedBox(height: 6),
          Text(
            _heatmapCaption(),
            style: theme.textTheme.bodySmall?.copyWith(
              color: m3.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeatmapModeSelector(BuildContext context) {
    const List<(HeatmapMode, String)> modes = <(HeatmapMode, String)>[
      (HeatmapMode.daily, 'Daily'),
      (HeatmapMode.weekly, 'Weekly'),
      (HeatmapMode.cumulative, 'Cumulative'),
    ];

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final (HeatmapMode mode, String label) in modes)
          ChoiceChip(
            label: Text(label),
            selected: _heatmapMode == mode,
            showCheckmark: false,
            onSelected: (_) {
              if (_heatmapMode == mode) return;
              setState(() => _heatmapMode = mode);
            },
          ),
      ],
    );
  }

  Widget _buildHeatmapLegend(BuildContext context) {
    final theme = Theme.of(context);
    final m3 = theme.m3;
    final TextStyle? labelStyle = theme.textTheme.bodySmall?.copyWith(
      color: m3.onSurfaceVariant,
    );

    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Text('Less', style: labelStyle),
        const SizedBox(width: 6),
        for (int level = 0; level <= 4; level++) ...[
          Container(
            width: 11,
            height: 11,
            decoration: BoxDecoration(
              color: _heatmapCellColor(context, level),
              borderRadius: BorderRadius.circular(3),
            ),
          ),
          if (level < 4) const SizedBox(width: 3),
        ],
        const SizedBox(width: 6),
        Text('More', style: labelStyle),
      ],
    );
  }

  String _heatmapCaption() {
    switch (_heatmapMode) {
      case HeatmapMode.daily:
        return 'Each cell is one day, shaded by tokens used that day.';
      case HeatmapMode.weekly:
        return 'Each cell is shaded by its ISO-week token total.';
      case HeatmapMode.cumulative:
        return 'Each cell is shaded by the running token total across the '
            'days shown.';
    }
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

    return ExpressiveCard(
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
      return ExpressiveCard(
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

    return ExpressiveCard(
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

/// One of the two streak read-outs: a big number over a quiet label.
class _StreakTile extends StatelessWidget {
  const _StreakTile({
    required this.label,
    required this.value,
    required this.icon,
  });

  final String label;
  final int value;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m3 = theme.m3;

    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: m3.surfaceContainerHigh,
        borderRadius: kBorderRadiusField,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 15, color: m3.onSurfaceVariant),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: m3.onSurfaceVariant,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                '$value',
                style: theme.textTheme.headlineMedium?.copyWith(
                  color: theme.colorScheme.primary,
                  fontWeight: FontWeight.w700,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(width: 4),
              Text(
                value == 1 ? 'day' : 'days',
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
}

/// A GitHub-contribution-style grid: one column per ISO week (oldest at the
/// left), seven rows Mon–Sun. [values] is parallel to [series] and carries
/// the per-cell number for the active [mode]; the cell colour is a quartile
/// of that number relative to the grid's own maximum.
class _TokenActivityHeatmap extends StatelessWidget {
  const _TokenActivityHeatmap({
    required this.series,
    required this.values,
    required this.mode,
  });

  final List<DailyTokenPoint> series;
  final List<int> values;
  final HeatmapMode mode;

  static const double _cell = 12;
  static const double _gap = 3;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m3 = theme.m3;

    if (series.isEmpty) {
      return const SizedBox.shrink();
    }

    int maxValue = 0;
    for (final int v in values) {
      if (v > maxValue) maxValue = v;
    }

    // Chunk the flat day series into week columns of 7 (Mon..Sun). The series
    // starts on a Monday, so index % 7 is the weekday row.
    final int weekCount = (series.length + 6) ~/ 7;

    final List<Widget> columns = <Widget>[];
    for (int week = 0; week < weekCount; week++) {
      final List<Widget> cells = <Widget>[];
      for (int row = 0; row < 7; row++) {
        final int index = week * 7 + row;
        if (index >= series.length) {
          // Days past today in the trailing partial week: keep the slot so
          // columns stay the same height, but draw nothing.
          cells.add(
            const SizedBox(width: _cell, height: _cell),
          );
        } else {
          cells.add(_cell3(context, series[index], values[index], maxValue));
        }
        if (row < 6) cells.add(const SizedBox(height: _gap));
      }
      columns.add(Column(children: cells));
      if (week < weekCount - 1) columns.add(const SizedBox(width: _gap));
    }

    final List<Widget> weekdayLabels = _buildWeekdayLabels(theme, m3);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: weekdayLabels,
        ),
        const SizedBox(width: 6),
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: columns),
      ],
    );
  }

  Widget _cell3(
    BuildContext context,
    DailyTokenPoint point,
    int value,
    int maxValue,
  ) {
    final int level = _heatmapLevel(value, maxValue);
    return Tooltip(
      // Report the number that drives the shade, which in weekly/cumulative
      // mode is not the day's own token count.
      message: _tooltipFor(point, value),
      waitDuration: const Duration(milliseconds: 300),
      child: Container(
        width: _cell,
        height: _cell,
        decoration: BoxDecoration(
          color: _heatmapCellColor(context, level),
          borderRadius: BorderRadius.circular(3),
        ),
      ),
    );
  }

  List<Widget> _buildWeekdayLabels(ThemeData theme, MaterialYouTokens m3) {
    const List<String> labels = <String>['', 'Mon', '', 'Wed', '', 'Fri', ''];
    final TextStyle? style = theme.textTheme.labelSmall?.copyWith(
      color: m3.onSurfaceVariant,
      height: 1,
    );
    final List<Widget> out = <Widget>[];
    for (int row = 0; row < 7; row++) {
      out.add(
        SizedBox(
          height: _cell,
          child: labels[row].isEmpty
              ? null
              : Text(labels[row], style: style),
        ),
      );
      if (row < 6) out.add(const SizedBox(height: _gap));
    }
    return out;
  }

  String _tooltipFor(DailyTokenPoint point, int value) {
    final String tokens = '${_formatTokens(value)}'
        '${value == 1 ? ' token' : ' tokens'}';
    switch (mode) {
      case HeatmapMode.daily:
        return '${_formatDay(point.day)} · $tokens';
      case HeatmapMode.weekly:
        final DateTime monday = TokenActivityStatsService.mondayOf(point.day);
        return 'Week of ${_formatDay(monday)} · $tokens';
      case HeatmapMode.cumulative:
        return 'Through ${_formatDay(point.day)} · $tokens so far';
    }
  }

  String _formatDay(DateTime day) =>
      '${day.day.toString().padLeft(2, '0')}.'
      '${day.month.toString().padLeft(2, '0')}.${day.year}';

  String _formatTokens(int value) {
    final String raw = value.toString();
    return raw.replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
  }
}

/// Quartile of [value] against [maxValue]: 0 (none) then 1–4 (light→dark).
int _heatmapLevel(int value, int maxValue) {
  if (value <= 0 || maxValue <= 0) {
    return 0;
  }
  final double frac = value / maxValue;
  if (frac <= 0.25) return 1;
  if (frac <= 0.5) return 2;
  if (frac <= 0.75) return 3;
  return 4;
}

/// Cell colour for a heat level, from theme tokens so both themes read well:
/// level 0 is the empty container, 1–4 are the primary at rising opacity.
Color _heatmapCellColor(BuildContext context, int level) {
  final theme = Theme.of(context);
  final Color primary = theme.colorScheme.primary;
  switch (level) {
    case 0:
      return theme.m3.surfaceContainerHighest;
    case 1:
      return primary.withValues(alpha: 0.30);
    case 2:
      return primary.withValues(alpha: 0.52);
    case 3:
      return primary.withValues(alpha: 0.76);
    default:
      return primary;
  }
}
