// lib/platform_specific/chat/widgets/mobile_chat_widgets.dart

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:chuk_chat/ui/expressive/icon_map.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:chuk_chat/ui/expressive/waveform.dart';
import 'package:chuk_chat/utils/shift_key_tracker.dart';

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
        // Flat fill, no coloured shadow: a button that glows in its own colour
        // is the one effect this app does not use (docs/DESIGN.md).
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

/// Row one of the mobile composer: the text field, and — while the microphone
/// is open — the live waveform drawn in its place.
///
/// The field is kept in the layout while it is hidden ([Visibility] with
/// `maintainSize`), so the composer keeps exactly the height it had at rest.
/// Recording must not make the box taller: a taller box pushes the thread up
/// the moment the microphone opens. Do not replace this with a branch that
/// swaps in a row of its own height.
class ComposerInputRow extends StatelessWidget {
  const ComposerInputRow({
    super.key,
    required this.isRecording,
    required this.audioLevels,
    required this.accentColor,
    required this.timeColor,
    required this.child,
  });

  final bool isRecording;

  /// The recorder's rolling level buffer (0..1, oldest first).
  final List<double> audioLevels;

  /// The colour of the bars.
  final Color accentColor;

  /// The colour of the elapsed time.
  final Color timeColor;

  /// The text field of the composer.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        Visibility(
          visible: !isRecording,
          maintainSize: true,
          maintainState: true,
          maintainAnimation: true,
          child: child,
        ),
        if (isRecording)
          Positioned.fill(
            child: RecordingWaveformBar(
              audioLevels: audioLevels,
              color: accentColor,
              timeColor: timeColor,
            ),
          ),
      ],
    );
  }
}

/// The open microphone: the live waveform, and the elapsed time beside it.
///
/// Nothing else. The bars are the same rounded, round-capped bars a voice
/// message is drawn with in the reference messenger (see [LiveWaveform]), so
/// dictating and listening look like one feature.
class RecordingWaveformBar extends StatefulWidget {
  const RecordingWaveformBar({
    super.key,
    required this.audioLevels,
    required this.color,
    required this.timeColor,
  });

  final List<double> audioLevels;
  final Color color;
  final Color timeColor;

  @override
  State<RecordingWaveformBar> createState() => _RecordingWaveformBarState();
}

class _RecordingWaveformBarState extends State<RecordingWaveformBar> {
  final Stopwatch _clock = Stopwatch();
  Timer? _ticker;
  Duration _elapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    _clock.start();
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (Timer _) {
      if (!mounted) return;
      setState(() => _elapsed = _clock.elapsed);
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _clock.stop();
    super.dispose();
  }

  static String _format(Duration value) {
    final int minutes = value.inMinutes;
    final int seconds = value.inSeconds % 60;
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Expanded(
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final double room = constraints.maxHeight.isFinite
                  ? constraints.maxHeight
                  : 26;
              return LiveWaveform(
                levels: widget.audioLevels,
                color: widget.color,
                height: math.min(26, math.max(12, room)),
              );
            },
          ),
        ),
        const SizedBox(width: 10),
        Text(
          _format(_elapsed),
          style: TextStyle(
            color: widget.timeColor,
            fontSize: 13,
            height: 1.0,
            fontWeight: FontWeight.w600,
            fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(width: 4),
      ],
    );
  }
}
