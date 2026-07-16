import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/skills/builtin_skills.g.dart';

import '../../../tool/gen_skills.dart' as gen;

/// The gate that makes build-time codegen safe.
///
/// `assets/skills/**/SKILL.md` is the source of truth; `builtin_skills.g.dart`
/// is derived. Nothing forces a developer to re-run the generator after
/// editing a skill, and no CI job runs tests on pull requests — this test is
/// the only thing standing between a stale generated file and a shipped build
/// whose skills silently differ from their .md sources.
void main() {
  group('builtin_skills.g.dart freshness', () {
    test('is up to date with assets/skills/**/SKILL.md', () {
      final fromDisk = gen.loadSkillsFromDisk(Directory(gen.kSkillsDir));

      expect(
        fromDisk,
        kBuiltinSkills,
        reason:
            'The generated skills no longer match the .md sources. Run:\n\n'
            '    dart run tool/gen_skills.dart\n',
      );
    });

    test('the generated file is marked as generated', () {
      // Comparing the file byte-for-byte would just fight `dart format`, and
      // the object equality above already catches every difference that
      // matters (escaping, ordering, content). Assert the warning survives.
      final checkedIn = File(gen.kOutputPath).readAsStringSync();
      expect(checkedIn, contains('GENERATED CODE - DO NOT MODIFY BY HAND'));
      expect(checkedIn, contains('dart run tool/gen_skills.dart'));
    });

    test('every skill directory produced a skill', () {
      final dirCount = Directory(
        gen.kSkillsDir,
      ).listSync().whereType<Directory>().length;

      expect(kBuiltinSkills, hasLength(dirCount));
      expect(kBuiltinSkills, isNotEmpty);
    });
  });
}
