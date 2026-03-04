// lib/platform_specific/chat/widgets/desktop_chat_widgets.dart
import 'package:flutter/material.dart';

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

/// Build audio visualizer for desktop (matches mobile style with gradient + glow)
Widget buildDesktopAudioVisualizer({
  required List<double> audioLevels,
  required Color accent,
  required Color iconFg,
}) {
  const int barCount = 40;
  final int startIndex = audioLevels.length > barCount
      ? audioLevels.length - barCount
      : 0;

  return SizedBox(
    key: const ValueKey<String>('audio-visualizer'),
    height: 32,
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: List.generate(barCount, (index) {
        final int levelIndex = startIndex + index;
        final double rawLevel = levelIndex < audioLevels.length
            ? audioLevels[levelIndex]
            : 0.0;

        // Exponential scaling for more dramatic response
        final double level = rawLevel * rawLevel;

        // Bar height with good range (3-28px)
        final double barHeight = (level * 26 + 3).clamp(3.0, 28.0);

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
                    accent.withValues(alpha: opacity),
                    accent.withValues(alpha: opacity * 0.7),
                  ],
                ),
                borderRadius: BorderRadius.circular(2),
                boxShadow: level > 0.3
                    ? [
                        BoxShadow(
                          color: accent.withValues(alpha: 0.3),
                          blurRadius: 2,
                          spreadRadius: 0.5,
                        ),
                      ]
                    : null,
              ),
            ),
          ),
        );
      }),
    ),
  );
}
