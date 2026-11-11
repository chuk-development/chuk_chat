import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/widgets/message_bubble.dart';

import '../support/test_app.dart';

/// The user bubble's text keeps the reader's icon colour unless that falls
/// below 2 : 1 on the bubble fill (UI audit 2026-10-05, R-2).

// The pastel-blue look these rules were written for (the app default until
// the Plane pack, now the Aya pack's dark variant).
const Color _kPastelAccent = Color(0xFFA8C7FA);
const Color _kPastelIconFg = Color(0xFFE2E2E9);
const Color _kPastelBg = Color(0xFF111318);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  Future<Color?> userTextColour(
    WidgetTester tester, {
    required Color accent,
    required Color iconFg,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildAppTheme(
          accent: accent,
          iconFg: iconFg,
          bg: _kPastelBg,
          brightness: Brightness.dark,
        ),
        localizationsDelegates: kTestLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(
          body: MessageBubble(
            message: 'hello there',
            isUser: true,
            maxWidth: 400,
          ),
        ),
      ),
    );
    await tester.pump();
    final Text text = tester.widget<Text>(find.text('hello there'));
    return text.style?.color;
  }

  testWidgets('owner look: white text on the orange accent stays white', (
    tester,
  ) async {
    expect(
      await userTextColour(
        tester,
        accent: const Color(0xFFE07A5F),
        iconFg: const Color(0xFFFFFFFF),
      ),
      const Color(0xFFFFFFFF),
    );
  });

  testWidgets('pastel default: near-white icon colour flips to black', (
    tester,
  ) async {
    expect(
      await userTextColour(
        tester,
        accent: _kPastelAccent,
        iconFg: _kPastelIconFg,
      ),
      const Color(0xFF000000),
    );
  });
}
