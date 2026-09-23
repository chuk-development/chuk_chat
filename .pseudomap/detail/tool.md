# tool · Signaturen

## tool/gen_skills.dart  (191 Z.)
- L28 `kSkillsDir = 'assets/skills'`
- L29 `kOutputPath = 'lib/services/skills/builtin_skills.g.dart'`
- L31 `void main(List<String> args)`
- L68 `List<Skill> loadSkillsFromDisk(Directory skillsDir)`  — Parses every `<dir>/<name>/SKILL.md`, validating each against the spec plus
- L104 `void _validateBudgets(Skill skill, String path)`  — Budgets that are stricter than the spec, because built-in skills are
- L125 `String renderBuiltinSkillsFile(List<Skill> skills)`  — Renders the generated Dart source for [skills].
- L182 `String _dartString(String value)`  — Escapes [value] into a single-quoted Dart string literal.

## tool/generate_hugeicons.py  (119 Z.)
- L23 `WANTED = [ "Message01Icon", "Album02Icon", "Folder03Icon", "Settings01Icon", "UserIcon", "User02Icon", "CheckIcon", "Plu`
- L55 `CAMEL = re.compile(r"([a-z0-9])([A-Z])")`
- L58 `def parse(source: str) -> list`  — Read the module's array. Keys are bare identifiers, values are already
- L66 `def attribute_name(key: str) -> str`  — `strokeLinecap` -> `stroke-linecap`.
- L71 `def to_svg(nodes: list) -> str`
- L86 `def file_stem(icon: str) -> str`  — `ArrowLeft02Icon` -> `arrow-left02`.
- L92 `def main() -> int`
