import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/services/agents/agents_chat_core.dart';

/// The theme has one side. The Agents build uses chuk_chat's theme as is: the
/// on-accent colour, the pill SnackBar, the FAB, the type and the shape scale
/// do not change with the flag.
void main() {
  ThemeData build(Brightness b) => buildAppTheme(
    accent: kDefaultAccentColor,
    iconFg: kDefaultIconFgColor,
    bg: kDefaultBgColor,
    brightness: b,
  );

  tearDown(() => debugAgentsChatCoreOverride = null);

  for (final bool agents in <bool>[false, true]) {
    test('Agents $agents: chuk_chat on-accent colour, pill SnackBar, flat '
        'type', () {
      debugAgentsChatCoreOverride = agents;
      final ThemeData dark = build(Brightness.dark);
      final ThemeData light = build(Brightness.light);
      expect(dark.colorScheme.onPrimary, kDefaultIconFgColor);
      expect(light.colorScheme.onPrimary, kDefaultIconFgColor);
      expect(dark.snackBarTheme.behavior, SnackBarBehavior.floating);
      expect(dark.floatingActionButtonTheme.elevation, isNull);
      expect(
        dark.floatingActionButtonTheme.backgroundColor,
        kDefaultAccentColor,
      );
      expect(
        dark.textTheme.headlineLarge?.fontWeight,
        ThemeData(brightness: Brightness.dark).textTheme.headlineLarge
            ?.fontWeight,
      );
    });
  }

  test('the shape scale is chuk_chat\'s', () {
    expect(kRadiusCard, 20);
    expect(kRadiusField, 16);
    expect(kRadiusMenu, 16);
    expect(kRadiusRow, 14);
    expect(kRadiusDialog, 28);
  });
}
