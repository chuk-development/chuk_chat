/// Expressive feedback surfaces: the floating pill toast, the big-cornered
/// modal sheet and the tappable action row used inside it.
library;

import 'package:flutter/material.dart';

import 'package:cowork/ui/expressive/motion.dart';

/// A floating pill toast — the expressive replacement for a flat SnackBar.
void pillToast(BuildContext context, String message, {IconData? icon}) {
  final ColorScheme scheme = Theme.of(context).colorScheme;
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  messenger.clearSnackBars();
  messenger.showSnackBar(
    SnackBar(
      behavior: SnackBarBehavior.floating,
      backgroundColor: scheme.inverseSurface,
      elevation: 6,
      duration: const Duration(milliseconds: 1800),
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 96),
      shape: const StadiumBorder(),
      padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
      content: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, color: scheme.onInverseSurface, size: 20),
            const SizedBox(width: 12),
          ],
          Flexible(
            child: Text(
              message,
              style: TextStyle(
                color: scheme.onInverseSurface,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

/// An expressive modal sheet: 36 px top corners, a drag handle, generous pad.
Future<T?> expressiveSheet<T>(
  BuildContext context, {
  required String title,
  required Widget child,
}) {
  final ColorScheme scheme = Theme.of(context).colorScheme;
  final TextTheme text = Theme.of(context).textTheme;
  return showModalBottomSheet<T>(
    context: context,
    backgroundColor: scheme.surfaceContainerLow,
    showDragHandle: false,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(36)),
    ),
    isScrollControlled: true,
    builder: (BuildContext context) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 14, 24, 28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: scheme.outlineVariant,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text(title, style: text.headlineSmall),
            const SizedBox(height: 18),
            child,
          ],
        ),
      ),
    ),
  );
}

/// A big tappable action row for an expressive sheet.
class SheetAction extends StatelessWidget {
  const SheetAction({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.color,
    this.subtitle,
    this.enabled = true,
  });

  final IconData icon;
  final String label;
  final String? subtitle;
  final Color? color;
  final VoidCallback onTap;

  /// A parked action (the voice call) is rendered dimmed and does not fire.
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color c = color ?? scheme.primary;
    final double alpha = enabled ? 1.0 : 0.45;
    return Opacity(
      opacity: alpha,
      child: MorphTap(
        onTap: enabled ? onTap : null,
        color: scheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        pressedShape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: ShapeDecoration(
                color: c.withValues(alpha: 0.16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
              child: Icon(icon, color: c, size: 22),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    label,
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: scheme.onSurfaceVariant),
          ],
        ),
      ),
    );
  }
}
