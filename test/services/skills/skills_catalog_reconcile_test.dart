// Tests for the pure catalog reconciliation planner: every branch of
// add / silent-update / suggest / no-op / builtin-skip, plus the manifest
// entry parsing and hashing helpers. No network, no database.

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/skills/skills_catalog_service.dart';

CatalogSkill _cat(String name, String hash) => CatalogSkill(
  name: name,
  description: 'does $name',
  path: 'skills/$name',
  hash: hash,
);

void main() {
  group('planCatalogReconcile', () {
    test('a skill the user does not have is added', () {
      final plan = planCatalogReconcile(
        catalog: [_cat('browser', 'sha256:aaa')],
        localByCatalogName: const {},
        builtinNames: const {},
      );
      expect(plan.toAdd.map((c) => c.name), ['browser']);
      expect(plan.toUpdate, isEmpty);
      expect(plan.suggestions, isEmpty);
    });

    test('a pristine skill whose catalog hash changed is updated silently', () {
      final plan = planCatalogReconcile(
        catalog: [_cat('browser', 'sha256:new')],
        localByCatalogName: {
          // source hash == baseline hash => never edited.
          'browser': const LocalSkillState(
            id: 'row-1',
            sourceHash: 'sha256:old',
            baselineHash: 'sha256:old',
          ),
        },
        builtinNames: const {},
      );
      expect(plan.toUpdate, hasLength(1));
      expect(plan.toUpdate.first.id, 'row-1');
      expect(plan.toUpdate.first.catalog.hash, 'sha256:new');
      expect(plan.suggestions, isEmpty);
      expect(plan.toAdd, isEmpty);
    });

    test('an edited skill whose catalog hash changed becomes a suggestion', () {
      final plan = planCatalogReconcile(
        catalog: [_cat('browser', 'sha256:new')],
        localByCatalogName: {
          // source hash != baseline hash => the user edited it.
          'browser': const LocalSkillState(
            id: 'row-1',
            sourceHash: 'sha256:mine',
            baselineHash: 'sha256:old',
          ),
        },
        builtinNames: const {},
      );
      expect(plan.suggestions, hasLength(1));
      expect(plan.suggestions.first.id, 'row-1');
      expect(plan.suggestions.first.catalog.hash, 'sha256:new');
      expect(plan.toUpdate, isEmpty);
      expect(plan.toAdd, isEmpty);
    });

    test('a skill already on the current catalog hash is left alone', () {
      final plan = planCatalogReconcile(
        catalog: [_cat('browser', 'sha256:same')],
        localByCatalogName: {
          'browser': const LocalSkillState(
            id: 'row-1',
            sourceHash: 'sha256:same',
            baselineHash: 'sha256:same',
          ),
        },
        builtinNames: const {},
      );
      expect(plan.isEmpty, isTrue);
    });

    test('an edited skill whose catalog did NOT move gets no suggestion', () {
      final plan = planCatalogReconcile(
        catalog: [_cat('browser', 'sha256:base')],
        localByCatalogName: {
          'browser': const LocalSkillState(
            id: 'row-1',
            sourceHash: 'sha256:mine',
            baselineHash: 'sha256:base',
          ),
        },
        builtinNames: const {},
      );
      expect(plan.isEmpty, isTrue);
    });

    test('a catalog entry that collides with a built-in is skipped', () {
      final plan = planCatalogReconcile(
        catalog: [_cat('weather-cards', 'sha256:x')],
        localByCatalogName: const {},
        builtinNames: {'weather-cards'},
      );
      expect(plan.skippedBuiltin.map((c) => c.name), ['weather-cards']);
      expect(plan.toAdd, isEmpty);
    });
  });

  group('CatalogSkill.fromJson', () {
    test('parses a full entry', () {
      final skill = CatalogSkill.fromJson({
        'name': 'browser',
        'description': 'd',
        'path': 'skills/browser',
        'hash': 'sha256:abc',
        'license': 'Apache-2.0',
        'allowed_tools': ['bash', 'web_crawl'],
        'resources': ['references/R.md'],
      });
      expect(skill, isNotNull);
      expect(skill!.allowedTools, ['bash', 'web_crawl']);
      expect(skill.resources, ['references/R.md']);
      expect(skill.license, 'Apache-2.0');
    });

    test('returns null when a required field is missing', () {
      expect(
        CatalogSkill.fromJson({'name': 'x', 'description': 'y'}),
        isNull,
      );
    });
  });

  test('hashOf is stable and prefixed', () {
    final h = SkillsCatalogService.hashOf('hello');
    expect(h, startsWith('sha256:'));
    expect(h, SkillsCatalogService.hashOf('hello'));
    expect(h, isNot(SkillsCatalogService.hashOf('world')));
  });
}
