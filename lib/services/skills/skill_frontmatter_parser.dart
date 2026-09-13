/// Parses and validates a SKILL.md against the open Agent Skills spec
/// (https://agentskills.io/specification).
///
/// This is the single parser for both sources of skills:
///  - built-in skills, parsed at build time by `tool/gen_skills.dart`
///  - user-authored skills (Supabase, E2E-encrypted), parsed at runtime
///
/// Sharing it is deliberate: two parsers would drift, and the build-time one
/// is the only thing standing between a malformed skill and a silent failure
/// in front of a user.
///
/// Validation is **strict**, including rejecting unknown top-level keys. The
/// spec defines exactly six fields; anything else is a typo (`allowed_tools`
/// for `allowed-tools`) or a non-portable vendor extension. For built-in
/// skills a strict parser turns both into a test failure. Note the spec has
/// no top-level `version` — a version belongs in `metadata`.
library;

import 'package:yaml/yaml.dart';

import 'package:chuk_chat/models/skill.dart';

/// Thrown when a SKILL.md violates the spec.
class SkillParseException implements Exception {
  const SkillParseException(this.message, {this.field});

  final String message;
  final String? field;

  @override
  String toString() => field == null
      ? 'SkillParseException: $message'
      : 'SkillParseException [$field]: $message';
}

/// The six fields the spec defines. Anything else is rejected.
const Set<String> _kSpecFields = {
  'name',
  'description',
  'license',
  'compatibility',
  'metadata',
  'allowed-tools',
};

/// Spec: 1-64 chars of `[a-z0-9-]`, no leading/trailing hyphen, no double
/// hyphen. Expressed as segments so all three hyphen rules fall out for free.
final RegExp _kNamePattern = RegExp(r'^[a-z0-9]+(-[a-z0-9]+)*$');

final RegExp _kFrontmatterPattern = RegExp(
  r'^---[ \t]*\r?\n(.*?)\r?\n---[ \t]*(?:\r?\n(.*))?$',
  dotAll: true,
);

/// Parses [source] (the full contents of a SKILL.md) into a [Skill].
///
/// [expectedName] enforces the spec rule that `name` must equal the
/// containing directory name. Pass null to skip that check (user-authored
/// skills have no directory).
///
/// Throws [SkillParseException] on any violation.
Skill parseSkillMarkdown(
  String source, {
  String? expectedName,
  SkillSource skillSource = SkillSource.builtin,
}) {
  final match = _kFrontmatterPattern.firstMatch(source.trimLeft());
  if (match == null) {
    throw const SkillParseException(
      'Missing YAML frontmatter. A SKILL.md must start with a "---" line, '
      'contain the frontmatter, and close with another "---" line.',
    );
  }

  final frontmatterText = match.group(1) ?? '';
  final body = (match.group(2) ?? '').trim();

  if (body.isEmpty) {
    throw const SkillParseException(
      'Body is empty. A skill with no instructions below the frontmatter '
      'has nothing to disclose.',
    );
  }

  final dynamic parsed;
  try {
    parsed = loadYaml(frontmatterText);
  } on YamlException catch (e) {
    throw SkillParseException('Frontmatter is not valid YAML: ${e.message}');
  }

  if (parsed is! YamlMap) {
    throw const SkillParseException(
      'Frontmatter must be a YAML mapping of fields.',
    );
  }

  final keys = parsed.keys.map((k) => k.toString()).toList();
  final unknown = keys.where((k) => !_kSpecFields.contains(k)).toList();
  if (unknown.isNotEmpty) {
    final hint = unknown.contains('version')
        ? ' The spec has no top-level "version" — put it under "metadata".'
        : '';
    throw SkillParseException(
      'Unknown frontmatter field(s): ${unknown.join(', ')}. '
      'The spec defines only: ${_kSpecFields.join(', ')}.$hint',
      field: unknown.first,
    );
  }

  final name = _requireString(parsed, 'name');
  if (name.length > Skill.kMaxNameChars) {
    throw SkillParseException(
      'name is ${name.length} chars, max is ${Skill.kMaxNameChars}.',
      field: 'name',
    );
  }
  if (!_kNamePattern.hasMatch(name)) {
    throw SkillParseException(
      'name "$name" is invalid. Use only lowercase letters, digits and '
      'single hyphens, with no leading or trailing hyphen '
      '(e.g. "weather-cards").',
      field: 'name',
    );
  }
  if (expectedName != null && name != expectedName) {
    throw SkillParseException(
      'name "$name" must match the directory name "$expectedName".',
      field: 'name',
    );
  }

  final description = _requireString(parsed, 'description');
  if (description.length > Skill.kSpecMaxDescriptionChars) {
    throw SkillParseException(
      'description is ${description.length} chars, spec max is '
      '${Skill.kSpecMaxDescriptionChars}.',
      field: 'description',
    );
  }

  final license = _optionalString(parsed, 'license');

  final compatibility = _optionalString(parsed, 'compatibility');
  if (compatibility != null &&
      compatibility.length > Skill.kMaxCompatibilityChars) {
    throw SkillParseException(
      'compatibility is ${compatibility.length} chars, max is '
      '${Skill.kMaxCompatibilityChars}.',
      field: 'compatibility',
    );
  }

  return Skill(
    name: name,
    description: description,
    body: body,
    license: license,
    compatibility: compatibility,
    metadata: _parseMetadata(parsed),
    allowedTools: _parseAllowedTools(parsed),
    source: skillSource,
  );
}

Map<String, String> _parseMetadata(YamlMap parsed) {
  final raw = parsed['metadata'];
  if (raw == null) return const {};
  if (raw is! YamlMap) {
    throw const SkillParseException(
      'metadata must be a mapping of string keys to string values.',
      field: 'metadata',
    );
  }
  final result = <String, String>{};
  for (final entry in raw.entries) {
    // Strict, like every other field here. Coercing with toString() would
    // accept numbers and booleans the spec forbids, and — worse — collapse
    // the distinct YAML keys `1` and `"1"` onto one string key, silently
    // dropping a value. Quote it in the YAML: `version: "1.0"`.
    if (entry.key is! String || entry.value is! String) {
      throw SkillParseException(
        'metadata.${entry.key} must be a string key with a string value — '
        'metadata is a flat string-to-string map. Quote the value, '
        'e.g. version: "1.0".',
        field: 'metadata',
      );
    }
    result[entry.key as String] = entry.value as String;
  }
  return Map.unmodifiable(result);
}

List<String> _parseAllowedTools(YamlMap parsed) {
  final raw = parsed['allowed-tools'];
  if (raw == null) return const [];
  if (raw is! String) {
    throw const SkillParseException(
      'allowed-tools must be a single space-separated string '
      '(e.g. "weather geocode").',
      field: 'allowed-tools',
    );
  }
  final tools = raw.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();
  final seen = <String>{};
  for (final tool in tools) {
    if (!seen.add(tool)) {
      throw SkillParseException(
        'allowed-tools lists "$tool" more than once.',
        field: 'allowed-tools',
      );
    }
  }
  return List.unmodifiable(tools);
}

String _requireString(YamlMap parsed, String field) {
  final raw = parsed[field];
  if (raw == null) {
    throw SkillParseException('$field is required.', field: field);
  }
  if (raw is! String) {
    throw SkillParseException('$field must be a string.', field: field);
  }
  final value = raw.trim();
  if (value.isEmpty) {
    throw SkillParseException('$field must not be empty.', field: field);
  }
  return value;
}

String? _optionalString(YamlMap parsed, String field) {
  final raw = parsed[field];
  if (raw == null) return null;
  if (raw is! String) {
    throw SkillParseException('$field must be a string.', field: field);
  }
  final value = raw.trim();
  return value.isEmpty ? null : value;
}
