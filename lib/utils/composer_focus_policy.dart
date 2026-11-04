// lib/utils/composer_focus_policy.dart
//
// When the chat may move the keyboard focus into the composer by itself, and
// how large the composer text is. Pure functions, so the rules are testable
// without building a chat screen.

import 'package:flutter/foundation.dart';

/// Whether a chat screen may focus the composer without a tap: on load, on a
/// new chat, after a send.
///
/// Never on a phone (Android, iOS) and never on the web, where the page may
/// run on a phone: a focus grab opens the soft keyboard over the thread the
/// reader just opened. With a hardware keyboard (desktop) the focus costs
/// nothing and stays.
bool mayAutoFocusComposer({bool? isWeb, TargetPlatform? platform}) {
  final bool web = isWeb ?? kIsWeb;
  final TargetPlatform target = platform ?? defaultTargetPlatform;
  if (web) return false;
  return target != TargetPlatform.android && target != TargetPlatform.iOS;
}

/// Composer font size. 16 on the web: mobile Safari zooms the page into any
/// field whose text is under 16 px. 15 elsewhere, as the composer always was.
double composerFontSize({bool? isWeb}) => (isWeb ?? kIsWeb) ? 16 : 15;
