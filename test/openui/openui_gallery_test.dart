// Smoke test for the dev gallery entrypoint.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/openui/dev/gallery_main.dart';

void main() {
  testWidgets('the gallery lists the samples, toggles, streams', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1400, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const OpenUiGalleryApp());
    await tester.pumpAndSettle();
    expect(find.textContaining('OpenUI gallery ('), findsOneWidget);
    expect(find.text('chat_ex1.oui'), findsOneWidget);

    await tester.tap(find.text('Light'));
    await tester.pumpAndSettle();
    expect(find.text('Dark'), findsOneWidget);

    await tester.tap(find.text('Source').first);
    await tester.pumpAndSettle();
    expect(find.text('Hide source'), findsOneWidget);

    await tester.tap(find.text('Stream').first);
    // The replay shows 12 characters per 16 ms; 800 frames cover the
    // longest sample.
    for (var i = 0; i < 800; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
