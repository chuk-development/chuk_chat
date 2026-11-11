// lib/constants.dart
import 'package:flutter/material.dart';
import 'package:chuk_chat/utils/color_extensions.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/utils/chat_font_resolver.dart';
import 'package:chuk_chat/theme/theme_palette.dart';

/* ---------- DEFAULT COLOURS (the Plane pack, dark) ----------
   The app default is the dark variant of the Plane pack (theme_presets.dart):
   panels #141415, text #E4E6E7, a grey accent. With the default contrast the
   pack's exact palette applies, so "reset to default" gives the whole Plane
   look. The old Material You blue lives on as the Aya pack. */
const Color kDefaultBgColor = Color(0xFF141415);
const Color kDefaultAccentColor = Color(0xFFAFB3B6);
const Color kDefaultIconFgColor = Color(0xFFE4E6E7);
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
const double kDefaultChatFontSize = 16.0;
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
const String kChatFontFamilyInter = 'inter';
const String kChatFontFamilyArimo = 'arimo';
const String kChatFontFamilyMerriweather = 'merriweather';
const String kChatFontFamilyJetBrainsMono = 'jetbrains_mono';

/// Inter is the default for chat and UI: open shapes, a tall x-height and
/// full Latin-Ext (ä ö ü ß ẞ). Mono is selectable but never a default.
const String kDefaultChatFontFamily = kChatFontFamilyInter;

const List<String> kSupportedChatFontFamilies = <String>[
  kChatFontFamilyInter,
  kChatFontFamilySystem,
  kChatFontFamilyArimo,
  kChatFontFamilyMerriweather,
  kChatFontFamilyJetBrainsMono,
];

/* ---------- UI FONT FAMILY ----------
   The font used for the whole app chrome (menus, settings, buttons — every
   surface outside the chat body). Reuses the same bundled families as the
   chat font and shares its default (Inter), so UI and chat use one face.
   Theme packs never set it. Resolved via [resolveUiFontFamily]. */
const String kDefaultUiFontFamily = kChatFontFamilyInter;

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

/* ---------- RADIUS BY HEIGHT ----------
   The six steps of the corner scale (docs/DESIGN.md §6.1). A surface picks
   its corner from its height with [radiusForHeight]; a surface inside
   another one takes [innerRadius], so the two curves stay concentric. */
const double kRadiusXs = 4.0; // below 20 px: key caps, inline code, tiny marks
const double kRadiusSm = 8.0; // 20–28 px: compact chips and buttons
const double kRadiusMd = 12.0; // 32–40 px: buttons, fields, one-line rows
const double kRadiusLg = 16.0; // code blocks, diffs, grouped content
const double kRadiusXl = 20.0; // an independent card
const double kRadiusXxl = 28.0; // a main surface: dialog, panel, composer

/// The scale, smallest first.
const List<double> kRadiusScale = <double>[
  kRadiusXs,
  kRadiusSm,
  kRadiusMd,
  kRadiusLg,
  kRadiusXl,
  kRadiusXxl,
];

/// The corner for a control or block of [height] logical pixels.
///
/// Below 20 → 4, below 30 → 8, up to 40 → 12, up to 56 → 16, up to 96 →
/// 20, taller → 28. A tall card stays a card: pass the height the design
/// gives the element, not the height its content grew to.
double radiusForHeight(double height) {
  if (height < 20) return kRadiusXs;
  if (height < 30) return kRadiusSm;
  if (height <= 40) return kRadiusMd;
  if (height <= 56) return kRadiusLg;
  if (height <= 96) return kRadiusXl;
  return kRadiusXxl;
}

/// The corner of a surface inset by [inset] inside a surface with corner
/// [outer]: `max(0, outer − inset)`. Both arcs then share one centre.
double innerRadius(double outer, double inset) {
  final double r = outer - inset;
  return r < 0 ? 0 : r;
}

/// One padding, one minimum height and one label style for every button
/// role — the reason a Save and a Reset side by side look like siblings.
const EdgeInsets _kButtonPadding = EdgeInsets.symmetric(
  horizontal: 20,
  vertical: 14,
);

/// Material 3 Expressive button shape: round at rest, and squarer while the
/// button is held (m3.material.io/components/buttons, "shape morph"). A 48 px
/// button sits between the spec's small (40, pressed 8) and medium (56,
/// pressed 12) sizes and takes the medium corner. [Material] animates the
/// change, so every themed button morphs on press.
final WidgetStateProperty<OutlinedBorder> _kM3eButtonShape =
    WidgetStateProperty.resolveWith((Set<WidgetState> states) {
      if (states.contains(WidgetState.pressed)) {
        return const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(12)),
        );
      }
      return const StadiumBorder();
    });

/// The same morph for a small (40 px) icon button: circle at rest, corner 8
/// while held, as in the spec's icon button table.
final WidgetStateProperty<OutlinedBorder> _kM3eIconButtonShape =
    WidgetStateProperty.resolveWith((Set<WidgetState> states) {
      if (states.contains(WidgetState.pressed)) {
        return const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(8)),
        );
      }
      return const CircleBorder();
    });

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
  ThemePalette? palette,
}) {
  final bool isDark = brightness == Brightness.dark;
  // A pack with its own palette (see [ThemePalette]) replaces every derived
  // surface, outline and status colour below with its hand-picked value.
  final ThemePalette? p = palette;

  // Contrast scales the surface-ladder deltas and the outline alphas. At the
  // default midpoint the factor is exactly 1.0, so every value below matches
  // the original hand-tuned palette; higher values pull surfaces and outlines
  // further from the background for a crisper look, lower values flatten them.
  final double factor = contrastFactor(contrast);
  double scaled(double base) => (base * factor).clamp(0.0, 1.0);

  // Container-style surfaces are derived by lightening the scaffold bg
  // in dark mode and darkening it in light mode, producing the M3
  // surface-container ladder.
  final Color surfaceLow =
      p?.surfaceLow ??
      (isDark ? bg.lighten(scaled(0.03)) : bg.darken(scaled(0.03)));
  final Color surface =
      p?.surface ??
      (isDark ? bg.lighten(scaled(0.06)) : bg.darken(scaled(0.05)));
  final Color surfaceHigh =
      p?.surfaceHigh ??
      (isDark ? bg.lighten(scaled(0.10)) : bg.darken(scaled(0.08)));
  final Color surfaceHighest =
      p?.surfaceHighest ??
      (isDark ? bg.lighten(scaled(0.14)) : bg.darken(scaled(0.12)));

  // Primary / tertiary containers — tint accent toward the surface to get
  // a muted container color that still reads as accented.
  final Color primaryContainer =
      p?.primaryContainer ??
      (isDark
          ? Color.lerp(accent, bg, 0.70)!
          : Color.lerp(accent, const Color(0xFFFFFFFF), 0.70)!);
  final Color onPrimaryContainer =
      p?.onPrimaryContainer ??
      (isDark
          ? Color.lerp(accent, const Color(0xFFFFFFFF), 0.55)!
          : Color.lerp(accent, const Color(0xFF000000), 0.55)!);
  final Color tertiary = _shiftHue(accent, 45);
  final Color tertiaryContainer = isDark
      ? Color.lerp(tertiary, bg, 0.65)!
      : Color.lerp(tertiary, const Color(0xFFFFFFFF), 0.70)!;
  final Color onTertiaryContainer = isDark
      ? Color.lerp(tertiary, const Color(0xFFFFFFFF), 0.55)!
      : Color.lerp(tertiary, const Color(0xFF000000), 0.55)!;
  final Color secondaryContainer =
      p?.secondaryContainer ??
      (isDark ? bg.lighten(scaled(0.18)) : bg.darken(scaled(0.15)));
  final Color selection =
      p?.selection ?? Color.alphaBlend(accent.withValues(alpha: 0.20), surface);
  // A pack with its own palette keeps every selection neutral; the accent is
  // then only for the primary action, as in the product it was taken from.
  final Color onSelection =
      p?.onSelection ?? accentForegroundFor(accent, selection);
  final Color selectedFill = p?.selectedFill ?? accent;
  final Color onSelectedFill =
      p?.onSelectedFill ?? readableOnFill(accent, iconFg);
  // The user's own bubble: the accent at 80 % over the page, unless the pack
  // has a neutral bubble of its own (Plane: a raised grey, light text). Its
  // text keeps the reader's icon colour unless that falls below 2 : 1 on the
  // blended fill; then it is black or white, whichever reads better.
  final Color userBubble = p?.userBubble ?? accent.withValues(alpha: .8);
  final Color onUserBubble =
      p?.onUserBubble ??
      readableOnFill(Color.alphaBlend(userBubble, bg), iconFg);
  final Color onSecondaryContainer = iconFg;

  // The accent as a text or icon colour on the page (a text button, a
  // selected list row). The pastel default on a light page is about 1.4 : 1;
  // this is the same hue moved towards black until it reaches 3 : 1. When
  // the accent already reaches 3 : 1 it is the accent itself.
  final Color accentInk = accentForegroundFor(accent, bg);

  final Color outline = p?.outline ?? iconFg.withValues(alpha: scaled(0.55));
  final Color outlineVariant =
      p?.outlineVariant ?? iconFg.withValues(alpha: scaled(0.25));
  final Color onSurfaceVariant =
      p?.onSurfaceVariant ?? iconFg.withValues(alpha: scaled(0.82));

  final Color errorColor =
      p?.error ?? (isDark ? const Color(0xFFFFB4AB) : const Color(0xFFBA1A1A));
  final Color errorContainer =
      p?.errorContainer ??
      (isDark ? const Color(0xFF93000A) : const Color(0xFFFFDAD6));
  final Color onErrorContainer =
      p?.onErrorContainer ??
      (isDark ? const Color(0xFFFFDAD6) : const Color(0xFF410002));

  final ColorScheme colorScheme = ColorScheme(
    brightness: brightness,
    primary: accent,
    // What sits on an accent fill: a filled button's label, its glyph, a
    // selected pill segment, a badge. The reader's own icon colour, unless
    // it is below 2 : 1 on the accent; then black or white, whichever reads
    // better (`readableOnFill`). White on an orange accent stays white; the
    // near-white default icon colour on the pastel blue default (1.33 : 1)
    // becomes black.
    onPrimary: readableOnFill(accent, iconFg),
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
    surfaceContainerLowest:
        p?.surfaceLowest ??
        (isDark ? bg.darken(scaled(0.02)) : bg.lighten(scaled(0.02))),
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
    success:
        p?.success ??
        (isDark ? const Color(0xFF7FD79A) : const Color(0xFF2E7D43)),
    onSuccess:
        p?.onSuccess ??
        (isDark ? const Color(0xFF003918) : const Color(0xFFFFFFFF)),
    successContainer:
        p?.successContainer ??
        (isDark ? const Color(0xFF143A1F) : const Color(0xFFB6F2C2)),
    onSuccessContainer:
        p?.onSuccessContainer ??
        (isDark ? const Color(0xFFA5F0B0) : const Color(0xFF002110)),
    warning:
        p?.warning ??
        (isDark ? const Color(0xFFFFC860) : const Color(0xFF855300)),
    warningContainer:
        p?.warningContainer ??
        (isDark ? const Color(0xFF3D2E00) : const Color(0xFFFFDEA4)),
    onWarningContainer:
        p?.onWarningContainer ??
        (isDark ? const Color(0xFFFFDEA4) : const Color(0xFF291800)),
    selection: selection,
    onSelection: onSelection,
    selectedFill: selectedFill,
    onSelectedFill: onSelectedFill,
    userBubble: userBubble,
    onUserBubble: onUserBubble,
  );

  // 'system' leaves [ThemeData.fontFamily] unset, so the platform default
  // font is used. Null or an unknown id means the default (Inter). A bundled
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
    // Every message the app drops on the reader, in one place.
    //
    // Flutter's default is a full-bleed rectangle glued to the bottom edge,
    // and there are over a hundred call sites that just call
    // `showSnackBar` — styling them one by one is how half of them end up
    // looking like the default again. So the shape lives here: a floating
    // pill in the same fill and radius as the rest of the floating chrome,
    // clear of the bottom edge, and swipeable away in either direction.
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: surface,
      contentTextStyle: TextStyle(
        color: iconFg,
        fontSize: 14,
        fontWeight: FontWeight.w500,
      ),
      actionTextColor: accent,
      // No shadow: the fill is a step off the page, which is what separates
      // it. A shadow on a borderless pill only draws a dark halo.
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
      insetPadding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
      dismissDirection: DismissDirection.horizontal,
      closeIconColor: iconFg,
    ),
    // Ink is rounded everywhere. A ListTile without a shape paints its
    // hover/press fill as a full-bleed rectangle, which is what makes a
    // rounded settings card turn square the moment you touch it.
    listTileTheme: ListTileThemeData(
      iconColor: iconFg,
      textColor: iconFg,
      selectedColor: p?.onSelection ?? accentInk,
      selectedTileColor: p?.selection ?? accent.withValues(alpha: 0.1),
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
    // Every floating action button carries the accent fill, with the glyph
    // colour picked for contrast. The Material default is a muted container
    // that reads as a disabled button next to the app's other actions.
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: accent,
      foregroundColor:
          ThemeData.estimateBrightnessForColor(accent) == Brightness.dark
          ? const Color(0xFFFFFFFF)
          : const Color(0xFF000000),
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
        padding: _kButtonPadding,
        minimumSize: _kButtonMinSize,
        textStyle: _kButtonTextStyle,
        elevation: 0,
      ).copyWith(shape: _kM3eButtonShape),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: surfaceHigh,
        foregroundColor: iconFg,
        padding: _kButtonPadding,
        minimumSize: _kButtonMinSize,
        textStyle: _kButtonTextStyle,
        elevation: 0,
      ).copyWith(shape: _kM3eButtonShape),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: iconFg,
        side: BorderSide(color: outline),
        padding: _kButtonPadding,
        minimumSize: _kButtonMinSize,
        textStyle: _kButtonTextStyle,
      ).copyWith(shape: _kM3eButtonShape),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: accentInk,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        minimumSize: const Size(0, 44),
        textStyle: _kButtonTextStyle,
      ).copyWith(shape: _kM3eButtonShape),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(foregroundColor: iconFg)
          .copyWith(shape: _kM3eIconButtonShape),
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

    // Progress and sliders on the current Material 3 spec (not the 2023
    // one): rounded track ends, a gap between active and inactive track,
    // the stop dot at the end, the tall slider handle. M3 Expressive builds
    // on this geometry (m3.material.io/components/progress-indicators,
    // /sliders).
    // ignore: deprecated_member_use
    progressIndicatorTheme: const ProgressIndicatorThemeData(year2023: false),
    // ignore: deprecated_member_use
    sliderTheme: const SliderThemeData(year2023: false),

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
        borderRadius: BorderRadius.vertical(
          top: Radius.circular(kRadiusDialog),
        ),
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

/// Width of the open desktop sidebar: chuk's chat list and the Agents roster.
/// Both halves use this one number, so the switch between them does not move
/// the content.
const double kDesktopSidebarWidth = 320.0;
const double kTabletBreakpoint = 800.0; // NEW: Define tablet breakpoint

/* ---------- MAIN UI LAYOUT CONSTANTS ---------- */
const double kFixedLeftPadding = 8.0;
const double kTopInitialSpacing = 16.0;
const double kMenuButtonHeight = 48.0;
const double kButtonVisualHeight = 40.0;
