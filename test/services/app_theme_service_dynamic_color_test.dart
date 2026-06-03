// Tests for Material You / dynamic-colour accent resolution in
// AppThemeService.buildTheme().
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/services/app_theme_service.dart';

ColorScheme _schemeWithPrimary(Color primary, Brightness brightness) {
  return ColorScheme.fromSeed(seedColor: primary, brightness: brightness)
      .copyWith(primary: primary);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final service = AppThemeService.instance;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await service.loadFromPrefs(); // resets to defaults
  });

  test('dynamic colour OFF: user accent wins even when schemes provided',
      () async {
    await service.setDynamicColorEnabled(false);
    service.setThemeMode(Brightness.dark);

    final dynamicScheme = _schemeWithPrimary(
      const Color(0xFFFF0000),
      Brightness.dark,
    );
    final theme = service.buildTheme(
      lightDynamic: dynamicScheme,
      darkDynamic: dynamicScheme,
    );

    expect(theme.colorScheme.primary, kDefaultAccentColor);
  });

  test('dynamic colour ON: dark scheme primary drives the accent in dark mode',
      () async {
    service.setThemeMode(Brightness.dark);
    await service.setDynamicColorEnabled(true);

    const systemAccent = Color(0xFF00FF00);
    final theme = service.buildTheme(
      lightDynamic: _schemeWithPrimary(
        const Color(0xFF0000FF),
        Brightness.light,
      ),
      darkDynamic: _schemeWithPrimary(systemAccent, Brightness.dark),
    );

    expect(theme.colorScheme.primary, systemAccent);
  });

  test('dynamic colour ON: light scheme primary drives accent in light mode',
      () async {
    service.setThemeMode(Brightness.light);
    await service.setDynamicColorEnabled(true);

    const systemAccent = Color(0xFF123456);
    final theme = service.buildTheme(
      lightDynamic: _schemeWithPrimary(systemAccent, Brightness.light),
      darkDynamic: _schemeWithPrimary(
        const Color(0xFF654321),
        Brightness.dark,
      ),
    );

    expect(theme.colorScheme.primary, systemAccent);
  });

  test('dynamic colour ON but no platform palette: falls back to user accent',
      () async {
    service.setThemeMode(Brightness.dark);
    await service.setDynamicColorEnabled(true);

    final theme = service.buildTheme(lightDynamic: null, darkDynamic: null);

    expect(theme.colorScheme.primary, kDefaultAccentColor);
  });

  test('changing the system palette rebuilds the theme (cache keyed on accent)',
      () async {
    service.setThemeMode(Brightness.dark);
    await service.setDynamicColorEnabled(true);

    final first = service.buildTheme(
      darkDynamic: _schemeWithPrimary(const Color(0xFFAA0000), Brightness.dark),
    );
    final second = service.buildTheme(
      darkDynamic: _schemeWithPrimary(const Color(0xFF00AA00), Brightness.dark),
    );

    expect(first.colorScheme.primary, const Color(0xFFAA0000));
    expect(second.colorScheme.primary, const Color(0xFF00AA00));
  });

  test('dynamic colour ON: whole palette follows the system scheme', () async {
    service.setThemeMode(Brightness.dark);
    await service.setDynamicColorEnabled(true);

    final dyn = _schemeWithPrimary(const Color(0xFF00FF00), Brightness.dark);
    final theme = service.buildTheme(lightDynamic: dyn, darkDynamic: dyn);

    // Not just the accent — background (surface) and foreground (onSurface)
    // come from the dynamic scheme too.
    expect(theme.colorScheme.primary, const Color(0xFF00FF00));
    expect(theme.colorScheme.surface, dyn.surface);
    expect(theme.colorScheme.onSurface, dyn.onSurface);
    expect(theme.scaffoldBackgroundColor, dyn.surface);
  });

  test('dynamic colour OFF: surface/onSurface keep user-picked colours',
      () async {
    await service.setDynamicColorEnabled(false);
    service.setThemeMode(Brightness.dark);

    final dyn = _schemeWithPrimary(const Color(0xFFFF0000), Brightness.dark);
    final theme = service.buildTheme(lightDynamic: dyn, darkDynamic: dyn);

    expect(theme.colorScheme.surface, kDefaultBgColor);
    expect(theme.colorScheme.onSurface, kDefaultIconFgColor);
  });

  test('changing only the system surface rebuilds the theme', () async {
    service.setThemeMode(Brightness.dark);
    await service.setDynamicColorEnabled(true);

    const accent = Color(0xFF00AA00);
    final schemeA = _schemeWithPrimary(accent, Brightness.dark)
        .copyWith(surface: const Color(0xFF101010));
    final schemeB = _schemeWithPrimary(accent, Brightness.dark)
        .copyWith(surface: const Color(0xFF202020));

    final first = service.buildTheme(darkDynamic: schemeA);
    final second = service.buildTheme(darkDynamic: schemeB);

    expect(first.colorScheme.surface, const Color(0xFF101010));
    expect(second.colorScheme.surface, const Color(0xFF202020));
  });

  test('setDynamicColorEnabled persists to SharedPreferences', () async {
    // Force a state transition so the write is not skipped by the
    // no-op guard (the singleton may already hold `true` from a prior test).
    await service.setDynamicColorEnabled(false);
    await service.setDynamicColorEnabled(true);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('dynamicColorEnabled'), true);
  });
}
