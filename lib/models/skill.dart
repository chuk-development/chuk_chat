/// An Agent Skill: a named procedure the AI loads on demand.
///
/// Skills implement progressive disclosure, mirroring how `find_tools`
/// already works in this app:
///
///  - **Level 1** — [name] + [description] sit in every system prompt
///    (~40-70 tokens each). This is the only thing the model sees until
///    it decides the skill is relevant.
///  - **Level 2** — [body] is injected under `## ACTIVE SKILL` on the next
///    system prompt rebuild, after the model calls the `skill` tool.
///  - **Level 3** — bundled resources (scripts, references) are not
///    implemented yet; the `assets/skills/<name>/` layout accommodates them.
///
/// The shape follows the open Agent Skills specification
/// (https://agentskills.io/specification). Deliberately NOT modelled on
/// [ClientTool]: there is no `id`, `tags` or `config`. `tags` is the keyword
/// corpus `find_tools` scores against — skills are selected by the model
/// reading [description], not by keyword matching, and adding `tags` would
/// invite wiring skills into `find_tools`, which is the wrong mechanism.
///
/// This library imports nothing on purpose: `tool/gen_skills.dart` runs under
/// plain `dart run`, which has no Flutter bindings, so a `flutter/foundation`
/// import here would break the generator.
library;

/// Where a [Skill] came from. Determines its trust level.
enum SkillSource {
  /// Authored in this repo, validated at build time, compiled into the
  /// binary. Same trust level as the Dart code around it.
  builtin,

  /// Authored by the user, stored E2E-encrypted in Supabase. Not yet
  /// implemented — the enum value exists so the parser and registry are
  /// written against both cases from the start.
  user,
}

class Skill {
  const Skill({
    required this.name,
    required this.description,
    required this.body,
    this.license,
    this.compatibility,
    this.metadata = const {},
    this.allowedTools = const [],
    this.source = SkillSource.builtin,
  });

  /// Spec: 1-64 chars, `[a-z0-9-]` only, no leading/trailing/double hyphen.
  /// Must equal the containing directory name.
  final String name;

  /// Spec: 1-1024 chars. Written in third person, stating what the skill
  /// does and when to use it, including trigger words.
  ///
  /// This is the ONLY discovery signal the model gets, and it is charged to
  /// every single prompt — see [kMaxDescriptionChars] for the budget we hold
  /// ourselves to, which is far below the spec ceiling.
  final String description;

  /// The Markdown below the frontmatter. Injected verbatim on activation.
  final String body;

  final String? license;

  /// Spec: max 500 chars. Environment requirements. Rarely needed.
  final String? compatibility;

  /// Spec: arbitrary string->string map. Note there is no top-level
  /// `version` field in the spec — a version belongs in here.
  final Map<String, String> metadata;

  /// Spec: space-separated tool names. Per the spec this **pre-approves**
  /// tools, it does not restrict them.
  ///
  /// Here it means: on activation these tools are marked as discovered, so
  /// their full definitions appear in the same prompt rebuild that carries
  /// the skill body. Entries are filtered against the enabled tool set at
  /// activation time, so a skill can never resurrect a user-disabled tool.
  final List<String> allowedTools;

  final SkillSource source;

  /// Spec ceiling for [name].
  static const int kMaxNameChars = 64;

  /// Spec ceiling for [description] is 1024, but that is ~256 tokens of
  /// permanent prompt weight per skill. We hold built-in skills to this
  /// instead, enforced by test.
  static const int kMaxDescriptionChars = 300;

  /// Spec ceiling for [description].
  static const int kSpecMaxDescriptionChars = 1024;

  /// Spec ceiling for [compatibility].
  static const int kMaxCompatibilityChars = 500;

  /// Recommended ceiling for [body] from the spec's best practices.
  static const int kMaxBodyLines = 500;

  /// `metadata.version`, or null. There is no top-level `version` in the spec.
  String? get version => metadata['version'];

  @override
  String toString() => 'Skill($name, ${body.length} body chars)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is Skill &&
          other.name == name &&
          other.description == description &&
          other.body == body &&
          other.license == license &&
          other.compatibility == compatibility &&
          _mapEquals(other.metadata, metadata) &&
          _listEquals(other.allowedTools, allowedTools) &&
          other.source == source;

  @override
  int get hashCode => Object.hash(
    name,
    description,
    body,
    license,
    compatibility,
    Object.hashAllUnordered(metadata.entries.map((e) => '${e.key}=${e.value}')),
    Object.hashAll(allowedTools),
    source,
  );
}

bool _listEquals(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

bool _mapEquals(Map<String, String> a, Map<String, String> b) {
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    // Values are non-null, so a missing key reads as null and fails here.
    if (b[entry.key] != entry.value) return false;
  }
  return true;
}
