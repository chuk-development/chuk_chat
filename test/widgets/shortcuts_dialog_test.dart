import 'package:chuk_chat/services/shortcut_registry.dart';
import 'package:chuk_chat/widgets/shortcuts_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _harness() => MaterialApp(
  // InkSparkle needs a shader the test backend does not have.
  theme: ThemeData(splashFactory: InkRipple.splashFactory),
  home: Scaffold(
    body: Builder(
      builder: (BuildContext context) => Focus(
        autofocus: true,
        onKeyEvent: (FocusNode node, KeyEvent event) {
          if (AppShortcuts.matches(AppShortcuts.showShortcuts, event)) {
            showShortcutsDialog(context);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: const SizedBox.expand(),
      ),
    ),
  ),
);

void main() {
  testWidgets('Ctrl+/ opens the list with every entry', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_harness());
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.slash);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();

    expect(find.byType(ShortcutsDialog), findsOneWidget);
    for (final ShortcutEntry e in AppShortcuts.entries) {
      expect(
        find.byKey(ValueKey<String>('shortcut-row-${e.id}')),
        findsOneWidget,
        reason: e.id,
      );
    }
    expect(find.text('Send the message'), findsOneWidget);
  });

  testWidgets('search filters by description and by keys', (tester) async {
    await tester.pumpWidget(_harness());
    await tester.pump();
    final BuildContext ctx = tester.element(find.byType(SizedBox).last);
    showShortcutsDialog(ctx);
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey<String>('shortcuts-search')),
      'room',
    );
    await tester.pump();
    expect(
      find.byKey(const ValueKey<String>('shortcut-row-agents.newRoom')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('shortcut-row-chat.send')),
      findsNothing,
    );

    await tester.enterText(
      find.byKey(const ValueKey<String>('shortcuts-search')),
      'zzz-nothing',
    );
    await tester.pump();
    expect(find.text('No shortcut matches'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey<String>('shortcuts-close')));
    await tester.pumpAndSettle();
    expect(find.byType(ShortcutsDialog), findsNothing);
  });

  test('filterShortcuts matches keys', () {
    final List<String> ids = <String>[
      for (final ShortcutEntry e in filterShortcuts('ctrl+k')) e.id,
    ];
    expect(ids, <String>[AppShortcuts.quickSwitcher]);
  });
}
