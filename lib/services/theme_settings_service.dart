import 'dart:ui';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/utils/color_extensions.dart';

/// The synced look. A theme pack is the three colours *plus* the contrast and
/// the app font, so all five travel together — otherwise a second device shows
/// the pack's palette but cannot recognise the pack any more. Dynamic colour
/// rides along because it overrides the palette.
class ThemeSettings {
  const ThemeSettings({
    required this.userId,
    required this.themeMode,
    required this.accentColor,
    required this.iconColor,
    required this.backgroundColor,
    this.contrast,
    this.uiFont,
    this.dynamicColor,
  });

  final String userId;
  final Brightness themeMode;
  final Color accentColor;
  final Color iconColor;
  final Color backgroundColor;

  /// Null when the row predates these columns: the user has a look stored, but
  /// never these three values. The caller keeps its local ones in that case
  /// instead of being reset to the defaults.
  final double? contrast;
  final String? uiFont;
  final bool? dynamicColor;

  ThemeSettings copyWith({
    Brightness? themeMode,
    Color? accentColor,
    Color? iconColor,
    Color? backgroundColor,
    double? contrast,
    String? uiFont,
    bool? dynamicColor,
  }) {
    return ThemeSettings(
      userId: userId,
      themeMode: themeMode ?? this.themeMode,
      accentColor: accentColor ?? this.accentColor,
      iconColor: iconColor ?? this.iconColor,
      backgroundColor: backgroundColor ?? this.backgroundColor,
      contrast: contrast ?? this.contrast,
      uiFont: uiFont ?? this.uiFont,
      dynamicColor: dynamicColor ?? this.dynamicColor,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'user_id': userId,
      'theme_mode': themeMode == Brightness.light ? 'light' : 'dark',
      'accent_color': accentColor.toHexString(),
      'icon_color': iconColor.toHexString(),
      'background_color': backgroundColor.toHexString(),
      // A null look field is left out rather than written as NULL, so a
      // device that keeps it local (the Agents build) never clears the value
      // another device stored.
      if (contrast != null) 'contrast': contrast,
      if (uiFont != null) 'ui_font': uiFont,
      if (dynamicColor != null) 'dynamic_color': dynamicColor,
    };
  }

  static ThemeSettings defaults(String userId) {
    return ThemeSettings(
      userId: userId,
      themeMode: kDefaultThemeMode,
      accentColor: kDefaultAccentColor,
      iconColor: kDefaultIconFgColor,
      backgroundColor: kDefaultBgColor,
      contrast: kDefaultContrast,
      uiFont: kDefaultUiFontFamily,
      dynamicColor: kDefaultDynamicColorEnabled,
    );
  }

  static ThemeSettings fromMap(String userId, Map<String, dynamic> map) {
    final modeRaw = (map['theme_mode'] as String?)?.toLowerCase();
    return ThemeSettings(
      userId: userId,
      themeMode: modeRaw == 'light' ? Brightness.light : Brightness.dark,
      accentColor: ColorExtension.fromHexString(
        map['accent_color'] as String?,
        fallback: kDefaultAccentColor,
      ),
      iconColor: ColorExtension.fromHexString(
        map['icon_color'] as String?,
        fallback: kDefaultIconFgColor,
      ),
      backgroundColor: ColorExtension.fromHexString(
        map['background_color'] as String?,
        fallback: kDefaultBgColor,
      ),
      // A row written before these columns existed has no values for them.
      contrast: _clampContrast(map['contrast']),
      uiFont: _sanitizeUiFont(map['ui_font'] as String?),
      dynamicColor: map['dynamic_color'] as bool?,
    );
  }
}

/// Null stays null — "never stored" is not the same as "stored as default".
/// A stored value out of range is repaired.
double? _clampContrast(Object? raw) {
  final value = raw is num ? raw.toDouble() : null;
  if (value == null) return null;
  return value.clamp(kMinContrast, kMaxContrast).toDouble();
}

String? _sanitizeUiFont(String? raw) {
  if (raw == null) return null;
  return kSupportedUiFontFamilies.contains(raw) ? raw : kDefaultUiFontFamily;
}

class ThemeSettingsService {
  const ThemeSettingsService();

  SupabaseQueryBuilder get _table =>
      SupabaseService.client.from('theme_settings');

  Future<ThemeSettings> loadOrCreate() async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw const ThemeSettingsServiceException('User is not signed in.');
    }

    final existing = await _table.select().eq('user_id', user.id).maybeSingle();

    if (existing != null) {
      return ThemeSettings.fromMap(user.id, existing);
    }

    final defaults = ThemeSettings.defaults(user.id);
    await _table.upsert(defaults.toMap());
    return defaults;
  }

  Future<void> save(ThemeSettings settings) async {
    await _table.upsert(settings.toMap(), onConflict: 'user_id');
  }
}

class ThemeSettingsServiceException implements Exception {
  const ThemeSettingsServiceException(this.message);

  final String message;

  @override
  String toString() => message;
}
