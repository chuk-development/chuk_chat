// lib/constants.dart
import 'package:flutter/material.dart';

/* ---------- COLOURS ---------- */
const Color bg     = Color(0xFF211B15);
const Color accent = Color(0xFF3F5E5D);
const Color iconFg = Color(0xFF93854C);

/* ---------- THEME ---------- */
final appTheme = ThemeData.dark().copyWith(
  scaffoldBackgroundColor: bg,
  cardColor: bg,
  dividerColor: iconFg.withOpacity(.4),
  iconTheme: const IconThemeData(color: iconFg),
  colorScheme: const ColorScheme.dark(primary: accent, secondary: iconFg, surface: bg),
  listTileTheme: ListTileThemeData(
    iconColor: iconFg,
    textColor: iconFg,
    selectedColor: accent,
    selectedTileColor: accent.withOpacity(0.1),
  ),
);

/* ---------- RESPONSIVE BREAKPOINTS ---------- */
// Der Bildschirm wird als "kompakt" (z.B. Handygröße) betrachtet, wenn die Breite unter diesem Wert liegt.
const double kCompactModeBreakpoint = 600.0;

/* ---------- MAIN UI LAYOUT CONSTANTS (Shared for consistency) ---------- */
const double kFixedLeftPadding = 8.0; // Abstand von der linken Wand für alle Icons
const double kTopInitialSpacing = 16.0; // Abstand vom oberen Bildschirmrand
const double kMenuButtonHeight = 48.0; // Höhe des IconButtons (Standard 48x48)
const double kButtonVisualHeight = 40.0; // Höhe der "New Chat"/"Projects"-Buttons
const double kSpacingBetweenTopButtons = 8.0; // Abstand zwischen den oberen Elementen