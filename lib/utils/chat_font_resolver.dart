// lib/utils/chat_font_resolver.dart
//
// Resolves chat font family identifiers to actual [fontFamily] strings.
// GoogleFonts.<name>().fontFamily returns the cached family name that can be
// handed to [TextStyle.fontFamily]; the font assets themselves are lazily
// downloaded and cached by the google_fonts package on first use.

import 'package:google_fonts/google_fonts.dart';

import 'package:chuk_chat/constants.dart';

/// Map a stored identifier (e.g. `'arimo'`) to a font family string usable
/// by [TextStyle.fontFamily]. Returns `null` for the system default so the
/// platform font stack is used.
String? resolveChatFontFamily(String id) {
  switch (id) {
    case kChatFontFamilySystem:
      return null;
    case kChatFontFamilyArimo:
      return GoogleFonts.arimo().fontFamily;
    case kChatFontFamilyMerriweather:
      return GoogleFonts.merriweather().fontFamily;
    case kChatFontFamilyJetBrainsMono:
      return GoogleFonts.jetBrainsMono().fontFamily;
    default:
      return GoogleFonts.arimo().fontFamily;
  }
}
