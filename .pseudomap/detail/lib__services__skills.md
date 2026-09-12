# lib/services/skills · Signatures

## lib/services/skills/skill_frontmatter_parser.dart  (241 Z.)

- L24 `class SkillParseException implements Exception`  — Thrown when a SKILL.md violates the spec.
  - L25 `const SkillParseException(this.message, {this.field})`
  - L27 `final String message`
  - L28 `final String? field`
  - L31 `String toString()`
- L37 `_kSpecFields = { 'name', 'description', 'license', 'compatibility', 'metadata', 'allowed-tools', }`  — The six fields the spec defines. Anything else is rejected.
- L48 `_kNamePattern = RegExp(r'^[a-z0-9]+(-[a-z0-9]+)*$')`  — Spec: 1-64 chars of `[a-z0-9-]`, no leading/trailing hyphen, no double
- L50 `_kFrontmatterPattern = RegExp( r'^---[ \t]*\r?\n(.*?)\r?\n---[ \t]*(?:\r?\n(.*))?$', dotAll: true, )`
- L62 `Skill parseSkillMarkdown( String source, { String? expectedName, SkillSource skillSource = SkillSource.builtin, })`  — Parses [source] (the full contents of a SKILL.md) into a [Skill].
- L166 `Map<String, String> _parseMetadata(YamlMap parsed)`
- L194 `List<String> _parseAllowedTools(YamlMap parsed)`
- L217 `String _requireString(YamlMap parsed, String field)`
- L232 `String? _optionalString(YamlMap parsed, String field)`

## lib/services/skills/skill_registry.dart  (115 Z.)

- L24 `class SkillRegistry`
  - L25 `const SkillRegistry._()`
  - L27 `static List<Skill> _userSkills = const []`
  - L28 `static List<Skill>? _all`
  - L29 `static Map<String, Skill>? _byName`
  - L35 `static List<Skill> get all`  — Every registered skill: built-ins first, then the user's own.
  - L38 `static Map<String, Skill> get _index`
  - L43 `static Skill? byName(String name)`  — The skill called [name], or null. Case- and whitespace-tolerant, because
  - L45 `static bool exists(String name)`
  - L47 `static List<Skill> bySource(SkillSource source)`
  - L51 `static List<String> get names`  — Names of every registered skill, ordered. Used for error messages.
  - L54 `static Set<String> get builtinNames`  — Names that a user skill may not take.
  - L59 `static Future<void> refreshUserSkills({bool forceRefresh = false})`  — Reloads the user's skills from storage. Safe to call repeatedly; call it
  - L81 `static void setUserSkills(List<Skill> skills)`  — Replaces the user-skill layer, dropping anything that would make the
  - L104 `static void _invalidate()`
  - L110 `static void resetForTest()`

## lib/services/skills/skills_catalog_service.dart  (418 Z.)

- L30 `class CatalogSkill`  — One entry in the catalog manifest.
  - L31 `const CatalogSkill({ required this.name, required this.description, required this.path, required this.hash, this.license, this.allowedTools = const [], this.resources = const [], this.enabled = true, })`
  - L42 `final String name`
  - L43 `final String description`
  - L46 `final String path`  — Repo-relative folder, e.g. `skills/browser-skill`.
  - L49 `final String hash`  — `sha256:<hex>` of the SKILL.md, the update trigger.
  - L51 `final String? license`
  - L52 `final List<String> allowedTools`
  - L55 `final List<String> resources`  — Repo-relative resource paths (`references/…`, `scripts/…`, `assets/…`).
  - L60 `final bool enabled`  — Manifest toggle. A `false` entry stays in the catalog but is never exposed
  - L62 `static CatalogSkill? fromJson(Map<String, dynamic> json)`
- L90 `class LocalSkillState`  — The local state the reconciler needs about one stored catalog skill.
  - L91 `const LocalSkillState({ required this.id, required this.sourceHash, required this.baselineHash, })`
  - L97 `final String id`
  - L100 `final String sourceHash`  — `sha256:<hex>` of the skill's current SKILL.md source.
  - L103 `final String? baselineHash`  — The catalog hash the skill was last seeded from, or null.
  - L105 `bool get isEdited`
- L110 `class SkillUpdateSuggestion`  — An edited skill whose catalog version moved — the user is asked, never
  - L111 `const SkillUpdateSuggestion({required this.id, required this.catalog})`
  - L114 `final String id`  — Stored row id of the user's copy.
  - L117 `final CatalogSkill catalog`  — The newer catalog version being offered.
- L121 `class ReconcilePlan`  — The outcome of a reconcile: what to add, silently update, and suggest.
  - L122 `const ReconcilePlan({ required this.toAdd, required this.toUpdate, required this.suggestions, required this.skippedBuiltin, this.toRemove = const [], })`
  - L131 `final List<CatalogSkill> toAdd`  — Catalog skills the user does not have — add automatically.
  - L135 `final List<({String id, CatalogSkill catalog})> toUpdate`  — Pristine copies whose catalog version changed — update silently. The value
  - L138 `final List<SkillUpdateSuggestion> suggestions`  — Edited copies whose catalog version changed — ask the user.
  - L142 `final List<CatalogSkill> skippedBuiltin`  — Catalog skills whose name is a compiled built-in — skipped (the built-in
  - L147 `final List<String> toRemove`  — Local row ids of stored catalog skills whose catalog entry is now
  - L149 `bool get isEmpty`
- L158 `ReconcilePlan planCatalogReconcile({ required List<CatalogSkill> catalog, required Map<String, LocalSkillState> localByCatalogName, required Set<String> builtinNames, })`  — Pure reconciliation: decide what to do with each catalog entry given the
- L208 `class SkillsCatalogService`
  - L209 `const SkillsCatalogService._()`
  - L213 `static const String _kBase = String.fromEnvironment( 'SKILLS_CATALOG_BASE', defaultValue: 'https://raw.githubusercontent.com/chuk-development/chuk-skills/main/', )`  — Raw fetch base for the catalog repo. Override with
  - L219 `static const Duration _cacheTtl = Duration(hours: 24)`
  - L220 `static const Duration _httpTimeout = Duration(seconds: 5)`
  - L222 `static const String _kManifestKey = 'skills_catalog_manifest'`
  - L223 `static const String _kManifestTsKey = 'skills_catalog_manifest_ts'`
  - L225 `static bool _reconciling = false`
  - L228 `static List<SkillUpdateSuggestion> _suggestions = const []`  — Pending update suggestions from the last reconcile, for the settings UI.
  - L229 `static List<SkillUpdateSuggestion> get suggestions`
  - L231 `static String hashOf(String source)`
  - L234 `static Uri _manifestUri()`
  - L235 `static Uri _bodyUri(CatalogSkill skill)`
  - L241 `static Future<List<CatalogSkill>?> fetchManifest({ bool forceRefresh = false, })`  — Fetches and parses the manifest, cache-first with a 24h TTL. Returns the
  - L271 `static Future<bool> _cacheFresh()`
  - L279 `static Future<List<CatalogSkill>?> _readCachedManifest()`
  - L285 `static List<CatalogSkill>? _parseManifest(String body)`
  - L303 `static Future<String?> _fetchBody(CatalogSkill skill)`
  - L316 `static Future<void> reconcile({bool forceRefresh = false})`  — Fetches the catalog and applies the plan: adds new skills, silently
  - L380 `static Future<void> _applyCatalogSkill( CatalogSkill entry, { String? id, })`
  - L404 `static Future<void> acceptSuggestion(SkillUpdateSuggestion suggestion)`  — Accepts a pending suggestion: replaces the user's copy with the catalog
  - L413 `static void resetForTest()`

## lib/services/skills/user_skills_service.dart  (397 Z.)

- L38 `class UserSkillException implements Exception`  — Thrown for storage-level failures. Spec violations surface as
  - L39 `const UserSkillException(this.message)`
  - L41 `final String message`
  - L44 `String toString()`
- L47 `class UserSkillsService`
  - L48 `const UserSkillsService._()`
  - L50 `static const String _kTable = 'user_skills'`
  - L56 `static const int kMaxUserSkills = 200`  — Ceiling on stored skills. Every one costs a catalog entry (name +
  - L58 `static String? _cachedUserId`
  - L59 `static List<Skill>? _memCache`
  - L63 `static void _syncCacheToCurrentUser(String? userId)`  — Drops the cache when the active user changed. Called at the top of every
  - L69 `static String _nowIso()`
  - L75 `static String _encodeEnvelope( String source, { String? catalogName, String? baselineHash, })`  — Wraps a skill's source and catalog bookkeeping into the JSON that gets
  - L91 `static ({String source, String? catalogName, String? baselineHash}) _decodeEnvelope(String plaintext)`  — Reads a decrypted `encrypted_source`. A v1 JSON envelope yields the source
  - L115 `static Future<List<Skill>> load({bool forceRefresh = false})`  — Every stored skill, newest first. Local-first: memory, then the SQLite
  - L136 `static Future<List<Skill>> _loadLocal(String userId)`  — Reads the SQLite store and parses each row. A row that fails to parse is
  - L151 `static Skill? _rowToSkill(Map<String, dynamic> row)`
  - L170 `static Future<List<Skill>> _refreshFromServer(String userId)`
  - L195 `static Future<({List<Skill> skills, List<Map<String, dynamic>> localRows})> _decodeRows(List<dynamic> rows)`  — Decrypts and parses server rows into both [Skill]s (for the prompt) and
  - L266 `static Future<Skill> save( String source, { String? id, String? catalogName, String? baselineHash, })`  — Validates, stores and returns a skill.
  - L368 `static Future<void> delete(String id)`  — Deletes the skill with [id]. Throws [UserSkillException] on failure —
  - L392 `static void resetForTest()`  — Test seam: drops the in-memory cache state.
