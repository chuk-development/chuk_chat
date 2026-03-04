import 'package:flutter/material.dart';

import 'package:chuk_chat/services/usage_logs_service.dart';
import 'package:chuk_chat/utils/color_extensions.dart';

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
    final Color scaffoldBg = theme.scaffoldBackgroundColor;
    final Color onSurface = theme.colorScheme.onSurface;
    final TextStyle? titleTextStyle = theme.appBarTheme.titleTextStyle;

    final UsageOverview? overview = _overview;

    if (_isLoading && overview == null) {
      return Scaffold(
        backgroundColor: scaffoldBg,
        appBar: AppBar(
          title: Text('Usage Details', style: titleTextStyle),
          backgroundColor: scaffoldBg,
          elevation: 0,
          iconTheme: IconThemeData(color: onSurface),
        ),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (overview == null) {
      return Scaffold(
        backgroundColor: scaffoldBg,
        appBar: AppBar(
          title: Text('Usage Details', style: titleTextStyle),
          backgroundColor: scaffoldBg,
          elevation: 0,
          iconTheme: IconThemeData(color: onSurface),
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _errorMessage ?? 'Unable to load usage details right now.',
                  style: theme.textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: _loadUsageOverview,
                  child: const Text('Retry'),
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
      backgroundColor: scaffoldBg,
      appBar: AppBar(
        title: Text('Usage Details', style: titleTextStyle),
        backgroundColor: scaffoldBg,
        elevation: 0,
        iconTheme: IconThemeData(color: onSurface),
      ),
      body: RefreshIndicator(
        onRefresh: _loadUsageOverview,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildHeroCard(context, selectedScope, usageSlice),
                    const SizedBox(height: 12),
                    _buildScopeSelector(context, scopeOptions),
                    const SizedBox(height: 12),
                    _buildSummaryCard(context, usageSlice),
                    const SizedBox(height: 12),
                    _buildBillingCard(context, overview, selectedScope),
                    const SizedBox(height: 12),
                    _buildModelSummaryCard(context, usageSlice),
                    const SizedBox(height: 16),
                    Text(
                      'Every Request (${_formatCount(usageSlice.requests)})',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                        color: onSurface,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Image and audio requests are treated as media requests and excluded from text-token totals.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: onSurface.withValues(alpha: 0.72),
                      ),
                    ),
                    if (_lastUpdatedAt != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        'Last updated: ${_formatDateTime(_lastUpdatedAt)}',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: onSurface.withValues(alpha: 0.6),
                        ),
                      ),
                    ],
                    if (_isLoading) ...[
                      const SizedBox(height: 10),
                      LinearProgressIndicator(
                        minHeight: 3,
                        color: theme.colorScheme.primary,
                        backgroundColor: onSurface.withValues(alpha: 0.12),
                      ),
                    ],
                    if (_errorMessage != null) ...[
                      const SizedBox(height: 10),
                      _buildInlineWarning(context, _errorMessage!),
                    ],
                    const SizedBox(height: 10),
                  ],
                ),
              ),
            ),
            if (usageSlice.entries.isEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  child: _buildSectionCard(
                    context,
                    child: Text(
                      'No requests found for this period.',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: onSurface.withValues(alpha: 0.75),
                      ),
                    ),
                  ),
                ),
              )
            else
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                sliver: SliverList(
                  delegate: SliverChildBuilderDelegate((context, index) {
                    final entry = usageSlice.entries[index];
                    return _buildRequestCard(context, entry);
                  }, childCount: usageSlice.entries.length),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeroCard(
    BuildContext context,
    _UsageScopeOption selectedScope,
    _UsageSlice usageSlice,
  ) {
    final theme = Theme.of(context);
    final Color onSurface = theme.colorScheme.onSurface;
    final Color accent = theme.colorScheme.primary;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: LinearGradient(
          colors: [
            accent.withValues(alpha: 0.22),
            accent.withValues(alpha: 0.09),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        border: Border.all(color: accent.withValues(alpha: 0.35), width: 1.2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.query_stats, color: accent),
              const SizedBox(width: 8),
              Text(
                'Usage and Billing',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.w800,
                  color: onSurface,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Showing ${selectedScope.label.toLowerCase()} with ${_formatCount(usageSlice.requests)} requests.',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: onSurface.withValues(alpha: 0.82),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'This screen is read-only and pulled from your usage logs.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: onSurface.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildScopeSelector(
    BuildContext context,
    List<_UsageScopeOption> scopeOptions,
  ) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;
    final accent = theme.colorScheme.primary;

    return _buildSectionCard(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Period',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: onSurface,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: scopeOptions
                .map((option) {
                  final bool isSelected = option.key == _selectedScopeKey;
                  return ChoiceChip(
                    label: Text(option.label),
                    selected: isSelected,
                    onSelected: (_) {
                      setState(() {
                        _selectedScopeKey = option.key;
                      });
                    },
                    selectedColor: accent.withValues(alpha: 0.22),
                    side: BorderSide(
                      color: isSelected
                          ? accent.withValues(alpha: 0.7)
                          : onSurface.withValues(alpha: 0.25),
                    ),
                    labelStyle: theme.textTheme.labelLarge?.copyWith(
                      color: isSelected
                          ? accent
                          : onSurface.withValues(alpha: 0.8),
                      fontWeight: isSelected
                          ? FontWeight.w700
                          : FontWeight.w500,
                    ),
                    backgroundColor: Colors.transparent,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  );
                })
                .toList(growable: false),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryCard(BuildContext context, _UsageSlice usageSlice) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;

    return _buildSectionCard(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Totals',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: onSurface,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _UsageMetricTile(
                icon: Icons.request_page_outlined,
                label: 'Requests',
                value: _formatCount(usageSlice.requests),
              ),
              _UsageMetricTile(
                icon: Icons.notes_outlined,
                label: 'Text Tokens',
                value: _formatCount(usageSlice.textTokens),
              ),
              _UsageMetricTile(
                icon: Icons.image_outlined,
                label: 'Media Requests',
                value: _formatCount(usageSlice.mediaRequests),
              ),
              _UsageMetricTile(
                icon: Icons.account_balance_wallet_outlined,
                label: 'Credits Spent',
                value: _formatEur(usageSlice.totalCreditsEur, decimals: 4),
              ),
              _UsageMetricTile(
                icon: Icons.attach_money_outlined,
                label: 'USD Cost',
                value: _formatUsd(usageSlice.totalCostUsd, decimals: 6),
              ),
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
    final onSurface = theme.colorScheme.onSurface;
    final accent = theme.colorScheme.primary;

    final double? allocated = overview.totalCreditsAllocated;
    final double? remaining = overview.creditsRemaining;
    final double? used = overview.creditsUsedThisPeriod;

    final bool canShowCreditProgress =
        selectedScope.type == _UsageScopeType.billingPeriod &&
        allocated != null &&
        remaining != null &&
        used != null &&
        allocated > 0;

    return _buildSectionCard(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Billing Snapshot',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: onSurface,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            selectedScope.type == _UsageScopeType.allTime
                ? 'You are viewing all-time request history.'
                : 'You are viewing ${selectedScope.label.toLowerCase()}.',
            style: theme.textTheme.bodySmall?.copyWith(
              color: onSurface.withValues(alpha: 0.75),
            ),
          ),
          if (selectedScope.start != null) ...[
            const SizedBox(height: 6),
            Text(
              selectedScope.end == null
                  ? 'From: ${_formatDate(selectedScope.start)}'
                  : 'Range: ${_formatDate(selectedScope.start)} to ${_formatDate(selectedScope.end!.subtract(const Duration(seconds: 1)))}',
              style: theme.textTheme.bodySmall?.copyWith(
                color: onSurface.withValues(alpha: 0.68),
              ),
            ),
          ],
          if (canShowCreditProgress) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                _UsageMetricTile(
                  icon: Icons.savings_outlined,
                  label: 'Allocated',
                  value: _formatEur(allocated),
                ),
                _UsageMetricTile(
                  icon: Icons.trending_down,
                  label: 'Used',
                  value: _formatEur(used, decimals: 4),
                ),
                _UsageMetricTile(
                  icon: Icons.trending_up,
                  label: 'Remaining',
                  value: _formatEur(remaining, decimals: 4),
                ),
              ],
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: (used / allocated).clamp(0.0, 1.0),
                minHeight: 8,
                backgroundColor: onSurface.withValues(alpha: 0.14),
                valueColor: AlwaysStoppedAnimation<Color>(accent),
              ),
            ),
          ] else ...[
            const SizedBox(height: 10),
            Text(
              'Allocated and remaining credits are only shown for the billing-period view.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: onSurface.withValues(alpha: 0.66),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildModelSummaryCard(BuildContext context, _UsageSlice usageSlice) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;
    final accent = theme.colorScheme.primary;

    return _buildSectionCard(
      context,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Usage by Model',
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w700,
              color: onSurface,
            ),
          ),
          const SizedBox(height: 10),
          if (usageSlice.models.isEmpty)
            Text(
              'No model activity in this period.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: onSurface.withValues(alpha: 0.75),
              ),
            )
          else
            ...usageSlice.models.asMap().entries.map((entry) {
              final int index = entry.key;
              final _ModelSliceSummary summary = entry.value;

              String detailText =
                  '${_formatCount(summary.requestCount)} requests';
              if (summary.textTokens > 0) {
                detailText =
                    '$detailText - ${_formatCount(summary.textTokens)} text tokens';
              }
              if (summary.mediaRequests > 0) {
                detailText =
                    '$detailText - ${_formatCount(summary.mediaRequests)} media';
              }

              return Container(
                margin: EdgeInsets.only(
                  bottom: index == usageSlice.models.length - 1 ? 0 : 10,
                ),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  color: accent.withValues(alpha: 0.08),
                  border: Border.all(color: onSurface.withValues(alpha: 0.16)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            summary.modelId,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: onSurface,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '$detailText - ${summary.primaryProvider}',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: onSurface.withValues(alpha: 0.74),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          _formatEur(summary.totalCreditsEur, decimals: 4),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: accent,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          _formatUsd(summary.totalCostUsd, decimals: 6),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: onSurface.withValues(alpha: 0.66),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              );
            }),
        ],
      ),
    );
  }

  Widget _buildRequestCard(BuildContext context, UsageLogEntry entry) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;
    final accent = theme.colorScheme.primary;

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: theme.scaffoldBackgroundColor.lighten(0.05),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: onSurface.withValues(alpha: 0.2), width: 1),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: accent.withValues(alpha: 0.14),
                  ),
                  child: Icon(
                    entry.isMediaRequest
                        ? Icons.perm_media_outlined
                        : Icons.chat_bubble_outline,
                    size: 16,
                    color: accent,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    entry.modelId,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                      color: onSurface,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  _formatEur(entry.creditsDeductedEur, decimals: 4),
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: accent,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.only(left: 38),
              child: Text(
                '${entry.providerSlug} - ${_formatDateTime(entry.createdAt)}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: onSurface.withValues(alpha: 0.72),
                ),
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (entry.isMediaRequest)
                  _buildPill(context, 'Media request')
                else ...[
                  _buildPill(
                    context,
                    'Prompt ${_formatCount(entry.promptTokens)}',
                  ),
                  _buildPill(
                    context,
                    'Completion ${_formatCount(entry.completionTokens)}',
                  ),
                  _buildPill(context, 'Text ${_formatCount(entry.textTokens)}'),
                ],
                _buildPill(
                  context,
                  _formatUsd(entry.totalCostUsd, decimals: 6),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPill(BuildContext context, String text) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        text,
        style: theme.textTheme.labelMedium?.copyWith(
          fontWeight: FontWeight.w600,
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }

  Widget _buildInlineWarning(BuildContext context, String message) {
    final theme = Theme.of(context);
    final bool isDark = theme.brightness == Brightness.dark;
    final Color warningBackground = isDark
        ? Colors.orange.shade200.withValues(alpha: 0.14)
        : Colors.orange.withValues(alpha: 0.1);
    final Color warningBorder = isDark
        ? Colors.orange.shade300.withValues(alpha: 0.45)
        : Colors.orange.withValues(alpha: 0.3);
    final Color warningText = isDark
        ? Colors.orange.shade200
        : Colors.orange.shade800;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: warningBackground,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: warningBorder),
      ),
      child: Text(
        message,
        style: theme.textTheme.bodySmall?.copyWith(color: warningText),
      ),
    );
  }

  Widget _buildSectionCard(BuildContext context, {required Widget child}) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;

    return Card(
      color: theme.scaffoldBackgroundColor.lighten(0.05),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: onSurface.withValues(alpha: 0.2), width: 1),
      ),
      margin: EdgeInsets.zero,
      child: Padding(padding: const EdgeInsets.all(16), child: child),
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
  });

  final List<UsageLogEntry> entries;
  final int requests;
  final int textTokens;
  final int mediaRequests;
  final double totalCreditsEur;
  final double totalCostUsd;
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

class _UsageMetricTile extends StatelessWidget {
  const _UsageMetricTile({
    required this.icon,
    required this.label,
    required this.value,
  });

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final onSurface = theme.colorScheme.onSurface;
    final accent = theme.colorScheme.primary;

    return Container(
      constraints: const BoxConstraints(minWidth: 150),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        color: accent.withValues(alpha: 0.1),
        border: Border.all(color: onSurface.withValues(alpha: 0.16), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: accent),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: onSurface.withValues(alpha: 0.75),
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: theme.textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w800,
              color: onSurface,
            ),
          ),
        ],
      ),
    );
  }
}
