import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';

final SupabaseClient _supabase = Supabase.instance.client;

/// Data class holding free message quota information
class FreeMessageQuota {
  const FreeMessageQuota({
    required this.total,
    required this.used,
    required this.remaining,
  });

  const FreeMessageQuota.empty()
      : total = 10,
        used = 0,
        remaining = 10;

  final int total;
  final int used;
  final int remaining;

  bool get hasRemaining => remaining > 0;
  double get usedRatio => total > 0 ? used / total : 0.0;
}

/// Mixin for listening to free message quota updates
mixin _FreeMessageListenerMixin<T extends StatefulWidget> on State<T> {
  FreeMessageQuota freeMessageQuota = const FreeMessageQuota.empty();
  bool freeMessageLoading = true;

  RealtimeChannel? _freeMessageChannel;
  bool _hasLoadedOnce = false;

  @protected
  void initFreeMessageListener({String? channelName}) {
    final String resolvedChannelName =
        channelName ?? 'free_message_updates_${identityHashCode(this)}';

    // Ensure previous channel is cleaned up before creating a new one
    _freeMessageChannel?.unsubscribe();
    _freeMessageChannel = _supabase.channel(resolvedChannelName)
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
          refreshFreeMessages(reloadSilently: true);
        },
      )
      ..subscribe();

    refreshFreeMessages(reloadSilently: false);
  }

  @protected
  Future<void> refreshFreeMessages({bool reloadSilently = false}) async {
    if (!reloadSilently || !_hasLoadedOnce) {
      if (mounted) {
        setState(() {
          freeMessageLoading = true;
        });
      }
    }

    try {
      final user = _supabase.auth.currentUser;
      if (user == null) {
        if (!mounted) return;
        setState(() {
          freeMessageQuota = const FreeMessageQuota.empty();
          freeMessageLoading = false;
          _hasLoadedOnce = true;
        });
        return;
      }

      // Get free message info from profiles table
      final profileResponse = await _supabase
          .from('profiles')
          .select('free_messages_total, free_messages_used')
          .eq('id', user.id)
          .single();

      final int total = _parseToInt(profileResponse['free_messages_total']) ?? 10;
      final int used = _parseToInt(profileResponse['free_messages_used']) ?? 0;
      final int remaining = (total - used).clamp(0, total);

      if (!mounted) return;
      setState(() {
        freeMessageQuota = FreeMessageQuota(
          total: total,
          used: used,
          remaining: remaining,
        );
        freeMessageLoading = false;
        _hasLoadedOnce = true;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        freeMessageLoading = false;
        _hasLoadedOnce = true;
      });
      debugPrint('Error loading free messages: $error');
    }
  }

  @protected
  void disposeFreeMessageListener() {
    if (_freeMessageChannel != null) {
      _supabase.removeChannel(_freeMessageChannel!);
      _freeMessageChannel = null;
    }
  }

  int? _parseToInt(dynamic value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }
}

/// Full-featured free message display card
class FreeMessageDisplay extends StatefulWidget {
  const FreeMessageDisplay({super.key});

  @override
  State<FreeMessageDisplay> createState() => _FreeMessageDisplayState();
}

class _FreeMessageDisplayState extends State<FreeMessageDisplay>
    with _FreeMessageListenerMixin<FreeMessageDisplay> {
  @override
  void initState() {
    super.initState();
    initFreeMessageListener();
  }

  @override
  void dispose() {
    disposeFreeMessageListener();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Color iconFg = theme.resolvedIconColor;
    final Color accent = theme.colorScheme.primary;

    if (freeMessageLoading) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16.0),
          child: Center(
            child: CircularProgressIndicator(color: accent),
          ),
        ),
      );
    }

    final double percentage = 1.0 - freeMessageQuota.usedRatio;

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
                    Icon(Icons.chat_bubble_outline, color: accent),
                    const SizedBox(width: 8),
                    Text(
                      'Free Messages',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: iconFg,
                      ),
                    ),
                  ],
                ),
                Text(
                  '${freeMessageQuota.remaining}/${freeMessageQuota.total}',
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
                  'Used: ${freeMessageQuota.used}',
                  style: TextStyle(
                    fontSize: 12,
                    color: iconFg.withValues(alpha: 0.7),
                  ),
                ),
                Text(
                  'Total: ${freeMessageQuota.total}',
                  style: TextStyle(
                    fontSize: 12,
                    color: iconFg.withValues(alpha: 0.7),
                  ),
                ),
              ],
            ),
            if (!freeMessageQuota.hasRemaining) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.warning_amber_rounded,
                        color: Colors.red, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Subscribe to continue chatting',
                        style: TextStyle(
                          color: Colors.red.shade700,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Compact badge showing free message count
class FreeMessageBadge extends StatefulWidget {
  const FreeMessageBadge({
    super.key,
    this.textStyle,
    this.placeholderStyle,
    this.padding,
    this.showOnlyWhenLow = false,
    this.lowThreshold = 3,
  });

  final TextStyle? textStyle;
  final TextStyle? placeholderStyle;
  final EdgeInsetsGeometry? padding;

  /// If true, only show the badge when remaining messages are below threshold
  final bool showOnlyWhenLow;

  /// Threshold for "low" messages (default 3)
  final int lowThreshold;

  @override
  State<FreeMessageBadge> createState() => _FreeMessageBadgeState();
}

class _FreeMessageBadgeState extends State<FreeMessageBadge>
    with _FreeMessageListenerMixin<FreeMessageBadge> {
  @override
  void initState() {
    super.initState();
    initFreeMessageListener();
  }

  @override
  void dispose() {
    disposeFreeMessageListener();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final TextStyle resolvedTextStyle = widget.textStyle ??
        Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
            ) ??
        const TextStyle(fontSize: 14, fontWeight: FontWeight.w600);

    final EdgeInsetsGeometry resolvedPadding =
        widget.padding ?? const EdgeInsets.symmetric(horizontal: 8, vertical: 4);

    if (freeMessageLoading) {
      final TextStyle placeholderStyle = widget.placeholderStyle ??
          resolvedTextStyle.copyWith(
            color: resolvedTextStyle.color?.withValues(alpha: 0.6) ??
                Theme.of(context).hintColor,
          );

      return Padding(
        padding: resolvedPadding,
        child: Text('Free: --', style: placeholderStyle),
      );
    }

    // Hide if showOnlyWhenLow is true and messages are above threshold
    if (widget.showOnlyWhenLow &&
        freeMessageQuota.remaining > widget.lowThreshold) {
      return const SizedBox.shrink();
    }

    final String formatted =
        'Free: ${freeMessageQuota.remaining}/${freeMessageQuota.total}';

    // Color based on remaining messages
    Color badgeColor;
    if (freeMessageQuota.remaining == 0) {
      badgeColor = Colors.red;
    } else if (freeMessageQuota.remaining <= widget.lowThreshold) {
      badgeColor = Colors.orange;
    } else {
      badgeColor = Theme.of(context).colorScheme.primary;
    }

    return Tooltip(
      message: freeMessageQuota.remaining == 0
          ? 'No free messages remaining. Subscribe to continue.'
          : '${freeMessageQuota.remaining} free messages remaining',
      waitDuration: const Duration(milliseconds: 500),
      child: Container(
        padding: resolvedPadding,
        decoration: BoxDecoration(
          color: badgeColor.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          formatted,
          style: resolvedTextStyle.copyWith(color: badgeColor),
        ),
      ),
    );
  }
}

/// Static helper to check free messages remaining (for use in chat UI)
class FreeMessageService {
  FreeMessageService._();

  /// Check remaining free messages for current user
  /// Returns null if user is not logged in
  static Future<int?> getRemainingFreeMessages() async {
    try {
      final user = _supabase.auth.currentUser;
      if (user == null) return null;

      final response = await _supabase
          .from('profiles')
          .select('free_messages_total, free_messages_used')
          .eq('id', user.id)
          .single();

      final int total = (response['free_messages_total'] as int?) ?? 10;
      final int used = (response['free_messages_used'] as int?) ?? 0;

      return (total - used).clamp(0, total);
    } catch (e) {
      debugPrint('Error getting free messages: $e');
      return null;
    }
  }

  /// Check if user has any remaining free messages
  static Future<bool> hasFreeMessages() async {
    final remaining = await getRemainingFreeMessages();
    return remaining != null && remaining > 0;
  }
}
