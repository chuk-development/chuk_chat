// lib/platform_specific/chat/widgets/mobile_chat_widgets.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
// Agents imported ui/expressive/icon_map.dart and ui/expressive/waveform.dart
// here. Both are byte copies of the widgets/ files below, so importing both
// would make AppIcon and LiveWaveform ambiguous.
import 'package:chuk_chat/utils/shift_key_tracker.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/icons/icon_map.dart';

/// Build a tiny icon button widget
Widget buildTinyIconButton({
  IconData? icon,
  String? svgAssetPath,
  required VoidCallback? onTap,
  required bool isActive,
  required Color color,
  double buttonSize = 38,
  double cornerRadius = 12,
  double iconSize = 18,
  String? semanticsId,
}) {
  assert(
    icon != null || svgAssetPath != null,
    'Either icon or svgAssetPath must be provided.',
  );
  final Color effectiveColor = isActive ? color : color.withValues(alpha: 0.6);

  final result = Material(
    color: Colors.transparent,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(cornerRadius),
      child: Container(
        width: buttonSize,
        height: buttonSize,
        decoration: BoxDecoration(
          color: isActive ? color.withValues(alpha: 0.15) : Colors.transparent,
          borderRadius: BorderRadius.circular(cornerRadius),
        ),
        child: svgAssetPath != null
            ? SvgPicture.asset(
                svgAssetPath,
                width: iconSize,
                height: iconSize,
                colorFilter: ColorFilter.mode(effectiveColor, BlendMode.srcIn),
              )
            : AppIcon(icon!, size: iconSize, color: effectiveColor),
      ),
    ),
  );
  if (semanticsId != null) {
    return Semantics(identifier: semanticsId, child: result);
  }
  return result;
}

/// Build a tiny action button widget (for send, etc.)
Widget buildTinyActionButton({
  IconData? icon,
  String? svgAssetPath,
  required VoidCallback onTap,
  required Color color,
  bool isLoading = false,
  double buttonSize = 40,
  double iconSize = 16,
  String? semanticsId,
}) {
  assert(
    icon != null || svgAssetPath != null,
    'Either icon or svgAssetPath must be provided.',
  );
  // A Builder rather than a context parameter: every call site already sits
  // under a Theme, and threading one through would touch all of them.
  final result = Builder(
    builder: (BuildContext context) {
      final Color foregroundColor = Theme.of(
        context,
      ).accentButtonForeground(color);
            return Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: isLoading ? null : onTap,
            borderRadius: BorderRadius.circular(buttonSize / 2),
            child: Container(
              width: buttonSize,
              height: buttonSize,
              // Flat fill, no sheen and no coloured shadow. The button is the one
              // accent-coloured thing down here; a glow around it only smears that
              // colour into the composer behind it.
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              child: isLoading
                  ? Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(foregroundColor),
                      ),
                    )
                  : svgAssetPath != null
                  ? SvgPicture.asset(
                      svgAssetPath,
                      width: iconSize,
                      height: iconSize,
                      colorFilter: ColorFilter.mode(foregroundColor, BlendMode.srcIn),
                    )
            : AppIcon(icon!, size: iconSize, color: foregroundColor),
          ),
        ),
      );
    },
  );
  if (semanticsId != null) {
    return Semantics(identifier: semanticsId, child: result);
  }
  return result;
}

/// Build attachment sheet option (for bottom sheet)
Widget buildAttachmentSheetOption({
  required BuildContext context,
  required IconData icon,
  required String label,
  required VoidCallback onTap,
  required bool isEnabled,
}) {
  final theme = Theme.of(context);
  final Color background = isEnabled
      ? theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6)
      : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3);
  final Color borderColor = isEnabled
      ? theme.dividerColor.withValues(alpha: 0.2)
      : theme.dividerColor.withValues(alpha: 0.1);
  final Color foreground = isEnabled
      ? theme.colorScheme.onSurface
      : theme.colorScheme.onSurface.withValues(alpha: 0.3);

  return Expanded(
    child: Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: isEnabled ? onTap : null,
        borderRadius: BorderRadius.circular(16),
        child: Ink(
          height: 84,
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: borderColor),
          ),
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AppIcon(icon, color: foreground, size: 22),
              const SizedBox(height: 6),
              Text(
                label,
                style: TextStyle(
                  color: foreground,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// Build keyboard listener for text field (handles Enter/Shift+Enter)
Widget buildKeyboardListener({
  required FocusNode focusNode,
  required TextEditingController controller,
  required VoidCallback onSend,
  required Widget child,
}) {
  return KeyboardListener(
    focusNode: focusNode,
    onKeyEvent: (event) {
      if (event is! KeyDownEvent) return;
      if (event.logicalKey != LogicalKeyboardKey.enter) return;

      if (isShiftKeyPressed) {
        final value = controller.value;
        final updatedText = value.text.replaceRange(
          value.selection.start,
          value.selection.end,
          '\n',
        );
        controller.value = value.copyWith(
          text: updatedText,
          selection: TextSelection.collapsed(offset: value.selection.start + 1),
        );
        return;
      }

      onSend();
    },
    child: child,
  );
}
