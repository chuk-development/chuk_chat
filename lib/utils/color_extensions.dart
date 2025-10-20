// lib/utils/color_extensions.dart
import 'package:flutter/material.dart';

/// Helper extension to subtly lighten or darken colors.
extension ColorExtension on Color {
  Color lighten([double amount = .1]) {
    assert(amount >= 0 && amount <= 1); // amount should be between 0.0 and 1.0
    final hsl = HSLColor.fromColor(this);
    final hslLight = hsl.withLightness(
      (hsl.lightness + amount).clamp(0.0, 1.0),
    );
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
    final rgb = toARGB32() & 0xFFFFFF;
    return '#${rgb.toRadixString(16).padLeft(6, '0').toUpperCase()}';
  }

  // Creates a Color from a hex string (e.g., #RRGGBB, RRGGBB, #AARRGGBB, or AARRGGBB)
  // Supports both 6-digit (#RRGGBB or RRGGBB) and 8-digit (#AARRGGBB or AARRGGBB) formats.
  // 8-digit values include an alpha channel (AARRGGBB) to specify opacity.
  static Color fromHexString(String? hexString, {Color? fallback}) {
    if (hexString == null) {
      if (fallback != null) return fallback;
      throw const FormatException('Color hex string was null.');
    }

    String hex = hexString.trim();
    if (hex.startsWith('#')) {
      hex = hex.substring(1);
    } else if (hex.toLowerCase().startsWith('0x')) {
      hex = hex.substring(2);
    }

    if (hex.isEmpty) {
      if (fallback != null) return fallback;
      throw const FormatException('Color hex string was empty.');
    }

    final isValidHex = RegExp(r'^[0-9a-fA-F]{6,8}$').hasMatch(hex);
    if (!isValidHex) {
      if (fallback != null) return fallback;
      throw FormatException('Invalid hex colour value: $hexString');
    }

    if (hex.length == 6) {
      hex = 'FF$hex'; // Add alpha for opaque color
    }

    return Color(int.parse(hex, radix: 16));
  }
}
