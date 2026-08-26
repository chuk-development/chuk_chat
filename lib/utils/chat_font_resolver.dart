// lib/utils/chat_font_resolver.dart
//
// Resolves chat font family identifiers to actual [fontFamily] strings.
// The three chat fonts are bundled as assets (declared in pubspec.yaml under
// `flutter: fonts:`), so the family name is handed straight to
// [TextStyle.fontFamily] with no runtime download.

import 'package:chuk_chat/constants.dart';

/// Family name of the bundled Arimo font (see `pubspec.yaml`).
const String kFontFamilyArimo = 'Arimo';

/// Family name of the bundled Merriweather font (see `pubspec.yaml`).
const String kFontFamilyMerriweather = 'Merriweather';

/// Family name of the bundled JetBrains Mono font (see `pubspec.yaml`).
const String kFontFamilyJetBrainsMono = 'JetBrains Mono';

/// Map a stored identifier (e.g. `'arimo'`) to a font family string usable
/// by [TextStyle.fontFamily]. Returns `null` for the system default so the
/// platform font stack is used.
String? resolveChatFontFamily(String id) {
  switch (id) {
    case kChatFontFamilySystem:
      return null;
    case kChatFontFamilyArimo:
      return kFontFamilyArimo;
    case kChatFontFamilyMerriweather:
      return kFontFamilyMerriweather;
    case kChatFontFamilyJetBrainsMono:
      return kFontFamilyJetBrainsMono;
    default:
      return kFontFamilyArimo;
  }
}

/// Normalize an unknown id (e.g. from Supabase) back to a known value so the
/// UI and persistence never drift.
String sanitizeChatFontFamily(String? id) {
  if (id == null || !kSupportedChatFontFamilies.contains(id)) {
    return kDefaultChatFontFamily;
  }
  return id;
}
