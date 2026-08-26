import 'package:flutter/painting.dart';

/// Font category for the quick-access font picker buttons.
enum FontCategory { handDrawn, normal, code }

/// Resolves font family names to Flutter [TextStyle]s.
///
/// Three resolution strategies:
/// - **Bundled** (`Excalifont`, `Virgil`): resolved from pubspec font assets
/// - **Google Fonts** (`Nunito`, `Lilita One`, `Assistant`, etc.): resolved via
///   [GoogleFonts]
/// - **System** (everything else): plain `TextStyle(fontFamily:)` — platform
///   fallback
class FontResolver {
  /// The default font family used for new text elements.
  static const defaultFontFamily = 'Excalifont';

  /// All known font families (for serialization compatibility).
  static const allFonts = [
    'Excalifont',
    'Virgil',
    'Helvetica',
    'Cascadia',
    'Nunito',
    'Lilita One',
    'Comic Shanns',
    'Liberation Sans',
    'Assistant',
    'Roboto',
    'Open Sans',
    'Lato',
    'Montserrat',
    'Playfair Display',
    'Source Code Pro',
    'Fira Code',
    'Caveat',
    'Pacifico',
    'Dancing Script',
  ];

  /// Curated list for the property panel font picker.
  static const uiFonts = [
    'Excalifont',
    'Virgil',
    'Caveat',
    'Dancing Script',
    'Pacifico',
    'Nunito',
    'Assistant',
    'Roboto',
    'Open Sans',
    'Lato',
    'Montserrat',
    'Lilita One',
    'Playfair Display',
    'Source Code Pro',
    'Fira Code',
    'Cascadia',
    'Helvetica',
  ];

  /// Maps font family names to their category.
  static const fontCategories = <String, FontCategory>{
    'Excalifont': FontCategory.handDrawn,
    'Virgil': FontCategory.handDrawn,
    'Caveat': FontCategory.handDrawn,
    'Dancing Script': FontCategory.handDrawn,
    'Pacifico': FontCategory.handDrawn,
    'Nunito': FontCategory.normal,
    'Helvetica': FontCategory.normal,
    'Assistant': FontCategory.normal,
    'Roboto': FontCategory.normal,
    'Open Sans': FontCategory.normal,
    'Lato': FontCategory.normal,
    'Montserrat': FontCategory.normal,
    'Liberation Sans': FontCategory.normal,
    'Lilita One': FontCategory.normal,
    'Playfair Display': FontCategory.normal,
    'Comic Shanns': FontCategory.code,
    'Cascadia': FontCategory.code,
    'Source Code Pro': FontCategory.code,
    'Fira Code': FontCategory.code,
  };

  /// Returns the [FontCategory] for the given font family.
  static FontCategory categoryOf(String fontFamily) =>
      fontCategories[fontFamily] ?? FontCategory.normal;

  /// Default font for each category (used by quick-access buttons).
  static const defaultForCategory = <FontCategory, String>{
    FontCategory.handDrawn: 'Excalifont',
    FontCategory.normal: 'Nunito',
    FontCategory.code: 'Source Code Pro',
  };

  /// Resolves a font family name to a [TextStyle].
  ///
  /// Merges the resolved font into [baseStyle] if provided. Every family is
  /// resolved as a plain [TextStyle.fontFamily]: the bundled families
  /// (`Excalifont`, `Virgil`) render from the pubspec font assets, and any
  /// other family falls back to the platform font stack. The runtime Google
  /// Fonts download path was removed with the `google_fonts` dependency to
  /// drop its font metadata table from the release snapshot.
  static TextStyle resolve(String fontFamily, {TextStyle? baseStyle}) {
    final base = baseStyle ?? const TextStyle();
    return base.copyWith(fontFamily: fontFamily);
  }
}
