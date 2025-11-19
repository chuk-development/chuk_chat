// lib/platform_specific/chat/widgets/mobile_chat_widgets.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Build a tiny icon button widget
Widget buildTinyIconButton({
  required IconData icon,
  required VoidCallback? onTap,
  required bool isActive,
  required Color color,
}) {
  return Material(
    color: Colors.transparent,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          color: isActive
              ? color.withValues(alpha: 0.15)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(
          icon,
          size: 18,
          color: isActive ? color : color.withValues(alpha: 0.6),
        ),
      ),
    ),
  );
}

/// Build a tiny action button widget (for send, etc.)
Widget buildTinyActionButton({
  required IconData icon,
  required VoidCallback onTap,
  required Color color,
}) {
  return Material(
    color: Colors.transparent,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        width: 32,
        height: 32,
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [color, color.withValues(alpha: 0.85)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.25),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Icon(icon, size: 16, color: Colors.white),
      ),
    ),
  );
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
          padding: const EdgeInsets.symmetric(vertical: 16),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: foreground),
              const SizedBox(height: 8),
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

      final isShiftPressed = HardwareKeyboard.instance.isShiftPressed;
      if (isShiftPressed) {
        final value = controller.value;
        final updatedText = value.text.replaceRange(
          value.selection.start,
          value.selection.end,
          '\n',
        );
        controller.value = value.copyWith(
          text: updatedText,
          selection: TextSelection.collapsed(
            offset: value.selection.start + 1,
          ),
        );
        return;
      }

      onSend();
    },
    child: child,
  );
}

/// Build audio visualizer widget
Widget buildAudioVisualizer({
  required List<double> audioLevels,
  required Color accentColor,
}) {
  return SizedBox(
    height: 20,
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: List.generate(10, (index) {
        final double level = index < audioLevels.length
            ? audioLevels[index]
            : 0.0;
        final double barHeight = (level * 16).clamp(2.0, 16.0);
        return Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 0.5),
            child: Container(
              height: barHeight,
              decoration: BoxDecoration(
                color: accentColor.withValues(alpha: 0.8),
                borderRadius: BorderRadius.circular(1.5),
              ),
            ),
          ),
        );
      }),
    ),
  );
}

/// Build recording indicator (red dot)
Widget buildRecordingIndicator() {
  return Container(
    width: 6,
    height: 6,
    decoration: const BoxDecoration(
      color: Colors.red,
      shape: BoxShape.circle,
    ),
  );
}
