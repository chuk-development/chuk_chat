import 'package:flutter/material.dart';

class AppPalette {
  final bool isDark;
  final Color bg;
  final Color surfaceLow;
  final Color surface;
  final Color surfaceHigh;
  final Color fg;
  final Color muted;
  final Color hairline;
  final Color accent;
  final Color accentSubtle;
  final Color accentText;

  const AppPalette._({
    required this.isDark,
    required this.bg,
    required this.surfaceLow,
    required this.surface,
    required this.surfaceHigh,
    required this.fg,
    required this.muted,
    required this.hairline,
    required this.accent,
    required this.accentSubtle,
    required this.accentText,
  });

  static AppPalette of(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return isDark ? dark : light;
  }

  static const dark = AppPalette._(
    isDark: true,
    bg: Color(0xFF111318),
    surfaceLow: Color(0xFF181B22),
    surface: Color(0xFF1E222B),
    surfaceHigh: Color(0xFF252A35),
    fg: Color(0xFFE2E2E9),
    muted: Color(0xFF9AA0AB),
    hairline: Color(0xFF2A2E38),
    accent: Color(0xFFA8C7FA),
    accentSubtle: Color(0x33A8C7FA),
    accentText: Color(0xFFA8C7FA),
  );

  static const light = AppPalette._(
    isDark: false,
    bg: Color(0xFFF6F7FB),
    surfaceLow: Color(0xFFFFFFFF),
    surface: Color(0xFFFFFFFF),
    surfaceHigh: Color(0xFFEFF1F6),
    fg: Color(0xFF1A1C22),
    muted: Color(0xFF5F6571),
    hairline: Color(0xFFE2E5EC),
    accent: Color(0xFF285DA9),
    accentSubtle: Color(0x33285DA9),
    accentText: Color(0xFF285DA9),
  );
}
