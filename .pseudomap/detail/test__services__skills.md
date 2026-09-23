# test/services/skills · Signaturen

## test/services/skills/builtin_skills_freshness_test.dart  (49 Z.)
- L16 `void main()`  — The gate that makes build-time codegen safe.

## test/services/skills/builtin_skills_validity_test.dart  (132 Z.)
- L12 `_kMaxBodyTokens = 5000`  — Budget for one skill body (level 2). The spec's best practices put the
- L14 `void main()`

## test/services/skills/skill_frontmatter_parser_test.dart  (367 Z.)
- L7 `String _md(String frontmatter, {String body = '# Body\n\nDo the thing.'})`  — Builds a SKILL.md with [frontmatter] verbatim between the --- fences.
- L10 `_minimal = 'name: weather-cards\ndescription: Does a thing.'`
- L12 `void main()`

## test/services/skills/skill_registry_user_layer_test.dart  (199 Z.)
- L7 `Skill _userSkill(String name, {String? id})`
- L15 `void main()`

## test/services/skills/skill_tool_execution_test.dart  (165 Z.)
- L9 `ToolExecutor _executorWith(List<String> toolNames)`  — Registers just the tools a skill test needs, straight from the catalogue,
- L19 `void main()`

## test/services/skills/skills_catalog_reconcile_test.dart  (225 Z.)
- L9 `CatalogSkill _cat(String name, String hash)`
- L16 `void main()`

## test/services/skills/skills_local_store_test.dart  (156 Z.)
- L13 `class _FakePathProvider extends PathProviderPlatform with MockPlatformInterfaceMixin`
  - L15 `_FakePathProvider(this.dir)`
  - L17 `final String dir`
  - L20 `Future<String?> getApplicationSupportPath()`
  - L23 `Future<String?> getApplicationDocumentsPath()`
  - L26 `Future<String?> getTemporaryPath()`
- L29 `Map<String, dynamic> _skillRow( String id, String userId, { required String source, String? catalogName, String? baselineHash, String updatedAt = '2026-08-20T10:00:00.000Z', })`
- L47 `void main()`
