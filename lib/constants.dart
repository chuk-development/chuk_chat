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