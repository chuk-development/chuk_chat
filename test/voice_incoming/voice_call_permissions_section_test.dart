// Settings → Voice calls: its own page with one row per grant; a tap asks for
// a missing one, a granted one shows as allowed.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/voice/incoming/voice_call_permissions.dart';
import 'package:chuk_chat/voice/incoming/voice_call_settings_page.dart';

void main() {
  testWidgets('shows every grant and asks for a missing one', (
    WidgetTester tester,
  ) async {
    final Map<VoiceCallGrant, bool> granted = <VoiceCallGrant, bool>{
      VoiceCallGrant.microphone: true,
      VoiceCallGrant.notifications: false,
      VoiceCallGrant.fullScreenIntent: false,
      VoiceCallGrant.background: false,
    };
    final List<VoiceCallGrant> asked = <VoiceCallGrant>[];

    await tester.pumpWidget(
      MaterialApp(
        home: VoiceCallSettingsPage(
          load: () async => Map<VoiceCallGrant, bool>.of(granted),
          ask: (VoiceCallGrant g) async {
            asked.add(g);
            granted[g] = true;
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Its own page, titled like the settings row that opens it.
    expect(find.text('Voice calls'), findsOneWidget);
    expect(find.text('What a call needs'), findsOneWidget);
    expect(find.text('Microphone'), findsOneWidget);
    expect(find.text('Notifications'), findsOneWidget);
    expect(find.text('Ring over the lock screen'), findsOneWidget);
    expect(find.text('Run in the background'), findsOneWidget);
    // Three still missing.
    expect(find.textContaining('Not allowed.'), findsNWidgets(3));

    await tester.tap(find.text('Ring over the lock screen'));
    await tester.pumpAndSettle();
    expect(asked, <VoiceCallGrant>[VoiceCallGrant.fullScreenIntent]);
    expect(find.textContaining('Not allowed.'), findsNWidgets(2));

    // A granted row does not ask again.
    await tester.tap(find.text('Microphone'));
    await tester.pumpAndSettle();
    expect(asked, <VoiceCallGrant>[VoiceCallGrant.fullScreenIntent]);
  });
}
