// lib/utils/color_extensions.dart
import 'package:flutter/material.dart';

/// Helper extension to subtly lighten or darken colors.
extension ColorExtension on Color {
  Color lighten([double amount = .1]) {
    assert(amount >= 0 && amount <= 1); // amount should be between 0.0 and 1.0
    final hsl = HSLColor.fromColor(this);
    final hslLight = hsl.withLightness((hsl.lightness + amount).clamp(0.0, 1.0));
    return hslLight.toColor();
  }

  Color darken([double amount = .1]) {
    assert(amount >= 0 && amount <= 1); // amount should be between 0.0 and 1.0
    final hsl = HSLColor.fromColor(this);
    final hslDark = hsl.withLightness((hsl.lightness - amount).clamp(0.0, 1.0));
    return hslDark.toColor();
  }

  // Converts a Color to its hex string representation (e.g., #RRGGBB)
  String toHexString() {
    return '#${(value & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
  }

  // Creates a Color from a hex string (e.g., #RRGGBB or RRGGBB)
  static Color fromHexString(String hexString) {
    String hex = hexString.replaceAll('#', '');
    if (hex.length == 6) {
      hex = 'FF$hex'; // Add alpha for opaque color
    }
    return Color(int.parse(hex, radix: 16));
  }
}