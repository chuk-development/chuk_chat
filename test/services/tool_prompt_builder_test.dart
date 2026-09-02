import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/models/skill.dart';
import 'package:chuk_chat/services/skills/builtin_skills.g.dart';
import 'package:chuk_chat/services/tool_prompt_builder.dart';
import 'package:chuk_chat/utils/token_estimator.dart';

final Map<String, dynamic> _skillToolDef = {
  'name': 'skill',
  'description': 'Load a skill.',
  'parameters': <String, dynamic>{'name': 'string'},
};

final List<Map<String, dynamic>> _tools = [
  {
    'name': 'find_tools',
    'description': 'Discovery',
    'parameters': <String, dynamic>{},
  },
  {
    'name': 'web_search',
    'description': 'Search',
    'parameters': <String, dynamic>{},
  },
  {
    'name': 'weather',
    'description': 'Weather',
    'parameters': <String, dynamic>{},
  },
  {
    'name': 'skill',
    'description': 'Load a skill.',
    'parameters': <String, dynamic>{},
  },
];

const Skill _testSkill = Skill(
  name: 'weather-cards',
  description: 'Renders weather. Use when the user asks about weather.',
  body: '# Weather cards\n\nEmit a <weather> block. UNIQUE-BODY-MARKER.',
  allowedTools: ['weather'],
);

void main() {
  group('ToolPromptBuilder image output guidance', () {
    test('includes explicit <image> render-only protocol and fetch split', () {
      final builder = ToolPromptBuilder(discoveryMode: true);
      final tools = <Map<String, dynamic>>[
        {
          'name': 'find_tools',
          'description': 'Discovery',
          'parameters': <String, dynamic>{},
        },
        {
          'name': 'web_search',
          'description': 'Search',
          'parameters': <String, dynamic>{},
        },
        {
          'name': 'web_crawl',
          'description': 'Crawl',
          'parameters': <String, dynamic>{},
        },
      ];

      final section = builder.buildToolProtocolSection(
        tools: tools,
        webSearchToolDef: tools[1],
        webCrawlToolDef: tools[2],
      );

      expect(section, contains('<image>'));
      expect(section, contains('Image routing rules'));
      expect(section, contains('not for display-only rendering'));
    });
  });

  group('ToolPromptBuilder continuation guidance (isToolResult)', () {
    final tools = <Map<String, dynamic>>[
      {
        'name': 'generate_image',
        'description': 'Generate an image',
        'parameters': <String, dynamic>{},
      },
    ];

    test('adds continuation block on post-tool-result passes', () {
      final builder = ToolPromptBuilder(discoveryMode: true);
      final section = builder.buildToolProtocolSection(
        tools: tools,
        isToolResult: true,
      );
      expect(section, contains('CONTINUATION'));
      expect(section, contains('ALREADY shown to the user'));
    });

    test('omits continuation block on the initial pass', () {
      final builder = ToolPromptBuilder(discoveryMode: true);
      final section = builder.buildToolProtocolSection(
        tools: tools,
        isToolResult: false,
      );
      expect(section, isNot(contains('CONTINUATION —')));
    });
  });

  group(
    'ToolPromptBuilder artifact rewrite rule (regression for user-edit drop)',
    () {
      test(
        'artifact protocol forbids regenerating rewrites from the AI\'s own memory',
        () {
          final builder = ToolPromptBuilder(discoveryMode: false);
          final artifactTool = <String, dynamic>{
            'name': 'artifact_manager',
            'description': 'Manage artifacts.',
            'parameters': <String, dynamic>{
              'action': 'create | update | rewrite',
            },
          };

          final section = builder.buildToolProtocolSection(
            tools: <Map<String, dynamic>>[artifactTool],
            artifactToolDef: artifactTool,
          );

          // The rule must be present so excalidraw / mermaid / svg rewrites
          // base their output on the live body in the system message instead
          // of regenerating from the AI's memory of the original version
          // (which silently destroys user edits between turns — the bug we
          // are fixing here).
          expect(
            section,
            contains('Rewrites MUST be derived from the CURRENT artifact body'),
            reason:
                'tool protocol must instruct the AI to base rewrites on the '
                'system-message body, not its memory of the previous version',
          );
          expect(
            section,
            contains('never from your own memory'),
            reason:
                'the explicit "do not regenerate from memory" clause '
                'must be present',
          );
          expect(
            section,
            contains('silently destroys every user edit'),
            reason:
                'the consequence (silent edit loss) must be stated so '
                'the model treats this as a hard rule, not a suggestion',
          );
        },
      );
    },
  );

  group('ToolPromptBuilder skills catalog', () {
    String build({
      required bool discoveryMode,
      List<Map<String, dynamic>>? discoveredTools,
      List<Skill> catalog = const [_testSkill],
      List<Skill> active = const [],
    }) {
      return ToolPromptBuilder(
        discoveryMode: discoveryMode,
      ).buildToolProtocolSection(
        tools: _tools,
        discoveredTools: discoveredTools,
        skillToolDef: _skillToolDef,
        skillCatalog: catalog,
        activeSkills: active,
      );
    }

    test('is emitted in all three prompt branches', () {
      // The catalog lives after the branch dispatch precisely so no branch
      // can forget it.
      final branches = <String, String>{
        'discovery, names only': build(discoveryMode: true),
        'discovery, post-find_tools': build(
          discoveryMode: true,
          discoveredTools: [_tools[1]],
        ),
        'full protocol': build(discoveryMode: false),
      };

      for (final entry in branches.entries) {
        expect(
          entry.value,
          contains('## SKILLS'),
          reason: '${entry.key} branch dropped the catalog',
        );
        expect(
          entry.value,
          contains('- weather-cards: Renders weather.'),
          reason: '${entry.key} branch dropped the catalog entry',
        );
      }
    });

    test('tells the model a skill is not a tool', () {
      // The discovery prompt insists the model must call find_tools before
      // using anything it can only see the name of. Without this the model
      // calls find_tools("weather-cards") or puts it in a tool_call.
      final section = build(discoveryMode: true);

      expect(section, contains('Skills are procedures, not tools'));
      expect(section, contains('never call find_tools for a skill'));
      expect(section, contains('never put a skill name in the "name" field'));
    });

    test('says loading is a setup step, not the answer', () {
      // Guards against the CONTINUATION block ("reply ONCE with a short final
      // answer") being read as "done" right after a bare skill ack.
      expect(
        build(discoveryMode: true),
        contains('is never the answer by itself'),
      );
    });

    test('is omitted entirely when no skills are available', () {
      // Flag-off: the `skill` tool never registers, so the catalog is empty
      // and the prompt must be exactly what it was before this feature.
      final section = build(discoveryMode: true, catalog: const []);

      expect(section, isNot(contains('## SKILLS')));
      expect(section, isNot(contains('ACTIVE SKILL')));
    });
  });

  group('ToolPromptBuilder active skill bodies', () {
    String build({List<Skill> active = const []}) =>
        ToolPromptBuilder(discoveryMode: false).buildToolProtocolSection(
          tools: _tools,
          skillToolDef: _skillToolDef,
          skillCatalog: const [_testSkill],
          activeSkills: active,
        );

    test('injects the body verbatim under a per-skill heading', () {
      final section = build(active: const [_testSkill]);

      expect(section, contains('## ACTIVE SKILL: weather-cards'));
      expect(section, contains('UNIQUE-BODY-MARKER'));
    });

    test('injects no body when nothing is active', () {
      final section = build();

      expect(section, contains('## SKILLS'));
      // The catalog preamble names "## ACTIVE SKILL" to tell the model where
      // a body will appear, so assert on the heading form specifically.
      expect(section, isNot(contains('## ACTIVE SKILL:')));
      expect(section, isNot(contains('UNIQUE-BODY-MARKER')));
    });

    test('body comes after the catalog so it sits closest to the answer', () {
      final section = build(active: const [_testSkill]);

      expect(
        section.indexOf('## ACTIVE SKILL'),
        greaterThan(section.indexOf('## SKILLS')),
      );
    });
  });

  group('ToolPromptBuilder protocol blocks migrated to skills', () {
    String build({required List<Skill> catalog, bool discoveryMode = false}) =>
        ToolPromptBuilder(
          discoveryMode: discoveryMode,
        ).buildToolProtocolSection(
          tools: _tools,
          skillToolDef: catalog.isEmpty ? null : _skillToolDef,
          skillCatalog: catalog,
        );

    test('inlines weather/news/chart/research detail when skills are off', () {
      for (final discovery in [true, false]) {
        final section = build(catalog: const [], discoveryMode: discovery);

        expect(section, contains('WMO codes'), reason: 'discovery=$discovery');
        expect(section, contains('### News'), reason: 'discovery=$discovery');
        expect(section, contains('### Charts'), reason: 'discovery=$discovery');
      }
      expect(build(catalog: const []), contains('### Research depth:'));
      expect(
        build(catalog: const [], discoveryMode: true),
        contains('RESEARCH DEPTH:'),
      );
    });

    test('drops each block once the skill that replaces it exists', () {
      for (final discovery in [true, false]) {
        final section = build(
          catalog: kBuiltinSkills,
          discoveryMode: discovery,
        );

        expect(
          section,
          isNot(contains('WMO codes')),
          reason: 'discovery=$discovery',
        );
        expect(
          section,
          isNot(contains('### News')),
          reason: 'discovery=$discovery',
        );
        expect(
          section,
          isNot(contains('### Charts')),
          reason: 'discovery=$discovery',
        );
        expect(
          section,
          isNot(contains('RESEARCH DEPTH:')),
          reason: 'discovery=$discovery',
        );
        expect(
          section,
          isNot(contains('### Research depth:')),
          reason: 'discovery=$discovery',
        );
        expect(
          section,
          isNot(contains('FRESH RELEASES:')),
          reason: 'discovery=$discovery',
        );
      }
    });

    test('gating is per skill, not all-or-nothing', () {
      // Only weather-cards available: its block goes, the others stay.
      final section = build(catalog: const [_testSkill]);

      expect(section, isNot(contains('WMO codes')));
      expect(section, contains('### News'));
      expect(section, contains('### Charts'));
    });

    test('points the model at the skill before it emits a gated tag', () {
      final section = build(catalog: kBuiltinSkills);

      expect(section, contains('<weather> -> `weather-cards`'));
      expect(section, contains('<news> -> `news-cards`'));
      expect(section, contains('<chart> -> `chart-authoring`'));
      expect(section, contains('Never write one from memory'));
    });

    test('keeps the unconditional "search the web first" reflex', () {
      // deep-research carries the method, not the reflex — the model must
      // still know to search without loading anything.
      final section = build(catalog: kBuiltinSkills);

      expect(section, contains('OUTDATED KNOWLEDGE'));
      expect(section, contains('SEARCH THE WEB FIRST'));
      expect(section, contains('USER-CLAIMED RECENCY IS A HARD TRIGGER'));
    });

    test('keeps the <map> reflex — maps are never gated behind a load', () {
      final section = build(catalog: kBuiltinSkills);

      expect(section, contains('ALWAYS include a <map> after location'));
      expect(section, contains('### Maps'));
    });

    test('numbered rules have no gap when a rule is migrated away', () {
      // Only the "### Rules:" list of the tool protocol — the visual output
      // section has its own list that counts past 10.
      String toolRules(String section) {
        final start = section.indexOf('### Rules:');
        expect(start, isNot(-1));
        final end = section.indexOf('\n##', start);
        return section.substring(start, end == -1 ? section.length : end);
      }

      // Rule 10 was NEWS, rule 11 WEB SEARCH TUNING. With news-cards and
      // deep-research both present neither survives, so 9 must be last.
      final migrated = toolRules(build(catalog: kBuiltinSkills));
      expect(migrated, contains('\n9. '));
      expect(migrated, isNot(contains('\n10. ')));
      expect(migrated, isNot(contains('\n11. ')));

      // With no skills at all, both rules stay and keep their numbers.
      final inlined = toolRules(build(catalog: const []));
      expect(inlined, contains('\n10. NEWS & TIME-SENSITIVE QUERIES'));
      expect(inlined, contains('\n11. WEB SEARCH TUNING'));

      // Only news-cards migrated: tuning must slide up to 10, not stay at 11.
      final partial = toolRules(build(catalog: [kBuiltinSkills[2]]));
      expect(partial, isNot(contains('NEWS & TIME-SENSITIVE QUERIES')));
      expect(partial, contains('\n10. WEB SEARCH TUNING'));
      expect(partial, isNot(contains('\n11. ')));
    });
  });

  group('ToolPromptBuilder skills token budget', () {
    test('the real catalog costs fewer tokens than the blocks it removes', () {
      // The point of M1: the catalog is not a new cost, it is a net saving.
      // A catalog that does not pay for itself would never justify the flag.
      String build(List<Skill> catalog) =>
          ToolPromptBuilder(discoveryMode: false).buildToolProtocolSection(
            tools: _tools,
            skillToolDef: catalog.isEmpty ? null : _skillToolDef,
            skillCatalog: catalog,
          );

      final without = TokenEstimator.estimateTokens(build(const []));
      final with_ = TokenEstimator.estimateTokens(build(kBuiltinSkills));

      expect(
        with_,
        lessThan(without),
        reason:
            'skills must SHRINK the base prompt: $without -> $with_ tokens '
            '(delta ${with_ - without})',
      );
    });

    test('an active body is charged only once it is loaded', () {
      String build(List<Skill> active) =>
          ToolPromptBuilder(discoveryMode: false).buildToolProtocolSection(
            tools: _tools,
            skillToolDef: _skillToolDef,
            skillCatalog: kBuiltinSkills,
            activeSkills: active,
          );

      final idle = TokenEstimator.estimateTokens(build(const []));
      final loaded = TokenEstimator.estimateTokens(
        build([kBuiltinSkills.first]),
      );

      expect(loaded, greaterThan(idle));
    });
  });
}
