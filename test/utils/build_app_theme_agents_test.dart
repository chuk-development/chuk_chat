import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/services/agents/agents_chat_core.dart';

/// The theme has two sides. With Agents off it is upstream chuk_chat's; with
/// Agents on it is the Agents app's (its on-accent colour, the default
/// SnackBar, the expressive type layer and the rounder shape scale).
void main() {
  ThemeData build(Brightness b) => buildAppTheme(
    accent: kDefaultAccentColor,
    iconFg: kDefaultIconFgColor,
    bg: kDefaultBgColor,
    brightness: b,
  );

  tearDown(() => debugAgentsChatCoreOverride = null);

  test('Agents off: upstream on-accent colour, pill SnackBar, flat type', () {
    debugAgentsChatCoreOverride = false;
    final ThemeData t = build(Brightness.dark);
    expect(t.colorScheme.onPrimary, kDefaultIconFgColor);
    expect(t.snackBarTheme.behavior, SnackBarBehavior.floating);
    expect(t.floatingActionButtonTheme.elevation, isNull);
    expect(kRadiusCard, 20);
    expect(kRadiusRow, 14);
  });

  test('Agents on: the Agents app navy / white on accent fills', () {
    debugAgentsChatCoreOverride = true;
    expect(build(Brightness.dark).colorScheme.onPrimary, const Color(0xFF062E6F));
    expect(build(Brightness.light).colorScheme.onPrimary, const Color(0xFFFFFFFF));
  });

  test('Agents on: default SnackBar, expressive layer, rounder shapes', () {
    debugAgentsChatCoreOverride = true;
    final ThemeData t = build(Brightness.dark);
    expect(t.snackBarTheme.behavior, isNull);
    expect(t.textTheme.headlineLarge?.fontWeight, FontWeight.w800);
    expect(t.floatingActionButtonTheme.elevation, 3);
    expect(kRadiusCard, 28);
    expect(kRadiusRow, 20);
  });
}
