# tool · Signaturen

## tool/gen_openui_skill.dart  (449 Z.)
- L23 `kOpenUiSkillPath = 'assets/skills/openui/SKILL.md'`  — Where the generated skill goes.
- L27 `kOpenUiGroupOrder = <String>[ 'Content', 'Tables', 'Charts (2D)', 'Charts (1D)', 'Charts (Scatter)', 'Forms', 'Buttons',`  — The prompt groups in upstream order. Other groups follow in
- L44 `kOpenUiSkillDescription = 'Draws native UI in an answer: cards, tables, lists, forms, metrics, ' 'charts, follow-up butt`  — The skill description: in EVERY prompt, so it stays short (max 300).
- L55 `_kSkillNotes = <String, String>{ 'CardHeader': '', 'TextContent': 'Markdown text', 'MarkDownRenderer': 'Markdown in a co`  — Short notes that replace the upstream description in the skill.
- L144 `_header = r''' # OpenUI: rich UI in the answer The app draws OpenUI Lang (spec v0.5) as native widgets. Use it when a st`
- L198 `_examples = r''' ## Examples A comparison: ```openui-lang root = Card([header, table, note, followUps]) header = CardHea`
- L239 `List<String> openUiSkillExamplePrograms()`  — The example programs of the skill (the fence bodies), for tests.
- L246 `_kObjectAliasNames = <String, String>{ 'rules': 'Rules', 'rows': 'EntityRow', }`  — Names for repeated object types, by the param name where the type
- L252 `_kContentAlias = 'Content'`  — The name of the shared start of the long child unions.
- L256 `class OpenUiTypeAlias`  — A short name for a long type that repeats in the signatures. The
  - L258 `const OpenUiTypeAlias(this.name, this.text)`  — Creates an alias.
  - L261 `final String name`  — The short name, for example `Rules`.
  - L265 `final String text`  — The full type text. For the content union it is the member list
- L268 `_objectType = RegExp(r'\{[^{}]*\}')`
- L269 `_unionGroup = RegExp(r'\(([^()]*)\)')`
- L273 `List<OpenUiTypeAlias> openUiSkillAliases(OpenUiLibrary library)`  — The aliases for [library]: object types that show 3+ times, and the
- L320 `List<String> _members(String union)`
- L324 `String openUiSkillShortType(String type, List<OpenUiTypeAlias> aliases)`  — [type] with the long parts replaced by alias names.
- L348 `String expandOpenUiSkillType(String short, List<OpenUiTypeAlias> aliases)`  — [short] with the alias names replaced by their full text again.
- L366 `String openUiSkillSignature(OpenUiComponentDef def, List<OpenUiTypeAlias> a)`  — The signature as the skill writes it, with alias names.
- L375 `String buildOpenUiSkillMarkdown(OpenUiLibrary library)`  — Builds the SKILL.md text for [library].
- L435 `void main()`

## tool/gen_skills.dart  (191 Z.)
- L28 `kSkillsDir = 'assets/skills'`
- L29 `kOutputPath = 'lib/services/skills/builtin_skills.g.dart'`
- L31 `void main(List<String> args)`
- L68 `List<Skill> loadSkillsFromDisk(Directory skillsDir)`  — Parses every `<dir>/<name>/SKILL.md`, validating each against the spec plus
- L104 `void _validateBudgets(Skill skill, String path)`  — Budgets that are stricter than the spec, because built-in skills are
- L125 `String renderBuiltinSkillsFile(List<Skill> skills)`  — Renders the generated Dart source for [skills].
- L182 `String _dartString(String value)`  — Escapes [value] into a single-quoted Dart string literal.

## tool/generate_hugeicons.py  (179 Z.)
- L23 `WANTED = [ "Message01Icon", "Album02Icon", "Folder03Icon", "Settings01Icon", "UserIcon", "User02Icon", "CheckIcon", "Plu`
- L115 `CAMEL = re.compile(r"([a-z0-9])([A-Z])")`
- L118 `def parse(source: str) -> list`  — Read the module's array. Keys are bare identifiers, values are already
- L126 `def attribute_name(key: str) -> str`  — `strokeLinecap` -> `stroke-linecap`.
- L131 `def to_svg(nodes: list) -> str`
- L146 `def file_stem(icon: str) -> str`  — `ArrowLeft02Icon` -> `arrow-left02`.
- L152 `def main() -> int`
