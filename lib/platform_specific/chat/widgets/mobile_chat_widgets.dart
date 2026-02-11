// lib/platform_specific/chat/widgets/mobile_chat_widgets.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Build a tiny icon button widget
Widget buildTinyIconButton({
  required IconData icon,
  required VoidCallback? onTap,
  required bool isActive,
  required Color color,
  String? semanticsId,
}) {
  final result = Material(
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
  if (semanticsId != null) {
    return Semantics(identifier: semanticsId, child: result);
  }
  return result;
}

/// Build a tiny action button widget (for send, etc.)
Widget buildTinyActionButton({
  required IconData icon,
  required VoidCallback onTap,
  required Color color,
  bool isLoading = false,
  String? semanticsId,
}) {
  final result = Material(
    color: Colors.transparent,
    child: InkWell(
      onTap: isLoading ? null : onTap,
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
        child: isLoading
            ? Padding(
                padding: const EdgeInsets.all(8.0),
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              )
            : Icon(icon, size: 16, color: Colors.white),
      ),
    ),
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

/// Build audio visualizer widget with live amplitude response
Widget buildAudioVisualizer({
  required List<double> audioLevels,
  required Color accentColor,
}) {
  // Use the last 24 samples for smooth, responsive visualization
  const int barCount = 24;
  final int startIndex = audioLevels.length > barCount
      ? audioLevels.length - barCount
      : 0;

  return SizedBox(
    height: 24,
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: List.generate(barCount, (index) {
        final int levelIndex = startIndex + index;
        final double rawLevel = levelIndex < audioLevels.length
            ? audioLevels[levelIndex]
            : 0.0;

        // Apply exponential scaling for more dramatic response
        final double level = rawLevel * rawLevel;

        // Calculate bar height with better range (3-22px)
        final double barHeight = (level * 20 + 3).clamp(3.0, 22.0);

        // Vary opacity based on level for depth effect
        final double opacity = (0.6 + (level * 0.4)).clamp(0.6, 1.0);

        return Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 0.8),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 50),
              curve: Curves.easeOut,
              height: barHeight,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    accentColor.withValues(alpha: opacity),
                    accentColor.withValues(alpha: opacity * 0.7),
                  ],
                ),
                borderRadius: BorderRadius.circular(2),
                boxShadow: level > 0.3 ? [
                  BoxShadow(
                    color: accentColor.withValues(alpha: 0.3),
                    blurRadius: 2,
                    spreadRadius: 0.5,
                  ),
                ] : null,
              ),
            ),
          ),
        );
      }),
    ),
  );
}

/// Build recording indicator (pulsating red dot)
Widget buildRecordingIndicator() {
  return const _PulsatingRecordingIndicator();
}

class _PulsatingRecordingIndicator extends StatefulWidget {
  const _PulsatingRecordingIndicator();

  @override
  State<_PulsatingRecordingIndicator> createState() => _PulsatingRecordingIndicatorState();
}

class _PulsatingRecordingIndicatorState extends State<_PulsatingRecordingIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat(reverse: true);
    _animation = Tween<double>(begin: 0.4, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _animation,
      builder: (context, child) {
        return Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: Colors.red.withValues(alpha: _animation.value),
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: Colors.red.withValues(alpha: _animation.value * 0.6),
                blurRadius: 6 * _animation.value,
                spreadRadius: 1.5 * _animation.value,
              ),
            ],
          ),
        );
      },
    );
  }
}
