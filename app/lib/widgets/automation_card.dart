import 'package:flutter/material.dart';

import 'package:cowork/services/automations/cowork_automation.dart';

/// One automation as a card: name, spec, state, next / last fire, count,
/// and the actions the state allows (Pause / Resume, Cancel).
///
/// Used by the thread view's strip (compact) and by the Automations page
/// (full). The actions call back; the caller sends the control frame and the
/// card updates when the host's event lands — nothing changes optimistically.
class AutomationCard extends StatelessWidget {
  const AutomationCard({
    super.key,
    required this.automation,
    this.onPause,
    this.onResume,
    this.onCancel,
    this.compact = false,
  });

  final CoworkAutomation automation;
  final VoidCallback? onPause;
  final VoidCallback? onResume;
  final VoidCallback? onCancel;

  /// A tighter layout for the strip above a chat.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final a = automation;
    final icon = a.isWatcher ? Icons.visibility_outlined : Icons.schedule;
    final stateColor = switch (a.state) {
      'active' => scheme.primary,
      'paused' => scheme.tertiary,
      'failed' => scheme.error,
      _ => scheme.onSurfaceVariant,
    };
    final details = <String>[
      a.specLabel,
      if (a.isActive && a.nextFireAt != null) 'next ${_relative(a.nextFireAt!)}',
      if (a.lastFiredAt != null) 'last ${_relative(a.lastFiredAt!)}',
      if (a.fireCount > 0)
        a.fireCount == 1 ? 'fired once' : 'fired ${a.fireCount}×',
      if (a.suppressedCount > 0) '${a.suppressedCount} folded',
    ];
    return Card(
      margin: compact
          ? const EdgeInsets.symmetric(horizontal: 12, vertical: 4)
          : const EdgeInsets.symmetric(horizontal: 0, vertical: 6),
      child: Padding(
        padding: EdgeInsets.fromLTRB(12, compact ? 8 : 12, 8, compact ? 8 : 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 20, color: stateColor),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          a.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.titleSmall
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                      ),
                      const SizedBox(width: 8),
                      _StatePill(state: a.state, color: stateColor),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    details.join(' · '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant),
                  ),
                  if (!compact && a.prompt.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      a.prompt,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                  if (a.lastError != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      a.lastError!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall
                          ?.copyWith(color: scheme.error),
                    ),
                  ],
                ],
              ),
            ),
            if (!a.isOver) ...[
              if (a.isActive && onPause != null)
                IconButton(
                  tooltip: 'Pause',
                  icon: const Icon(Icons.pause_circle_outline),
                  onPressed: onPause,
                ),
              if (a.isPaused && onResume != null)
                IconButton(
                  tooltip: 'Resume',
                  icon: const Icon(Icons.play_circle_outline),
                  onPressed: onResume,
                ),
              if (onCancel != null)
                IconButton(
                  tooltip: 'Cancel',
                  icon: const Icon(Icons.cancel_outlined),
                  onPressed: onCancel,
                ),
            ],
          ],
        ),
      ),
    );
  }

  static String _relative(DateTime when) {
    final now = DateTime.now();
    final delta = when.difference(now);
    final abs = delta.abs();
    String unit;
    if (abs.inSeconds < 60) {
      unit = '${abs.inSeconds}s';
    } else if (abs.inMinutes < 60) {
      unit = '${abs.inMinutes}m';
    } else if (abs.inHours < 48) {
      unit = '${abs.inHours}h';
    } else {
      unit = '${abs.inDays}d';
    }
    return delta.isNegative ? '$unit ago' : 'in $unit';
  }
}

class _StatePill extends StatelessWidget {
  const _StatePill({required this.state, required this.color});

  final String state;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        state,
        style: Theme.of(context)
            .textTheme
            .labelSmall
            ?.copyWith(color: color, fontWeight: FontWeight.w600),
      ),
    );
  }
}
