import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cowork/pages/skills_settings_page.dart';
import 'package:cowork/services/cowork/cowork_relay_client.dart';
import 'package:cowork/services/cowork/cowork_relay_link.dart';
import 'package:cowork/services/skills/cowork_skill.dart';
import 'package:cowork/services/skills/skill_settings_sync.dart';
import 'package:cowork/services/skills/skills_source.dart';

import '../services/skills/skills_source_test.dart'
    show FakeMirror, FakeSkillsController;

CoworkSkill _skill(String name, {String source = 'workspace', bool enabled = true}) =>
    CoworkSkill.fromPayload(<String, dynamic>{
      'name': name,
      'description': 'Does $name.',
      'source': source,
      'enabled': enabled,
    })!;

void main() {
  final source = SkillsSource.instance;
  late FakeSkillsController controller;

  setUp(() {
    source.reset(mirror: FakeMirror(stored: <String, bool>{}));
    CoworkRelayLink.instance.reset();
    controller = FakeSkillsController();
    CoworkRelayLink.instance.bind(controller);
  });

  tearDown(() {
    source.reset(mirror: const NoopSkillSettingsMirror());
    CoworkRelayLink.instance.reset();
  });

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: SkillsSettingsPage()));
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
    controller.emit(CoworkRelaySkillsList(
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
    controller.emit(CoworkRelaySkillsList(skills: [
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
          matching: find.byIcon(Icons.verified_outlined),
        );
    expect(markOf('automations'), findsOneWidget);
    expect(markOf('youtube-transcript'), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey<String>('skill-youtube-transcript')),
        matching: find.byIcon(Icons.folder_outlined),
      ),
      findsOneWidget,
    );
  });

  testWidgets('the section follows the host source, never the skill name',
      (tester) async {
    // youtube-transcript is seeded from the repository, but it is a workspace
    // skill: the host says so, and the page must not second-guess a name.
    await pump(tester);
    controller.emit(CoworkRelaySkillsList(skills: [
      _skill('youtube-transcript'),
    ]));
    await tester.pump();

    expect(find.text('Workspace'), findsOneWidget);
    expect(find.text('Built in'), findsNothing);
  });

  testWidgets('a switch sends skill_control and the reply settles the row',
      (tester) async {
    await pump(tester);
    controller.emit(CoworkRelaySkillsList(skills: [_skill('deploy')]));
    await tester.pump();

    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(controller.controls, [('deploy', 'disable')]);
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);

    controller.emit(CoworkRelaySkillsList(skills: [_skill('deploy', enabled: false)]));
    await tester.pump();
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
  });

  testWidgets('an empty host list says so once the host answered', (tester) async {
    await pump(tester);
    controller.emit(const CoworkRelaySkillsList(skills: []));
    await tester.pump();
    expect(find.textContaining('The host has no skills'), findsOneWidget);
  });

  testWidgets('without a skills-capable controller the page says offline',
      (tester) async {
    CoworkRelayLink.instance.reset();
    await pump(tester);
    expect(find.textContaining('Not connected to the host'), findsOneWidget);
  });
}
