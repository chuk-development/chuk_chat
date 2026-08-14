import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:chuk_chat/services/api_config_service.dart';
import 'package:chuk_chat/services/network_status_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:flutter/foundation.dart';

final SupabaseClient _supabase = Supabase.instance.client;

// Cache keys for offline credit display (BalanceBadge)
const String _kCachedCredits = 'cached_credits';
const String _kCachedHasSubscription = 'cached_has_subscription';
const String _kCachedFreeMessagesRemaining = 'cached_free_messages_remaining';
const String _kCachedFreeMessagesTotal = 'cached_free_messages_total';

// Cache keys for CreditListenerMixin (CreditDisplay/CreditBadge)
const String _kCachedTotalCreditsAllocated = 'cached_total_credits_allocated';
const String _kCachedRemainingCredits = 'cached_remaining_credits';
const String _kCachedBillingPeriodStart = 'cached_billing_period_start';
const String _kCachedBillingPeriodEnd = 'cached_billing_period_end';

class CreditBalances {
  const CreditBalances({
    required this.totalCredits,
    required this.usedCredits,
    required this.remainingCredits,
    this.billingPeriodStart,
    this.billingPeriodEnd,
  });

  const CreditBalances.empty()
    : totalCredits = 0,
      usedCredits = 0,
      remainingCredits = 0,
      billingPeriodStart = null,
      billingPeriodEnd = null;

  final double totalCredits;
  final double usedCredits;
  final double remainingCredits;
  final DateTime? billingPeriodStart;
  final DateTime? billingPeriodEnd;

  double get remainingRatio =>
      totalCredits > 0 ? remainingCredits / totalCredits : 0.0;
}

mixin _CreditListenerMixin<T extends StatefulWidget> on State<T> {
  CreditBalances creditBalances = const CreditBalances.empty();
  bool creditLoading = true;

  RealtimeChannel? _creditChannel;
  bool _hasLoadedOnce = false;

  @protected
  void initCreditListener({String? channelName}) {
    final String resolvedChannelName =
        channelName ?? 'credit_updates_${identityHashCode(this)}';

    // Load from cache first, then sync from remote
    _loadCreditsFromCacheThenRemote();

    // Ensure previous channel is cleaned up before creating a new one
    _creditChannel?.unsubscribe();
    _creditChannel = _supabase.channel(resolvedChannelName)
      ..onPostgresChanges(
        event: PostgresChangeEvent.update,
        schema: 'public',
        table: 'user_billing',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'user_id',
          value: _supabase.auth.currentUser?.id,
        ),
        callback: (_) {
          refreshCredits(reloadSilently: true);
        },
      )
      ..subscribe();
  }

  /// Load from cache first for instant UI, then sync from remote in background
  Future<void> _loadCreditsFromCacheThenRemote() async {
    // Step 1: Load from cache immediately (fast, no network)
    await _loadCreditsFromCache();

    // Step 2: Sync from remote in BACKGROUND (don't block UI!)
    unawaited(refreshCredits(reloadSilently: true));
  }

  /// Load credits from local cache for instant display
  Future<void> _loadCreditsFromCache() async {
    final sw = Stopwatch()..start();
    try {
      final prefs = await SharedPreferences.getInstance();
      final cachedTotal = prefs.getDouble(_kCachedTotalCreditsAllocated);
      final cachedRemaining = prefs.getDouble(_kCachedRemainingCredits);

      // Only show cached value if we have one - otherwise wait for server
      if (cachedTotal != null) {
        if (!mounted) return;
        final double total = cachedTotal;
        final double remaining = cachedRemaining ?? 0.0;
        final double used = total - remaining;

        final int? cachedStartMs = prefs.getInt(_kCachedBillingPeriodStart);
        final int? cachedEndMs = prefs.getInt(_kCachedBillingPeriodEnd);
        final DateTime? cachedStart = cachedStartMs != null
            ? DateTime.fromMillisecondsSinceEpoch(cachedStartMs, isUtc: true)
            : null;
        final DateTime? cachedEnd = cachedEndMs != null
            ? DateTime.fromMillisecondsSinceEpoch(cachedEndMs, isUtc: true)
            : null;

        setState(() {
          creditBalances = CreditBalances(
            totalCredits: total,
            usedCredits: used.clamp(0.0, total),
            remainingCredits: remaining,
            billingPeriodStart: cachedStart,
            billingPeriodEnd: cachedEnd,
          );
          creditLoading = false;
          _hasLoadedOnce = true;
        });
        if (kDebugMode) {
          debugPrint(
            '📦 [CreditMixin] Loaded from cache: €$remaining / €$total (${sw.elapsedMilliseconds}ms)',
          );
        }
      } else {
        // No cache - keep loading state, server will provide value
        if (kDebugMode) {
          debugPrint('📦 [CreditMixin] No cache - waiting for server (${sw.elapsedMilliseconds}ms)');
        }
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('⚠️ [CreditMixin] Cache load failed (${sw.elapsedMilliseconds}ms): $e');
      }
      // On error, keep loading - server will handle it
    }
  }

  /// Save credits to cache for offline access
  Future<void> _saveCreditsToCache(
    double total,
    double remaining, {
    DateTime? periodStart,
    DateTime? periodEnd,
  }) async {
    final sw = Stopwatch()..start();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kCachedTotalCreditsAllocated, total);
      await prefs.setDouble(_kCachedRemainingCredits, remaining);
      if (periodStart != null) {
        await prefs.setInt(
          _kCachedBillingPeriodStart,
          periodStart.toUtc().millisecondsSinceEpoch,
        );
      } else {
        await prefs.remove(_kCachedBillingPeriodStart);
      }
      if (periodEnd != null) {
        await prefs.setInt(
          _kCachedBillingPeriodEnd,
          periodEnd.toUtc().millisecondsSinceEpoch,
        );
      } else {
        await prefs.remove(_kCachedBillingPeriodEnd);
      }
      if (kDebugMode) {
        debugPrint('💾 [CreditMixin] Saved to cache (${sw.elapsedMilliseconds}ms)');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('⚠️ [CreditMixin] Cache save failed (${sw.elapsedMilliseconds}ms): $e');
      }
    }
  }

  @protected
  Future<void> refreshCredits({bool reloadSilently = false}) async {
    // Only show loading spinner if this is a non-silent reload AND we haven't loaded once
    if (!reloadSilently && !_hasLoadedOnce) {
      if (mounted) {
        setState(() {
          creditLoading = true;
        });
      }
    }

    final sw = Stopwatch()..start();
    try {
      final session = await SupabaseService.refreshSession() ??
          _supabase.auth.currentSession;
      if (session == null) {
        if (!mounted) return;
        setState(() {
          creditBalances = const CreditBalances.empty();
          creditLoading = false;
          _hasLoadedOnce = true;
        });
        return;
      }

      // Fire user_status + user_billing in parallel — the billing query no
      // longer waits for /user/status to resolve, so the billing-cycle panel
      // appears at the same time as the credits figure.
      final Future<http.Response> statusFuture = http
          .get(
            Uri.parse('${ApiConfigService.apiBaseUrl}/v1/user/status'),
            headers: {'Authorization': 'Bearer ${session.accessToken}'},
          )
          .timeout(const Duration(seconds: 10));

      final Future<Map<String, dynamic>?> billingFuture = _supabase
          .from('user_billing')
          .select('credits_last_renewed_period')
          .eq('user_id', session.user.id)
          .maybeSingle()
          .then<Map<String, dynamic>?>((row) => row)
          .catchError((Object e) {
        if (kDebugMode) {
          debugPrint('⚠️ [CreditMixin] Billing period fetch failed: $e');
        }
        return null;
      });

      final results = await Future.wait<Object?>([statusFuture, billingFuture]);
      final response = results[0] as http.Response;
      final billing = results[1] as Map<String, dynamic>?;
      final int apiMs = sw.elapsedMilliseconds;

      if (response.statusCode != 200) {
        throw Exception(
          'API returned ${response.statusCode}: ${response.body}',
        );
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final double remainingCredits =
          (data['credits_remaining'] as num?)?.toDouble() ?? 0.0;
      final bool hasSubscription = data['has_subscription'] == true;

      // If user has subscription, monthly budget is €16.00
      final double totalCredits = hasSubscription ? 16.0 : 0.0;
      final double usedCredits = (totalCredits - remainingCredits).clamp(
        0.0,
        totalCredits,
      );

      // Derive billing period dates from the parallel query (subscribers only)
      DateTime? periodStart;
      DateTime? periodEnd;
      if (hasSubscription && billing != null) {
        final rawDate = billing['credits_last_renewed_period'];
        if (rawDate is String) {
          periodStart = DateTime.tryParse(rawDate);
        } else if (rawDate is DateTime) {
          periodStart = rawDate;
        }
        if (periodStart != null) {
          // Handle month overflow (e.g., Jan 31 → Feb 28)
          final nextMonth = DateTime(
            periodStart.year,
            periodStart.month + 1,
          );
          final lastDay = DateTime(
            nextMonth.year,
            nextMonth.month + 1,
            0,
          ).day;
          periodEnd = DateTime(
            nextMonth.year,
            nextMonth.month,
            periodStart.day.clamp(1, lastDay),
          );
        }
      }

      if (!mounted) return;
      setState(() {
        creditBalances = CreditBalances(
          totalCredits: totalCredits,
          usedCredits: usedCredits,
          remainingCredits: remainingCredits,
          billingPeriodStart: periodStart,
          billingPeriodEnd: periodEnd,
        );
        creditLoading = false;
        _hasLoadedOnce = true;
      });

      // Save to cache in background
      unawaited(
        _saveCreditsToCache(
          totalCredits,
          remainingCredits,
          periodStart: periodStart,
          periodEnd: periodEnd,
        ),
      );
      if (kDebugMode) {
        debugPrint(
          '✅ [CreditMixin] Loaded from API: €$remainingCredits / €$totalCredits (API+billing ${apiMs}ms)',
        );
      }
    } catch (error) {
      if (!mounted) return;
      setState(() {
        creditLoading = false;
        _hasLoadedOnce = true;
      });
      if (kDebugMode) {
        debugPrint('⚠️ [CreditMixin] API load failed (${sw.elapsedMilliseconds}ms, using cache): $error');
      }
    }
  }

  @protected
  void disposeCreditListener() {
    if (_creditChannel != null) {
      _supabase.removeChannel(_creditChannel!);
      _creditChannel = null;
    }
  }
}

class CreditDisplay extends StatefulWidget {
  const CreditDisplay({super.key});

  @override
  State<CreditDisplay> createState() => _CreditDisplayState();
}

class _CreditDisplayState extends State<CreditDisplay>
    with _CreditListenerMixin<CreditDisplay> {
  @override
  void initState() {
    super.initState();
    initCreditListener();
  }

  @override
  void dispose() {
    disposeCreditListener();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final m3 = theme.m3;
    final Color accent = theme.colorScheme.primary;
    final Color muted = m3.onSurfaceVariant;

    if (creditLoading) {
      return SizedBox(
        height: 96,
        child: Center(child: CircularProgressIndicator(color: accent)),
      );
    }

    final double percentage = creditBalances.remainingRatio;
    final Color barColor = percentage > 0.5
        ? m3.success
        : percentage > 0.2
            ? m3.warning
            : theme.colorScheme.error;

    // No Card here. This block is placed inside a rounded section on the
    // subscription page, and a card inside a card gave it two borders, two
    // corner radii and a shadow that belonged to neither.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Remaining',
          style: theme.textTheme.labelMedium?.copyWith(
            color: muted,
            letterSpacing: 0.4,
          ),
        ),
        const SizedBox(height: 4),
        // The number is the point of this block, so it is the biggest thing
        // in it rather than a value squeezed opposite a wallet icon.
        Text(
          '\u20ac${creditBalances.remainingCredits.toStringAsFixed(2)}',
          style: theme.textTheme.displaySmall?.copyWith(
            color: accent,
            fontWeight: FontWeight.w700,
            height: 1.05,
          ),
        ),
        const SizedBox(height: 14),
        ClipRRect(
          borderRadius: BorderRadius.circular(999),
          child: LinearProgressIndicator(
            value: percentage,
            minHeight: 6,
            backgroundColor: m3.surfaceContainerHighest,
            valueColor: AlwaysStoppedAnimation<Color>(barColor),
          ),
        ),
        const SizedBox(height: 10),
        _MetaLine(
          left: 'Used \u20ac${creditBalances.usedCredits.toStringAsFixed(2)}',
          right: 'of \u20ac${creditBalances.totalCredits.toStringAsFixed(2)}',
        ),
        if (creditBalances.billingPeriodStart != null &&
            creditBalances.billingPeriodEnd != null) ...[
          const SizedBox(height: 18),
          Divider(height: 1, color: m3.outlineVariant),
          const SizedBox(height: 14),
          Builder(builder: (context) {
            final now = DateTime.now().toUtc();
            final start = creditBalances.billingPeriodStart!;
            final end = creditBalances.billingPeriodEnd!;
            final int daysLeft = end.difference(now).inDays;
            final double totalDuration =
                end.difference(start).inSeconds.toDouble();
            final double elapsed = now.difference(start).inSeconds.toDouble();
            final double progress = totalDuration > 0
                ? (elapsed / totalDuration).clamp(0.0, 1.0)
                : 0.0;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.event_repeat_outlined, color: muted, size: 16),
                    const SizedBox(width: 8),
                    Text(
                      'Billing cycle',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: muted,
                        letterSpacing: 0.4,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      daysLeft > 0 ? '$daysLeft days left' : 'Renews soon',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: theme.colorScheme.onSurface,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                ClipRRect(
                  borderRadius: BorderRadius.circular(999),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 6,
                    backgroundColor: m3.surfaceContainerHighest,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      accent.withValues(alpha: 0.6),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                _MetaLine(
                  left: _formatDate(start),
                  right: 'Renews ${_formatDate(end)}',
                ),
              ],
            );
          }),
        ],
      ],
    );
  }

  static String _formatDate(DateTime dt) {
    final local = dt.toLocal();
    return '${local.day.toString().padLeft(2, '0')}.${local.month.toString().padLeft(2, '0')}.${local.year}';
  }
}

class CreditBadge extends StatefulWidget {
  const CreditBadge({
    super.key,
    this.textStyle,
    this.placeholderStyle,
    this.padding,
  });

  final TextStyle? textStyle;
  final TextStyle? placeholderStyle;
  final EdgeInsetsGeometry? padding;

  @override
  State<CreditBadge> createState() => _CreditBadgeState();
}

class _CreditBadgeState extends State<CreditBadge>
    with _CreditListenerMixin<CreditBadge> {
  @override
  void initState() {
    super.initState();
    initCreditListener();
  }

  @override
  void dispose() {
    disposeCreditListener();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final TextStyle resolvedTextStyle =
        widget.textStyle ??
        Theme.of(
          context,
        ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600) ??
        const TextStyle(fontSize: 14, fontWeight: FontWeight.w600);

    final EdgeInsetsGeometry resolvedPadding =
        widget.padding ??
        const EdgeInsets.symmetric(horizontal: 8, vertical: 4);

    if (creditLoading) {
      final TextStyle placeholderStyle =
          widget.placeholderStyle ??
          resolvedTextStyle.copyWith(
            color:
                resolvedTextStyle.color?.withValues(alpha: 0.6) ??
                Theme.of(context).hintColor,
          );

      return Padding(
        padding: resolvedPadding,
        child: Text('€--', style: placeholderStyle),
      );
    }

    final String formatted =
        '€${creditBalances.remainingCredits.toStringAsFixed(2)}';

    return Tooltip(
      message:
          'Remaining credits: $formatted\nTotal: €${creditBalances.totalCredits.toStringAsFixed(2)}',
      waitDuration: const Duration(milliseconds: 500),
      child: Container(
        padding: resolvedPadding,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(formatted, style: resolvedTextStyle),
      ),
    );
  }
}

/// Smart badge that shows credits for subscribed users OR free messages for non-subscribed users
class BalanceBadge extends StatefulWidget {
  const BalanceBadge({
    super.key,
    this.textStyle,
    this.placeholderStyle,
    this.padding,
  });

  final TextStyle? textStyle;
  final TextStyle? placeholderStyle;
  final EdgeInsetsGeometry? padding;

  @override
  State<BalanceBadge> createState() => _BalanceBadgeState();
}

class _BalanceBadgeState extends State<BalanceBadge> {
  bool _loading = true;
  double _credits = 0.0;
  int _freeMessagesRemaining = 0;
  int _freeMessagesTotal = 10;
  // Default to assuming paid user - server will correct if free user
  bool _hasSubscription = true;
  RealtimeChannel? _channel;
  VoidCallback? _networkListener;

  @override
  void initState() {
    super.initState();
    _loadFromCacheThenRemote();
    _initListener();
  }

  @override
  void dispose() {
    if (_channel != null) {
      _supabase.removeChannel(_channel!);
      _channel = null;
    }
    if (_networkListener != null) {
      NetworkStatusService.isOnlineListenable.removeListener(_networkListener!);
      _networkListener = null;
    }
    super.dispose();
  }

  void _initListener() {
    final user = _supabase.auth.currentUser;
    if (user == null) return;

    // Listen for profile updates via Supabase Realtime
    _channel = _supabase.channel('balance_updates_${identityHashCode(this)}')
      ..onPostgresChanges(
        event: PostgresChangeEvent.update,
        schema: 'public',
        table: 'user_billing',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'user_id',
          value: user.id,
        ),
        callback: (_) => _loadBalance(silent: true),
      )
      ..subscribe();

    // Listen for network status changes - refresh when back online
    _networkListener = () {
      if (NetworkStatusService.isOnline && mounted) {
        if (kDebugMode) {
          debugPrint('🌐 [Credits] Back online - refreshing balance');
        }
        _loadBalance(silent: true);
      }
    };
    NetworkStatusService.isOnlineListenable.addListener(_networkListener!);
  }

  /// Load cached data first for instant display, then fetch from remote in background
  Future<void> _loadFromCacheThenRemote() async {
    // Step 1: Load from cache immediately (fast, no network)
    await _loadFromCache();

    // Step 2: Sync from remote in BACKGROUND (don't block UI!)
    unawaited(_loadBalance(silent: true));
  }

  /// Load balance from local cache for offline display
  Future<void> _loadFromCache() async {
    final sw = Stopwatch()..start();
    try {
      final prefs = await SharedPreferences.getInstance();
      final cachedCredits = prefs.getDouble(_kCachedCredits);
      final cachedHasSubscription = prefs.getBool(_kCachedHasSubscription);
      final cachedFreeRemaining = prefs.getInt(_kCachedFreeMessagesRemaining);
      final cachedFreeTotal = prefs.getInt(_kCachedFreeMessagesTotal);

      // Only show cached value if we have one - otherwise wait for server
      if (cachedCredits != null) {
        if (!mounted) return;
        setState(() {
          _credits = cachedCredits;
          _hasSubscription = cachedHasSubscription ?? true;
          _freeMessagesRemaining = cachedFreeRemaining ?? 0;
          _freeMessagesTotal = cachedFreeTotal ?? 10;
          _loading = false;
        });
        if (kDebugMode) {
          debugPrint('📦 [BalanceBadge] Loaded from cache: €$_credits (${sw.elapsedMilliseconds}ms)');
        }
      } else {
        // No cache - keep loading state, server will provide value
        if (kDebugMode) {
          debugPrint('📦 [BalanceBadge] No cache - waiting for server (${sw.elapsedMilliseconds}ms)');
        }
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('⚠️ [BalanceBadge] Cache load failed (${sw.elapsedMilliseconds}ms): $e');
      }
      // On error, keep loading - server will handle it
    }
  }

  /// Save balance to local cache
  Future<void> _saveToCache() async {
    final sw = Stopwatch()..start();
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kCachedCredits, _credits);
      await prefs.setBool(_kCachedHasSubscription, _hasSubscription);
      await prefs.setInt(_kCachedFreeMessagesRemaining, _freeMessagesRemaining);
      await prefs.setInt(_kCachedFreeMessagesTotal, _freeMessagesTotal);
      if (kDebugMode) {
        debugPrint('💾 [BalanceBadge] Saved to cache (${sw.elapsedMilliseconds}ms)');
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('⚠️ [BalanceBadge] Cache save failed (${sw.elapsedMilliseconds}ms): $e');
      }
    }
  }

  Future<void> _loadBalance({bool silent = false}) async {
    if (!silent && mounted) {
      setState(() => _loading = true);
    }

    final sw = Stopwatch()..start();
    try {
      final session = await SupabaseService.refreshSession() ??
          _supabase.auth.currentSession;
      if (session == null) {
        if (mounted) setState(() => _loading = false);
        return;
      }

      // Load credits from API server (not Supabase)
      final response = await http
          .get(
            Uri.parse('${ApiConfigService.apiBaseUrl}/v1/user/status'),
            headers: {'Authorization': 'Bearer ${session.accessToken}'},
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        throw Exception(
          'API returned ${response.statusCode}: ${response.body}',
        );
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final double credits =
          (data['credits_remaining'] as num?)?.toDouble() ?? 0.0;
      final bool hasSubscription = data['has_subscription'] == true;
      final int freeTotal = (data['free_messages_total'] as int?) ?? 10;
      final int freeRemaining = (data['free_messages_remaining'] as int?) ?? 0;

      if (!mounted) return;
      setState(() {
        _credits = credits;
        _hasSubscription = hasSubscription;
        _freeMessagesTotal = freeTotal;
        _freeMessagesRemaining = freeRemaining;
        _loading = false;
      });

      // Save to cache for offline access (in background)
      unawaited(_saveToCache());
      if (kDebugMode) {
        debugPrint(
          '✅ [BalanceBadge] Loaded from API: €$_credits, $_freeMessagesRemaining/$_freeMessagesTotal free (${sw.elapsedMilliseconds}ms)',
        );
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('⚠️ [BalanceBadge] API load failed (${sw.elapsedMilliseconds}ms, using cache): $e');
      }
      if (mounted) setState(() => _loading = false);
      // Don't clear data on error - keep showing cached values
    }
  }

  @override
  Widget build(BuildContext context) {
    final TextStyle resolvedTextStyle =
        widget.textStyle ??
        Theme.of(
          context,
        ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600) ??
        const TextStyle(fontSize: 14, fontWeight: FontWeight.w600);

    final EdgeInsetsGeometry resolvedPadding =
        widget.padding ??
        const EdgeInsets.symmetric(horizontal: 8, vertical: 4);

    if (_loading) {
      final TextStyle placeholderStyle =
          widget.placeholderStyle ??
          resolvedTextStyle.copyWith(
            color:
                resolvedTextStyle.color?.withValues(alpha: 0.6) ??
                Theme.of(context).hintColor,
          );

      return Padding(
        padding: resolvedPadding,
        child: Text('€--', style: placeholderStyle),
      );
    }

    // Show test messages for non-subscribed users with no credits
    final bool showTestMessages =
        !_hasSubscription && _credits < 0.01 && _freeMessagesTotal > 0;
    final String formatted = showTestMessages
        ? '$_freeMessagesRemaining / $_freeMessagesTotal'
        : '€${_credits.toStringAsFixed(2)}';
    final String tooltip = showTestMessages
        ? 'Test messages: $_freeMessagesRemaining of $_freeMessagesTotal remaining'
        : 'Remaining credits: $formatted';
    // Fix A: removed the inner ring (was a tinted BoxDecoration on this
    // Container). The outer chip — drawn by the parent (e.g. sidebar
    // bottom-bar) — already provides the visible ring around the amount,
    // so this inner decoration produced a doubled "ring around the price"
    // effect. We keep the Padding so the layout/spacing is unchanged.
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: Padding(
        padding: resolvedPadding,
        child: Text(formatted, style: resolvedTextStyle),
      ),
    );
  }
}

/// Two small captions on one line — the pattern used under both bars.
class _MetaLine extends StatelessWidget {
  final String left;
  final String right;

  const _MetaLine({required this.left, required this.right});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final TextStyle? style = theme.textTheme.bodySmall?.copyWith(
      color: theme.m3.onSurfaceVariant,
    );
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(left, style: style),
        Text(right, style: style),
      ],
    );
  }
}
