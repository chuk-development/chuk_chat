import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/skill.dart';
import 'package:chuk_chat/pages/skills_settings_page.dart';
import 'package:chuk_chat/services/skills/builtin_skills.g.dart';
import 'package:chuk_chat/services/skills/skill_frontmatter_parser.dart';
import 'package:chuk_chat/services/skills/skill_registry.dart';
import '../helpers/icon_finder.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/services/skills/agents_skill.dart';
import 'package:chuk_chat/services/skills/skill_settings_sync.dart';
import 'package:chuk_chat/services/skills/skills_source.dart';
import '../services/skills/skills_source_test.dart'
    show FakeMirror, FakeSkillsController;
// Two findIcon() helpers exist in this tree; the Agents group wants the one
// that also matches a plain Material Icon, so it takes a prefix.
import '../support/icon_finder.dart' as expressive;

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

AgentsSkill _skill(String name, {String source = 'workspace', bool enabled = true}) =>
    AgentsSkill.fromPayload(<String, dynamic>{
      'name': name,
      'description': 'Does $name.',
      'source': source,
      'enabled': enabled,
    })!;

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

      expect(findIcon(Icons.delete_outline), findsNothing);
      expect(
        findIcon(Icons.lock_outline),
        findsNWidgets(kBuiltinSkills.length),
      );
    });

    testWidgets('offers a way to add a skill', (tester) async {
      await tester.pumpWidget(_host(const SkillsSettingsPage()));
      // Flush the deferred-hydration timer the page arms in initState.
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      // Two entry points now: the FAB, and the empty-state panel's own
      // "New skill" button shown while the user has authored none.
      expect(find.text('New skill'), findsWidgets);
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

  // Agents's own skills screen: the host's list, one switch per skill. It is a
  // different screen from the one above, under a different name — see the note
  // in lib/pages/skills_settings_page.dart.
  group('AgentsSkillsSettingsPage', () {

    final source = SkillsSource.instance;
    late FakeSkillsController controller;

    setUp(() {
      source.reset(mirror: FakeMirror(stored: <String, bool>{}));
      AgentsRelayLink.instance.reset();
      controller = FakeSkillsController();
      AgentsRelayLink.instance.bind(controller);
    });

    tearDown(() {
      source.reset(mirror: const NoopSkillSettingsMirror());
      AgentsRelayLink.instance.reset();
    });

    Future<void> pump(WidgetTester tester) async {
      await tester.pumpWidget(const MaterialApp(home: AgentsSkillsSettingsPage()));
      await tester.pump();
    }

    testWidgets('asks the host for the list on open and waits', (tester) async {
      await pump(tester);
      expect(controller.listRequests, 1);
      expect(find.text('Waiting for the host…'), findsOneWidget);
      expect(find.byType(Switch), findsNothing);
    });

    testWidgets('shows the host list in two sections with one switch each',
        (tester) async {
      await pump(tester);
      controller.emit(AgentsRelaySkillsList(
        skills: [
          _skill('automations', source: 'builtin', enabled: false),
          _skill('youtube-transcript'),
          _skill('deploy'),
        ],
        errors: const ['ws/skills/broken/SKILL.md: no YAML frontmatter'],
      ));
      await tester.pump();

      expect(find.text('Built in'), findsOneWidget);
      expect(find.text('Workspace'), findsOneWidget);
      expect(find.text('youtube-transcript'), findsOneWidget);
      expect(find.text('Does deploy.'), findsOneWidget);
      expect(find.byType(Switch), findsNWidgets(3));
      expect(find.textContaining('no YAML frontmatter'), findsOneWidget);

      final off = tester.widget<Switch>(find.descendant(
        of: find.byKey(const ValueKey<String>('skill-automations')),
        matching: find.byType(Switch),
      ));
      expect(off.value, isFalse);
    });

    testWidgets('each section says what it is, and every row carries its mark',
        (tester) async {
      await pump(tester);
      controller.emit(AgentsRelaySkillsList(skills: [
        _skill('automations', source: 'builtin'),
        _skill('youtube-transcript'),
      ]));
      await tester.pump();

      // Why a section is what it is, not only its label.
      // Anchored on what the caption has to say, not on how the app is named.
      expect(find.textContaining('the sandbox terminal'), findsOneWidget);
      expect(find.textContaining('under skills/'), findsOneWidget);

      // The mark on the row repeats the section, so a scrolled row still reads.
      Finder markOf(String name) => find.descendant(
            of: find.byKey(ValueKey<String>('skill-$name')),
            matching: expressive.findIcon(Icons.verified_outlined),
          );
      expect(markOf('automations'), findsOneWidget);
      expect(markOf('youtube-transcript'), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<String>('skill-youtube-transcript')),
          matching: expressive.findIcon(Icons.folder_outlined),
        ),
        findsOneWidget,
      );
    });

    testWidgets('the section follows the host source, never the skill name',
        (tester) async {
      // youtube-transcript is seeded from the repository, but it is a workspace
      // skill: the host says so, and the page must not second-guess a name.
      await pump(tester);
      controller.emit(AgentsRelaySkillsList(skills: [
        _skill('youtube-transcript'),
      ]));
      await tester.pump();

      expect(find.text('Workspace'), findsOneWidget);
      expect(find.text('Built in'), findsNothing);
    });

    testWidgets('a switch sends skill_control and the reply settles the row',
        (tester) async {
      await pump(tester);
      controller.emit(AgentsRelaySkillsList(skills: [_skill('deploy')]));
      await tester.pump();

      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect(controller.controls, [('deploy', 'disable')]);
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);

      controller.emit(AgentsRelaySkillsList(skills: [_skill('deploy', enabled: false)]));
      await tester.pump();
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
    });

    testWidgets('an empty host list says so once the host answered', (tester) async {
      await pump(tester);
      controller.emit(const AgentsRelaySkillsList(skills: []));
      await tester.pump();
      expect(find.textContaining('The host has no skills'), findsOneWidget);
    });

    testWidgets('without a skills-capable controller the page says offline',
        (tester) async {
      AgentsRelayLink.instance.reset();
      await pump(tester);
      expect(find.textContaining('Not connected to the host'), findsOneWidget);
    });
  });
}
