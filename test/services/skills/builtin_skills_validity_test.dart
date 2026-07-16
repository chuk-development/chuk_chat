import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/models/skill.dart';
import 'package:chuk_chat/services/skills/builtin_skills.g.dart';
import 'package:chuk_chat/services/skills/skill_registry.dart';
import 'package:chuk_chat/services/tool_registry.dart' as registry;
import 'package:chuk_chat/utils/token_estimator.dart';

/// Budget for one skill body (level 2). The spec's best practices put the
/// ceiling at 5k tokens; a body is re-injected into the system prompt on every
/// round for the rest of the conversation, so this is real recurring weight.
const int _kMaxBodyTokens = 5000;

void main() {
  group('built-in skill budgets', () {
    test('descriptions stay within the level-1 budget', () {
      // The description sits in EVERY system prompt. The spec allows 1024
      // chars (~256 tokens), which is why Kimi's image_generation skill burns
      // ~375 tokens permanently. We hold ourselves far below that.
      for (final skill in kBuiltinSkills) {
        expect(
          skill.description.length,
          lessThanOrEqualTo(Skill.kMaxDescriptionChars),
          reason: '${skill.name}: description too long for a level-1 entry',
        );
      }
    });

    test('bodies stay under $_kMaxBodyTokens tokens and 500 lines', () {
      for (final skill in kBuiltinSkills) {
        expect(
          TokenEstimator.estimateTokens(skill.body),
          lessThan(_kMaxBodyTokens),
          reason: '${skill.name}: body too large',
        );
        expect(
          skill.body.split('\n').length,
          lessThanOrEqualTo(Skill.kMaxBodyLines),
          reason: '${skill.name}: body too long',
        );
      }
    });

    test('the whole catalog costs less than the blocks it replaces', () {
      // Sanity bound on level 1: this is what every prompt pays before a
      // single skill is loaded.
      final catalogChars = kBuiltinSkills
          .map((s) => s.name.length + s.description.length + 4)
          .fold<int>(0, (a, b) => a + b);

      expect(
        TokenEstimator.estimateTokens('x' * catalogChars),
        lessThan(500),
        reason: 'the level-1 catalog must stay cheap or it never pays back',
      );
    });
  });

  group('built-in skill contents', () {
    test('descriptions say when to use the skill', () {
      // The description is the only discovery signal the model gets.
      for (final skill in kBuiltinSkills) {
        expect(
          skill.description.toLowerCase(),
          contains('use when'),
          reason:
              '${skill.name}: description must state its trigger conditions',
        );
      }
    });

    test('descriptions are third person, not first or second', () {
      // Spec: mixed point-of-view causes discovery problems.
      for (final skill in kBuiltinSkills) {
        final lower = skill.description.toLowerCase();
        expect(lower, isNot(startsWith('i ')));
        expect(lower, isNot(contains('i can ')));
        expect(lower, isNot(contains('you can use this')));
      }
    });

    test('every allowed-tool is a real, registered tool', () {
      // Catches a typo that would otherwise silently pre-approve nothing.
      for (final skill in kBuiltinSkills) {
        for (final tool in skill.allowedTools) {
          expect(
            registry.toolCategoryMap.keys,
            contains(tool),
            reason:
                '${skill.name}: allowed-tools lists "$tool", which is not a '
                'known tool',
          );
        }
      }
    });

    test('names are unique', () {
      final names = kBuiltinSkills.map((s) => s.name).toList();
      expect(names.toSet(), hasLength(names.length));
    });
  });

  group('SkillRegistry', () {
    test('resolves by exact name', () {
      expect(SkillRegistry.byName('weather-cards')?.name, 'weather-cards');
      expect(SkillRegistry.exists('weather-cards'), isTrue);
    });

    test('tolerates the whitespace and casing a model might emit', () {
      expect(SkillRegistry.byName('  weather-cards  ')?.name, 'weather-cards');
      expect(SkillRegistry.byName('Weather-Cards')?.name, 'weather-cards');
    });

    test('returns null for an unknown name rather than throwing', () {
      expect(SkillRegistry.byName('does-not-exist'), isNull);
      expect(SkillRegistry.exists('does-not-exist'), isFalse);
    });

    test('every built-in skill is registered as builtin', () {
      expect(
        SkillRegistry.bySource(SkillSource.builtin),
        hasLength(kBuiltinSkills.length),
      );
      expect(SkillRegistry.bySource(SkillSource.user), isEmpty);
    });

    test('names matches the catalog order', () {
      expect(SkillRegistry.names, kBuiltinSkills.map((s) => s.name).toList());
    });
  });
}
