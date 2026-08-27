import 'package:flutter/material.dart';
import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/app_mode.dart';

/// Compact top-left segmented control that toggles between Chat and CoWork.
///
/// Same app, runtime mode — no navigation/router change. Rendered only when
/// [kFeatureCoWork] is enabled by the call sites (desktop + mobile shells).
class CoWorkModeSwitcher extends StatelessWidget {
  const CoWorkModeSwitcher({
    super.key,
    required this.mode,
    required this.onChanged,
    this.compact = false,
  });

  final AppMode mode;
  final ValueChanged<AppMode> onChanged;

  /// When true, renders icon-only segments (used in tight mobile app bars).
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context)!;
    final scheme = Theme.of(context).colorScheme;

    Widget segment({
      required AppMode value,
      required IconData icon,
      required String label,
    }) {
      final selected = mode == value;
      final fg = selected ? scheme.onPrimary : scheme.onSurfaceVariant;
      return Semantics(
        button: true,
        selected: selected,
        label: label,
        child: InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: selected
              ? null
              : () {
                  // Mirror into the app-global notifier so the service layer
                  // (prompt builder) sees the mode change, then drive the
                  // shell's own state as before.
                  appModeNotifier.value = value;
                  onChanged(value);
                },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: EdgeInsets.symmetric(
              horizontal: compact ? 10 : 12,
              vertical: 6,
            ),
            decoration: BoxDecoration(
              color: selected ? scheme.primary : Colors.transparent,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 16, color: fg),
                if (!compact) ...[
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: TextStyle(
                      color: fg,
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(21),
        border: Border.all(color: scheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          segment(
            value: AppMode.chat,
            icon: Icons.chat_bubble_outline_rounded,
            label: l.chatMode,
          ),
          const SizedBox(width: 2),
          segment(
            value: AppMode.cowork,
            icon: Icons.hub_outlined,
            label: l.coworkMode,
          ),
        ],
      ),
    );
  }
}
