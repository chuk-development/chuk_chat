import 'package:flutter/material.dart';

extension ThemeDataIconColorX on ThemeData {
  Color get resolvedIconColor => iconTheme.color ?? colorScheme.onSurface;

  /// The glyph colour for a button that is filled with the accent — the send
  /// button, the new-chat button, every round accent circle.
  ///
  /// Every other icon in the app is the reader's own icon colour, so these
  /// buttons take that colour too rather than flipping to a flat black or
  /// white picked purely for contrast: a black glyph on the one accent-filled
  /// control looks pasted in from another app.
  ///
  /// The icon colour is often a muted tone, though, and muted-on-accent can
  /// be unreadable — the default tan sits at a contrast of 1.2 against the
  /// default orange. So the glyph keeps that hue and is lightened towards
  /// white until it reads: near-white with a trace of the accent in it, which
  /// is what the rest of the app looks like anyway. Only an accent too pale
  /// for any light glyph sends it the other way, towards black.
  Color accentButtonForeground(Color fill) {
    const double target = 2.0;
    final Color tint = resolvedIconColor;
    if (_contrastRatio(tint, fill) >= target) return tint;

    final Color? lightened = _blendUntilReadable(tint, Colors.white, fill);
    if (lightened != null) return lightened;

    // Not even white reads on this fill, so the fill is pale. Same walk the
    // other way.
    return _blendUntilReadable(tint, Colors.black, fill) ?? Colors.black;
  }
}

/// Walks [from] towards [towards] in tenths and returns the first blend that
/// reaches a contrast of 2.0 against [on]. Null when the far end never does.
Color? _blendUntilReadable(Color from, Color towards, Color on) {
  for (int step = 1; step <= 10; step++) {
    final Color candidate = Color.lerp(from, towards, step / 10)!;
    if (_contrastRatio(candidate, on) >= 2.0) return candidate;
  }
  return null;
}

/// WCAG contrast ratio, 1.0 (identical) to 21.0 (black on white).
double _contrastRatio(Color a, Color b) {
  final double la = a.computeLuminance();
  final double lb = b.computeLuminance();
  final double hi = la > lb ? la : lb;
  final double lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

/// Material You extension tokens that aren't exposed on the default
/// [ColorScheme]. Pages read these via `Theme.of(context).m3`.
@immutable
class MaterialYouTokens extends ThemeExtension<MaterialYouTokens> {
  const MaterialYouTokens({
    required this.surfaceContainerLow,
    required this.surfaceContainer,
    required this.surfaceContainerHigh,
    required this.surfaceContainerHighest,
    required this.primaryContainer,
    required this.onPrimaryContainer,
    required this.secondaryContainer,
    required this.onSecondaryContainer,
    required this.tertiaryContainer,
    required this.onTertiaryContainer,
    required this.outline,
    required this.outlineVariant,
    required this.onSurfaceVariant,
    required this.success,
    required this.onSuccess,
    required this.successContainer,
    required this.onSuccessContainer,
    required this.warning,
    required this.warningContainer,
    required this.onWarningContainer,
  });

  final Color surfaceContainerLow;
  final Color surfaceContainer;
  final Color surfaceContainerHigh;
  final Color surfaceContainerHighest;
  final Color primaryContainer;
  final Color onPrimaryContainer;
  final Color secondaryContainer;
  final Color onSecondaryContainer;
  final Color tertiaryContainer;
  final Color onTertiaryContainer;
  final Color outline;
  final Color outlineVariant;
  final Color onSurfaceVariant;
  final Color success;
  final Color onSuccess;
  final Color successContainer;
  final Color onSuccessContainer;
  final Color warning;
  final Color warningContainer;
  final Color onWarningContainer;

  @override
  MaterialYouTokens copyWith({
    Color? surfaceContainerLow,
    Color? surfaceContainer,
    Color? surfaceContainerHigh,
    Color? surfaceContainerHighest,
    Color? primaryContainer,
    Color? onPrimaryContainer,
    Color? secondaryContainer,
    Color? onSecondaryContainer,
    Color? tertiaryContainer,
    Color? onTertiaryContainer,
    Color? outline,
    Color? outlineVariant,
    Color? onSurfaceVariant,
    Color? success,
    Color? onSuccess,
    Color? successContainer,
    Color? onSuccessContainer,
    Color? warning,
    Color? warningContainer,
    Color? onWarningContainer,
  }) {
    return MaterialYouTokens(
      surfaceContainerLow: surfaceContainerLow ?? this.surfaceContainerLow,
      surfaceContainer: surfaceContainer ?? this.surfaceContainer,
      surfaceContainerHigh: surfaceContainerHigh ?? this.surfaceContainerHigh,
      surfaceContainerHighest:
          surfaceContainerHighest ?? this.surfaceContainerHighest,
      primaryContainer: primaryContainer ?? this.primaryContainer,
      onPrimaryContainer: onPrimaryContainer ?? this.onPrimaryContainer,
      secondaryContainer: secondaryContainer ?? this.secondaryContainer,
      onSecondaryContainer: onSecondaryContainer ?? this.onSecondaryContainer,
      tertiaryContainer: tertiaryContainer ?? this.tertiaryContainer,
      onTertiaryContainer: onTertiaryContainer ?? this.onTertiaryContainer,
      outline: outline ?? this.outline,
      outlineVariant: outlineVariant ?? this.outlineVariant,
      onSurfaceVariant: onSurfaceVariant ?? this.onSurfaceVariant,
      success: success ?? this.success,
      onSuccess: onSuccess ?? this.onSuccess,
      successContainer: successContainer ?? this.successContainer,
      onSuccessContainer: onSuccessContainer ?? this.onSuccessContainer,
      warning: warning ?? this.warning,
      warningContainer: warningContainer ?? this.warningContainer,
      onWarningContainer: onWarningContainer ?? this.onWarningContainer,
    );
  }

  @override
  MaterialYouTokens lerp(
    covariant ThemeExtension<MaterialYouTokens>? other,
    double t,
  ) {
    if (other is! MaterialYouTokens) return this;
    return MaterialYouTokens(
      surfaceContainerLow:
          Color.lerp(surfaceContainerLow, other.surfaceContainerLow, t)!,
      surfaceContainer:
          Color.lerp(surfaceContainer, other.surfaceContainer, t)!,
      surfaceContainerHigh:
          Color.lerp(surfaceContainerHigh, other.surfaceContainerHigh, t)!,
      surfaceContainerHighest: Color.lerp(
        surfaceContainerHighest,
        other.surfaceContainerHighest,
        t,
      )!,
      primaryContainer:
          Color.lerp(primaryContainer, other.primaryContainer, t)!,
      onPrimaryContainer:
          Color.lerp(onPrimaryContainer, other.onPrimaryContainer, t)!,
      secondaryContainer:
          Color.lerp(secondaryContainer, other.secondaryContainer, t)!,
      onSecondaryContainer:
          Color.lerp(onSecondaryContainer, other.onSecondaryContainer, t)!,
      tertiaryContainer:
          Color.lerp(tertiaryContainer, other.tertiaryContainer, t)!,
      onTertiaryContainer:
          Color.lerp(onTertiaryContainer, other.onTertiaryContainer, t)!,
      outline: Color.lerp(outline, other.outline, t)!,
      outlineVariant: Color.lerp(outlineVariant, other.outlineVariant, t)!,
      onSurfaceVariant:
          Color.lerp(onSurfaceVariant, other.onSurfaceVariant, t)!,
      success: Color.lerp(success, other.success, t)!,
      onSuccess: Color.lerp(onSuccess, other.onSuccess, t)!,
      successContainer:
          Color.lerp(successContainer, other.successContainer, t)!,
      onSuccessContainer:
          Color.lerp(onSuccessContainer, other.onSuccessContainer, t)!,
      warning: Color.lerp(warning, other.warning, t)!,
      warningContainer:
          Color.lerp(warningContainer, other.warningContainer, t)!,
      onWarningContainer:
          Color.lerp(onWarningContainer, other.onWarningContainer, t)!,
    );
  }
}

extension MaterialYouTokensX on ThemeData {
  /// Returns Material You extension tokens. Falls back to sensible defaults
  /// derived from the current [ColorScheme] if no extension is registered.
  MaterialYouTokens get m3 {
    final ext = extension<MaterialYouTokens>();
    if (ext != null) return ext;
    final cs = colorScheme;
    final isDark = brightness == Brightness.dark;
    return MaterialYouTokens(
      surfaceContainerLow: isDark
          ? const Color(0xFF191C20)
          : const Color(0xFFF3F3F8),
      surfaceContainer: isDark
          ? const Color(0xFF1D2024)
          : const Color(0xFFEDEEF3),
      surfaceContainerHigh: isDark
          ? const Color(0xFF272A2F)
          : const Color(0xFFE7E8ED),
      surfaceContainerHighest: isDark
          ? const Color(0xFF32353A)
          : const Color(0xFFE1E2E8),
      primaryContainer: cs.primaryContainer,
      onPrimaryContainer: cs.onPrimaryContainer,
      secondaryContainer: cs.secondaryContainer,
      onSecondaryContainer: cs.onSecondaryContainer,
      tertiaryContainer: cs.tertiaryContainer,
      onTertiaryContainer: cs.onTertiaryContainer,
      outline: cs.outline,
      outlineVariant: cs.outlineVariant,
      onSurfaceVariant: cs.onSurfaceVariant,
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
  }
}
