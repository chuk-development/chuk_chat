import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:chuk_chat/services/network_status_service.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';

final SupabaseClient _supabase = Supabase.instance.client;

// Cache keys for offline credit display
const String _kCachedCredits = 'cached_credits';
const String _kCachedHasSubscription = 'cached_has_subscription';
const String _kCachedFreeMessagesRemaining = 'cached_free_messages_remaining';
const String _kCachedFreeMessagesTotal = 'cached_free_messages_total';

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

    refreshCredits(reloadSilently: false);
  }

  @protected
  Future<void> refreshCredits({bool reloadSilently = false}) async {
    if (!reloadSilently || !_hasLoadedOnce) {
      if (mounted) {
        setState(() {
          creditLoading = true;
        });
      }
    }

    try {
      final user = _supabase.auth.currentUser;
      if (user == null) {
        if (!mounted) return;
        setState(() {
          creditBalances = const CreditBalances.empty();
          creditLoading = false;
          _hasLoadedOnce = true;
        });
        return;
      }

      // Get total credits allocated from profiles table
      final profileResponse = await _supabase
          .from('profiles')
          .select('total_credits_allocated')
          .eq('id', user.id)
          .single();

      final double totalCredits =
          _parseToDouble(profileResponse['total_credits_allocated']) ?? 0.0;

      // Get remaining credits via RPC function
      final creditsRemainingResponse = await _supabase.rpc(
        'get_credits_remaining',
        params: {'p_user_id': user.id},
      );

      final double remainingCredits =
          _parseToDouble(creditsRemainingResponse) ?? 0.0;

      // Calculate used credits
      final double usedCredits = totalCredits - remainingCredits;

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
    } catch (error) {
      if (!mounted) return;
      setState(() {
        creditLoading = false;
        _hasLoadedOnce = true;
      });
      debugPrint('Error loading credits: $error');
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
  bool _hasSubscription = false;
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

  /// Load cached data first for instant display, then fetch from remote
  Future<void> _loadFromCacheThenRemote() async {
    // Step 1: Load from cache immediately
    await _loadFromCache();

    // Step 2: Try to load from remote (will update cache on success)
    await _loadBalance(silent: true);
  }

  /// Load balance from local cache for offline display
  Future<void> _loadFromCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cachedCredits = prefs.getDouble(_kCachedCredits);
      final cachedHasSub = prefs.getBool(_kCachedHasSubscription);
      final cachedFreeRemaining = prefs.getInt(_kCachedFreeMessagesRemaining);
      final cachedFreeTotal = prefs.getInt(_kCachedFreeMessagesTotal);

      if (cachedCredits != null || cachedFreeRemaining != null) {
        if (!mounted) return;
        setState(() {
          _credits = cachedCredits ?? 0.0;
          _hasSubscription = cachedHasSub ?? false;
          _freeMessagesRemaining = cachedFreeRemaining ?? 0;
          _freeMessagesTotal = cachedFreeTotal ?? 10;
          _loading = false;
        });
        debugPrint('📦 [Credits] Loaded from cache: €$_credits, $_freeMessagesRemaining/$_freeMessagesTotal free');
      }
    } catch (e) {
      debugPrint('⚠️ [Credits] Cache load failed: $e');
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
      final user = _supabase.auth.currentUser;
      if (user == null) {
        if (mounted) setState(() => _loading = false);
        return;
      }

      // Fetch profile data including credits and free messages
      final profile = await _supabase
          .from('profiles')
          .select('total_credits_allocated, current_plan, free_messages_total, free_messages_used')
          .eq('id', user.id)
          .single();

      // Get remaining credits via RPC
      final creditsResponse = await _supabase.rpc(
        'get_credits_remaining',
        params: {'p_user_id': user.id},
      );

      final double credits = (creditsResponse is num) ? creditsResponse.toDouble() : 0.0;
      final bool hasSubscription = profile['current_plan'] != null;
      final int freeTotal = (profile['free_messages_total'] as int?) ?? 10;
      final int freeUsed = (profile['free_messages_used'] as int?) ?? 0;
      final int freeRemaining = (freeTotal - freeUsed).clamp(0, freeTotal);

      if (!mounted) return;
      setState(() {
        _credits = credits;
        _hasSubscription = hasSubscription;
        _freeMessagesTotal = freeTotal;
        _freeMessagesRemaining = freeRemaining;
        _loading = false;
      });

      // Save to cache for offline access
      await _saveToCache();
      debugPrint('✅ [Credits] Loaded from remote: €$_credits, $_freeMessagesRemaining/$_freeMessagesTotal free');
    } catch (e) {
      debugPrint('⚠️ [Credits] Remote load failed (using cache): $e');
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
        child: Text('--', style: placeholderStyle),
      );
    }

    // Subscribed user with credits > 0.01: show credits
    if (_hasSubscription || _credits >= 0.01) {
      final String formatted = '€${_credits.toStringAsFixed(2)}';
      return Tooltip(
        message: 'Remaining credits: $formatted',
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

    // Non-subscribed user: show free messages
    final Color badgeColor;
    if (_freeMessagesRemaining == 0) {
      badgeColor = Colors.red;
    } else if (_freeMessagesRemaining <= 3) {
      badgeColor = Colors.orange;
    } else {
      badgeColor = Theme.of(context).colorScheme.primary;
    }

    final String freeFormatted = '$_freeMessagesRemaining/$_freeMessagesTotal free';

    return Tooltip(
      message: _freeMessagesRemaining == 0
          ? 'No free messages remaining. Subscribe to continue.'
          : '$_freeMessagesRemaining of $_freeMessagesTotal free messages remaining',
      waitDuration: const Duration(milliseconds: 500),
      child: Container(
        padding: resolvedPadding,
        decoration: BoxDecoration(
          color: badgeColor.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          freeFormatted,
          style: resolvedTextStyle.copyWith(color: badgeColor),
        ),
      ),
    );
  }
}
