import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/widgets/settings_kit.dart';

Widget _host(Widget child) {
  return MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child)));
}

void main() {
  testWidgets('section header renders the label in caps', (tester) async {
    await tester.pumpWidget(_host(const SettingsSectionHeader('Appearance')));
    expect(find.text('APPEARANCE'), findsOneWidget);
  });

  testWidgets('grouped card puts a divider between rows', (tester) async {
    await tester.pumpWidget(
      _host(
        const SettingsGroupedCard(
          children: [Text('a'), Text('b'), Text('c')],
        ),
      ),
    );
    expect(find.byType(Divider), findsNWidgets(2));
  });

  testWidgets('grouped card can drop the dividers', (tester) async {
    await tester.pumpWidget(
      _host(
        const SettingsGroupedCard(
          dividers: false,
          children: [Text('a'), Text('b')],
        ),
      ),
    );
    expect(find.byType(Divider), findsNothing);
  });

  testWidgets('row shows title, subtitle and chevron and reports taps', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      _host(
        SettingsRow(
          icon: Icons.palette_outlined,
          title: 'Theme',
          subtitle: 'Dark',
          showChevron: true,
          onTap: () => taps++,
        ),
      ),
    );
    expect(find.text('Theme'), findsOneWidget);
    expect(find.text('Dark'), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);
    await tester.tap(find.text('Theme'));
    expect(taps, 1);
  });

  testWidgets('row hides an empty subtitle and the chevron', (tester) async {
    await tester.pumpWidget(
      _host(
        const SettingsRow(
          icon: Icons.palette_outlined,
          title: 'Theme',
          subtitle: '',
        ),
      ),
    );
    expect(find.byIcon(Icons.chevron_right), findsNothing);
    expect(find.byType(Text), findsOneWidget);
  });

  testWidgets('info card picks an icon per tone', (tester) async {
    await tester.pumpWidget(
      _host(
        const Column(
          children: [
            SettingsInfoCard('plain'),
            SettingsInfoCard('careful', tone: SettingsInfoTone.warn),
            SettingsInfoCard('broken', tone: SettingsInfoTone.danger),
          ],
        ),
      ),
    );
    expect(find.byIcon(Icons.info_outline), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
  });

  testWidgets('info card keeps an explicit icon', (tester) async {
    await tester.pumpWidget(
      _host(
        const SettingsInfoCard(
          'synced',
          tone: SettingsInfoTone.success,
          icon: Icons.cloud_done_outlined,
        ),
      ),
    );
    expect(find.byIcon(Icons.cloud_done_outlined), findsOneWidget);
  });
}
