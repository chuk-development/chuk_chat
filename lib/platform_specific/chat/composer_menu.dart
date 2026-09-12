// lib/platform_specific/chat/composer_menu.dart
import 'package:flutter/material.dart';

import 'package:cowork/ui/expressive/icon_map.dart';
import 'package:cowork/utils/theme_extensions.dart';
import 'package:cowork/widgets/anchored_menu.dart';

/// One row of a composer menu — same metrics as the mode menu.
PopupMenuItem<T> composerMenuRow<T>({
  required T value,
  required Color iconFg,
  required IconData icon,
  required String label,
  bool isEnabled = true,
  bool isSelected = false,
}) {
  final Color color = isEnabled ? iconFg : iconFg.withValues(alpha: 0.35);

  return PopupMenuItem<T>(
    value: value,
    enabled: isEnabled,
    height: 40,
    padding: const EdgeInsets.symmetric(horizontal: 16),
    child: Row(
      children: [
        AppIcon(icon, size: 18, color: color),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            label,
            softWrap: false,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: color, fontWeight: FontWeight.w600),
          ),
        ),
        if (isSelected) ...[
          const SizedBox(width: 12),
          AppIcon(Icons.check, size: 18, color: color),
        ],
      ],
    ),
  );
}

/// Open a menu anchored to a composer button. It leaves the focus and
/// so the keyboard alone.
Future<T?> showAnchoredComposerMenu<T>({
  required BuildContext anchorContext,
  required List<PopupMenuEntry<T>> items,
}) {
  final theme = Theme.of(anchorContext);
  return showAnchoredMenu<T>(
    anchorContext,
    items: items,
    color: theme.scaffoldBackgroundColor.withValues(alpha: 0.94),
    borderColor: theme.resolvedIconColor.withValues(alpha: 0.3),
  );
}
