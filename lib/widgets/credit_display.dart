import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:chuk_chat/services/api_config_service.dart';
import 'package:chuk_chat/services/network_status_service.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';

final SupabaseClient _supabase = Supabase.instance.client;

// Cache keys for offline credit display (BalanceBadge)
const String _kCachedCredits = 'cached_credits';
const String _kCachedHasSubscription = 'cached_has_subscription';
const String _kCachedFreeMessagesRemaining = 'cached_free_messages_remaining';
const String _kCachedFreeMessagesTotal = 'cached_free_messages_total';

// Cache keys for CreditListenerMixin (CreditDisplay/CreditBadge)
const String _kCachedTotalCreditsAllocated = 'cached_total_credits_allocated';
const String _kCachedRemainingCredits = 'cached_remaining_credits';

class CreditBalances {
  const CreditBalances({
    required this.totalCredits,
    required this.usedCredits,
    required this.remainingCredits,
  });

  const CreditBalances.empty()
      : totalCredits = 0,
        usedCredits = 0,
        remainingCredits = 0;

  final double totalCredits;
  final double usedCredits;
  final double remainingCredits;

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
        table: 'profiles',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'id',
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

        setState(() {
          creditBalances = CreditBalances(
            totalCredits: total,
            usedCredits: used.clamp(0.0, total),
            remainingCredits: remaining,
          );
          creditLoading = false;
          _hasLoadedOnce = true;
        });
        debugPrint('📦 [CreditMixin] Loaded from cache: €$remaining / €$total');
      } else {
        // No cache - keep loading state, server will provide value
        debugPrint('📦 [CreditMixin] No cache - waiting for server');
      }
    } catch (e) {
      debugPrint('⚠️ [CreditMixin] Cache load failed: $e');
      // On error, keep loading - server will handle it
    }
  }

  /// Save credits to cache for offline access
  Future<void> _saveCreditsToCache(double total, double remaining) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kCachedTotalCreditsAllocated, total);
      await prefs.setDouble(_kCachedRemainingCredits, remaining);
    } catch (e) {
      debugPrint('⚠️ [CreditMixin] Cache save failed: $e');
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

    try {
      final session = _supabase.auth.currentSession;
      if (session == null) {
        if (!mounted) return;
        setState(() {
          creditBalances = const CreditBalances.empty();
          creditLoading = false;
          _hasLoadedOnce = true;
        });
        return;
      }

      // Load credits from API server (not Supabase)
      final response = await http.get(
        Uri.parse('${ApiConfigService.apiBaseUrl}/user/status'),
        headers: {'Authorization': 'Bearer ${session.accessToken}'},
      );

      if (response.statusCode != 200) {
        throw Exception('API returned ${response.statusCode}: ${response.body}');
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final double remainingCredits = (data['credits_remaining'] as num?)?.toDouble() ?? 0.0;
      final bool hasSubscription = data['has_subscription'] == true;

      // If user has subscription, monthly budget is €16.00
      final double totalCredits = hasSubscription ? 16.0 : 0.0;
      final double usedCredits = (totalCredits - remainingCredits).clamp(0.0, totalCredits);

      if (!mounted) return;
      setState(() {
        creditBalances = CreditBalances(
          totalCredits: totalCredits,
          usedCredits: usedCredits,
          remainingCredits: remainingCredits,
        );
        creditLoading = false;
        _hasLoadedOnce = true;
      });

      // Save to cache in background
      unawaited(_saveCreditsToCache(totalCredits, remainingCredits));
      debugPrint('✅ [CreditMixin] Loaded from API: €$remainingCredits / €$totalCredits');
    } catch (error) {
      if (!mounted) return;
      setState(() {
        creditLoading = false;
        _hasLoadedOnce = true;
      });
      debugPrint('⚠️ [CreditMixin] API load failed (using cache): $error');
    }
  }

  @protected
  void disposeCreditListener() {
    if (_creditChannel != null) {
      _supabase.removeChannel(_creditChannel!);
      _creditChannel = null;
    }
  }

  double? _parseToDouble(dynamic value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
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
    final Color iconFg = theme.resolvedIconColor;
    final Color accent = theme.colorScheme.primary;

    if (creditLoading) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Center(
            child: CircularProgressIndicator(color: accent),
          ),
        ),
      );
    }

    final double percentage = creditBalances.remainingRatio;

    return Card(
      elevation: 4,
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Icon(Icons.account_balance_wallet, color: accent),
                    const SizedBox(width: 8),
                    Text(
                      'Credits',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: iconFg,
                      ),
                    ),
                  ],
                ),
                Text(
                  '€${creditBalances.remainingCredits.toStringAsFixed(2)}',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    color: accent,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: percentage,
                minHeight: 8,
                backgroundColor: iconFg.withValues(alpha: 0.2),
                valueColor: AlwaysStoppedAnimation<Color>(
                  percentage > 0.5
                      ? Colors.green
                      : percentage > 0.2
                          ? Colors.orange
                          : Colors.red,
                ),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Used: €${creditBalances.usedCredits.toStringAsFixed(2)}',
                  style: TextStyle(
                    fontSize: 12,
                    color: iconFg.withValues(alpha: 0.7),
                  ),
                ),
                Text(
                  'Total: €${creditBalances.totalCredits.toStringAsFixed(2)}',
                  style: TextStyle(
                    fontSize: 12,
                    color: iconFg.withValues(alpha: 0.7),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
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
        Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ) ??
        const TextStyle(fontSize: 14, fontWeight: FontWeight.w600);

    final EdgeInsetsGeometry resolvedPadding =
        widget.padding ?? const EdgeInsets.symmetric(horizontal: 8, vertical: 4);

    if (creditLoading) {
      final TextStyle placeholderStyle =
          widget.placeholderStyle ??
              resolvedTextStyle.copyWith(
                color: resolvedTextStyle.color?.withValues(alpha: 0.6) ??
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
        table: 'profiles',
        filter: PostgresChangeFilter(
          type: PostgresChangeFilterType.eq,
          column: 'id',
          value: user.id,
        ),
        callback: (_) => _loadBalance(silent: true),
      )
      ..subscribe();

    // Listen for network status changes - refresh when back online
    _networkListener = () {
      if (NetworkStatusService.isOnline && mounted) {
        debugPrint('🌐 [Credits] Back online - refreshing balance');
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
        debugPrint('📦 [BalanceBadge] Loaded from cache: €$_credits');
      } else {
        // No cache - keep loading state, server will provide value
        debugPrint('📦 [BalanceBadge] No cache - waiting for server');
      }
    } catch (e) {
      debugPrint('⚠️ [BalanceBadge] Cache load failed: $e');
      // On error, keep loading - server will handle it
    }
  }

  /// Save balance to local cache
  Future<void> _saveToCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(_kCachedCredits, _credits);
      await prefs.setBool(_kCachedHasSubscription, _hasSubscription);
      await prefs.setInt(_kCachedFreeMessagesRemaining, _freeMessagesRemaining);
      await prefs.setInt(_kCachedFreeMessagesTotal, _freeMessagesTotal);
    } catch (e) {
      debugPrint('⚠️ [Credits] Cache save failed: $e');
    }
  }

  Future<void> _loadBalance({bool silent = false}) async {
    if (!silent && mounted) {
      setState(() => _loading = true);
    }

    try {
      final session = _supabase.auth.currentSession;
      if (session == null) {
        if (mounted) setState(() => _loading = false);
        return;
      }

      // Load credits from API server (not Supabase)
      final response = await http.get(
        Uri.parse('${ApiConfigService.apiBaseUrl}/user/status'),
        headers: {'Authorization': 'Bearer ${session.accessToken}'},
      );

      if (response.statusCode != 200) {
        throw Exception('API returned ${response.statusCode}: ${response.body}');
      }

      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final double credits = (data['credits_remaining'] as num?)?.toDouble() ?? 0.0;
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
      debugPrint('✅ [BalanceBadge] Loaded from API: €$_credits, $_freeMessagesRemaining/$_freeMessagesTotal free');
    } catch (e) {
      debugPrint('⚠️ [BalanceBadge] API load failed (using cache): $e');
      if (mounted) setState(() => _loading = false);
      // Don't clear data on error - keep showing cached values
    }
  }

  @override
  Widget build(BuildContext context) {
    final TextStyle resolvedTextStyle =
        widget.textStyle ??
        Theme.of(context).textTheme.bodyMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                ) ??
        const TextStyle(fontSize: 14, fontWeight: FontWeight.w600);

    final EdgeInsetsGeometry resolvedPadding =
        widget.padding ?? const EdgeInsets.symmetric(horizontal: 8, vertical: 4);

    if (_loading) {
      final TextStyle placeholderStyle =
          widget.placeholderStyle ??
              resolvedTextStyle.copyWith(
                color: resolvedTextStyle.color?.withValues(alpha: 0.6) ??
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
    return Tooltip(
      message: tooltip,
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
