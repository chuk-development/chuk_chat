import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/skill.dart';
import 'package:chuk_chat/services/skills/skill_registry.dart';
import 'package:chuk_chat/widgets/skill_picker.dart';

Widget _host(Widget child) => MaterialApp(
  localizationsDelegates: const [AppLocalizations.delegate],
  supportedLocales: AppLocalizations.supportedLocales,
  locale: const Locale('en'),
  home: Scaffold(body: child),
);

void main() {
  tearDown(SkillRegistry.resetForTest);

  group('SkillChipsRow', () {
    testWidgets('renders nothing when no skill is attached', (tester) async {
      await tester.pumpWidget(
        _host(
          SkillChipsRow(
            selected: const [],
            onRemove: (_) {},
            iconColor: Colors.black,
          ),
        ),
      );
      await tester.pump();

      expect(find.byType(Wrap), findsNothing);
    });

    testWidgets('renders one chip per attached skill', (tester) async {
      await tester.pumpWidget(
        _host(
          SkillChipsRow(
            selected: const ['weather-cards', 'news-cards'],
            onRemove: (_) {},
            iconColor: Colors.black,
          ),
        ),
      );
      await tester.pump();

      expect(find.text('weather-cards'), findsOneWidget);
      expect(find.text('news-cards'), findsOneWidget);
    });

    testWidgets('removing a chip reports the right name', (tester) async {
      String? removed;
      await tester.pumpWidget(
        _host(
          SkillChipsRow(
            selected: const ['weather-cards', 'news-cards'],
            onRemove: (name) => removed = name,
            iconColor: Colors.black,
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.byIcon(Icons.close).last);
      await tester.pump();

      expect(removed, 'news-cards');
    });
  });

  group('SkillPickerButton', () {
    testWidgets('lists every registered skill, built-in and user', (
      tester,
    ) async {
      SkillRegistry.setUserSkills(const [
        Skill(
          name: 'my-review',
          description: 'Reviews. Use when asked.',
          body: 'b',
          source: SkillSource.user,
          id: 'row-1',
        ),
      ]);

      await tester.pumpWidget(
        _host(
          SkillPickerButton(
            selected: const [],
            onChanged: (_) {},
            iconColor: Colors.black,
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.byType(SkillPickerButton));
      await tester.pumpAndSettle();

      expect(find.text('weather-cards'), findsOneWidget);
      expect(find.text('my-review'), findsOneWidget);
    });

    testWidgets('a pick is reported back on save', (tester) async {
      List<String>? picked;
      await tester.pumpWidget(
        _host(
          SkillPickerButton(
            selected: const [],
            onChanged: (names) => picked = names,
            iconColor: Colors.black,
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.byType(SkillPickerButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('weather-cards'));
      await tester.pump();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(picked, ['weather-cards']);
    });

    testWidgets('dismissing without saving reports nothing', (tester) async {
      var called = false;
      await tester.pumpWidget(
        _host(
          SkillPickerButton(
            selected: const [],
            onChanged: (_) => called = true,
            iconColor: Colors.black,
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.byType(SkillPickerButton));
      await tester.pumpAndSettle();
      Navigator.of(tester.element(find.text('weather-cards'))).pop();
      await tester.pumpAndSettle();

      expect(called, isFalse);
    });

    testWidgets('an already-attached skill starts checked', (tester) async {
      await tester.pumpWidget(
        _host(
          SkillPickerButton(
            selected: const ['weather-cards'],
            onChanged: (_) {},
            iconColor: Colors.black,
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.byType(SkillPickerButton));
      await tester.pumpAndSettle();

      final tile = tester.widget<CheckboxListTile>(
        find.ancestor(
          of: find.text('weather-cards'),
          matching: find.byType(CheckboxListTile),
        ),
      );
      expect(tile.value, isTrue);
    });
  });
}
