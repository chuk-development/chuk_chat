// assets/skills/openui/SKILL.md is generated from chukOpenUiLibrary by
// tool/gen_openui_skill.dart. This test fails when the file is stale, so a
// component change cannot ship with an old prompt.
// ignore_for_file: experimental_member_use

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:openui_core/openui_core.dart';

import 'package:chuk_chat/models/skill.dart';
import 'package:chuk_chat/openui/openui.dart';
import 'package:chuk_chat/services/skills/builtin_skills.g.dart';

import '../../tool/gen_openui_skill.dart' as gen;
import 'openui_fixtures_test.dart' show componentNames;
import 'openui_signatures_test.dart' show upstreamSignatures;

void main() {
  test('SKILL.md is up to date with chukOpenUiLibrary', () {
    expect(
      File(gen.kOpenUiSkillPath).readAsStringSync(),
      gen.buildOpenUiSkillMarkdown(chukOpenUiLibrary),
      reason:
          'The OpenUI skill no longer matches the component library. Run:\n\n'
          '    flutter test tool/gen_openui_skill.dart\n',
    );
  });

  test('the compiled skill is in the builtin skills', () {
    final skill = kBuiltinSkills.where((s) => s.name == 'openui');
    expect(skill, hasLength(1), reason: 'Run: dart run tool/gen_skills.dart');
    expect(skill.single.description, gen.kOpenUiSkillDescription);
  });

  test('the description fits the prompt budget', () {
    expect(
      gen.kOpenUiSkillDescription.length,
      lessThanOrEqualTo(Skill.kMaxDescriptionChars),
    );
  });

  test('every registered component is listed with its signature', () {
    final markdown = gen.buildOpenUiSkillMarkdown(chukOpenUiLibrary);
    final aliases = gen.openUiSkillAliases(chukOpenUiLibrary);
    for (final def in chukOpenUiLibrary.components) {
      final short = gen.openUiSkillSignature(def, aliases);
      // A line is the signature alone or the signature plus a note.
      expect(
        markdown.split('\n').any(
          (line) => line == short || line.startsWith('$short — '),
        ),
        isTrue,
        reason: def.name,
      );
      // The type names are only shorthand: expanded again, the line is
      // the exact signature, with the same order and names.
      expect(
        gen.expandOpenUiSkillType(short, aliases),
        def.signature,
        reason: def.name,
      );
    }
  });

  test('every type name is defined once and used', () {
    final markdown = gen.buildOpenUiSkillMarkdown(chukOpenUiLibrary);
    final aliases = gen.openUiSkillAliases(chukOpenUiLibrary);
    expect(aliases.map((a) => a.name), containsAll(<String>['Rules']));
    for (final a in aliases) {
      expect(markdown, contains('- `${a.name}` = '), reason: a.name);
      final uses = RegExp('\\b${a.name}\\b').allMatches(markdown).length;
      expect(uses, greaterThan(2), reason: a.name);
    }
  });

  test('the examples parse and use only upstream components', () {
    final upstream = upstreamSignatures().keys.toSet();
    final examples = gen.openUiSkillExamplePrograms();
    expect(examples, hasLength(3));
    for (final program in examples) {
      final result = createStreamingParser().set(program);
      expect(result.meta.errors.map((e) => e.message), isEmpty);
      expect(result.root, isNotNull);
      expect(program.trimLeft(), startsWith('root = Card('));
      expect(componentNames(program).difference(upstream), isEmpty);
    }
  });
}
