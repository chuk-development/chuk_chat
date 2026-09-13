/// Lookup over the skills available to the AI: built-in plus user-authored.
///
/// Built-ins (`builtin_skills.g.dart`, generated from `assets/skills/`) are
/// compiled in and carry the trust level of the surrounding Dart code.
/// User skills come from [UserSkillsService] (Supabase, E2E-encrypted).
/// Nothing is ever fetched from a marketplace or a URL at runtime: 36.8% of
/// publicly shared skills carry a security flaw, and 84% of those live in the
/// SKILL.md prose itself, which is processed with operator-level authority on
/// activation.
///
/// [all] is deliberately synchronous — it is read while building the system
/// prompt on every round. User skills are therefore held in a cache that
/// [refreshUserSkills] fills asynchronously; until it has run, only built-ins
/// are visible, which is the correct failure mode (a missing user skill costs
/// a capability, never correctness).
library;

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/models/skill.dart';
import 'package:chuk_chat/services/skills/builtin_skills.g.dart';
import 'package:chuk_chat/services/skills/user_skills_service.dart';

class SkillRegistry {
  const SkillRegistry._();

  static List<Skill> _userSkills = const [];
  static List<Skill>? _all;
  static Map<String, Skill>? _byName;

  /// Every registered skill: built-ins first, then the user's own.
  ///
  /// Unmodifiable: this is a memoized cache, and a caller mutating it would
  /// corrupt the catalog while leaving [_byName] pointing at the old contents.
  static List<Skill> get all =>
      _all ??= List.unmodifiable([...kBuiltinSkills, ..._userSkills]);

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

  /// Names that a user skill may not take.
  static Set<String> get builtinNames =>
      kBuiltinSkills.map((s) => s.name).toSet();

  /// Reloads the user's skills from storage. Safe to call repeatedly; call it
  /// after any create/edit/delete and once at startup.
  static Future<void> refreshUserSkills({bool forceRefresh = false}) async {
    final loaded = await UserSkillsService.load(forceRefresh: forceRefresh);
    setUserSkills(loaded);
  }

  /// Replaces the user-skill layer, dropping anything that would make the
  /// catalog ambiguous.
  ///
  /// Two rules, both about names, because the name is what the model resolves
  /// a skill by:
  ///
  ///  - **Built-ins win a collision.** A user skill shadowing `weather-cards`
  ///    would gate the built-in weather protocol out of the prompt (see
  ///    `ToolPromptBuilder._migratedToSkill`) while injecting arbitrary text in
  ///    its place. [UserSkillsService.save] rejects such names up front; this is
  ///    the backstop for rows predating the check or arriving from another
  ///    device.
  ///  - **First occurrence wins a duplicate.** Uniqueness cannot be constrained
  ///    server-side — the name lives inside the encrypted blob — so two devices
  ///    creating the same name concurrently both land. Without this, [all] would
  ///    list both while [_index] silently resolved the last, so the catalog the
  ///    model reads and the skill it actually gets would disagree.
  static void setUserSkills(List<Skill> skills) {
    final reserved = builtinNames;
    final seen = <String>{};
    final filtered = <Skill>[];
    var dropped = 0;

    for (final skill in skills) {
      if (reserved.contains(skill.name) || !seen.add(skill.name)) {
        dropped++;
        continue;
      }
      filtered.add(skill);
    }

    if (dropped > 0 && kDebugMode) {
      // Count only — a skill name is user-authored content.
      debugPrint('[Skills] dropped $dropped user skill(s) with a taken name');
    }

    _userSkills = List.unmodifiable(filtered);
    _invalidate();
  }

  static void _invalidate() {
    _all = null;
    _byName = null;
  }

  @visibleForTesting
  static void resetForTest() {
    _userSkills = const [];
    _invalidate();
  }
}
