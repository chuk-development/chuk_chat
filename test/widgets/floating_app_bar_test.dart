import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/widgets/floating_app_bar.dart';
import 'package:chuk_chat/widgets/floating_chrome_surface.dart';

void main() {
  Widget page({List<Widget>? actions}) => Scaffold(
    appBar: FloatingAppBar(title: const Text('Settings'), actions: actions),
    body: const SizedBox(height: 2000),
  );

  testWidgets('the bar itself draws nothing — the page shows behind it', (
    tester,
  ) async {
    await tester.pumpWidget(MaterialApp(home: page()));
    final AppBar bar = tester.widget<AppBar>(find.byType(AppBar));
    expect(bar.backgroundColor, Colors.transparent);
    expect(bar.elevation, 0);
    expect(bar.scrolledUnderElevation, 0);
  });

  testWidgets('the title is a floating pill', (tester) async {
    await tester.pumpWidget(MaterialApp(home: page()));
    expect(find.text('Settings'), findsOneWidget);
    expect(
      find.ancestor(
        of: find.text('Settings'),
        matching: find.byType(FloatingChromeSurface),
      ),
      findsOneWidget,
    );
  });

  testWidgets('a pushed page gets a floating back chip that pops', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(builder: (_) => page()),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byType(FloatingHeaderButton), findsOneWidget);
    await tester.tap(find.byType(FloatingHeaderButton));
    await tester.pumpAndSettle();
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('a root page has no back chip', (tester) async {
    await tester.pumpWidget(MaterialApp(home: page()));
    expect(find.byType(FloatingHeaderButton), findsNothing);
  });

  group('FloatingHeaderButton', () {
    Future<void> pumpChip(WidgetTester tester, Widget chip) =>
        tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: Center(child: chip)),
          ),
        );

    BoxDecoration chipDecoration(WidgetTester tester) {
      final Ink ink = tester.widget<Ink>(
        find.descendant(
          of: find.byType(FloatingHeaderButton),
          matching: find.byType(Ink),
        ),
      );
      return ink.decoration! as BoxDecoration;
    }

    testWidgets('is an opaque 42 px circle with a 48 px press', (
      tester,
    ) async {
      await pumpChip(
        tester,
        FloatingHeaderButton(
          icon: Icons.close,
          tooltip: 'Close',
          onPressed: () {},
        ),
      );
      final BoxDecoration deco = chipDecoration(tester);
      expect(deco.shape, BoxShape.circle);
      // Never transparent: a bare glyph over a light map vanishes.
      expect(deco.color!.a, greaterThan(0.9));
      expect(deco.boxShadow, isNull);
      expect(
        tester.getSize(find.byType(FloatingHeaderButton)),
        const Size(kFloatingAppBarTarget, kFloatingAppBarTarget),
      );
      expect(
        tester.getSize(
          find.descendant(
            of: find.byType(FloatingHeaderButton),
            matching: find.byType(Ink),
          ),
        ),
        const Size(kFloatingAppBarChip, kFloatingAppBarChip),
      );
    });

    testWidgets('accent fills with the primary colour', (tester) async {
      await pumpChip(
        tester,
        FloatingHeaderButton(
          icon: Icons.check,
          accent: true,
          onPressed: () {},
        ),
      );
      final BuildContext context = tester.element(
        find.byType(FloatingHeaderButton),
      );
      expect(
        chipDecoration(tester).color,
        Theme.of(context).colorScheme.primary,
      );
    });

    testWidgets('busy shows a spinner and swallows the tap', (tester) async {
      int taps = 0;
      await pumpChip(
        tester,
        FloatingHeaderButton(
          icon: Icons.download,
          busy: true,
          onPressed: () => taps++,
        ),
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.tap(find.byType(FloatingHeaderButton));
      expect(taps, 0);
    });

    testWidgets('parked keeps the tap', (tester) async {
      int taps = 0;
      await pumpChip(
        tester,
        FloatingHeaderButton(
          icon: Icons.call,
          parked: true,
          onPressed: () => taps++,
        ),
      );
      await tester.tap(find.byType(FloatingHeaderButton));
      expect(taps, 1);
    });
  });

  testWidgets('a bar without a title draws no pill', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(appBar: FloatingAppBar())),
    );
    expect(find.byType(FloatingChromeSurface), findsNothing);
  });
}
