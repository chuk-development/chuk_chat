import 'package:chuk_chat/services/tool_prompt_builder.dart';
import 'package:flutter_test/flutter_test.dart';

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
        includeMapVisualOutput: true,
        includeChartVisualOutput: true,
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

  group('ToolPromptBuilder artifact rewrite rule (regression for user-edit drop)', () {
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
          includeMapVisualOutput: false,
          includeChartVisualOutput: false,
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
          reason: 'the explicit "do not regenerate from memory" clause '
              'must be present',
        );
        expect(
          section,
          contains('silently destroys every user edit'),
          reason: 'the consequence (silent edit loss) must be stated so '
              'the model treats this as a hard rule, not a suggestion',
        );
      },
    );
  });
}
