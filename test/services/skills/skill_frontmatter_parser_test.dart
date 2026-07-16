import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/models/skill.dart';
import 'package:chuk_chat/services/skills/skill_frontmatter_parser.dart';

/// Builds a SKILL.md with [frontmatter] verbatim between the --- fences.
String _md(String frontmatter, {String body = '# Body\n\nDo the thing.'}) =>
    '---\n$frontmatter\n---\n\n$body\n';

const String _minimal = 'name: weather-cards\ndescription: Does a thing.';

void main() {
  group('SkillFrontmatterParser structure', () {
    test('parses a minimal valid skill', () {
      final skill = parseSkillMarkdown(_md(_minimal));

      expect(skill.name, 'weather-cards');
      expect(skill.description, 'Does a thing.');
      expect(skill.body, '# Body\n\nDo the thing.');
      expect(skill.allowedTools, isEmpty);
      expect(skill.metadata, isEmpty);
      expect(skill.source, SkillSource.builtin);
    });

    test('rejects a file with no frontmatter', () {
      expect(
        () => parseSkillMarkdown('# Just markdown\n'),
        throwsA(
          isA<SkillParseException>().having(
            (e) => e.message,
            'message',
            contains('Missing YAML frontmatter'),
          ),
        ),
      );
    });

    test('rejects an empty body — a skill with no instructions is useless', () {
      expect(
        () => parseSkillMarkdown('---\n$_minimal\n---\n'),
        throwsA(
          isA<SkillParseException>().having(
            (e) => e.message,
            'message',
            contains('Body is empty'),
          ),
        ),
      );
    });

    test('rejects malformed YAML', () {
      expect(
        () => parseSkillMarkdown(_md('name: [unclosed\ndescription: x')),
        throwsA(isA<SkillParseException>()),
      );
    });
  });

  group('SkillFrontmatterParser name rules', () {
    test('accepts lowercase, digits and single hyphens', () {
      for (final name in ['a', 'pdf2', 'weather-cards', 'a-b-c-1']) {
        final skill = parseSkillMarkdown(
          _md('name: $name\ndescription: Does a thing.'),
        );
        expect(skill.name, name);
      }
    });

    test('rejects uppercase, underscores and other charset violations', () {
      // Kimi ships `name: image_generation`, which the spec forbids.
      for (final name in [
        'Weather',
        'image_generation',
        'weather cards',
        'a.b',
      ]) {
        expect(
          () => parseSkillMarkdown(_md('name: "$name"\ndescription: x.')),
          throwsA(isA<SkillParseException>()),
          reason: '"$name" must be rejected',
        );
      }
    });

    test('rejects leading, trailing and doubled hyphens', () {
      for (final name in ['-weather', 'weather-', 'pdf--processing']) {
        expect(
          () => parseSkillMarkdown(_md('name: "$name"\ndescription: x.')),
          throwsA(isA<SkillParseException>()),
          reason: '"$name" must be rejected',
        );
      }
    });

    test('rejects a name over ${Skill.kMaxNameChars} chars', () {
      final tooLong = 'a' * (Skill.kMaxNameChars + 1);
      expect(
        () => parseSkillMarkdown(_md('name: $tooLong\ndescription: x.')),
        throwsA(
          isA<SkillParseException>().having(
            (e) => e.message,
            'message',
            contains('max is ${Skill.kMaxNameChars}'),
          ),
        ),
      );
      expect(
        parseSkillMarkdown(
          _md('name: ${'a' * Skill.kMaxNameChars}\ndescription: x.'),
        ).name,
        hasLength(Skill.kMaxNameChars),
      );
    });

    test('name must equal the directory name when one is given', () {
      expect(
        () => parseSkillMarkdown(_md(_minimal), expectedName: 'news-cards'),
        throwsA(
          isA<SkillParseException>().having(
            (e) => e.message,
            'message',
            contains('must match the directory name'),
          ),
        ),
      );
      expect(
        parseSkillMarkdown(_md(_minimal), expectedName: 'weather-cards').name,
        'weather-cards',
      );
    });

    test('name is required', () {
      expect(
        () => parseSkillMarkdown(_md('description: x.')),
        throwsA(
          isA<SkillParseException>().having((e) => e.field, 'field', 'name'),
        ),
      );
    });
  });

  group('SkillFrontmatterParser description rules', () {
    test('is required and must be non-empty', () {
      for (final fm in ['name: a', 'name: a\ndescription: "   "']) {
        expect(
          () => parseSkillMarkdown(_md(fm)),
          throwsA(
            isA<SkillParseException>().having(
              (e) => e.field,
              'field',
              'description',
            ),
          ),
        );
      }
    });

    test('accepts exactly the spec ceiling and rejects one over', () {
      final atLimit = 'x' * Skill.kSpecMaxDescriptionChars;
      expect(
        parseSkillMarkdown(_md('name: a\ndescription: $atLimit')).description,
        hasLength(Skill.kSpecMaxDescriptionChars),
      );

      final overLimit = 'x' * (Skill.kSpecMaxDescriptionChars + 1);
      expect(
        () => parseSkillMarkdown(_md('name: a\ndescription: $overLimit')),
        throwsA(
          isA<SkillParseException>().having(
            (e) => e.message,
            'message',
            contains('spec max is ${Skill.kSpecMaxDescriptionChars}'),
          ),
        ),
      );
    });

    test('accepts a multi-line block scalar', () {
      // Kimi's image_generation skill uses `|-` for a ~1500-char description.
      // The parser must handle the form (the length budget is enforced
      // separately, by the generator).
      final skill = parseSkillMarkdown(
        _md('name: a\ndescription: |-\n  First line.\n  Second line.'),
      );
      expect(skill.description, 'First line.\nSecond line.');
    });
  });

  group('SkillFrontmatterParser unknown fields', () {
    test('rejects a top-level version — the spec has none, use metadata', () {
      expect(
        () => parseSkillMarkdown(_md('$_minimal\nversion: "1.0"')),
        throwsA(
          isA<SkillParseException>()
              .having((e) => e.field, 'field', 'version')
              .having(
                (e) => e.message,
                'message',
                contains('put it under "metadata"'),
              ),
        ),
      );
    });

    test('rejects a typo\'d field name instead of ignoring it', () {
      // The whole reason for strictness: `allowed_tools` would silently
      // grant nothing.
      expect(
        () => parseSkillMarkdown(_md('$_minimal\nallowed_tools: weather')),
        throwsA(
          isA<SkillParseException>().having(
            (e) => e.message,
            'message',
            contains('Unknown frontmatter field'),
          ),
        ),
      );
    });

    test('accepts all six spec fields together', () {
      final skill = parseSkillMarkdown(
        _md(
          'name: weather-cards\n'
          'description: Does a thing.\n'
          'license: Apache-2.0\n'
          'compatibility: Needs network access.\n'
          'metadata:\n'
          '  version: "1.2"\n'
          '  author: chuk\n'
          'allowed-tools: weather geocode',
        ),
      );

      expect(skill.license, 'Apache-2.0');
      expect(skill.compatibility, 'Needs network access.');
      expect(skill.metadata, {'version': '1.2', 'author': 'chuk'});
      expect(skill.version, '1.2');
      expect(skill.allowedTools, ['weather', 'geocode']);
    });
  });

  group('SkillFrontmatterParser compatibility rules', () {
    test('rejects over ${Skill.kMaxCompatibilityChars} chars', () {
      final over = 'x' * (Skill.kMaxCompatibilityChars + 1);
      expect(
        () => parseSkillMarkdown(_md('$_minimal\ncompatibility: $over')),
        throwsA(
          isA<SkillParseException>().having(
            (e) => e.field,
            'field',
            'compatibility',
          ),
        ),
      );
    });
  });

  group('SkillFrontmatterParser metadata rules', () {
    test('accepts quoted string values', () {
      final skill = parseSkillMarkdown(
        _md('$_minimal\nmetadata:\n  version: "1.0"\n  author: chuk'),
      );
      expect(skill.metadata, {'version': '1.0', 'author': 'chuk'});
    });

    test('rejects unquoted numbers and booleans rather than coercing', () {
      // The spec says string-to-string. Coercing with toString() would accept
      // these, and would also collapse the distinct YAML keys `1` and `"1"`
      // onto one string key, silently dropping a value.
      for (final fm in [
        '  version: 1.0',
        '  stable: true',
        '  1: a\n  "1": b',
      ]) {
        expect(
          () => parseSkillMarkdown(_md('$_minimal\nmetadata:\n$fm')),
          throwsA(
            isA<SkillParseException>().having(
              (e) => e.field,
              'field',
              'metadata',
            ),
          ),
          reason: 'metadata:\n$fm must be rejected',
        );
      }
    });

    test('rejects a nested map — metadata is flat string-to-string', () {
      expect(
        () => parseSkillMarkdown(
          _md('$_minimal\nmetadata:\n  nested:\n    a: b'),
        ),
        throwsA(
          isA<SkillParseException>().having(
            (e) => e.field,
            'field',
            'metadata',
          ),
        ),
      );
    });

    test('rejects a non-map metadata value', () {
      expect(
        () => parseSkillMarkdown(_md('$_minimal\nmetadata: nope')),
        throwsA(
          isA<SkillParseException>().having(
            (e) => e.field,
            'field',
            'metadata',
          ),
        ),
      );
    });
  });

  group('SkillFrontmatterParser allowed-tools rules', () {
    test('splits on arbitrary whitespace', () {
      final skill = parseSkillMarkdown(
        _md('$_minimal\nallowed-tools: "weather   geocode\tget_route"'),
      );
      expect(skill.allowedTools, ['weather', 'geocode', 'get_route']);
    });

    test('rejects a YAML list — the spec says space-separated string', () {
      expect(
        () => parseSkillMarkdown(
          _md('$_minimal\nallowed-tools:\n  - weather\n  - geocode'),
        ),
        throwsA(
          isA<SkillParseException>().having(
            (e) => e.field,
            'field',
            'allowed-tools',
          ),
        ),
      );
    });

    test('rejects duplicates', () {
      expect(
        () => parseSkillMarkdown(
          _md('$_minimal\nallowed-tools: weather weather'),
        ),
        throwsA(
          isA<SkillParseException>().having(
            (e) => e.message,
            'message',
            contains('more than once'),
          ),
        ),
      );
    });
  });

  group('SkillFrontmatterParser source', () {
    test('carries the requested source through', () {
      final skill = parseSkillMarkdown(
        _md(_minimal),
        skillSource: SkillSource.user,
      );
      expect(skill.source, SkillSource.user);
    });
  });
}
