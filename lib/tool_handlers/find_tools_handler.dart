import 'package:chuk_chat/models/client_tool.dart';

/// Companion tools that are always bundled together.
/// When a trigger tool is discovered, its companions are auto-included.
const companions = <String, List<String>>{
  'web_search': ['web_crawl'],
  'web_crawl': ['web_search'],
  'generate_image': ['edit_image', 'fetch_image', 'view_chat_images'],
  'edit_image': ['generate_image', 'fetch_image', 'view_chat_images'],
  'fetch_image': ['view_chat_images', 'web_crawl'],
  'view_chat_images': ['fetch_image'],
  'search_restaurants': ['web_search', 'web_crawl', 'get_route', 'geocode'],
  'search_places': ['web_search', 'web_crawl', 'get_route', 'geocode'],
  'get_route': ['geocode'],
  'geocode': ['get_route'],
  'stock_data': ['web_search', 'web_crawl'],
  'weather': ['geocode', 'web_search'],
  'search_chats': ['notes'],
  'notes': ['search_chats'],
};

void _appendToolDefinition(
  StringBuffer buf,
  ClientTool tool,
  String Function(String) getDescription,
) {
  buf.writeln('TOOL: ${tool.name}');
  buf.writeln('Description: ${getDescription(tool.name)}');
  if (tool.parameters.isNotEmpty) {
    buf.writeln('Parameters:');
    for (final entry in tool.parameters.entries) {
      if (entry.value is Map) {
        final ptype = (entry.value as Map)['type'] ?? 'string';
        final pdesc = (entry.value as Map)['description'] ?? '';
        buf.writeln('  - ${entry.key} ($ptype): $pdesc');
      } else {
        buf.writeln('  - ${entry.key}: ${entry.value}');
      }
    }
  }
  buf.writeln();
}

/// Find tools by keyword/query. Returns full tool definitions for matching
/// tools.
///
/// [args] - tool call arguments (expects 'query' key)
/// [tools] - map of all registered tools
/// [getDescription] - function to get effective description for a tool
/// [isAvailable] - function to check if a tool is available
String executeFindTools({
  required Map<String, dynamic> args,
  required Map<String, ClientTool> tools,
  required String Function(String) getDescription,
  required bool Function(String) isAvailable,
}) {
  final query = (args['query'] as String? ?? '').toLowerCase().trim();
  if (query.isEmpty) {
    return 'Error: "query" parameter required. Use 1-3 SHORT category '
        'keywords, e.g. "restaurant", "web search", "email senden"';
  }

  // Filter out very short words and common noise words
  const noiseWords = {
    'in',
    'im',
    'am',
    'um',
    'zu',
    'an',
    'es',
    'is',
    'it',
    'on',
    'at',
    'to',
    'of',
    'or',
    'my',
    'me',
    'do',
    'so',
    'no',
    'go',
    'ich',
    'du',
    'er',
    'und',
    'der',
    'die',
    'das',
    'ein',
    'mit',
    'von',
    'the',
    'and',
    'for',
    'not',
    'are',
    'but',
    'can',
    'has',
    'had',
  };
  final queryWords = query
      .split(RegExp(r'\s+'))
      .where((w) => w.length >= 2 && !noiseWords.contains(w))
      .toList();

  if (queryWords.isEmpty) {
    return 'Error: query too vague. Use keywords like "qr", "restaurant", '
        '"web search", "email", "rechnen"';
  }

  const visualKeywords = {
    'chart',
    'charts',
    'graph',
    'graphs',
    'plot',
    'diagram',
    'visual',
    'visualize',
    'visualization',
    'map',
    'maps',
    'karte',
    'karten',
    'route',
    'routing',
  };
  const chartKeywords = {
    'chart',
    'charts',
    'graph',
    'graphs',
    'plot',
    'diagram',
    'visual',
    'visualize',
    'visualization',
  };
  const mapKeywords = {'map', 'maps', 'karte', 'karten', 'route', 'routing'};

  final hasChartIntent = queryWords.any(chartKeywords.contains);
  final hasMapIntent = queryWords.any(mapKeywords.contains);
  final isVisualOnlyQuery = queryWords.every(visualKeywords.contains);

  if (isVisualOnlyQuery && (hasChartIntent || hasMapIntent)) {
    final recommendedNames = <String>{
      if (hasChartIntent) ...[
        'web_search',
        'web_crawl',
        'stock_data',
        'weather',
      ],
      if (hasMapIntent) ...[
        'search_places',
        'search_restaurants',
        'geocode',
        'get_route',
      ],
    };

    final recommendedTools = recommendedNames
        .map((name) => tools[name])
        .whereType<ClientTool>()
        .where((tool) => isAvailable(tool.name))
        .toList();

    final buf = StringBuffer();
    buf.writeln(
      'Chart/map rendering is built into the UI and is NOT a tool. '
      'Do NOT call find_tools again for chart/map.',
    );
    buf.writeln(
      'Use data tools to gather facts, then emit <chart> or <map> in your '
      'final text response.',
    );
    buf.writeln();

    if (recommendedTools.isNotEmpty) {
      buf.writeln('Recommended data tools for "$query":');
      buf.writeln();
      for (final tool in recommendedTools) {
        _appendToolDefinition(buf, tool, getDescription);
      }
      buf.writeln(
        'You can now call these tools using '
        '<tool_call>{"name": "tool_name", "arguments": {...}}</tool_call>',
      );
      return buf.toString();
    }

    return '${buf.toString().trimRight()}\nNo matching data tools are currently '
        'available.';
  }

  final scored = <MapEntry<ClientTool, int>>[];

  for (final tool in tools.values) {
    if (tool.name == 'find_tools') continue;
    if (!isAvailable(tool.name)) continue;

    int score = 0;
    bool hasExactTagMatch = false;
    final nameLower = tool.name.toLowerCase();
    final effectiveDesc = getDescription(tool.name);
    final descLower = effectiveDesc.toLowerCase();

    for (final word in queryWords) {
      // Exact tag match = 3 points (strongest signal)
      if (tool.tags.any((t) => t.toLowerCase() == word)) {
        score += 3;
        hasExactTagMatch = true;
      }
      // Name contains word = 2 points
      else if (word.length >= 4 && nameLower.contains(word)) {
        score += 2;
      }
      // Partial tag match = 1 point
      else if (word.length >= 4 &&
          tool.tags.any(
            (t) =>
                t.toLowerCase().contains(word) ||
                word.contains(t.toLowerCase()),
          )) {
        score += 1;
      }
      // Description match = 1 point
      else if (word.length >= 5 && descLower.contains(word)) {
        score += 1;
      }
    }

    if (score >= 3 || hasExactTagMatch) {
      scored.add(MapEntry(tool, score));
    }
  }

  if (scored.isEmpty) {
    // Fallback to web_search + web_crawl
    final webSearch = tools['web_search'];
    final webCrawl = tools['web_crawl'];
    final fallbackTools = <ClientTool>[];
    if (webSearch != null && isAvailable(webSearch.name)) {
      fallbackTools.add(webSearch);
    }
    if (webCrawl != null && isAvailable(webCrawl.name)) {
      fallbackTools.add(webCrawl);
    }

    if (fallbackTools.isNotEmpty) {
      final buf = StringBuffer();
      buf.writeln(
        'No exact match for "$query", but these web tools are available:',
      );
      buf.writeln();
      for (final tool in fallbackTools) {
        _appendToolDefinition(buf, tool, getDescription);
      }
      buf.writeln(
        'You can now call these tools using '
        '<tool_call>{"name": "tool_name", "arguments": {...}}</tool_call>',
      );
      return buf.toString();
    }
    return 'No tools matched "$query". Try keywords like "web search", '
        '"restaurant", "email", "rechnen".';
  }

  // Sort by score descending, take top 6
  scored.sort((a, b) => b.value.compareTo(a.value));
  final topTools = scored.take(6).map((e) => e.key).toList();

  // Auto-bundle companion tools
  final topNames = topTools.map((t) => t.name).toSet();
  for (final entry in companions.entries) {
    if (topNames.contains(entry.key)) {
      for (final companionName in entry.value) {
        if (!topNames.contains(companionName)) {
          final companion = tools[companionName];
          if (companion != null && isAvailable(companionName)) {
            topTools.add(companion);
            topNames.add(companionName);
          }
        }
      }
    }
  }

  // Return full tool definitions
  final buf = StringBuffer();
  buf.writeln('Found ${topTools.length} matching tools for "$query":');
  buf.writeln();
  for (final tool in topTools) {
    _appendToolDefinition(buf, tool, getDescription);
  }
  buf.writeln(
    'You can now call these tools using '
    '<tool_call>{"name": "tool_name", "arguments": {...}}</tool_call>',
  );
  return buf.toString();
}
