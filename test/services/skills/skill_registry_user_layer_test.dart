import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/models/skill.dart';
import 'package:chuk_chat/services/skills/builtin_skills.g.dart';
import 'package:chuk_chat/services/skills/skill_registry.dart';

Skill _userSkill(String name, {String? id}) => Skill(
  name: name,
  description: 'Does $name. Use when the user asks for $name.',
  body: '# $name\n\nBody of $name.',
  source: SkillSource.user,
  id: id,
);

void main() {
  setUp(SkillRegistry.resetForTest);
  tearDown(SkillRegistry.resetForTest);

  group('SkillRegistry user layer', () {
    test('only built-ins are visible before user skills load', () {
      // refreshUserSkills is fire-and-forget at startup, so this is the state
      // every prompt is built in until it lands. Costs a capability, never
      // correctness.
      expect(SkillRegistry.all, kBuiltinSkills);
      expect(SkillRegistry.bySource(SkillSource.user), isEmpty);
    });

    test('user skills append after built-ins', () {
      SkillRegistry.setUserSkills([_userSkill('my-review', id: 'row-1')]);

      expect(SkillRegistry.all, hasLength(kBuiltinSkills.length + 1));
      expect(SkillRegistry.all.last.name, 'my-review');
      expect(SkillRegistry.byName('my-review')?.source, SkillSource.user);
      expect(SkillRegistry.byName('my-review')?.id, 'row-1');
    });

    test('bySource splits the two layers', () {
      SkillRegistry.setUserSkills([
        _userSkill('a-skill'),
        _userSkill('b-skill'),
      ]);

      expect(
        SkillRegistry.bySource(SkillSource.builtin),
        hasLength(kBuiltinSkills.length),
      );
      expect(SkillRegistry.bySource(SkillSource.user), hasLength(2));
    });

    test('a user skill cannot shadow a built-in', () {
      // A shadow would gate the built-in's protocol block out of the prompt
      // (ToolPromptBuilder._migratedToSkill keys on the name) while injecting
      // the user's arbitrary text in its place.
      SkillRegistry.setUserSkills([
        _userSkill('weather-cards', id: 'row-evil'),
        _userSkill('legit-skill', id: 'row-ok'),
      ]);

      expect(
        SkillRegistry.byName('weather-cards')?.source,
        SkillSource.builtin,
      );
      expect(SkillRegistry.byName('weather-cards')?.id, isNull);
      expect(SkillRegistry.bySource(SkillSource.user), hasLength(1));
      expect(
        SkillRegistry.bySource(SkillSource.user).single.name,
        'legit-skill',
      );
    });

    test('a duplicate user name keeps only the first', () {
      // Uniqueness cannot be constrained server-side (the name lives inside
      // the encrypted blob), so two devices creating the same name both land.
      // Without dedup `all` would list both while `byName` resolved the last —
      // the catalog the model reads and the skill it gets would disagree.
      SkillRegistry.setUserSkills([
        _userSkill('dupe', id: 'row-first'),
        _userSkill('dupe', id: 'row-second'),
      ]);

      expect(SkillRegistry.bySource(SkillSource.user), hasLength(1));
      expect(SkillRegistry.byName('dupe')?.id, 'row-first');
      expect(
        SkillRegistry.names.where((n) => n == 'dupe'),
        hasLength(1),
        reason: 'the catalog must never advertise the same name twice',
      );
    });

    test('all is unmodifiable', () {
      // It is a memoized cache; a caller mutating it would corrupt the catalog
      // and leave the byName index pointing at the old contents.
      SkillRegistry.setUserSkills([_userSkill('x-skill')]);

      expect(
        () => SkillRegistry.all.add(_userSkill('sneaky')),
        throwsUnsupportedError,
      );
    });

    test('builtinNames covers every built-in', () {
      expect(
        SkillRegistry.builtinNames,
        kBuiltinSkills.map((s) => s.name).toSet(),
      );
      expect(SkillRegistry.builtinNames, contains('weather-cards'));
    });

    test('the byName index is invalidated when the user layer changes', () {
      // byName memoizes; a stale index would keep resolving a deleted skill.
      SkillRegistry.setUserSkills([_userSkill('first')]);
      expect(SkillRegistry.byName('first'), isNotNull);

      SkillRegistry.setUserSkills([_userSkill('second')]);
      expect(
        SkillRegistry.byName('first'),
        isNull,
        reason: 'the memoized index must be dropped when skills change',
      );
      expect(SkillRegistry.byName('second'), isNotNull);
    });

    test('replacing with an empty list clears the user layer', () {
      SkillRegistry.setUserSkills([_userSkill('temp')]);
      SkillRegistry.setUserSkills(const []);

      expect(SkillRegistry.all, kBuiltinSkills);
      expect(SkillRegistry.byName('temp'), isNull);
    });

    test('names covers both layers in catalog order', () {
      SkillRegistry.setUserSkills([_userSkill('zzz-last')]);

      expect(SkillRegistry.names.first, kBuiltinSkills.first.name);
      expect(SkillRegistry.names.last, 'zzz-last');
    });

    test('a model-typed name resolves across both layers', () {
      SkillRegistry.setUserSkills([_userSkill('my-review')]);

      expect(SkillRegistry.byName(' My-Review ')?.name, 'my-review');
      expect(SkillRegistry.byName('WEATHER-CARDS')?.name, 'weather-cards');
    });
  });

  group('Skill model storage identity', () {
    test('built-ins carry no row id', () {
      for (final skill in kBuiltinSkills) {
        expect(skill.id, isNull);
        expect(skill.isBuiltin, isTrue);
      }
    });

    test('copyWith attaches a row id without touching the content', () {
      const base = Skill(name: 'a', description: 'd', body: 'b');
      final stored = base.copyWith(id: 'row-9', source: SkillSource.user);

      expect(stored.id, 'row-9');
      expect(stored.source, SkillSource.user);
      expect(stored.name, base.name);
      expect(stored.body, base.body);
      expect(stored.isBuiltin, isFalse);
    });

    test('a built-in can never carry a row id', () {
      // A stale id on a built-in would let an edit or delete target someone's
      // stored skill.
      expect(
        () => Skill(name: 'a', description: 'd', body: 'b', id: 'row-1'),
        throwsA(isA<AssertionError>()),
      );

      final userSkill = const Skill(
        name: 'a',
        description: 'd',
        body: 'b',
      ).copyWith(id: 'row-1', source: SkillSource.user);
      expect(userSkill.id, 'row-1');

      // Moving back to builtin drops the id rather than carrying it over.
      expect(userSkill.copyWith(source: SkillSource.builtin).id, isNull);
    });

    test('equality distinguishes skills by row id and source', () {
      const a = Skill(name: 'x', description: 'd', body: 'b');
      Skill stored(String id) => a.copyWith(id: id, source: SkillSource.user);

      expect(stored('1'), isNot(stored('2')));
      expect(stored('1'), stored('1'));
      expect(a, isNot(a.copyWith(source: SkillSource.user)));
    });

    test('copyWith(id:) on a built-in is a no-op, not a smuggled id', () {
      const builtin = Skill(name: 'x', description: 'd', body: 'b');
      expect(builtin.copyWith(id: 'row-1').id, isNull);
    });
  });
}
