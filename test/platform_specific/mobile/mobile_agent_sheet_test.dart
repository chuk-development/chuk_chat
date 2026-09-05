import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cowork/platform_specific/mobile/mobile_agent_sheet.dart';

import 'mobile_support.dart';

void main() {
  testWidgets('shows only the rows that have an action, closes before acting',
      (tester) async {
    int copies = 0;
    late BuildContext ctx;
    await pumpPhone(
      tester,
      Builder(builder: (context) {
        ctx = context;
        return const SizedBox.expand();
      }),
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
    expect(find.text('Copy full chat'), findsOneWidget);
    expect(find.text('Sign out'), findsOneWidget);
    expect(find.text('Agent controls'), findsNothing);
    expect(find.text('Rooms'), findsNothing);
    expect(find.text('Settings'), findsNothing);

    // Every row is a full-width, ≥ 48 dp target.
    final Size row = tester.getSize(find.widgetWithText(ListTile, 'Copy full chat'));
    expect(row.height, greaterThanOrEqualTo(48));
    expect(row.width, kPhoneSize.width);

    await tester.tap(find.text('Copy full chat'));
    await tester.pumpAndSettle();
    expect(copies, 1);
    expect(find.byType(MobileAgentSheet), findsNothing, reason: 'sheet closed');
  });
}
