import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/platform_specific/mobile/mobile_agent_sheet.dart';
import 'package:chuk_chat/widgets/menu_tile_group.dart';

import 'mobile_support.dart';

void main() {
  testWidgets('rename closes the sheet and opens the name dialog', (
    tester,
  ) async {
    late BuildContext ctx;
    await pumpPhone(
      tester,
      Builder(
        builder: (context) {
          ctx = context;
          return const SizedBox.expand();
        },
      ),
    );
    MobileAgentSheet.show(
      ctx,
      agent: agent(id: 'a1', name: 'Chief of Staff'),
      onRename: () => showDialog<void>(
        context: ctx,
        builder: (_) => const AlertDialog(title: Text('Name editor')),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename agent'));
    await tester.pumpAndSettle();
    expect(find.byType(MobileAgentSheet), findsNothing);
    expect(find.text('Name editor'), findsOneWidget);
  });

  testWidgets('shows only the rows that have an action, closes before acting', (
    tester,
  ) async {
    int copies = 0;
    late BuildContext ctx;
    await pumpPhone(
      tester,
      Builder(
        builder: (context) {
          ctx = context;
          return const SizedBox.expand();
        },
      ),
    );
    MobileAgentSheet.show(
      ctx,
      agent: agent(id: 'a1', name: 'Chief of Staff', role: 'ops'),
      onCopyChat: () => copies++,
      onSignOut: () {},
    );
    await tester.pumpAndSettle();

    expect(find.text('Chief of Staff'), findsOneWidget);
    expect(find.text('ops'), findsOneWidget);
    expect(find.text('Copy Debug Chat'), findsOneWidget);
    expect(find.text('Sign out'), findsOneWidget);
    expect(find.text('Agent controls'), findsNothing);
    expect(find.text('Rooms'), findsNothing);
    expect(find.text('Settings'), findsNothing);

    // Every row is a full-width, ≥ 48 dp target. The menu surface keeps a
    // 16 dp margin on each side, so "full width" is the sheet's width.
    final Size row = tester.getSize(
      find.widgetWithText(MenuActionRow, 'Copy Debug Chat'),
    );
    expect(row.height, greaterThanOrEqualTo(48));
    expect(row.width, kPhoneSize.width - 32);

    await tester.tap(find.text('Copy Debug Chat'));
    await tester.pumpAndSettle();
    expect(copies, 1);
    expect(find.text('Copy Debug Chat'), findsNothing, reason: 'sheet closed');
  });
}
