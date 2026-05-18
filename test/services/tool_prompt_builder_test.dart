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
}
