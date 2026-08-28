import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cowork/pages/settings/settings_page.dart';
import 'package:cowork/pages/settings/theme_settings_page.dart';
import 'package:cowork/services/settings/theme_controller.dart';

void main() {
  Future<void> pumpSettings(
    WidgetTester tester,
    ThemeController controller,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: SettingsPage(themeController: controller)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('the settings hub lists every area as a tile', (tester) async {
    final controller = ThemeController();
    await pumpSettings(tester, controller);

    // Both the app-bar title and the big page title read "Settings".
    expect(find.text('Settings'), findsWidgets);
    expect(find.text('Account'), findsWidgets);
    expect(find.text('Model'), findsOneWidget);
    expect(find.text('MCP Connectors'), findsOneWidget);
    expect(find.text('Embedding model'), findsOneWidget);
    expect(find.text('Theme'), findsOneWidget);
    // Developer sits below the fold on the test surface — scroll it in.
    await tester.scrollUntilVisible(find.text('Developer'), 200);
    expect(find.text('Developer'), findsOneWidget);
  });

  testWidgets('the Theme tile subtitle follows the controller', (tester) async {
    final controller = ThemeController(ThemeMode.dark);
    await pumpSettings(tester, controller);

    // The Theme tile shows the current mode as its subtitle.
    expect(find.text('Dark'), findsOneWidget);
  });

  testWidgets('opening Theme and tapping Light updates the controller',
      (tester) async {
    final controller = ThemeController();
    await pumpSettings(tester, controller);

    await tester.tap(find.text('Theme'));
    await tester.pumpAndSettle();

    expect(find.byType(ThemeSettingsPage), findsOneWidget);
    await tester.tap(find.text('Light'));
    await tester.pumpAndSettle();

    expect(controller.value, ThemeMode.light);
  });
}
