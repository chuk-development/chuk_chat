import 'package:flutter/material.dart';

import 'package:cowork/ui/expressive/icon_map.dart';

import 'package:cowork/platform_specific/mobile/mobile_layout.dart';
import 'package:cowork/services/automations/cowork_automation.dart';
import 'package:cowork/utils/theme_extensions.dart';
import 'package:cowork/widgets/expressive_settings.dart';

/// One automation as a settings row: what it is, when it runs, what state it
/// is in, and the actions that state allows.
///
/// The row is built like every other row in this app (see
/// `widgets/expressive_settings.dart`): a tonal icon tile, a title, one line
/// of facts under it, and the trailing controls on one baseline. Every row is
/// the same height, so a list of them reads as a column and not as a pile.
///
/// The kind is said out loud on the row — `Schedule` or `Watcher` — because
/// the two behave differently and a reader must not have to guess from an
/// icon. A long task text is one line here; a tap opens the whole of it.
///
/// Used by the thread view's strip ([compact]) and by the Automations page.
/// The actions call back; the caller sends the control frame and the row
/// updates when the host's event lands — nothing changes optimistically.
class AutomationCard extends StatefulWidget {
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

  /// A tighter layout for the strip above a chat: no task text, no expanding.
  final bool compact;

  @override
  State<AutomationCard> createState() => _AutomationCardState();
}

class _AutomationCardState extends State<AutomationCard> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final m3 = theme.m3;
    final a = widget.automation;

    final Color tone = switch (a.state) {
      'active' => scheme.primaryContainer,
      'paused' => scheme.tertiaryContainer,
      'failed' => scheme.errorContainer,
      _ => m3.surfaceContainerHighest,
    };
    final IconData icon = a.isWatcher
        ? Icons.visibility_outlined
        : Icons.schedule;

    // The kind first, then the schedule or the script, then the clock facts.
    // One term per thing: a schedule has a next time, a watcher has reports.
    final facts = <String>[
      a.isWatcher ? 'Watcher' : 'Schedule',
      a.specLabel,
      if (a.isActive && a.nextFireAt != null)
        'next ${_relative(a.nextFireAt!)}',
      if (a.lastFiredAt != null) 'last ${_relative(a.lastFiredAt!)}',
      if (a.fireCount > 0)
        a.fireCount == 1 ? 'fired once' : 'fired ${a.fireCount}×',
      if (a.suppressedCount > 0) '${a.suppressedCount} folded',
    ];

    // The task text is a full-page detail; the last error belongs everywhere,
    // including the strip above a chat — it is the reason a watcher stopped.
    final bool hasPrompt = !widget.compact && a.prompt.isNotEmpty;
    final bool hasError = a.lastError != null;
    final bool hasDetail = hasPrompt || hasError;

    final Widget row = Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // The icon tile is the same box on every row, so the text column
        // starts at the same x down the whole list.
        ExpressiveIconTile(
          icon: icon,
          tone: tone,
          size: widget.compact ? 34 : 40,
        ),
        SizedBox(width: widget.compact ? 10 : 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // The name, the state and the controls share ONE line and one
              // baseline. The badge is on every row and is always the same
              // size, so the header line is the same height on every row and
              // the right-hand column lines up down the list.
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(
                    child: Text(
                      a.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ExpressiveBadge(a.state, tone: tone),
                  if (!a.isOver) _actions(),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                facts.join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: m3.onSurfaceVariant,
                ),
              ),
              if (hasDetail) ...[
                const SizedBox(height: 6),
                if (hasPrompt)
                  Text(
                    a.prompt,
                    maxLines: _open ? 40 : 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: m3.onSurfaceVariant,
                      height: 1.35,
                    ),
                  ),
                if (hasError) ...[
                  if (hasPrompt) const SizedBox(height: 4),
                  Text(
                    a.lastError!,
                    maxLines: _open ? 20 : 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.error,
                    ),
                  ),
                ],
              ],
            ],
          ),
        ),
      ],
    );

    if (widget.compact) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        child: ExpressiveTile(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: row,
        ),
      );
    }
    return ExpressiveTile(
      onTap: hasPrompt ? () => setState(() => _open = !_open) : null,
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      child: row,
    );
  }

  /// Pause / Resume and Cancel, on the same line as the state badge. Every
  /// button is the same box, so the right edge of every row lines up.
  Widget _actions() {
    final a = widget.automation;
    final buttons = <Widget>[
      if (a.isActive && widget.onPause != null)
        _action(Icons.pause_circle_outline, 'Pause', widget.onPause!),
      if (a.isPaused && widget.onResume != null)
        _action(Icons.play_circle_outline, 'Resume', widget.onResume!),
      if (widget.onCancel != null)
        _action(Icons.cancel_outlined, 'Cancel', widget.onCancel!),
    ];
    if (buttons.isEmpty) return const SizedBox.shrink();
    return Row(mainAxisSize: MainAxisSize.min, children: buttons);
  }

  Widget _action(IconData icon, String tooltip, VoidCallback onPressed) =>
      IconButton(
        tooltip: tooltip,
        icon: AppIcon(icon, size: 20),
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        // Material's minimum: the row is dense, the target is not.
        constraints: const BoxConstraints.tightFor(
          width: MobileLayout.minTouchTarget,
          height: MobileLayout.minTouchTarget,
        ),
      );

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
