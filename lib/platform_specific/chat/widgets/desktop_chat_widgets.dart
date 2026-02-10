// lib/platform_specific/chat/widgets/desktop_chat_widgets.dart
import 'package:flutter/material.dart';
import 'dart:math' as math;

/// Build icon button for desktop UI
Widget buildDesktopIconButton({
  required IconData icon,
  required VoidCallback onTap,
  required bool isActive,
  required Color iconFg,
  required Color bg,
  String? debugLabel,
}) {
  final ValueNotifier<bool> isHovered = ValueNotifier<bool>(false);

  return MouseRegion(
    onEnter: (_) => isHovered.value = true,
    onExit: (_) => isHovered.value = false,
    child: InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      splashFactory: InkRipple.splashFactory,
      hoverColor: Colors.transparent,
      highlightColor: Colors.transparent,
      child: ValueListenableBuilder<bool>(
        valueListenable: isHovered,
        builder: (context, hovered, child) {
          final Color effectiveBgColor = isActive ? iconFg : bg;
          final Color effectiveIconColor = isActive ? bg : iconFg;

          final Color effectiveBorderColor = hovered
              ? iconFg
              : isActive
                  ? iconFg.withValues(alpha: 0.6)
                  : iconFg.withValues(alpha: 0.3);

          final double effectiveBorderWidth = hovered
              ? 1.2
              : isActive
                  ? 1.0
                  : 0.8;

          return AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOutCubic,
            width: 44,
            height: 36,
            decoration: BoxDecoration(
              color: effectiveBgColor,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: effectiveBorderColor,
                width: effectiveBorderWidth,
              ),
            ),
            child: Icon(icon, color: effectiveIconColor, size: 20),
          );
        },
      ),
    ),
  );
}

/// Build audio visualizer for desktop
Widget buildDesktopAudioVisualizer({
  required List<double> audioLevels,
  required Color accent,
  required Color iconFg,
}) {
  return SizedBox(
    key: const ValueKey<String>('audio-visualizer'),
    height: 44,
    child: Row(
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final int barCount = audioLevels.length;
              if (barCount == 0) {
                return const SizedBox.shrink();
              }
              final double maxHeight = constraints.maxHeight;

              return Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: List.generate(barCount, (int index) {
                  final double level = audioLevels[index];
                  final double clampedLevel = level.clamp(0.0, 1.0);
                  final double barHeight = math.max(
                    4.0,
                    clampedLevel * maxHeight,
                  );
                  return Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 1.2),
                      child: Align(
                        alignment: Alignment.bottomCenter,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 90),
                          height: barHeight,
                          decoration: BoxDecoration(
                            color: accent,
                            borderRadius: BorderRadius.circular(3),
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              );
            },
          ),
        ),
      ],
    ),
  );
}
