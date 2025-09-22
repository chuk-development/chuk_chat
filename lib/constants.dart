// lib/constants.dart
import 'package:flutter/material.dart';
import 'package:chuk_chat/utils/color_extensions.dart'; // Import the new extension

/* ---------- DEFAULT COLOURS ---------- */
const Color kDefaultBgColor = Color(0xFF211B15);
const Color kDefaultAccentColor = Color(0xFF3F5E5D);
const Color kDefaultIconFgColor = Color(0xFF93854C);
const Brightness kDefaultThemeMode = Brightness.dark; // Default is dark mode

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
    cardColor: bg, // Use background color for cards
    dividerColor: iconFg.withOpacity(.4),
    iconTheme: IconThemeData(color: iconFg),
    colorScheme: ColorScheme(
      primary: accent,
      secondary: iconFg,
      surface: bg,
      background: bg,
      error: Colors.red,
      onPrimary: Colors.black, // Text on primary color
      onSecondary: Colors.black, // Text on secondary color
      onSurface: iconFg, // Text on surface color
      onBackground: iconFg, // Text on background color
      onError: Colors.white, // Text on error color
      brightness: brightness,
    ),
    listTileTheme: ListTileThemeData(
      iconColor: iconFg,
      textColor: iconFg,
      selectedColor: accent,
      selectedTileColor: accent.withOpacity(0.1),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: bg, // AppBar background matches general background
      elevation: 0,
      iconTheme: IconThemeData(color: iconFg),
      titleTextStyle: TextStyle(color: iconFg, fontSize: 20),
    ),
    // Customize text field decoration
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: bg.lighten(0.05),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: iconFg.withOpacity(0.3), width: 1),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: iconFg.withOpacity(0.3), width: 1),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: accent, width: 1.5),
      ),
      labelStyle: TextStyle(color: iconFg.withOpacity(0.8)),
      hintStyle: TextStyle(color: iconFg.withOpacity(0.6)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
    ),
  );
}


/* ---------- RESPONSIVE BREAKPOINTS ---------- */
// Der Bildschirm wird als "kompakt" (z.B. Handygröße) betrachtet, wenn die Breite unter diesem Wert liegt.
const double kCompactModeBreakpoint = 600.0;

/* ---------- MAIN UI LAYOUT CONSTANTS (Shared for consistency) ---------- */
const double kFixedLeftPadding = 8.0; // Abstand von der linken Wand für alle Icons
const double kTopInitialSpacing = 16.0; // Abstand vom oberen Bildschirmrand
const double kMenuButtonHeight = 48.0; // Höhe des IconButtons (Standard 48x48)
const double kButtonVisualHeight = 40.0; // Höhe der "New Chat"/"Projects"-Buttons
const double kSpacingBetweenTopButtons = 8.0; // Abstand zwischen den oberen Elementen