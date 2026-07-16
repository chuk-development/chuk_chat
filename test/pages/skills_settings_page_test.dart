import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/skill.dart';
import 'package:chuk_chat/pages/skills_settings_page.dart';
import 'package:chuk_chat/services/skills/builtin_skills.g.dart';
import 'package:chuk_chat/services/skills/skill_frontmatter_parser.dart';
import 'package:chuk_chat/services/skills/skill_registry.dart';

Widget _host(Widget child) => MaterialApp(
  localizationsDelegates: const [AppLocalizations.delegate],
  supportedLocales: AppLocalizations.supportedLocales,
  locale: const Locale('en'),
  home: child,
);

const Skill _userSkill = Skill(
  name: 'my-review',
  description: 'Reviews code. Use when the user asks for a review.',
  body: '# My review\n\nCheck the thing.\n\nThen check the other thing.',
  allowedTools: ['web_search', 'web_crawl'],
  metadata: {'version': '2.1'},
  license: 'MIT',
  source: SkillSource.user,
  id: 'row-1',
);

void main() {
  tearDown(SkillRegistry.resetForTest);

  group('SkillsSettingsPage', () {
    testWidgets('lists every built-in skill', (tester) async {
      await tester.pumpWidget(_host(const SkillsSettingsPage()));
      // Flush the deferred-hydration timer the page arms in initState.
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      for (final skill in kBuiltinSkills) {
        expect(
          find.text(skill.name),
          findsOneWidget,
          reason: '${skill.name} must be listed',
        );
      }
    });

    testWidgets('built-ins are read-only — no delete affordance', (
      tester,
    ) async {
      // Built-in names gate protocol blocks out of the prompt; they are not
      // the user's to remove.
      await tester.pumpWidget(_host(const SkillsSettingsPage()));
      // Flush the deferred-hydration timer the page arms in initState.
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(find.byIcon(Icons.delete_outline), findsNothing);
      expect(
        find.byIcon(Icons.lock_outline),
        findsNWidgets(kBuiltinSkills.length),
      );
    });

    testWidgets('offers a way to add a skill', (tester) async {
      await tester.pumpWidget(_host(const SkillsSettingsPage()));
      // Flush the deferred-hydration timer the page arms in initState.
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(find.text('New skill'), findsOneWidget);
    });
  });

  group('SkillEditorPage', () {
    testWidgets('a new skill starts from a valid template', (tester) async {
      // The template is the first thing a user sees; if it does not parse,
      // their first save fails for reasons that are not their fault.
      await tester.pumpWidget(_host(const SkillEditorPage()));
      await tester.pump();

      final field = tester.widget<TextField>(find.byType(TextField));
      final source = field.controller!.text;

      expect(() => parseSkillMarkdown(source), returnsNormally);
      expect(parseSkillMarkdown(source).name, 'my-skill');
    });

    testWidgets('editing round-trips a skill without losing a field', (
      tester,
    ) async {
      // The raw source is not stored — the editor rebuilds it from the parsed
      // skill. If that rebuild is lossy, opening and saving a skill silently
      // destroys whatever it failed to render.
      await tester.pumpWidget(_host(const SkillEditorPage(skill: _userSkill)));
      await tester.pump();

      final field = tester.widget<TextField>(find.byType(TextField));
      final reparsed = parseSkillMarkdown(
        field.controller!.text,
        skillSource: SkillSource.user,
      );

      expect(reparsed.name, _userSkill.name);
      expect(reparsed.description, _userSkill.description);
      expect(reparsed.body, _userSkill.body);
      expect(reparsed.allowedTools, _userSkill.allowedTools);
      expect(reparsed.metadata, _userSkill.metadata);
      expect(reparsed.license, _userSkill.license);
    });

    testWidgets('round-trips a description containing YAML metacharacters', (
      tester,
    ) async {
      // An unquoted `:` would make YAML read the description as a nested map.
      const tricky = Skill(
        name: 'tricky',
        description: 'Does this: that. Use when #hashtags or colons appear.',
        body: 'Body.',
        source: SkillSource.user,
        id: 'row-2',
      );

      await tester.pumpWidget(_host(const SkillEditorPage(skill: tricky)));
      await tester.pump();

      final field = tester.widget<TextField>(find.byType(TextField));
      final reparsed = parseSkillMarkdown(field.controller!.text);

      expect(reparsed.description, tricky.description);
    });

    testWidgets('round-trips metadata that YAML would read as a non-string', (
      tester,
    ) async {
      // Regression: the editor used to emit `version: 2.1` bare, so YAML read
      // it back as a double and the strict parser rejected the user's own
      // skill on save — with an error that looked like their mistake.
      const typed = Skill(
        name: 'typed-meta',
        description: 'Has typed-looking metadata. Use when testing.',
        body: 'Body.',
        metadata: {
          'version': '2.1',
          'stable': 'true',
          'count': '3',
          'nothing': 'null',
          'dash': '-leading',
        },
        source: SkillSource.user,
        id: 'row-3',
      );

      await tester.pumpWidget(_host(const SkillEditorPage(skill: typed)));
      await tester.pump();

      final field = tester.widget<TextField>(find.byType(TextField));
      final reparsed = parseSkillMarkdown(field.controller!.text);

      expect(reparsed.metadata, typed.metadata);
      expect(reparsed.version, '2.1');
    });

    testWidgets('round-trips control characters and quotes', (tester) async {
      // A hand-rolled quoter escapes \\ and " and stops there, so a newline or
      // a tab in a value silently changes what the skill means the first time
      // the user opens and saves it. jsonEncode covers the whole class.
      const gnarly = Skill(
        name: 'gnarly',
        description: 'Line one.\nLine two\twith a tab. Use when "quoted".',
        body: 'Body.',
        metadata: {
          'note': 'a\nb\tc "d" \\e',
          'key\nwith-newline': 'v',
          'yes': 'true',
        },
        source: SkillSource.user,
        id: 'row-4',
      );

      await tester.pumpWidget(_host(const SkillEditorPage(skill: gnarly)));
      await tester.pump();

      final field = tester.widget<TextField>(find.byType(TextField));
      final reparsed = parseSkillMarkdown(field.controller!.text);

      expect(reparsed.description, gnarly.description);
      expect(reparsed.metadata, gnarly.metadata);
    });

    testWidgets('shows the title for edit vs create', (tester) async {
      await tester.pumpWidget(_host(const SkillEditorPage()));
      await tester.pump();
      expect(find.text('New skill'), findsOneWidget);

      await tester.pumpWidget(_host(const SkillEditorPage(skill: _userSkill)));
      await tester.pump();
      expect(find.text('Edit skill'), findsOneWidget);
    });
  });
}
