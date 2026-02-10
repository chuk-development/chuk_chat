import 'dart:ui';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/utils/color_extensions.dart';

class ThemeSettings {
  const ThemeSettings({
    required this.userId,
    required this.themeMode,
    required this.accentColor,
    required this.iconColor,
    required this.backgroundColor,
    required this.grainEnabled,
  });

  final String userId;
  final Brightness themeMode;
  final Color accentColor;
  final Color iconColor;
  final Color backgroundColor;
  final bool grainEnabled;

  ThemeSettings copyWith({
    Brightness? themeMode,
    Color? accentColor,
    Color? iconColor,
    Color? backgroundColor,
    bool? grainEnabled,
  }) {
    return ThemeSettings(
      userId: userId,
      themeMode: themeMode ?? this.themeMode,
      accentColor: accentColor ?? this.accentColor,
      iconColor: iconColor ?? this.iconColor,
      backgroundColor: backgroundColor ?? this.backgroundColor,
      grainEnabled: grainEnabled ?? this.grainEnabled,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'user_id': userId,
      'theme_mode': themeMode == Brightness.light ? 'light' : 'dark',
      'accent_color': accentColor.toHexString(),
      'icon_color': iconColor.toHexString(),
      'background_color': backgroundColor.toHexString(),
      'grain_enabled': grainEnabled,
    };
  }

  static ThemeSettings defaults(String userId) {
    return ThemeSettings(
      userId: userId,
      themeMode: kDefaultThemeMode,
      accentColor: kDefaultAccentColor,
      iconColor: kDefaultIconFgColor,
      backgroundColor: kDefaultBgColor,
      grainEnabled: kDefaultGrainEnabled,
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
      grainEnabled: (map['grain_enabled'] as bool?) ?? kDefaultGrainEnabled,
    );
  }
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
