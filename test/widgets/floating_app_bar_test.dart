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
}
