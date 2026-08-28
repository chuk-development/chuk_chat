import 'package:flutter/material.dart';

/// The icon foreground colour the chat-mode selector and its menus paint with.
/// Ported from chuk_chat so the composer's pill matches it exactly.
extension ThemeDataIconColorX on ThemeData {
  Color get resolvedIconColor => iconTheme.color ?? colorScheme.onSurface;
}
