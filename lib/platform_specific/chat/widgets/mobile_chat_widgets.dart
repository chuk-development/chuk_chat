// lib/platform_specific/chat/widgets/mobile_chat_widgets.dart

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:cowork/ui/expressive/waveform.dart';
import 'package:cowork/utils/shift_key_tracker.dart';

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
            : Icon(icon!, size: iconSize, color: effectiveColor),
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
  final Color foregroundColor = color.computeLuminance() > 0.5
      ? Colors.black
      : Colors.white;

  final result = Material(
    color: Colors.transparent,
    child: InkWell(
      onTap: isLoading ? null : onTap,
      borderRadius: BorderRadius.circular(buttonSize / 2),
      child: Container(
        width: buttonSize,
        height: buttonSize,
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
            : Icon(icon!, size: iconSize, color: foregroundColor),
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
          padding: const EdgeInsets.symmetric(vertical: 14),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: foreground, size: 22),
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

/// The live microphone level, in the expressive waveform shape.
///
/// The bars are the same rounded, round-capped bars a voice message is drawn
/// with in the reference messenger (see [LiveWaveform]), so dictating and
/// listening look like one feature.
Widget buildAudioVisualizer({
  required List<double> audioLevels,
  required Color accentColor,
}) {
  return LiveWaveform(levels: audioLevels, color: accentColor, height: 26);
}

/// Build recording indicator (pulsating red dot)
Widget buildRecordingIndicator() {
  return const _PulsatingRecordingIndicator();
}

class _PulsatingRecordingIndicator extends StatefulWidget {
  const _PulsatingRecordingIndicator();

  @override
  State<_PulsatingRecordingIndicator> createState() =>
      _PulsatingRecordingIndicatorState();
}

class _PulsatingRecordingIndicatorState
    extends State<_PulsatingRecordingIndicator>
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
    _animation = Tween<double>(
      begin: 0.4,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeInOut));
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
