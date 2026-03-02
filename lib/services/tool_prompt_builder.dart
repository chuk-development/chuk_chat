/// Builds system prompts with tool calling protocol for LLM.
///
/// This is used by the tool call handler to inject tool definitions
/// and the XML tool calling protocol into the system prompt.
class ToolPromptBuilder {
  static const String toolCallStart = '<tool_call>';
  static const String toolCallEnd = '</tool_call>';

  /// Whether to use tool discovery mode (compact catalog + find_tools).
  bool discoveryMode;

  ToolPromptBuilder({this.discoveryMode = true});

  /// Build the tool protocol section to append to the existing system prompt.
  ///
  /// Returns the tool protocol text that should be appended to whatever
  /// system prompt the app already uses.
  String buildToolProtocolSection({
    required List<Map<String, dynamic>> tools,
    bool isToolResult = false,
    List<Map<String, dynamic>>? discoveredTools,
  }) {
    final buffer = StringBuffer();

    // Current date
    final now = DateTime.now();
    const months = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    const weekdays = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    buffer.writeln();
    buffer.writeln(
      'Today is ${weekdays[now.weekday - 1]}, '
      '${months[now.month - 1]} ${now.day}, ${now.year}.',
    );

    // Tool calling protocol
    if (tools.isNotEmpty) {
      buffer.writeln();
      if (discoveryMode && !isToolResult) {
        buffer.writeln(_buildDiscoveryPrompt());
      } else if (discoveryMode &&
          isToolResult &&
          discoveredTools != null &&
          discoveredTools.isNotEmpty) {
        final findToolDef = tools
            .where((t) => t['name'] == 'find_tools')
            .toList();
        buffer.writeln(
          _buildToolProtocol([...findToolDef, ...discoveredTools]),
        );
      } else {
        buffer.writeln(_buildToolProtocol(tools));
      }
    }

    return buffer.toString();
  }

  /// Discovery prompt: MINIMAL -- only find_tools explanation.
  String _buildDiscoveryPrompt() {
    return '''
ALWAYS respond in the user's language.

IMPORTANT: Never mention tool names, tool internals, or technical details to the user.

CRITICAL -- OUTDATED KNOWLEDGE: Your training data is OLD and INCOMPLETE.
RULE: For ANY question involving real-world facts, products, people, events, or current information -> SEARCH THE WEB FIRST.

You have tools available but don't know their names yet. Call **find_tools** first to discover them.

$toolCallStart
{"name": "find_tools", "arguments": {"query": "restaurant"}}
$toolCallEnd

$toolCallStart
{"name": "find_tools", "arguments": {"query": "web search"}}
$toolCallEnd

The query must be 1-3 SHORT keywords for the TYPE of tool (e.g. "restaurant", "web search", "email", "rechnen", "route karte"). Never paste the user's full message.

FORMAT: Emit raw $toolCallStart...$toolCallEnd tags only. Do NOT wrap tool calls in Markdown code fences.

RESEARCH DEPTH: Do NOT answer from a single source. A good answer requires multiple steps:
1) Discover relevant tools with find_tools
2) Use a search-style tool to find relevant sources
3) Use a page-reading/crawl-style tool on 1-3 of the best results
4) If coverage is still incomplete, run another discovery/search pass from a different angle
5) Only then compile your final answer from real tool outputs

After find_tools returns, you can use the discovered tools. If no tool is needed, just answer directly.
DO NOT STALL: Never end with intention-only text like "I will search". Either emit the next tool_call, or provide a complete final answer.

STOP after $toolCallEnd -- wait for real results. Never fabricate outputs.''';
  }

  /// Full tool protocol -- shown AFTER find_tools returns tool definitions.
  String _buildToolProtocol(List<Map<String, dynamic>> tools) {
    final toolDocs = <String>[];

    for (final tool in tools) {
      final nameValue = tool['name'];
      final name = nameValue is String ? nameValue.trim() : '';
      if (name.isEmpty) {
        continue;
      }

      final desc = tool['description']?.toString() ?? 'No description';
      final rawParams = tool['parameters'];
      final params = rawParams is Map<String, dynamic>
          ? rawParams
          : rawParams is Map
          ? Map<String, dynamic>.from(rawParams)
          : null;

      var paramStr = '';
      if (params != null && params.isNotEmpty) {
        final propsRaw = params['properties'] ?? params;
        final props = propsRaw is Map<String, dynamic>
            ? propsRaw
            : propsRaw is Map
            ? Map<String, dynamic>.from(propsRaw)
            : const <String, dynamic>{};
        final paramParts = <String>[];
        for (final entry in props.entries) {
          if (entry.value is Map) {
            final ptype = (entry.value as Map)['type'] ?? 'string';
            final pdesc = (entry.value as Map)['description'] ?? '';
            paramParts.add('    - ${entry.key} ($ptype): $pdesc');
          } else {
            paramParts.add('    - ${entry.key}: ${entry.value}');
          }
        }
        if (paramParts.isNotEmpty) {
          paramStr = '\n${paramParts.join('\n')}';
        }
      }

      toolDocs.add('  $name: $desc$paramStr');
    }

    final toolsText = toolDocs.join('\n');

    return '''
ALWAYS respond in the user's language. Never mix languages.

IMPORTANT: Never mention tool names, tool internals, or technical details to the user.

## TOOLS

$toolsText

### How to call:
$toolCallStart
{"name": "tool_name", "arguments": {"param1": "value1"}}
$toolCallEnd

Multiple tools in one response: use multiple $toolCallStart...$toolCallEnd blocks.

FORMAT: Emit raw $toolCallStart...$toolCallEnd tags only. Do NOT wrap tool calls in Markdown code fences.

### Rules:
1. ONLY the tools listed above exist. Unknown names are rejected.
2. STOP after your last $toolCallEnd. Wait for real results -- never fabricate outputs.
3. Never use OpenAI-style function_call -- only $toolCallStart...$toolCallEnd XML tags.
4. NEVER invent factual data (phone numbers, addresses, URLs, prices, ratings). Only include what tools returned.
5. web_search gives snippets/previews only. For exact details, verify with web_crawl.
6. Never stop with intention-only text (e.g. "I will now search"). Do the next tool_call or provide the final answer.
7. COST & PRIVACY: Before calling generate_image or edit_image, ALWAYS briefly inform the user that (a) it costs credits and (b) generated/edited images are NOT end-to-end encrypted and can be seen by the service operator. Then proceed with the tool call in the same response — do not wait for confirmation unless the user previously expressed privacy concerns.

### Research depth:
Do NOT give shallow one-search answers. For any factual question:
1) web_search -> find sources
2) web_crawl on 1-3 best results -> get full details and context
3) If gaps remain, do another web_search from a different angle
4) Compile final answer from crawled content, not just search snippets

${_mapProtocol()}''';
  }

  /// Map rendering protocol — tells the AI it can embed interactive maps
  /// in its responses using <map> XML tags. These are NOT tools — the AI
  /// writes JSON inside <map> tags as part of its text response.
  String _mapProtocol() {
    return '''
## VISUAL OUTPUT: Maps

You can embed interactive maps directly in your responses. These are NOT tools — just write JSON inside <map> tags as part of your text.

### Map types:

Type "markers" (simple pins):
<map>
{"type":"markers","title":"Cities","markers":[{"lat":54.32,"lon":10.13,"label":"Kiel"}]}
</map>

Type "places" (rich cards with details):
<map>
{"type":"places","title":"Restaurants","places":[{"name":"Example","lat":54.3,"lon":10.1,"cuisine":"Italian","opening_hours":"Mo-Fr 12-22","address":"Str. 82"}]}
</map>

Type "route" (navigation with polyline):
<map>
{"type":"route","from":{"lat":54.32,"lon":10.13,"label":"Kiel"},"to":{"lat":53.55,"lon":9.99,"label":"Hamburg"},"distance_km":"96.5","duration_min":"58"}
</map>

### Map rules:
1. <map> tags go OUTSIDE tool_call tags — they are part of your text response.
2. ALWAYS include a <map> after location/restaurant/route tool results that contain coordinates.
3. Write your FULL text answer FIRST, then the <map> at the very END.
4. STOP after the closing </map> tag. Do not write text after it.
5. In <map> JSON: only include fields from tool results. Do NOT fabricate data.
6. For places maps: include all fields the tool returned (name, lat, lon, cuisine, address, phone, website, opening_hours, rating, review_count, price_range). Omit fields marked "NOT AVAILABLE".''';
  }
}
