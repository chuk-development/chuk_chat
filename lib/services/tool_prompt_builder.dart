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
    Map<String, dynamic>? searchChatsToolDef,
    Map<String, dynamic>? projectToolDef,
    Map<String, dynamic>? artifactToolDef,
    Map<String, dynamic>? artifactSchemaToolDef,
    List<Map<String, dynamic>> extraAlwaysAvailableTools = const [],
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
      List<Map<String, dynamic>> alwaysAvailableTools = [];
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
      if (searchChatsToolDef != null) {
        alwaysAvailableTools.add(searchChatsToolDef);
      }
      if (projectToolDef != null) {
        alwaysAvailableTools.add(projectToolDef);
      }
      if (artifactToolDef != null) {
        alwaysAvailableTools.add(artifactToolDef);
      }
      if (artifactSchemaToolDef != null) {
        alwaysAvailableTools.add(artifactSchemaToolDef);
      }
      if (extraAlwaysAvailableTools.isNotEmpty) {
        alwaysAvailableTools.addAll(extraAlwaysAvailableTools);
      }
      alwaysAvailableTools = _dedupeToolsByName(alwaysAvailableTools);

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

    // After tool results come back the model is prompted again to continue.
    // Without guidance it re-runs the full discovery protocol and narrates the
    // plan a second time ("I'll generate…" → tool runs → "Done, shown above"),
    // which reads to the user as several separate answers for one request.
    // Steer the continuation pass toward a single, final reply. (Previously the
    // `isToolResult` flag was threaded all the way here but never used.)
    if (isToolResult && tools.isNotEmpty) {
      buffer.writeln();
      buffer.writeln(
        'CONTINUATION — you already have the tool results above:\n'
        '- The tool output (images, data, etc.) is ALREADY shown to the user. '
        'Do NOT restate it, repeat URLs / IDs / dimensions / metadata, or '
        'describe what a tool returned.\n'
        '- Do NOT re-announce your plan or narrate what you are "about to" do '
        '(no "I\'ll generate…", "Let me…", "Now I will…") — that step is done.\n'
        '- If the results fully satisfy the request, reply ONCE with a short '
        'final answer. Only call another tool if genuinely more work remains.',
      );
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
    buffer.writeln('### HARD RULE — TOOL NAME');
    buffer.writeln();
    buffer.writeln(
      'The ONLY way to update memory, user info, or soul is the `notes` '
      'tool with action="update_memory", "update_user", or "update_soul". '
      'There is NO `update_memory` tool, NO `update_user` tool, and NO '
      '`update_soul` tool — calling those names directly WILL BE REJECTED '
      'with "Tool not in declared tool set".',
    );
    buffer.writeln();
    buffer.writeln(
      'CORRECT: <tool_call>{"name":"notes","arguments":'
      '{"action":"update_memory","content":"…"}}</tool_call>',
    );
    buffer.writeln(
      'WRONG (rejected): <tool_call>{"name":"update_memory",'
      '"arguments":{…}}</tool_call>',
    );
    buffer.writeln(
      'WRONG (rejected): <tool_call>{"name":"update_user",'
      '"arguments":{…}}</tool_call>',
    );
    buffer.writeln(
      'WRONG (rejected): <tool_call>{"name":"update_soul",'
      '"arguments":{…}}</tool_call>',
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
      '- **Prefer patch_* over update_*** for small changes. '
      'patch_user/patch_memory/patch_soul accept an "edits" list of '
      '{old_str, new_str} pairs — each old_str must match exactly once. '
      'Use update_* only when rewriting the whole document.',
    );
    buffer.writeln(
      '- **Soul** (action: update_soul or patch_soul): You CAN update it '
      'but you MUST tell the user what you changed and why. '
      'The app shows a visual diff automatically — no need to describe '
      'the changes in text unless the user needs context.',
    );
    buffer.writeln(
      '- **User** (action: update_user or patch_user): For update_user, '
      'include ALL existing facts plus the new ones. Do not lose old info. '
      'For patch_user, supply only the changed lines.',
    );
    buffer.writeln(
      '- **Memory** (action: update_memory or patch_memory): Keep it '
      'curated — distilled knowledge, not raw logs.',
    );
    buffer.writeln(
      '- **Visual diff**: After any notes update the app renders a diff '
      'card showing exactly what changed. You do NOT need to describe the '
      'diff in your reply unless the user asks.',
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
NEVER emit legacy per-tool XML tags such as <fetch_image>...</fetch_image> or <web_search>...</web_search>. Only use $toolCallStart...$toolCallEnd.

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
- <chart>, <map>, <email>, <weather>, <news>, and <image> are OUTPUT TAGS, not tools. Write them directly in your response.
- Never call find_tools for "chart", "graph", "plot", "map", "email", or "weather".
- If user asks for a chart/map, discover DATA tools first, then emit <chart>/<map> directly in your final response text.
- To draft an email, emit <email>{"to":"...","subject":"...","body":"..."}</email> in your response. The app renders it as a card with an "Open in Mail App" button.
- For weather questions, call the weather tool first, then emit a <weather> block with the structured data so the app renders a nice weather card.
- For render-only pictures in your final answer, emit an <image> block with a URL (no tool call needed for rendering).
- For "technische Zeichnung" / "technical drawing" / "engineering drawing" / DIN-style blueprints: use artifact_manager with type="technical_drawing" and JSON content. This is a RENDERED drawing with dimensions, NOT an AI-generated image. Do NOT use generate_image for technical drawings.

REAL PHOTOS vs AI ART — HARD RULE:
- User wants pictures of REAL things (people, actors, celebrities, movies, posters, places, products, cars, animals, food, events) -> call `web_search` with `type: "images"`, then emit ONE `<image>` block in your final answer using a returned image_url.
- Only use generate_image when the user explicitly asks for AI art, illustration, fantasy, concept art, something fictional, or a stylized generated image.
- NEVER fall back to generate_image just because image search returned nothing useful. Retry web_search with type="images" and a different query first, or explain the failure — do not silently substitute AI fakes for a real-photo request.
- `fetch_image` is for fetch/store/vision flows (e.g. user asks to attach/store/analyze an image), not for display-only rendering.

NEWS QUERIES:
- For "latest", "news", "today", "breaking", "just released", "aktuell", "neu", "heute" or other time-sensitive questions -> call `web_search` with `type: "news"` and the matching `freshness` (pd/pw/pm/py). You get publisher, age and thumbnail without a separate crawl. Follow up with web_crawl only when the user asks for full article detail.

WEB SEARCH TUNING:
- When the user writes in German or asks about DE-specific facts (prices in EUR, DE laws, local events), pass `country: "DE"` and `search_lang: "de"` to web_search so Brave localizes the SERP.
- `extra_snippets: true` is the default — read those bullet points before deciding whether you need web_crawl. Only crawl when a single source needs the full article.
- Use `freshness` for web-mode too, not just news, when recency matters ("latest release notes", "current version").

VISUAL OUTPUT SWITCHES (current):
- chart tags: ${includeChartVisualOutput ? 'enabled' : 'disabled'}
- map tags: ${includeMapVisualOutput ? 'enabled' : 'disabled'}
- email tags: enabled
- weather tags: enabled

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

PRIOR-CONVERSATION REFERENCE IS A HARD TRIGGER: Whenever the user's message presupposes shared history that is NOT present in the CURRENT chat — they treat a subject as already known, point back to an earlier discussion, or use a definite/deictic reference whose antecedent you cannot find in the messages above — you MUST call `search_chats` (action="find_chats") to recover the real subject from past chats BEFORE answering. This is about meaning, not specific words: if you cannot fully resolve what the user is referring to from the current chat alone, search first. Do NOT guess the subject's identity from training data or from Memory — Memory may note that a topic was discussed without recording the specifics, and your training data does not contain this user's chats. Resolve the real subject from chat history first; only then web_search/web_crawl for facts about it. If find_chats returns nothing relevant, say you could not find the prior chat and ask the user to clarify — never substitute a plausible-but-unverified guess.

## TOOLS

$toolsText
$undiscoveredSection
### How to call:
$toolCallStart
{"name": "tool_name", "arguments": {"param1": "value1"}}
$toolCallEnd

Multiple tools in one response: use multiple $toolCallStart...$toolCallEnd blocks.

FORMAT: Emit raw $toolCallStart...$toolCallEnd tags only. Do NOT wrap tool calls in Markdown code fences.
NEVER emit legacy per-tool XML tags such as <fetch_image>...</fetch_image> or <web_search>...</web_search>. Only use $toolCallStart...$toolCallEnd.

### Rules:
1. You can only call tools whose full description is shown above. To use a tool from "Other available tools", call find_tools first to get its description.
2. STOP after your last $toolCallEnd. Wait for real results -- never fabricate outputs.
3. Never use OpenAI-style function_call -- only $toolCallStart...$toolCallEnd XML tags.
4. NEVER invent factual data (phone numbers, addresses, URLs, prices, ratings). Only include what tools returned.
5. web_search includes search snippets and auto-fetched context from top pages. Use web_crawl for deeper extraction of a specific URL.
6. Never stop with intention-only text (e.g. "I will now search"). Do the next tool_call or provide the final answer.
7. COST & PRIVACY: Before calling generate_image, ALWAYS briefly tell the user it costs credits. Whether to also warn about privacy depends on the model: model="turbo" (Z-Image Turbo) and model="flux" (FLUX 2 Klein) run under a no-retention policy — inputs and outputs are not stored or used for training — so NO privacy warning is needed, just mention the cost. For model="hunyuan", "ideogram", or "edit", ALSO warn the user that the image is processed on an external server, can be seen by the service operator, and is NOT end-to-end encrypted like chat messages. Then proceed with the tool call in the same response — do not wait for confirmation unless the user previously expressed privacy concerns. After the image is generated, do NOT show the URL, dimensions, seed, model, or other technical metadata — the image is displayed inline automatically by the app. Model selection: use model="turbo" (fast, ~0.01 EUR) by default; use "hunyuan" (high quality, ~0.08 EUR), "flux" (best quality, ~0.02 EUR), or "ideogram" (best text rendering, ~0.03–0.10 EUR) when the user requests higher quality, text in the image, or a specific model; use "edit" (requires image_url, ~0.03 EUR) to modify an existing image.
8. If the needed tool is already listed above with its full description, call it directly. Do NOT call find_tools again unless you need a tool from "Other available tools".
9. REAL PHOTOS vs AI ART: When the user wants pictures of REAL things (people, actors, celebrities, movies, posters, places, products, cars, animals, food, events), call `web_search` with `type: "images"`, then emit ONE `<image>` block in your final answer using a returned image_url. Do NOT use `fetch_image` for display-only rendering. Only call `fetch_image` when the user explicitly asks to save/store/attach/analyze a picture. Only use generate_image when the user explicitly asks for AI art, illustration, fantasy, concept art, fictional subjects, or a stylized generated image. Never silently swap a real-photo request for AI-generated fakes — retry web_search with type="images" and a better query first, or report the failure.
   IMAGE CAPTIONS: When you call fetch_image or generate_image and the image shows an identifiable subject (a person, actor, place, product, character, scene), pass a short `caption` argument — the app renders it as a subtitle under the image. Use the subject's name or a 2-4 word label (e.g. "Sean Connery", "Eiffel Tower at dusk"). Omit captions for abstract/decorative images. After a caption is set, do NOT repeat it in your message text — the app shows it automatically.
10. NEWS & TIME-SENSITIVE QUERIES: For "latest", "news", "today", "breaking", "just released", "aktuell", "neu", "heute" or similar, call `web_search` with `type: "news"` and the right `freshness` (pd/pw/pm/py). Then emit a `<news>` block with the structured results — the app renders polished cards. Do NOT also list the same articles as markdown. Follow up with `web_crawl` only when the user asks for full article detail.
11. WEB SEARCH TUNING: `extra_snippets` is on by default — read the bullet-point snippets before deciding you need web_crawl. Use `country`/`search_lang` (e.g. "DE"/"de") for German or region-specific queries. Use `freshness` in web mode too when recency matters.

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
- code blocks longer than about 15 lines (type: code)
- full markdown documents/specs (type: markdown)
- HTML apps/pages (type: html — rendered in a sandboxed webview)
- Mermaid diagrams (type: mermaid)
- SVG content (type: svg)
- Technical / engineering drawings (type: technical_drawing)
- Excalidraw sketches / flowcharts / architecture diagrams (type: excalidraw)

For Typst documents (math, tables, reports) use the dedicated `typst_compile` tool, NOT artifact_manager.

Do NOT use artifacts for short snippets or quick conversational replies.

Artifact rules:
1. Prefer action="update" over action="rewrite" for targeted changes.
2. In update edits, each old_str MUST match exactly once in current content.
3. Keep update edits small (max ~5 edits). If many structural changes are needed, use rewrite.
4. Create at most ONE artifact per assistant response.
5. Reuse the same artifact_id across follow-up edits so version history stays intact.
6. When recreating an artifact in a different format, use action="rewrite" with the SAME artifact_id and set the new type. Do NOT create a new artifact_id.
7. **Keep artifacts in sync with memory / user-profile corrections.** If the user corrects a fact about themselves (preferences, habits, hardware, projects, health, etc.) AND an existing artifact in this chat visualizes or summarizes that fact (mindmap, profile sketch, info diagram, persona doc, etc.), update BOTH the memory/notes AND the artifact in the same response. Do NOT update only one. When the pronoun is ambiguous ("update das", "korrigier das"), default to updating every place the fact appears — never silently skip the artifact. For excalidraw / mermaid / svg artifacts where targeted `update` edits often fail due to repeated substrings, switch to `action="rewrite"` and send the full corrected scene.
8. **Rewrites MUST be derived from the CURRENT artifact body in the system message — never from your own memory of what you originally produced.** The body shown under "ACTIVE ARTIFACTS (LATEST VERSION)" is the live state, including every edit the user made (moved boxes, recolored elements, added text, deleted shapes, etc.). When you call `action="rewrite"`, copy that current body verbatim and apply ONLY the requested change on top of it. Do NOT regenerate the artifact from scratch using your initial idea of it — that silently destroys every user edit between your original version and now. This applies especially to excalidraw, mermaid, svg, and technical_drawing artifacts where the user routinely tweaks the scene between turns.

### MANDATORY schema lookup before complex types

For `excalidraw`, `technical_drawing`, `mermaid`, `svg`, and `typst`, you MUST call `artifact_schema(type: "<type>")` FIRST — in the SAME response, before the artifact_manager call. The tool returns the exact content shape (JSON keys, element syntax, allowed values). Skipping this step is the #1 cause of silent render failures because the content field does not match what the renderer expects.

Flow:
  1. `<tool_call>{"name":"artifact_schema","arguments":{"type":"excalidraw"}}</tool_call>`
  2. Wait for the tool result (the schema).
  3. Build `content` strictly following that schema.
  4. `<tool_call>{"name":"artifact_manager","arguments":{"action":"create","artifact_id":"...","title":"...","type":"excalidraw","content":"...full JSON as a string..."}}</tool_call>`

For simple types (`code`, `markdown`, `html`) no schema lookup is needed.

### Inline <artifact> tag (alternative to artifact_manager)

As a shorthand, you may emit the artifact directly in your message text:

    <artifact id="my-id" type="excalidraw" title="Optional Title">
    {...content JSON or code...}
    </artifact>

The UI parses these tags on message finalization:
- If the id is new → creates a fresh artifact (equivalent to action="create").
- If the id already exists → bumps the version (equivalent to action="rewrite").

The mandatory-schema-lookup rule above also applies to inline tags for complex types. For targeted text edits you still MUST use artifact_manager with action="update" — inline tags only support create/rewrite.

Never wrap an <artifact> tag inside a markdown code fence (```…```); the parser reads the tag from raw message text.
''';
  }

  List<Map<String, dynamic>> _dedupeToolsByName(
    List<Map<String, dynamic>> tools,
  ) {
    final seen = <String>{};
    final out = <Map<String, dynamic>>[];
    for (final tool in tools) {
      final rawName = tool['name'];
      final name = rawName is String ? rawName.trim() : '';
      if (name.isEmpty || seen.contains(name)) {
        continue;
      }
      seen.add(name);
      out.add(tool);
    }
    return out;
  }

  /// Docs for visual tags that are always available regardless of the
  /// chart/map feature switches (email drafts, weather/news/image cards).
  void _appendAlwaysOnVisualTags(StringBuffer buffer) {
    buffer.writeln();
    buffer.writeln('### Diffs');
    buffer.writeln(
      'To show a before/after comparison in your response, emit a <diff> block. '
      'The app renders it as a color-coded diff card (+/- lines). '
      'notes tool results already include this automatically — you only need '
      'to emit <diff> yourself for comparisons unrelated to notes updates.',
    );
    buffer.writeln('<diff>');
    buffer.writeln(
      '{"type":"user_info","title":"User Info updated",'
      '"before":"Name: Alice\\nCity: Berlin",'
      '"after":"Name: Alice\\nCity: Hamburg"}',
    );
    buffer.writeln('</diff>');
    buffer.writeln();
    buffer.writeln('**Diff fields:**');
    buffer.writeln(
      '- "type": "user_info" | "memory" | "soul" | "artifact" | any string (shown as label)',
    );
    buffer.writeln('- "title": header text (optional)');
    buffer.writeln('- "before": original text (required)');
    buffer.writeln('- "after": updated text (required)');

    buffer.writeln();
    buffer.writeln('### Images');
    buffer.writeln(
      'Use `<image>` for display-only rendering in your final answer. This is an output tag (no tool call required for rendering).',
    );
    buffer.writeln('<image>');
    buffer.writeln(
      '{"url":"https://example.com/photo.jpg","caption":"Michelangelo (Porträt, ca. 1548)","source":"Daniele da Volterra"}',
    );
    buffer.writeln('</image>');
    buffer.writeln();
    buffer.writeln('**Image fields:**');
    buffer.writeln('- "url": direct http/https image URL (required)');
    buffer.writeln(
      '- "caption": short subtitle shown under the image (optional)',
    );
    buffer.writeln('- "source" or "credit": attribution text (optional)');
    buffer.writeln(
      '**Image routing rules:** `web_search type:"images"` finds URLs; `<image>` renders one selected URL; `fetch_image` is only for fetch/store/vision workflows.',
    );

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
    buffer.writeln('### Weather');
    buffer.writeln(
      'When the user asks about weather, call the weather tool FIRST, then emit a <weather> block populated from the tool output. The app renders it as a polished weather card.',
    );
    buffer.writeln('<weather>');
    buffer.writeln(
      '{"location":"Kiel, Schleswig-Holstein, Germany","current":{"temp":8,"feels_like":5,"condition":"Partly cloudy","code":2,"humidity":72,"wind_speed":14,"wind_dir":"W","precipitation":0,"unit_temp":"C","unit_wind":"km/h","unit_precip":"mm"},"daily":[{"date":"2026-04-24","code":2,"temp_max":10,"temp_min":3,"precip_prob":20,"condition":"Partly cloudy"}],"hourly":[{"time":"14:00","code":2,"temp":8,"precip_prob":10}]}',
    );
    buffer.writeln('</weather>');
    buffer.writeln();
    buffer.writeln('**Weather fields:**');
    buffer.writeln('- "location": display name (required)');
    buffer.writeln(
      '- "current": {temp, feels_like, condition, code (WMO 0-99), humidity, wind_speed, wind_dir (N/NE/.../NW), precipitation, unit_temp ("C"|"F"), unit_wind, unit_precip} (required)',
    );
    buffer.writeln(
      '- "daily": array of {date (YYYY-MM-DD), code, temp_max, temp_min, precip_prob, condition} (optional, recommended for forecast queries)',
    );
    buffer.writeln(
      '- "hourly": array of {time (HH:MM or ISO), code, temp, precip_prob} (optional, include when user asks for next hours)',
    );
    buffer.writeln(
      '**WMO codes:** 0=clear, 1-2=partly cloudy, 3=overcast, 45/48=fog, 51-57=drizzle, 61-67=rain, 71-77=snow, 80-82=rain showers, 85-86=snow showers, 95-99=thunderstorm.',
    );
    buffer.writeln(
      '**Weather rules:** Only include fields from weather tool results. Never fabricate temperatures, codes, or forecasts. Emit at most one <weather> block per response. Do NOT also dump the raw tool text — the card contains everything.',
    );

    buffer.writeln();
    buffer.writeln('### News');
    buffer.writeln(
      'After `web_search` with `type: "news"`, emit a single <news> block with the structured results. The app renders polished article cards (thumbnail, title, publisher, summary, tap-to-open). Do NOT also list the same articles as markdown — the cards contain everything. A short intro sentence above the block is fine.',
    );
    buffer.writeln('<news>');
    buffer.writeln(
      '{"items":[{"title":"Qualcomm surges on OpenAI tie-up","publisher":"Reuters","age":"3 hours ago","url":"https://www.reuters.com/...","thumbnail":"https://...","summary":"Qualcomm shares jump 13% on reports of a partnership with OpenAI and MediaTek to develop AI smartphone processors.","breaking":false}]}',
    );
    buffer.writeln('</news>');
    buffer.writeln();
    buffer.writeln('**News fields per item:**');
    buffer.writeln('- "title": headline (required)');
    buffer.writeln('- "url": article URL (required)');
    buffer.writeln('- "publisher": source name, e.g. "Reuters" (optional)');
    buffer.writeln('- "age": e.g. "3 hours ago", "1 day ago" (optional)');
    buffer.writeln(
      '- "thumbnail": image URL from the search result `thumbnail_url` (optional)',
    );
    buffer.writeln(
      '- "summary": 1-2 sentence description, taken from the result description (optional)',
    );
    buffer.writeln(
      '- "breaking": true if the result is flagged BREAKING (optional)',
    );
    buffer.writeln(
      '**News rules:** Only include fields from `web_search type:"news"` results. Never fabricate URLs or thumbnails. Emit at most one <news> block per response.',
    );
  }

  /// Chart and map rendering protocol — these are output formats, not tools.
  String _visualOutputProtocol({
    required bool includeMaps,
    required bool includeCharts,
  }) {
    if (!includeMaps && !includeCharts) {
      final buffer = StringBuffer();
      buffer.writeln('## VISUAL OUTPUT');
      buffer.writeln();
      buffer.writeln(
        'Charts and maps are disabled for this session. Do NOT emit <chart> or <map> tags.',
      );
      _appendAlwaysOnVisualTags(buffer);
      return buffer.toString();
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
        '{"type":"places","title":"Restaurants","places":[{"name":"Example","lat":54.3,"lon":10.1,"cuisine":"Italian","opening_hours":"Mo-Fr 12-22","address":"Str. 82","rating":4.5,"review_count":120,"price_range":"€€","description":"Cozy trattoria with wood-fired pizzas."}]}',
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

    _appendAlwaysOnVisualTags(buffer);

    buffer.writeln();
    buffer.writeln('### Visual output rules:');
    var ruleNumber = 1;
    final tagLabel = includeMaps && includeCharts
        ? '<map>/<chart>/<image>/<weather>/<news>/<email>'
        : includeCharts
        ? '<chart>/<image>/<weather>/<news>/<email>'
        : '<map>/<image>/<weather>/<news>/<email>';
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
        '${ruleNumber++}. STOP after your last visual closing tag (e.g. </map>, </chart>, </image>, </weather>, </news>, </email>). Do not write text after it.',
      );
      buffer.writeln(
        '${ruleNumber++}. In <map> and <chart> JSON: only include fields from tool results. Do NOT fabricate data.',
      );
    } else if (includeCharts) {
      buffer.writeln(
        '${ruleNumber++}. STOP after your last visual closing tag (e.g. </chart>, </image>, </weather>, </news>, </email>). Do not write text after it.',
      );
      buffer.writeln(
        '${ruleNumber++}. In <chart> JSON: only include fields from tool results. Do NOT fabricate data.',
      );
    } else {
      buffer.writeln(
        '${ruleNumber++}. STOP after your last visual closing tag (e.g. </map>, </image>, </weather>, </news>, </email>). Do not write text after it.',
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
        '${ruleNumber++}. For places maps: include all fields the tool returned (name, lat, lon, cuisine, address, phone, website, opening_hours, rating, review_count, price_range, description). Omit fields marked "NOT AVAILABLE".',
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
