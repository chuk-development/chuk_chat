// Where an anchored dropdown lands. The rule the composer needs: with the
// keyboard up, the menu opens above the button, never behind the keyboard.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/widgets/anchored_menu.dart';

const Size _screen = Size(400, 800);

Future<void> _pumpAnchor(
  WidgetTester tester, {
  required double keyboardInset,
  required Alignment anchorAt,
  int itemCount = 3,
  bool preferAbove = false,
}) async {
  await tester.pumpWidget(
    MediaQuery(
      // Above the app, the way the real keyboard inset arrives: the
      // Scaffold below strips it from the body again.
      data: MediaQueryData(
        size: _screen,
        viewInsets: EdgeInsets.only(bottom: keyboardInset),
      ),
      child: MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: anchorAt,
            child: Builder(
              builder: (context) => SizedBox(
                width: 60,
                height: 40,
                child: GestureDetector(
                  onTap: () => showAnchoredMenu<int>(
                    context,
                    items: <PopupMenuEntry<int>>[
                      for (int i = 0; i < itemCount; i++)
                        PopupMenuItem<int>(
                          value: i,
                          height: 40,
                          child: Text('row $i'),
                        ),
                    ],
                    color: Colors.black,
                    borderColor: Colors.white,
                    preferAbove: preferAbove,
                  ),
                  child: const ColoredBox(
                    color: Colors.blue,
                    child: Text('open'),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('with the keyboard up the menu opens above the button', (
    tester,
  ) async {
    tester.view.physicalSize = _screen;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _pumpAnchor(
      tester,
      keyboardInset: 300,
      anchorAt: Alignment.bottomCenter,
    );

    final Rect anchor = tester.getRect(find.text('open'));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final Rect menu = tester.getRect(find.text('row 0').hitTestable());
    expect(
      menu.bottom,
      lessThanOrEqualTo(anchor.top),
      reason: 'the menu must not cover or sit below its own button',
    );
  });

  testWidgets('the menu stays clear of the keyboard', (tester) async {
    tester.view.physicalSize = _screen;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _pumpAnchor(
      tester,
      keyboardInset: 300,
      anchorAt: Alignment.bottomCenter,
      itemCount: 6,
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final double keyboardTop = _screen.height - 300;
    int checked = 0;
    for (int i = 0; i < 6; i++) {
      final Finder row = find.text('row $i');
      if (row.evaluate().isEmpty) continue; // scrolled out, still fine
      expect(tester.getRect(row).bottom, lessThanOrEqualTo(keyboardTop));
      checked++;
    }
    expect(checked, greaterThan(0), reason: 'the menu never opened');
  });

  testWidgets('with room below and no keyboard the menu opens downwards', (
    tester,
  ) async {
    tester.view.physicalSize = _screen;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _pumpAnchor(tester, keyboardInset: 0, anchorAt: Alignment.topCenter);

    final Rect anchor = tester.getRect(find.text('open'));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(
      tester.getRect(find.text('row 0').hitTestable()).top,
      greaterThanOrEqualTo(anchor.bottom),
    );
  });

  testWidgets('preferAbove opens upwards even with room below', (tester) async {
    tester.view.physicalSize = _screen;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // Middle of the screen: room on both sides, and more of it below.
    await _pumpAnchor(
      tester,
      keyboardInset: 0,
      anchorAt: const Alignment(0, 0.2),
      preferAbove: true,
    );

    final Rect anchor = tester.getRect(find.text('open'));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(
      tester.getRect(find.text('row 0').hitTestable()).top,
      lessThan(anchor.top),
    );
  });

  testWidgets('preferAbove gives up when there is no room up there', (
    tester,
  ) async {
    tester.view.physicalSize = _screen;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _pumpAnchor(
      tester,
      keyboardInset: 0,
      anchorAt: Alignment.topCenter,
      preferAbove: true,
    );

    final Rect anchor = tester.getRect(find.text('open'));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(
      tester.getRect(find.text('row 0').hitTestable()).top,
      greaterThanOrEqualTo(anchor.bottom),
    );
  });
}
