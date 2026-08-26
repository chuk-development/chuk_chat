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
  /// binary. Same trust level as the Dart code around it. Used as the
  /// first-run seed before the local store has been populated.
  builtin,

  /// Stored in the user's local database and synced to Supabase
  /// (E2E-encrypted). This covers both skills the user (or the AI) authored
  /// from scratch and skills seeded from our GitHub catalog — the two are
  /// distinguished by [Skill.catalogName], not by a separate source.
  user,
}

/// A file bundled alongside a skill (Level 3): a `references/`, `scripts/` or
/// `assets/` entry. Carries only the reference, never the content — the body
/// of a resource is fetched lazily on demand.
///
/// Imports nothing, like [Skill], so `tool/gen_skills.dart` keeps running
/// under plain `dart run`.
class SkillResource {
  const SkillResource({required this.path, this.url});

  /// Path relative to the skill root, e.g. `references/REFERENCE.md`. This is
  /// how the model addresses the file and how it is validated against the
  /// manifest, so it must never contain a `..` segment.
  final String path;

  /// Absolute fetch URL for a catalog resource, or null for a resource that is
  /// resolved another way (e.g. a bundled asset).
  final String? url;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SkillResource && other.path == path && other.url == url;

  @override
  int get hashCode => Object.hash(path, url);

  @override
  String toString() => 'SkillResource($path)';
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
    this.id,
    this.catalogName,
    this.baselineHash,
    this.resources = const [],
  }) : assert(
         source == SkillSource.user || id == null,
         'Only user skills have a storage identity; a built-in with a row id '
         'is a bug in whatever constructed it.',
       );

  /// Supabase row id, for [SkillSource.user] skills only — null for built-ins,
  /// which have no storage identity.
  ///
  /// This is NOT the identifier the model uses; that is [name]. It exists
  /// because an edit or a delete has to address a row, and [name] cannot: it
  /// lives inside the encrypted blob, so the server cannot index or constrain
  /// it. Name uniqueness is enforced client-side instead.
  final String? id;

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

  /// The name of the catalog entry this skill was seeded from, or null for a
  /// skill the user or the AI authored from scratch.
  ///
  /// This is the matching key for updates: when the catalog is refreshed, a
  /// stored skill with `catalogName == cat.name` is the local copy of that
  /// catalog skill. It is bookkeeping only and never reaches the prompt.
  final String? catalogName;

  /// The hash of [body] as it was last taken from the catalog, or null for a
  /// skill with no catalog origin.
  ///
  /// Divergence from `hash(body)` means the user (or the AI) has edited the
  /// skill, so a catalog update becomes a suggestion rather than a silent
  /// overwrite. The hashing lives in the reconciliation service, never here —
  /// this library imports nothing so the generator can run under plain
  /// `dart run`.
  final String? baselineHash;

  /// Level-3 bundled files (`references/`, `scripts/`, `assets/`), by reference
  /// only. Empty for skills with no bundle. Content is fetched on demand.
  final List<SkillResource> resources;

  /// Whether this skill tracks a catalog entry (seeded from our GitHub
  /// catalog) rather than being authored from scratch.
  bool get isFromCatalog => catalogName != null;

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

  bool get isBuiltin => source == SkillSource.builtin;

  /// Returns a copy with a different storage identity or catalog bookkeeping.
  ///
  /// Moving a skill back to [SkillSource.builtin] drops the row id rather than
  /// carrying it over: a built-in has no row to address, and keeping a stale id
  /// would let an edit or a delete target someone's stored skill.
  ///
  /// [catalogName], [baselineHash] and [resources] follow the keep-if-omitted
  /// convention; a skill that needs them cleared is rebuilt through the
  /// constructor by the reconciliation service instead.
  Skill copyWith({
    String? id,
    SkillSource? source,
    String? catalogName,
    String? baselineHash,
    List<SkillResource>? resources,
  }) {
    final nextSource = source ?? this.source;
    return Skill(
      name: name,
      description: description,
      body: body,
      license: license,
      compatibility: compatibility,
      metadata: metadata,
      allowedTools: allowedTools,
      source: nextSource,
      id: nextSource == SkillSource.builtin ? null : (id ?? this.id),
      catalogName: catalogName ?? this.catalogName,
      baselineHash: baselineHash ?? this.baselineHash,
      resources: resources ?? this.resources,
    );
  }

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
          other.source == source &&
          other.id == id &&
          other.catalogName == catalogName &&
          other.baselineHash == baselineHash &&
          _resourceListEquals(other.resources, resources);

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
    id,
    catalogName,
    baselineHash,
    Object.hashAll(resources),
  );
}

bool _resourceListEquals(List<SkillResource> a, List<SkillResource> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
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
