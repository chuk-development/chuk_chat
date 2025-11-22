import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';

final SupabaseClient _supabase = Supabase.instance.client;

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
