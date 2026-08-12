import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cowork/pages/messenger_shell.dart';

void main() {
  testWidgets('MessengerShell renders roster and thread placeholders', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: MessengerShell()),
    );

    expect(find.text('Agents'), findsOneWidget);
    expect(find.text('No agents yet'), findsOneWidget);
    expect(find.text('Select an agent to start a thread'), findsOneWidget);
    expect(find.byIcon(Icons.logout), findsOneWidget);
  });
}
