/// Lookup over the skills available to the AI.
///
/// Today this is only the built-in, compiled-in set (`builtin_skills.g.dart`,
/// generated from `assets/skills/`). User-authored skills (Supabase,
/// E2E-encrypted) will register here too — hence [bySource]. Nothing is ever
/// fetched from a marketplace or a URL at runtime: 36.8% of publicly shared
/// skills carry a security flaw, and 84% of those live in the SKILL.md prose
/// itself, which is processed with operator-level authority on activation.
library;

import 'package:chuk_chat/models/skill.dart';
import 'builtin_skills.g.dart';

class SkillRegistry {
  const SkillRegistry._();

  static Map<String, Skill>? _byName;

  /// Every registered skill, ordered by name.
  static List<Skill> get all => kBuiltinSkills;

  static Map<String, Skill> get _index =>
      _byName ??= {for (final skill in all) skill.name: skill};

  /// The skill called [name], or null. Case- and whitespace-tolerant, because
  /// this resolves a name the model typed.
  static Skill? byName(String name) => _index[name.trim().toLowerCase()];

  static bool exists(String name) => byName(name) != null;

  static List<Skill> bySource(SkillSource source) =>
      all.where((s) => s.source == source).toList();

  /// Names of every registered skill, ordered. Used for error messages.
  static List<String> get names => all.map((s) => s.name).toList();
}
