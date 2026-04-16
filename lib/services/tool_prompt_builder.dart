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
  ///
  /// Identity system (always injected):
  /// - [soulText] — AI personality / tone / boundaries.
  /// - [userInfoText] — Facts about the user.
  /// - [memoryText] — Curated long-term memory (free text).
  ///
  /// [notesToolDef] and [askUserToolDef] are tool definitions that bypass
  /// discovery mode and are always shown in the prompt.
  String buildToolProtocolSection({
    required List<Map<String, dynamic>> tools,
    bool isToolResult = false,
    List<Map<String, dynamic>>? discoveredTools,
    String? soulText,
    String? userInfoText,
    String? memoryText,
    Map<String, dynamic>? notesToolDef,
    Map<String, dynamic>? askUserToolDef,
    Map<String, dynamic>? webSearchToolDef,
    Map<String, dynamic>? webCrawlToolDef,
    Map<String, dynamic>? projectToolDef,
    Map<String, dynamic>? artifactToolDef,
    bool includeMapVisualOutput = true,
    bool includeChartVisualOutput = true,
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

    // Identity system -- always injected (Soul > User > Memory).
    buffer.writeln(_buildIdentitySection(soulText, userInfoText, memoryText));

    // Tool calling protocol
    if (tools.isNotEmpty) {
      buffer.writeln();
      final hasDiscoveredTools =
          discoveredTools != null && discoveredTools.isNotEmpty;

      // Tools that bypass discovery and are always shown.
      final List<Map<String, dynamic>> alwaysAvailableTools = [];
      if (notesToolDef != null) {
        alwaysAvailableTools.add(notesToolDef);
      }
      if (askUserToolDef != null) {
        alwaysAvailableTools.add(askUserToolDef);
      }
      if (webSearchToolDef != null) {
        alwaysAvailableTools.add(webSearchToolDef);
      }
      if (webCrawlToolDef != null) {
        alwaysAvailableTools.add(webCrawlToolDef);
      }
      if (projectToolDef != null) {
        alwaysAvailableTools.add(projectToolDef);
      }
      if (artifactToolDef != null) {
        alwaysAvailableTools.add(artifactToolDef);
      }

      if (discoveryMode && hasDiscoveredTools) {
        final findToolDef = tools
            .where((t) => t['name'] == 'find_tools')
            .toList();
        // Collect names of tools not yet discovered so the AI knows
        // what else is available via find_tools.
        final shownNames = <String>{
          'find_tools',
          ...alwaysAvailableTools.map((t) => t['name']?.toString() ?? ''),
          ...discoveredTools.map((t) => t['name']?.toString() ?? ''),
        };
        final undiscoveredNames = tools
            .map((t) => t['name']?.toString() ?? '')
            .where((n) => n.isNotEmpty && !shownNames.contains(n))
            .toList();
        buffer.writeln(
          _buildToolProtocol(
            [...findToolDef, ...alwaysAvailableTools, ...discoveredTools],
            undiscoveredToolNames: undiscoveredNames,
            includeMapVisualOutput: includeMapVisualOutput,
            includeChartVisualOutput: includeChartVisualOutput,
          ),
        );
      } else if (discoveryMode) {
        // Extract all tool names so the AI sees what's available.
        // Order: commonly used tools first for better AI discoverability.
        const toolDisplayOrder = <String>[
          // Core tools the AI should find immediately
          'web_search',
          'web_crawl',
          'generate_image',
          'generate_image_hunyuan',
          'generate_image_flux',
          'edit_image',
          'fetch_image',
          'view_chat_images',
          'search_chats',
          'notes',
          'ask_user',
          // Utilities
          'calculate',
          'get_time',
          'generate_qr',
          'random_number',
          'flip_coin',
          'roll_dice',
          'countdown',
          'password_generator',
          'uuid_generator',
          // Location & maps
          'search_places',
          'search_restaurants',
          'geocode',
          'get_route',
          // Integrations
          'spotify_control',
          'whoop',
          'device',
          'calendar',
          'reminder',
          'weather',
          // Workspace
          'update_project',
          'artifact_manager',
          // Finance
          'crypto_data',
          // System
          'bash',
        ];
        final allToolNames =
            tools
                .map((t) => t['name']?.toString() ?? '')
                .where((n) => n.isNotEmpty && n != 'find_tools')
                .toList()
              ..sort((a, b) {
                final ai = toolDisplayOrder.indexOf(a);
                final bi = toolDisplayOrder.indexOf(b);
                final aPrio = ai >= 0 ? ai : 999;
                final bPrio = bi >= 0 ? bi : 999;
                return aPrio.compareTo(bPrio);
              });
        buffer.writeln(
          _buildDiscoveryPrompt(
            alwaysAvailableTools,
            allToolNames: allToolNames,
            includeMapVisualOutput: includeMapVisualOutput,
            includeChartVisualOutput: includeChartVisualOutput,
          ),
        );
      } else {
        buffer.writeln(
          _buildToolProtocol(
            tools,
            includeMapVisualOutput: includeMapVisualOutput,
            includeChartVisualOutput: includeChartVisualOutput,
          ),
        );
      }
    }

    return buffer.toString();
  }

  /// Build the full identity section: Soul, User, Memory.
  ///
  /// You have full read/write access to all three via the **notes** tool.
  /// These are re-read every message cycle so updates take effect immediately.
  String _buildIdentitySection(
    String? soulText,
    String? userInfoText,
    String? memoryText,
  ) {
    final buffer = StringBuffer();

    // ── Preamble: identity rules ──
    buffer.writeln();
    buffer.writeln('## IDENTITY SYSTEM');
    buffer.writeln();
    buffer.writeln(
      'You have three persistent stores that survive across conversations. '
      'They are re-read every message. You can update all three via the '
      '**notes** tool which is always available (no discovery needed).',
    );
    buffer.writeln();
    buffer.writeln('### CRITICAL — WHEN TO UPDATE');
    buffer.writeln();
    buffer.writeln(
      'After EVERY user message, check: did I learn something new about '
      'this person that is NOT already in User or Memory? If yes, call '
      'the notes tool IN THE SAME RESPONSE as your reply. Do NOT wait '
      'for a follow-up. Do NOT ask permission. Just update and respond.',
    );
    buffer.writeln();
    buffer.writeln('Triggers that MUST cause an update:');
    buffer.writeln(
      '- User reveals their name, language, location, job, timezone, '
      'or any personal detail → update User.',
    );
    buffer.writeln(
      '- User states a preference ("I prefer...", "always do X", '
      '"never do Y", "speak German") → update User or Memory.',
    );
    buffer.writeln(
      '- User mentions a workspace, tool, framework, or ongoing topic '
      'worth remembering → update Memory.',
    );
    buffer.writeln(
      '- Information in User or Memory is now outdated or contradicted '
      '→ update with the corrected version.',
    );
    buffer.writeln();
    buffer.writeln('### Update rules');
    buffer.writeln();
    buffer.writeln(
      '- **Soul** (action: update_soul): You CAN update it but you MUST '
      'tell the user what you changed and why. It is your personality — '
      'treat changes with care.',
    );
    buffer.writeln(
      '- **User** (action: update_user): Update the FULL text. Include '
      'all existing facts plus the new ones. Do not lose old info.',
    );
    buffer.writeln(
      '- **Memory** (action: update_memory): Update the FULL text. Keep '
      'it curated — distilled knowledge, not raw logs.',
    );

    // ── Soul (personality / tone / boundaries) ──
    buffer.writeln();
    buffer.writeln('## SOUL');
    buffer.writeln();
    final soul = soulText?.trim() ?? '';
    if (soul.isEmpty) {
      buffer.writeln('_(No soul defined yet.)_');
    } else {
      buffer.writeln(soul);
    }

    // ── User (facts about the human) ──
    buffer.writeln();
    buffer.writeln('## USER');
    buffer.writeln();
    final user = userInfoText?.trim() ?? '';
    if (user.isEmpty) {
      buffer.writeln('_(No user info saved yet.)_');
    } else {
      buffer.writeln(user);
    }

    // ── Memory (long-term knowledge, free text) ──
    buffer.writeln();
    buffer.writeln('## MEMORY');
    buffer.writeln();
    final memory = memoryText?.trim() ?? '';
    if (memory.isEmpty) {
      buffer.writeln('_(No memories saved yet.)_');
    } else {
      buffer.writeln(memory);
    }

    return buffer.toString();
  }

  /// Discovery prompt: shows ALL tool names but requires find_tools
  /// to get full descriptions before use.
  ///
  /// [alwaysAvailableTools] are tool definitions that bypass discovery
  /// (e.g. notes) and are always shown with full details.
  /// [allToolNames] is the list of all registered tool names (excluding
  /// find_tools) so the AI knows the full catalog.
  String _buildDiscoveryPrompt(
    List<Map<String, dynamic>> alwaysAvailableTools, {
    List<String> allToolNames = const [],
    required bool includeMapVisualOutput,
    required bool includeChartVisualOutput,
  }) {
    // Build the tool name catalog.
    final alwaysAvailableNames = alwaysAvailableTools
        .map((t) => t['name']?.toString() ?? '')
        .where((n) => n.isNotEmpty)
        .toSet();
    final discoverableNames = allToolNames
        .where((n) => !alwaysAvailableNames.contains(n))
        .toList();
    final hasWebSearch = alwaysAvailableNames.contains('web_search');
    final hasWebCrawl = alwaysAvailableNames.contains('web_crawl');
    final webToolNames = [
      if (hasWebSearch) '`web_search`',
      if (hasWebCrawl) '`web_crawl`',
    ];
    final webToolsException = webToolNames.isEmpty
        ? ''
        : 'Exception: ${webToolNames.join(' and ')} '
              '${webToolNames.length == 1 ? 'is' : 'are'} always available '
              'with full details below and can be used directly.\n';

    final catalogSection = discoverableNames.isNotEmpty
        ? '''

## AVAILABLE TOOLS

The following tools exist. You can see their names but you do NOT know what they do yet.
**Before using ANY of these tools, you MUST call find_tools first** to get the full description and parameters.

${discoverableNames.map((n) => '- $n').join('\n')}

'''
        : '';

    return '''
ALWAYS respond in the user's language.

IMPORTANT: Never mention tool names, tool internals, or technical details to the user.

CRITICAL -- OUTDATED KNOWLEDGE: Your training data is OLD and INCOMPLETE.
RULE: For ANY question involving real-world facts, products, people, events, or current information -> SEARCH THE WEB FIRST.

USER-CLAIMED RECENCY IS A HARD TRIGGER: If the user says something is "new", "just released", "brand new", "from today", "from yesterday", or otherwise recent — you MUST web_search + web_crawl before answering, even if you "know" the topic from training data. Your training knowledge is ALWAYS stale against these claims. Never contradict a recency claim from memory alone. If the claimed thing does not exist, the search will prove that — but you still must search.
$catalogSection
## TOOL DISCOVERY

You can see the tool names above but you do NOT have their descriptions or parameters yet.
**You MUST call find_tools to get the full description of a tool before you can use it.**
Do NOT guess what a tool does or what parameters it takes based on the name alone.
$webToolsException

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

FRESH RELEASES: Search engines take hours/days to index new content. When the user claims something was JUST released (today, hours ago), do NOT rely only on web_search. Use web_crawl to directly check primary sources:
- HuggingFace org pages (e.g. https://huggingface.co/MiniMaxAI, https://huggingface.co/Qwen)
- GitHub org pages and release pages
- Official blogs and announcement pages
If search results contradict the user's claim about a very recent release, crawl the source directly before concluding it doesn't exist.

After find_tools returns the tool descriptions and parameters, you can use those discovered tools. If no tool is needed, just answer directly.
DO NOT STALL: Never end with intention-only text like "I will search". Either emit the next tool_call, or provide a complete final answer.

VISUAL OUTPUT NOTE:
- <chart>, <map>, and <email> are OUTPUT TAGS, not tools. Write them directly in your response.
- Never call find_tools for "chart", "graph", "plot", "map", or "email".
- If user asks for a chart/map, discover DATA tools first, then emit <chart>/<map> directly in your final response text.
- To draft an email, emit <email>{"to":"...","subject":"...","body":"..."}</email> in your response. The app renders it as a card with an "Open in Mail App" button.
- For "technische Zeichnung" / "technical drawing" / "engineering drawing" / DIN-style blueprints: use artifact_manager with type="technical_drawing" and JSON content. This is a RENDERED drawing with dimensions, NOT an AI-generated image. Do NOT use generate_image for technical drawings.

VISUAL OUTPUT SWITCHES (current):
- chart tags: ${includeChartVisualOutput ? 'enabled' : 'disabled'}
- map tags: ${includeMapVisualOutput ? 'enabled' : 'disabled'}
- email tags: enabled

STOP after $toolCallEnd -- wait for real results. Never fabricate outputs.
${_buildAlwaysAvailableSection(alwaysAvailableTools)}
${alwaysAvailableNames.contains('artifact_manager') ? _artifactToolProtocol() : ''}
${_visualOutputProtocol(includeMaps: includeMapVisualOutput, includeCharts: includeChartVisualOutput)}''';
  }

  /// Renders tool definitions that are always available (bypass discovery).
  String _buildAlwaysAvailableSection(List<Map<String, dynamic>> tools) {
    if (tools.isEmpty) return '';
    final buffer = StringBuffer();
    buffer.writeln();
    buffer.writeln(
      'The following tools are ALWAYS available -- you can call them '
      'directly without find_tools:',
    );
    for (final tool in tools) {
      final name = tool['name']?.toString() ?? '';
      if (name.isEmpty) continue;
      final desc = tool['description']?.toString() ?? '';
      buffer.writeln('  $name: $desc');
      final rawParams = tool['parameters'];
      final params = rawParams is Map<String, dynamic>
          ? rawParams
          : rawParams is Map
          ? Map<String, dynamic>.from(rawParams)
          : null;
      if (params != null && params.isNotEmpty) {
        final propsRaw = params['properties'] ?? params;
        final props = propsRaw is Map<String, dynamic>
            ? propsRaw
            : propsRaw is Map
            ? Map<String, dynamic>.from(propsRaw)
            : const <String, dynamic>{};
        for (final entry in props.entries) {
          if (entry.value is Map) {
            final ptype = (entry.value as Map)['type'] ?? 'string';
            final pdesc = (entry.value as Map)['description'] ?? '';
            buffer.writeln('    - ${entry.key} ($ptype): $pdesc');
          } else {
            buffer.writeln('    - ${entry.key}: ${entry.value}');
          }
        }
      }
    }
    return buffer.toString();
  }

  /// Full tool protocol -- shown AFTER find_tools returns tool definitions.
  ///
  /// [undiscoveredToolNames] lists tools the AI hasn't discovered yet
  /// (names only) so it knows what else is available via find_tools.
  String _buildToolProtocol(
    List<Map<String, dynamic>> tools, {
    List<String> undiscoveredToolNames = const [],
    required bool includeMapVisualOutput,
    required bool includeChartVisualOutput,
  }) {
    final hasArtifactTool = tools.any(
      (tool) => (tool['name']?.toString() ?? '') == 'artifact_manager',
    );
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

    // Show undiscovered tool names if any.
    final undiscoveredSection = undiscoveredToolNames.isNotEmpty
        ? '''

### Other available tools (call find_tools to get details):
${undiscoveredToolNames.map((n) => '- $n').join('\n')}
'''
        : '';

    return '''
ALWAYS respond in the user's language. Never mix languages.

IMPORTANT: Never mention tool names, tool internals, or technical details to the user.

CRITICAL -- OUTDATED KNOWLEDGE: Your training data is OLD and INCOMPLETE.
RULE: For ANY question involving real-world facts, products, people, events, or current information -> SEARCH THE WEB FIRST.

USER-CLAIMED RECENCY IS A HARD TRIGGER: If the user says something is "new", "just released", "brand new", "from today", "from yesterday", or otherwise recent — you MUST web_search + web_crawl before answering, even if you "know" the topic from training data. Your training knowledge is ALWAYS stale against these claims. Never contradict a recency claim from memory alone. If the claimed thing does not exist, the search will prove that — but you still must search.

FRESH RELEASES: Search engines take hours/days to index new content. When the user claims something was JUST released (today, hours ago), do NOT rely only on web_search. Use web_crawl to directly check primary sources:
- HuggingFace org pages (e.g. https://huggingface.co/MiniMaxAI, https://huggingface.co/Qwen)
- GitHub org pages and release pages
- Official blogs and announcement pages
If search results contradict the user's claim about a very recent release, crawl the source directly before concluding it doesn't exist.

## TOOLS

$toolsText
$undiscoveredSection
### How to call:
$toolCallStart
{"name": "tool_name", "arguments": {"param1": "value1"}}
$toolCallEnd

Multiple tools in one response: use multiple $toolCallStart...$toolCallEnd blocks.

FORMAT: Emit raw $toolCallStart...$toolCallEnd tags only. Do NOT wrap tool calls in Markdown code fences.

### Rules:
1. You can only call tools whose full description is shown above. To use a tool from "Other available tools", call find_tools first to get its description.
2. STOP after your last $toolCallEnd. Wait for real results -- never fabricate outputs.
3. Never use OpenAI-style function_call -- only $toolCallStart...$toolCallEnd XML tags.
4. NEVER invent factual data (phone numbers, addresses, URLs, prices, ratings). Only include what tools returned.
5. web_search includes search snippets and auto-fetched context from top pages. Use web_crawl for deeper extraction of a specific URL.
6. Never stop with intention-only text (e.g. "I will now search"). Do the next tool_call or provide the final answer.
7. COST & PRIVACY: Before calling generate_image, generate_image_hunyuan, generate_image_flux, or edit_image, ALWAYS briefly inform the user that (a) it costs credits and (b) generated/edited images are NOT end-to-end encrypted and can be seen by the service operator. Then proceed with the tool call in the same response — do not wait for confirmation unless the user previously expressed privacy concerns. After the image is generated, do NOT show the URL, dimensions, seed, model, or other technical metadata — the image is displayed inline automatically by the app. Use generate_image (fast, ~0.01 EUR) by default; use generate_image_hunyuan (high quality, ~0.08 EUR) or generate_image_flux (best quality, ~0.02 EUR) when the user requests higher quality or a specific model.
8. If the needed tool is already listed above with its full description, call it directly. Do NOT call find_tools again unless you need a tool from "Other available tools".

### Research depth:
Do NOT give shallow one-search answers. For any factual question:
1) web_search -> find sources
2) web_crawl on 1-3 best results -> get full details and context
3) If gaps remain, do another web_search from a different angle
4) Compile final answer from crawled content, not just search snippets

${hasArtifactTool ? _artifactToolProtocol() : ''}

${_visualOutputProtocol(includeMaps: includeMapVisualOutput, includeCharts: includeChartVisualOutput)}''';
  }

  String _artifactToolProtocol() {
    return '''
## ARTIFACTS

Use artifact_manager for substantial outputs such as:
- code blocks longer than about 15 lines
- full markdown documents/specs
- HTML apps/pages
- Mermaid diagrams
- SVG content
- technical drawings (type: technical_drawing)

Do NOT use artifacts for short snippets or quick conversational replies.

Artifact rules:
1. Prefer action="update" over action="rewrite" for targeted changes.
2. In update edits, each old_str MUST match exactly once in current content.
3. Keep update edits small (max ~5 edits). If many structural changes are needed, use rewrite.
4. Create at most ONE artifact per assistant response.
5. Reuse the same artifact_id across follow-up edits so version history stays intact.
6. When recreating an artifact in a different format (e.g. SVG → technical_drawing), use action="rewrite" with the SAME artifact_id and set the new type. Do NOT create a new artifact_id — this keeps version history.

### Inline <artifact> tag (alternative to artifact_manager)

As a shorthand, you may also emit the artifact directly in your message text using this tag shape:

    <artifact id="my-id" type="technical_drawing" title="Optional Title">
    {...content JSON or code...}
    </artifact>

The UI parses these tags on message finalization and routes them through the same storage path as artifact_manager — so versioning still works:
- If the id is new → creates a fresh artifact (equivalent to action="create").
- If the id already exists → bumps the version (equivalent to action="rewrite").

Use the tag form when you want to produce an artifact as part of a normal answer. For targeted text edits (small old_str → new_str swaps) you still MUST use artifact_manager with action="update" — inline tags only support create/rewrite.

### Technical Drawings (type: technical_drawing)

For engineering/mechanical drawings, use type="technical_drawing". Content is JSON:

```json
{
  "type": "technical_drawing",
  "meta": {
    "title": "Flachplatte",
    "partNo": "FP-001",
    "material": "S235JR",
    "scale": "1:1",
    "unit": "mm",
    "tolerance": "ISO 2768-m",
    "author": "Claude",
    "date": "12.04.2026",
    "sheet": "1/1"
  },
  "elements": [
    {"type":"rect","lineStyle":"solid","weight":"thick","x":50,"y":30,"w":120,"h":80},
    {"type":"circle","lineStyle":"solid","weight":"thick","cx":110,"cy":70,"r":15},
    {"type":"line","lineStyle":"centerline","weight":"thin","x1":85,"y1":70,"x2":135,"y2":70},
    {"type":"dimension","subtype":"linear_h","x1":50,"x2":170,"y":110,"offset":14,"value":"120"},
    {"type":"dimension","subtype":"linear_v","y1":30,"y2":110,"x":50,"offset":-14,"value":"80"},
    {"type":"dimension","subtype":"diameter","cx":110,"cy":70,"r":15,"angle":45,"value":"\\u00d8 30"},
    {"type":"note","x":50,"y":22,"text":"t = 10"}
  ]
}
```

Drawing rules:
- Coordinates in mm, origin top-left, Y-axis down
- lineStyle: "solid" (visible edges), "dashed" (hidden edges), "centerline" (axes)
- weight: "thick" (body edges ~0.7mm), "thin" (dimensions/helpers ~0.25mm)
- Element types: rect (x,y,w,h), circle (cx,cy,r), line (x1,y1,x2,y2)
- Dimension subtypes: linear_h (horizontal), linear_v (vertical), diameter
- For linear_h: x1,x2 = endpoints, y = part edge Y, offset = distance to dim line (+ = down, - = up)
- For linear_v: y1,y2 = endpoints, x = part edge X, offset = distance to dim line (+ = right, - = left)
- For diameter: cx,cy,r from circle, angle = leader line angle in degrees, value includes \\u00d8 prefix
- note: freeform text annotation at position
- meta fields populate DIN title block (Schriftfeld)
- Always dimension all significant features
- Use centerlines through circles and symmetry axes
''';
  }

  /// Chart and map rendering protocol — these are output formats, not tools.
  String _visualOutputProtocol({
    required bool includeMaps,
    required bool includeCharts,
  }) {
    if (!includeMaps && !includeCharts) {
      return '''
## VISUAL OUTPUT

Charts and maps are disabled for this session. Do NOT emit <chart> or <map> tags.''';
    }

    final buffer = StringBuffer();
    buffer.writeln('## VISUAL OUTPUT');
    buffer.writeln();

    if (includeMaps && includeCharts) {
      buffer.writeln(
        'You can embed charts and maps directly in your responses. These are NOT tools — just write the JSON inside the tags.',
      );
    } else if (includeCharts) {
      buffer.writeln(
        'You can embed charts directly in your responses. These are NOT tools — just write JSON inside <chart> tags.',
      );
      buffer.writeln(
        'Maps are disabled for this session. Do NOT emit <map> tags.',
      );
    } else {
      buffer.writeln(
        'You can embed interactive maps directly in your responses. These are NOT tools — just write JSON inside <map> tags.',
      );
      buffer.writeln(
        'Charts are disabled for this session. Do NOT emit <chart> tags.',
      );
    }

    if (includeCharts) {
      buffer.writeln();
      buffer.writeln('### Charts');
      buffer.writeln('<chart>');
      buffer.writeln(
        '{"type":"line","title":"Revenue Growth","labels":["Q1 2024","Q2 2024","Q3 2024","Q4 2024"],"datasets":[{"label":"2024","data":[120,180,250,310],"color":"#4CAF50"},{"label":"2023","data":[90,110,140,190],"color":"#2196F3"}],"height":350}',
      );
      buffer.writeln('</chart>');
      buffer.writeln();
      buffer.writeln('**Chart types:** bar, line, pie, scatter, radar');
      buffer.writeln();
      buffer.writeln('**Chart fields:**');
      buffer.writeln('- "type": bar | line | pie | scatter | radar (required)');
      buffer.writeln('- "title": chart title (required)');
      buffer.writeln(
        '- "labels": x-axis labels, e.g. ["Jan 2025","Feb 2025","Mar 2025"] (required for bar/line/radar)',
      );
      buffer.writeln(
        '- "datasets": array of data series (required for bar/line/radar/scatter)',
      );
      buffer.writeln('  - "label": series name');
      buffer.writeln(
        '  - "data": array of numbers (or x/y objects for scatter)',
      );
      buffer.writeln('  - "color": hex color like "#FF5722"');
      buffer.writeln(
        '- "data": for pie charts, array of {"label":"...","value":N,"color":"#..."} objects',
      );
      buffer.writeln(
        '- "height": chart height in pixels (default 250, use 350-500 for detailed charts)',
      );
      buffer.writeln('- "max_y" / "min_y": fix y-axis range');
      buffer.writeln('- "max_x" / "min_x": fix x-axis range (scatter only)');
    }

    if (includeMaps) {
      buffer.writeln();
      buffer.writeln('### Maps');
      buffer.writeln('Type "markers" (simple pins):');
      buffer.writeln('<map>');
      buffer.writeln(
        '{"type":"markers","title":"Cities","markers":[{"lat":54.32,"lon":10.13,"label":"Kiel"}]}',
      );
      buffer.writeln('</map>');
      buffer.writeln();
      buffer.writeln('Type "places" (rich cards with details):');
      buffer.writeln('<map>');
      buffer.writeln(
        '{"type":"places","title":"Restaurants","places":[{"name":"Example","lat":54.3,"lon":10.1,"cuisine":"Italian","opening_hours":"Mo-Fr 12-22","address":"Str. 82"}]}',
      );
      buffer.writeln('</map>');
      buffer.writeln();
      buffer.writeln('Type "route" (navigation with polyline):');
      buffer.writeln('<map>');
      buffer.writeln(
        '{"type":"route","from":{"lat":54.32,"lon":10.13,"label":"Kiel"},"to":{"lat":53.55,"lon":9.99,"label":"Hamburg"},"distance_km":"96.5","duration_min":"58"}',
      );
      buffer.writeln('</map>');
    }

    // Email drafts — always available
    buffer.writeln();
    buffer.writeln('### Emails');
    buffer.writeln(
      'To draft an email, emit an <email> tag with JSON. The app renders it as a card with an "Open in Mail App" button. Nothing is sent automatically.',
    );
    buffer.writeln('<email>');
    buffer.writeln(
      '{"to":"recipient@example.com","subject":"Meeting Tomorrow","body":"Hi,\\n\\nJust confirming our meeting tomorrow at 2pm.\\n\\nBest regards"}',
    );
    buffer.writeln('</email>');
    buffer.writeln();
    buffer.writeln('**Email fields:**');
    buffer.writeln('- "to": recipient email address (required)');
    buffer.writeln('- "subject": email subject line (optional)');
    buffer.writeln(
      '- "body": email body text, use \\n for newlines (optional)',
    );
    buffer.writeln('- "cc": CC addresses, comma-separated (optional)');
    buffer.writeln('- "bcc": BCC addresses, comma-separated (optional)');

    buffer.writeln();
    buffer.writeln('### Visual output rules:');
    var ruleNumber = 1;
    final tagLabel = includeMaps && includeCharts
        ? '<map>/<chart>'
        : includeCharts
        ? '<chart>'
        : '<map>';
    buffer.writeln(
      '${ruleNumber++}. $tagLabel tags go OUTSIDE tool_call tags — they are part of your text response.',
    );
    buffer.writeln(
      '${ruleNumber++}. Never call find_tools for chart/map rendering. They are output tags, not tools.',
    );
    buffer.writeln(
      '${ruleNumber++}. Write your FULL text answer FIRST, then $tagLabel at the very END.',
    );
    if (includeMaps && includeCharts) {
      buffer.writeln(
        '${ruleNumber++}. STOP after the closing </map> or </chart> tag. Do not write text after it.',
      );
      buffer.writeln(
        '${ruleNumber++}. In <map> and <chart> JSON: only include fields from tool results. Do NOT fabricate data.',
      );
    } else if (includeCharts) {
      buffer.writeln(
        '${ruleNumber++}. STOP after the closing </chart> tag. Do not write text after it.',
      );
      buffer.writeln(
        '${ruleNumber++}. In <chart> JSON: only include fields from tool results. Do NOT fabricate data.',
      );
    } else {
      buffer.writeln(
        '${ruleNumber++}. STOP after the closing </map> tag. Do not write text after it.',
      );
      buffer.writeln(
        '${ruleNumber++}. In <map> JSON: only include fields from tool results. Do NOT fabricate data.',
      );
    }

    if (includeMaps) {
      buffer.writeln(
        '${ruleNumber++}. ALWAYS include a <map> after location/restaurant/route tool results that contain coordinates.',
      );
      buffer.writeln(
        '${ruleNumber++}. For places maps: include all fields the tool returned (name, lat, lon, cuisine, address, phone, website, opening_hours, rating, review_count, price_range). Omit fields marked "NOT AVAILABLE".',
      );
      buffer.writeln(
        '${ruleNumber++}. For any markers/places map, coordinates MUST come from map API tool output in this conversation (`search_places`, `search_restaurants`, or `geocode`). Never guess or approximate lat/lon.',
      );
      buffer.writeln(
        '${ruleNumber++}. Prefer `{"type":"places"...}` for destination lists; the app can compute routing after the user taps a place.',
      );
    }

    if (includeCharts) {
      buffer.writeln(
        '${ruleNumber++}. For stock/financial time series, include full history points in <chart> output; do not downsample data.',
      );
      if (includeMaps) {
        buffer.writeln(
          '${ruleNumber++}. Never use scatter for geographic data — use <map>.',
        );
      }
    }

    return buffer.toString();
  }
}
