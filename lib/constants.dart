// lib/constants.dart
import 'package:flutter/material.dart';
import 'package:chuk_chat/utils/color_extensions.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';

/* ---------- DEFAULT COLOURS (Material You dark palette) ---------- */
const Color kDefaultBgColor = Color(0xFF111318);
const Color kDefaultAccentColor = Color(0xFFA8C7FA);
const Color kDefaultIconFgColor = Color(0xFFE2E2E9);
const Brightness kDefaultThemeMode = Brightness.dark;

/* ---------- FILM GRAIN DEFAULT ---------- */
const bool kDefaultGrainEnabled = false;

/* ---------- MATERIAL YOU / DYNAMIC COLOUR DEFAULT ---------- */
/// When enabled, the entire palette (accent, background and foreground) is
/// taken from the system's Material You palette (Android 12+, and some
/// desktops) and follows wallpaper/accent changes automatically. Device-local
/// — not synced to Supabase, since it depends on the OS supporting dynamic
/// colour.
const bool kDefaultDynamicColorEnabled = false;

/* ---------- REASONING TOKENS DEFAULT ---------- */
const bool kDefaultShowReasoningTokens = true;

/* ---------- MODEL INFO DEFAULT ---------- */
const bool kDefaultShowModelInfo = false;

/* ---------- TPS (TOKENS PER SECOND) DEFAULT ---------- */
const bool kDefaultShowTps = false;

/* ---------- UI LOCALE DEFAULT ---------- */
const String kDefaultUiLocale = 'en';

/* ---------- TOOL CALLING DEFAULTS ---------- */
const bool kDefaultToolCallingEnabled = true;
const bool kDefaultToolDiscoveryMode = true;
const bool kDefaultShowToolCalls = true;
const bool kDefaultAllowMarkdownToolCalls = true;

/// Include prior tool calls + their results in the API history so the
/// model can reuse already-fetched data on follow-up questions instead
/// of re-running the same tools (web_search, etc).
const bool kDefaultIncludeToolResultsInHistory = true;

/* ---------- CHAT FONT SIZE ---------- */
const double kDefaultChatFontSize = 15.0;
const double kMinChatFontSize = 11.0;
const double kMaxChatFontSize = 24.0;

/* ---------- UI SCALE ---------- */
const double kDefaultUiScale = 1.0;
const double kMinUiScale = 0.8;
const double kMaxUiScale = 1.5;

/* ---------- CHAT FONT FAMILY ---------- */
/// Identifiers used to persist the user's font family preference.
/// The actual resolved [fontFamily] string is looked up at render time
/// via [resolveChatFontFamily] (handles GoogleFonts caching).
const String kChatFontFamilySystem = 'system';
const String kChatFontFamilyArimo = 'arimo';
const String kChatFontFamilyMerriweather = 'merriweather';
const String kChatFontFamilyJetBrainsMono = 'jetbrains_mono';
const String kDefaultChatFontFamily = kChatFontFamilyArimo;

const List<String> kSupportedChatFontFamilies = <String>[
  kChatFontFamilySystem,
  kChatFontFamilyArimo,
  kChatFontFamilyMerriweather,
  kChatFontFamilyJetBrainsMono,
];

/* ---------- THEME BUILDER ---------- */
ThemeData buildAppTheme({
  required Color accent,
  required Color iconFg,
  required Color bg,
  required Brightness brightness,
}) {
  final bool isDark = brightness == Brightness.dark;

  // Container-style surfaces are derived by lightening the scaffold bg
  // in dark mode and darkening it in light mode, producing the M3
  // surface-container ladder.
  final Color surfaceLow = isDark ? bg.lighten(0.03) : bg.darken(0.03);
  final Color surface = isDark ? bg.lighten(0.06) : bg.darken(0.05);
  final Color surfaceHigh = isDark ? bg.lighten(0.10) : bg.darken(0.08);
  final Color surfaceHighest = isDark ? bg.lighten(0.14) : bg.darken(0.12);

  // Primary / tertiary containers — tint accent toward the surface to get
  // a muted container color that still reads as accented.
  final Color primaryContainer = isDark
      ? Color.lerp(accent, bg, 0.70)!
      : Color.lerp(accent, const Color(0xFFFFFFFF), 0.70)!;
  final Color onPrimaryContainer = isDark
      ? Color.lerp(accent, const Color(0xFFFFFFFF), 0.55)!
      : Color.lerp(accent, const Color(0xFF000000), 0.55)!;
  final Color tertiary = _shiftHue(accent, 45);
  final Color tertiaryContainer = isDark
      ? Color.lerp(tertiary, bg, 0.65)!
      : Color.lerp(tertiary, const Color(0xFFFFFFFF), 0.70)!;
  final Color onTertiaryContainer = isDark
      ? Color.lerp(tertiary, const Color(0xFFFFFFFF), 0.55)!
      : Color.lerp(tertiary, const Color(0xFF000000), 0.55)!;
  final Color secondaryContainer = isDark ? bg.lighten(0.18) : bg.darken(0.15);
  final Color onSecondaryContainer = iconFg;

  final Color outline = iconFg.withValues(alpha: 0.55);
  final Color outlineVariant = iconFg.withValues(alpha: 0.25);
  final Color onSurfaceVariant = iconFg.withValues(alpha: 0.82);

  final Color errorColor = isDark
      ? const Color(0xFFFFB4AB)
      : const Color(0xFFBA1A1A);
  final Color errorContainer = isDark
      ? const Color(0xFF93000A)
      : const Color(0xFFFFDAD6);
  final Color onErrorContainer = isDark
      ? const Color(0xFFFFDAD6)
      : const Color(0xFF410002);

  final ColorScheme colorScheme = ColorScheme(
    brightness: brightness,
    primary: accent,
    onPrimary: isDark ? const Color(0xFF062E6F) : const Color(0xFFFFFFFF),
    primaryContainer: primaryContainer,
    onPrimaryContainer: onPrimaryContainer,
    secondary: iconFg,
    onSecondary: isDark ? const Color(0xFF0A0D13) : const Color(0xFFFFFFFF),
    secondaryContainer: secondaryContainer,
    onSecondaryContainer: onSecondaryContainer,
    tertiary: tertiary,
    onTertiary: isDark ? const Color(0xFF0A0D13) : const Color(0xFFFFFFFF),
    tertiaryContainer: tertiaryContainer,
    onTertiaryContainer: onTertiaryContainer,
    error: errorColor,
    onError: isDark ? const Color(0xFF690005) : const Color(0xFFFFFFFF),
    errorContainer: errorContainer,
    onErrorContainer: onErrorContainer,
    surface: bg,
    onSurface: iconFg,
    onSurfaceVariant: onSurfaceVariant,
    surfaceContainerLowest: isDark ? bg.darken(0.02) : bg.lighten(0.02),
    surfaceContainerLow: surfaceLow,
    surfaceContainer: surface,
    surfaceContainerHigh: surfaceHigh,
    surfaceContainerHighest: surfaceHighest,
    outline: outline,
    outlineVariant: outlineVariant,
    inverseSurface: isDark ? iconFg : bg,
    onInverseSurface: isDark ? bg : iconFg,
    inversePrimary: isDark ? accent.darken(0.25) : accent.lighten(0.25),
    shadow: const Color(0xFF000000),
    scrim: const Color(0xFF000000),
    surfaceTint: accent,
  );

  final MaterialYouTokens m3Tokens = MaterialYouTokens(
    surfaceContainerLow: surfaceLow,
    surfaceContainer: surface,
    surfaceContainerHigh: surfaceHigh,
    surfaceContainerHighest: surfaceHighest,
    primaryContainer: primaryContainer,
    onPrimaryContainer: onPrimaryContainer,
    secondaryContainer: secondaryContainer,
    onSecondaryContainer: onSecondaryContainer,
    tertiaryContainer: tertiaryContainer,
    onTertiaryContainer: onTertiaryContainer,
    outline: outline,
    outlineVariant: outlineVariant,
    onSurfaceVariant: onSurfaceVariant,
    success: isDark ? const Color(0xFF7FD79A) : const Color(0xFF2E7D43),
    onSuccess: isDark ? const Color(0xFF003918) : const Color(0xFFFFFFFF),
    successContainer: isDark
        ? const Color(0xFF143A1F)
        : const Color(0xFFB6F2C2),
    onSuccessContainer: isDark
        ? const Color(0xFFA5F0B0)
        : const Color(0xFF002110),
    warning: isDark ? const Color(0xFFFFC860) : const Color(0xFF855300),
    warningContainer: isDark
        ? const Color(0xFF3D2E00)
        : const Color(0xFFFFDEA4),
    onWarningContainer: isDark
        ? const Color(0xFFFFDEA4)
        : const Color(0xFF291800),
  );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    scaffoldBackgroundColor: bg,
    cardColor: surface,
    dividerColor: outlineVariant,
    iconTheme: IconThemeData(color: iconFg),
    colorScheme: colorScheme,
    extensions: <ThemeExtension<dynamic>>[m3Tokens],
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
    cardTheme: CardThemeData(
      color: surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    dividerTheme: DividerThemeData(color: outlineVariant, space: 1),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) {
          return colorScheme.onPrimary;
        }
        return outline;
      }),
      trackColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return accent;
        return surfaceHighest;
      }),
      trackOutlineColor: WidgetStateProperty.resolveWith((states) {
        if (states.contains(WidgetState.selected)) return accent;
        return outline;
      }),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: accent,
        foregroundColor: colorScheme.onPrimary,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: iconFg,
        side: BorderSide(color: outline),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: accent),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: surfaceHigh,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: outlineVariant, width: 1),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: outlineVariant, width: 1),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: accent, width: 1.5),
      ),
      labelStyle: TextStyle(color: onSurfaceVariant),
      hintStyle: TextStyle(color: onSurfaceVariant),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
    ),
  );
}

Color _shiftHue(Color c, double degrees) {
  final hsl = HSLColor.fromColor(c);
  final h = (hsl.hue + degrees) % 360;
  return hsl.withHue(h).toColor();
}

/* ---------- RESPONSIVE BREAKPOINTS ---------- */
const double kCompactModeBreakpoint = 600.0;
const double kTabletBreakpoint = 800.0; // NEW: Define tablet breakpoint

/* ---------- MAIN UI LAYOUT CONSTANTS ---------- */
const double kFixedLeftPadding = 8.0;
const double kTopInitialSpacing = 16.0;
const double kMenuButtonHeight = 48.0;
const double kButtonVisualHeight = 40.0;
