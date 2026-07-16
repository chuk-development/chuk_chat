// Generates lib/services/skills/builtin_skills.g.dart from the SKILL.md
// files under assets/skills/.
//
// Run from the repo root:
//
//   dart run tool/gen_skills.dart
//
// Why codegen instead of loading the .md files as Flutter assets at runtime:
//
//  - A malformed SKILL.md becomes a build/test failure instead of a skill
//    that silently goes missing in front of a user. For a feature whose whole
//    premise is "we bundle and audit our skills instead of fetching untrusted
//    ones", build-time validation IS the security posture.
//  - Flutter's pubspec `assets:` entries do not recurse into subdirectories,
//    and the spec requires one directory per skill — that would mean a pubspec
//    line per skill, i.e. another registration step to forget.
//  - It keeps ToolPromptBuilder synchronous and its tests binding-free.
//
// `test/services/skills/builtin_skills_freshness_test.dart` re-parses the
// .md files and fails if the generated output is stale, so a forgotten
// regen cannot ship.

import 'dart:io';

import 'package:chuk_chat/models/skill.dart';
import 'package:chuk_chat/services/skills/skill_frontmatter_parser.dart';

const String kSkillsDir = 'assets/skills';
const String kOutputPath = 'lib/services/skills/builtin_skills.g.dart';

void main(List<String> args) {
  final skills = loadSkillsFromDisk(Directory(kSkillsDir));
  if (skills.isEmpty) {
    stderr.writeln('No skills found under $kSkillsDir/');
    exitCode = 1;
    return;
  }

  final output = renderBuiltinSkillsFile(skills);
  File(kOutputPath).writeAsStringSync(output);

  // Commit the file formatted, so a `dart format` over the repo is a no-op
  // and the generated code reads like the rest of the codebase.
  // Fail loudly: exiting 0 here would leave unformatted — possibly
  // unparseable — generated output behind and call it a success.
  final fmt = Process.runSync('dart', ['format', kOutputPath]);
  if (fmt.exitCode != 0) {
    stderr.writeln('dart format failed on $kOutputPath: ${fmt.stderr}');
    exitCode = fmt.exitCode;
    return;
  }

  stdout.writeln('Generated $kOutputPath with ${skills.length} skill(s):');
  for (final skill in skills) {
    stdout.writeln(
      '  ${skill.name.padRight(20)} '
      '${skill.description.length.toString().padLeft(3)} desc chars, '
      '${skill.body.split('\n').length.toString().padLeft(3)} body lines',
    );
  }
}

/// Parses every `<dir>/<name>/SKILL.md`, validating each against the spec plus
/// our own stricter budgets. Sorted by name so the output is deterministic.
///
/// Shared with the freshness test — that is the point: the test proves the
/// generated file still equals what this function produces.
List<Skill> loadSkillsFromDisk(Directory skillsDir) {
  if (!skillsDir.existsSync()) {
    throw StateError('Skills directory not found: ${skillsDir.path}');
  }

  final skills = <Skill>[];
  final dirs = skillsDir.listSync().whereType<Directory>().toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  for (final dir in dirs) {
    final dirName = dir.uri.pathSegments.where((s) => s.isNotEmpty).last;
    final file = File('${dir.path}/SKILL.md');
    if (!file.existsSync()) {
      throw StateError('${dir.path} has no SKILL.md');
    }

    final Skill skill;
    try {
      skill = parseSkillMarkdown(
        file.readAsStringSync(),
        expectedName: dirName,
      );
    } on SkillParseException catch (e) {
      throw StateError('${file.path}: ${e.message}');
    }

    _validateBudgets(skill, file.path);
    skills.add(skill);
  }

  skills.sort((a, b) => a.name.compareTo(b.name));
  return skills;
}

/// Budgets that are stricter than the spec, because built-in skills are
/// charged to every prompt we send.
void _validateBudgets(Skill skill, String path) {
  if (skill.description.length > Skill.kMaxDescriptionChars) {
    throw StateError(
      '$path: description is ${skill.description.length} chars. Built-in '
      'skills are capped at ${Skill.kMaxDescriptionChars} because the '
      'description sits in EVERY system prompt. (The spec allows '
      '${Skill.kSpecMaxDescriptionChars}, which is ~256 tokens of permanent '
      'weight per skill — too expensive.)',
    );
  }

  final lines = skill.body.split('\n').length;
  if (lines > Skill.kMaxBodyLines) {
    throw StateError(
      '$path: body is $lines lines, max is ${Skill.kMaxBodyLines}. Split the '
      'detail into a reference file once level-3 resources are supported.',
    );
  }
}

/// Renders the generated Dart source for [skills].
String renderBuiltinSkillsFile(List<Skill> skills) {
  final buffer = StringBuffer()
    ..writeln('// GENERATED CODE - DO NOT MODIFY BY HAND')
    ..writeln('//')
    ..writeln('// Source: assets/skills/<name>/SKILL.md')
    ..writeln('// Regenerate: dart run tool/gen_skills.dart')
    ..writeln('//')
    ..writeln('// builtin_skills_freshness_test.dart fails if this file is')
    ..writeln('// out of date with the .md sources.')
    ..writeln()
    ..writeln('// ignore_for_file: lines_longer_than_80_chars')
    ..writeln()
    ..writeln("import 'package:chuk_chat/models/skill.dart';")
    ..writeln()
    ..writeln('/// Skills authored in this repo and compiled into the binary.')
    ..writeln('///')
    ..writeln('/// Built-in skills carry the same trust level as the Dart code')
    ..writeln('/// around them: they are reviewed here and cannot change after')
    ..writeln(
      '/// the build. Nothing is fetched from a marketplace at runtime.',
    )
    ..writeln('const List<Skill> kBuiltinSkills = <Skill>[');

  for (final skill in skills) {
    buffer
      ..writeln('  Skill(')
      ..writeln('    name: ${_dartString(skill.name)},')
      ..writeln('    description: ${_dartString(skill.description)},')
      ..writeln('    body: ${_dartString(skill.body)},');
    if (skill.license != null) {
      buffer.writeln('    license: ${_dartString(skill.license!)},');
    }
    if (skill.compatibility != null) {
      buffer.writeln(
        '    compatibility: ${_dartString(skill.compatibility!)},',
      );
    }
    if (skill.metadata.isNotEmpty) {
      final entries = skill.metadata.entries
          .map((e) => '${_dartString(e.key)}: ${_dartString(e.value)}')
          .join(', ');
      buffer.writeln('    metadata: <String, String>{$entries},');
    }
    if (skill.allowedTools.isNotEmpty) {
      final tools = skill.allowedTools.map(_dartString).join(', ');
      buffer.writeln('    allowedTools: <String>[$tools],');
    }
    buffer.writeln('  ),');
  }

  buffer.writeln('];');
  return buffer.toString();
}

/// Escapes [value] into a single-quoted Dart string literal.
///
/// Backslash must be escaped first, or the later replacements get mangled.
String _dartString(String value) {
  final escaped = value
      .replaceAll('\\', r'\\')
      .replaceAll("'", r"\'")
      .replaceAll(r'$', r'\$')
      .replaceAll('\r', r'\r')
      .replaceAll('\n', r'\n');
  return "'$escaped'";
}
