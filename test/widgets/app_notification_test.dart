import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/widgets/app_notification.dart';
import 'package:chuk_chat/widgets/floating_chrome_surface.dart';
import 'package:chuk_chat/widgets/nice_snackbar.dart';

void main() {
  Widget host(void Function(BuildContext) onTap) => MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => TextButton(
          onPressed: () => onTap(context),
          child: const Text('go'),
        ),
      ),
    ),
  );

  testWidgets('a message is the shared pill, not a bare SnackBar body', (
    tester,
  ) async {
    await tester.pumpWidget(host((c) => AppNotifications.show(c, 'Saved')));
    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(AppNotification), findsOneWidget);
    expect(find.text('Saved'), findsOneWidget);
    // The pill is the floating chrome, so it cannot drift from the sidebar
    // bars and the chat top bar.
    expect(
      find.descendant(
        of: find.byType(AppNotification),
        matching: find.byType(FloatingChromeSurface),
      ),
      findsOneWidget,
    );

    // The SnackBar itself contributes nothing visible.
    final SnackBar bar = tester.widget<SnackBar>(find.byType(SnackBar));
    expect(bar.backgroundColor, Colors.transparent);
    expect(bar.elevation, 0);
  });

  testWidgets('an error carries the error glyph colour', (tester) async {
    await tester.pumpWidget(host((c) => AppNotifications.error(c, 'Nope')));
    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    final AppNotification pill = tester.widget<AppNotification>(
      find.byType(AppNotification),
    );
    expect(pill.kind, AppNotificationKind.error);
  });

  testWidgets('the second message replaces the first, it does not queue', (
    tester,
  ) async {
    await tester.pumpWidget(
      host((c) {
        AppNotifications.show(c, 'first');
        AppNotifications.show(c, 'second');
      }),
    );
    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('second'), findsOneWidget);
    expect(find.text('first'), findsNothing);
  });

  testWidgets('the old NiceSnackBar name still reaches the same widget', (
    tester,
  ) async {
    await tester.pumpWidget(host((c) => NiceSnackBar.show(c, 'via old name')));
    await tester.tap(find.text('go'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(AppNotification), findsOneWidget);
    expect(find.text('via old name'), findsOneWidget);
  });
}
