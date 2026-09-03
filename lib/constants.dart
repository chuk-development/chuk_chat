// lib/constants.dart
import 'package:flutter/material.dart';
import 'package:chuk_chat/utils/color_extensions.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/utils/chat_font_resolver.dart';

/* ---------- DEFAULT COLOURS (Material You dark palette) ---------- */
const Color kDefaultBgColor = Color(0xFF111318);
const Color kDefaultAccentColor = Color(0xFFA8C7FA);
const Color kDefaultIconFgColor = Color(0xFFE2E2E9);
const Brightness kDefaultThemeMode = Brightness.dark;

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

/* ---------- UI FONT FAMILY ----------
   The font used for the whole app chrome (menus, settings, buttons — every
   surface outside the chat body). Reuses the same bundled families as the
   chat font, but defaults to the system font so an untouched install keeps
   Flutter's platform default. Resolved via [resolveUiFontFamily]. */
const String kDefaultUiFontFamily = kChatFontFamilySystem;

const List<String> kSupportedUiFontFamilies = kSupportedChatFontFamilies;

/* ---------- CONTRAST ----------
   Scales how strongly the surface-container ladder and the outline colours
   separate from the scaffold background. [kDefaultContrast] is the midpoint:
   at that value [buildAppTheme] reproduces the original hand-tuned palette
   exactly, so an install that never touches the slider looks identical. Below
   the midpoint the surfaces flatten toward the background; above it they pull
   apart for a crisper, higher-separation look. Device-local (SharedPreferences
   only), like UI scale and dynamic colour. */
const double kMinContrast = 0.0;
const double kMaxContrast = 1.0;
const double kDefaultContrast = 0.5;

/// Maps the [kMinContrast]..[kMaxContrast] slider value to the multiplier
/// applied to the surface/outline separation deltas. The default midpoint
/// maps to exactly `1.0` (identity), so the untouched theme is unchanged.
double contrastFactor(double contrast) {
  final double c = contrast.clamp(kMinContrast, kMaxContrast);
  return 0.5 + c; // 0.5 (flat) .. 1.0 (default) .. 1.5 (crisp)
}

/* ---------- SHAPE SCALE ----------
   One radius per role, used by the theme below and by hand-rolled
   surfaces. Anything a pointer can hover, focus or press must round its
   ink to one of these — a square highlight inside a rounded card is the
   single most visible inconsistency in the app. */
const double kRadiusCard = 20.0;
const double kRadiusField = 16.0;
const double kRadiusMenu = 16.0;
const double kRadiusRow = 14.0;
const double kRadiusDialog = 28.0;

/// Stadium radius for every button. Buttons are pills app-wide.
const double kRadiusPill = 999.0;

/// One padding, one minimum height and one label style for every button
/// role — the reason a Save and a Reset side by side look like siblings.
const EdgeInsets _kButtonPadding = EdgeInsets.symmetric(
  horizontal: 20,
  vertical: 14,
);
const Size _kButtonMinSize = Size(0, 48);
const TextStyle _kButtonTextStyle = TextStyle(
  fontSize: 14,
  fontWeight: FontWeight.w600,
  letterSpacing: 0.1,
);

final BorderRadius kBorderRadiusCard = BorderRadius.circular(kRadiusCard);
final BorderRadius kBorderRadiusField = BorderRadius.circular(kRadiusField);
final BorderRadius kBorderRadiusMenu = BorderRadius.circular(kRadiusMenu);
final BorderRadius kBorderRadiusRow = BorderRadius.circular(kRadiusRow);
final BorderRadius kBorderRadiusPill = BorderRadius.circular(kRadiusPill);

/* ---------- THEME BUILDER ---------- */
ThemeData buildAppTheme({
  required Color accent,
  required Color iconFg,
  required Color bg,
  required Brightness brightness,
  double contrast = kDefaultContrast,
  String? uiFont,
}) {
  final bool isDark = brightness == Brightness.dark;

  // Contrast scales the surface-ladder deltas and the outline alphas. At the
  // default midpoint the factor is exactly 1.0, so every value below matches
  // the original hand-tuned palette; higher values pull surfaces and outlines
  // further from the background for a crisper look, lower values flatten them.
  final double factor = contrastFactor(contrast);
  double scaled(double base) => (base * factor).clamp(0.0, 1.0);

  // Container-style surfaces are derived by lightening the scaffold bg
  // in dark mode and darkening it in light mode, producing the M3
  // surface-container ladder.
  final Color surfaceLow = isDark
      ? bg.lighten(scaled(0.03))
      : bg.darken(scaled(0.03));
  final Color surface = isDark
      ? bg.lighten(scaled(0.06))
      : bg.darken(scaled(0.05));
  final Color surfaceHigh = isDark
      ? bg.lighten(scaled(0.10))
      : bg.darken(scaled(0.08));
  final Color surfaceHighest = isDark
      ? bg.lighten(scaled(0.14))
      : bg.darken(scaled(0.12));

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
  final Color secondaryContainer = isDark
      ? bg.lighten(scaled(0.18))
      : bg.darken(scaled(0.15));
  final Color onSecondaryContainer = iconFg;

  final Color outline = iconFg.withValues(alpha: scaled(0.55));
  final Color outlineVariant = iconFg.withValues(alpha: scaled(0.25));
  final Color onSurfaceVariant = iconFg.withValues(alpha: scaled(0.82));

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
    surfaceContainerLowest: isDark
        ? bg.darken(scaled(0.02))
        : bg.lighten(scaled(0.02)),
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

  // Null / 'system' leaves [ThemeData.fontFamily] unset, so the platform
  // default font is used — this is the untouched-install behaviour. A bundled
  // family id applies that font to the whole app chrome via the base
  // textTheme; the chat body keeps its own resolved font on top of this.
  final String? uiFontFamily = resolveUiFontFamily(uiFont);

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    fontFamily: uiFontFamily,
    scaffoldBackgroundColor: bg,
    cardColor: surface,
    dividerColor: outlineVariant,
    iconTheme: IconThemeData(color: iconFg),
    colorScheme: colorScheme,
    extensions: <ThemeExtension<dynamic>>[m3Tokens],
    // Ink is rounded everywhere. A ListTile without a shape paints its
    // hover/press fill as a full-bleed rectangle, which is what makes a
    // rounded settings card turn square the moment you touch it.
    listTileTheme: ListTileThemeData(
      iconColor: iconFg,
      textColor: iconFg,
      selectedColor: accent,
      selectedTileColor: accent.withValues(alpha: 0.1),
      shape: RoundedRectangleBorder(borderRadius: kBorderRadiusRow),
    ),
    expansionTileTheme: ExpansionTileThemeData(
      shape: RoundedRectangleBorder(
        borderRadius: kBorderRadiusField,
        side: BorderSide.none,
      ),
      collapsedShape: RoundedRectangleBorder(
        borderRadius: kBorderRadiusField,
        side: BorderSide.none,
      ),
      iconColor: accent,
      collapsedIconColor: onSurfaceVariant,
      textColor: iconFg,
      collapsedTextColor: iconFg,
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
      // Same corner as the settings tiles (kExpressiveOuterRadius), so the
      // cards on every settings sub-page match the list they came from.
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
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
    // ── Buttons ───────────────────────────────────────────────────────
    // One shape, one height, one padding for every button role, so a
    // Save next to a Reset next to a Cancel reads as one family. Pages
    // must not re-declare shape or padding; only colour, if they must.
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: accent,
        foregroundColor: colorScheme.onPrimary,
        disabledBackgroundColor: iconFg.withValues(alpha: 0.12),
        disabledForegroundColor: iconFg.withValues(alpha: 0.38),
        shape: RoundedRectangleBorder(borderRadius: kBorderRadiusPill),
        padding: _kButtonPadding,
        minimumSize: _kButtonMinSize,
        textStyle: _kButtonTextStyle,
        elevation: 0,
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: surfaceHigh,
        foregroundColor: iconFg,
        shape: RoundedRectangleBorder(borderRadius: kBorderRadiusPill),
        padding: _kButtonPadding,
        minimumSize: _kButtonMinSize,
        textStyle: _kButtonTextStyle,
        elevation: 0,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: iconFg,
        side: BorderSide(color: outline),
        shape: RoundedRectangleBorder(borderRadius: kBorderRadiusPill),
        padding: _kButtonPadding,
        minimumSize: _kButtonMinSize,
        textStyle: _kButtonTextStyle,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: accent,
        shape: RoundedRectangleBorder(borderRadius: kBorderRadiusPill),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        minimumSize: const Size(0, 44),
        textStyle: _kButtonTextStyle,
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: iconFg,
        shape: const CircleBorder(),
      ),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        foregroundColor: iconFg,
        selectedForegroundColor: onPrimaryContainer,
        selectedBackgroundColor: primaryContainer,
        shape: RoundedRectangleBorder(borderRadius: kBorderRadiusPill),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        textStyle: _kButtonTextStyle,
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: surfaceHigh,
      selectedColor: primaryContainer,
      side: BorderSide(color: outlineVariant),
      shape: RoundedRectangleBorder(borderRadius: kBorderRadiusPill),
      labelStyle: TextStyle(color: iconFg, fontSize: 13),
    ),

    // ── Menus & dialogs ───────────────────────────────────────────────
    // The vertical menu padding matters: without it a highlighted first
    // or last item paints square into the menu's rounded corner.
    popupMenuTheme: PopupMenuThemeData(
      color: surfaceHigh,
      elevation: 3,
      shape: RoundedRectangleBorder(borderRadius: kBorderRadiusMenu),
      menuPadding: const EdgeInsets.symmetric(vertical: 8),
      textStyle: TextStyle(color: iconFg, fontSize: 14),
    ),
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: WidgetStatePropertyAll<Color>(surfaceHigh),
        elevation: const WidgetStatePropertyAll<double>(3),
        padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
          EdgeInsets.symmetric(vertical: 8),
        ),
        shape: WidgetStatePropertyAll<OutlinedBorder>(
          RoundedRectangleBorder(borderRadius: kBorderRadiusMenu),
        ),
      ),
    ),
    dropdownMenuTheme: DropdownMenuThemeData(
      menuStyle: MenuStyle(
        backgroundColor: WidgetStatePropertyAll<Color>(surfaceHigh),
        elevation: const WidgetStatePropertyAll<double>(3),
        padding: const WidgetStatePropertyAll<EdgeInsetsGeometry>(
          EdgeInsets.symmetric(vertical: 8),
        ),
        shape: WidgetStatePropertyAll<OutlinedBorder>(
          RoundedRectangleBorder(borderRadius: kBorderRadiusMenu),
        ),
      ),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: surfaceHigh,
      elevation: 3,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(kRadiusDialog),
      ),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: surfaceLow,
      elevation: 0,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(kRadiusDialog)),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: surfaceHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      textStyle: TextStyle(color: iconFg, fontSize: 12),
    ),

    // ── Text fields ───────────────────────────────────────────────────
    // Filled, borderless at rest, and a 2 px accent ring on focus. The
    // resting outline was fighting the fill and made every field look
    // like a 2014 form.
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: surfaceLow,
      border: OutlineInputBorder(
        borderRadius: kBorderRadiusField,
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: kBorderRadiusField,
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: kBorderRadiusField,
        borderSide: BorderSide(color: accent, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: kBorderRadiusField,
        borderSide: BorderSide(color: errorColor, width: 1.5),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: kBorderRadiusField,
        borderSide: BorderSide(color: errorColor, width: 2),
      ),
      disabledBorder: OutlineInputBorder(
        borderRadius: kBorderRadiusField,
        borderSide: BorderSide.none,
      ),
      labelStyle: TextStyle(color: onSurfaceVariant, fontSize: 15),
      floatingLabelStyle: TextStyle(color: accent, fontSize: 14),
      hintStyle: TextStyle(color: onSurfaceVariant, fontSize: 15),
      helperStyle: TextStyle(color: onSurfaceVariant, fontSize: 12),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
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
const double kSpacingBetweenTopButtons = 8.0;
