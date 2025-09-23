// lib/constants.dart
import 'package:flutter/material.dart';
import 'package:chuk_chat/utils/color_extensions.dart';

/* ---------- DEFAULT COLOURS ---------- */
const Color kDefaultBgColor = Color(0xFF211B15);
const Color kDefaultAccentColor = Color(0xFF3F5E5D);
const Color kDefaultIconFgColor = Color(0xFF93854C);
const Brightness kDefaultThemeMode = Brightness.dark;

/* ---------- FILM GRAIN DEFAULT ---------- */
const bool kDefaultGrainEnabled = true;

/* ---------- THEME BUILDER ---------- */
ThemeData buildAppTheme({
  required Color accent,
  required Color iconFg,
  required Color bg,
  required Brightness brightness,
}) {
  return ThemeData(
    brightness: brightness,
    scaffoldBackgroundColor: bg,
    cardColor: bg,
    dividerColor: iconFg.withValues(alpha: .4),
    iconTheme: IconThemeData(color: iconFg),
    colorScheme: ColorScheme(
      primary: accent,
      secondary: iconFg,
      surface: bg,
      background: bg,
      error: Colors.red,
      onPrimary: Colors.black,
      onSecondary: Colors.black,
      onSurface: iconFg,
      onBackground: iconFg,
      onError: Colors.white,
      brightness: brightness,
    ),
    listTileTheme: ListTileThemeData(
      iconColor: iconFg,
      textColor: iconFg,
      selectedColor: accent,
      selectedTileColor: accent.withValues(alpha: 0.1),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: bg,
      elevation: 0,
      iconTheme: IconThemeData(color: iconFg),
      titleTextStyle: TextStyle(color: iconFg, fontSize: 20),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: bg.lighten(0.05),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: iconFg.withValues(alpha: 0.3), width: 1),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: iconFg.withValues(alpha: 0.3), width: 1),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: accent, width: 1.5),
      ),
      labelStyle: TextStyle(color: iconFg.withValues(alpha: 0.8)),
      hintStyle: TextStyle(color: iconFg.withValues(alpha: 0.6)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    ),
  );
}

/* ---------- RESPONSIVE BREAKPOINTS ---------- */
const double kCompactModeBreakpoint = 600.0;
const double kTabletBreakpoint = 800.0; // NEW: Define tablet breakpoint

/* ---------- MAIN UI LAYOUT CONSTANTS ---------- */
const double kFixedLeftPadding = 8.0;
const double kTopInitialSpacing = 16.0;
const double kMenuButtonHeight = 48.0;
const double kButtonVisualHeight = 40.0;
const double kSpacingBetweenTopButtons = 8.0;