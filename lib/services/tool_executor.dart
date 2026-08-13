import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'package:chuk_chat/models/client_tool.dart';
import 'package:chuk_chat/models/content_block.dart';
import 'package:chuk_chat/models/artifact.dart';
import 'package:chuk_chat/services/api_config_service.dart';
import 'package:chuk_chat/services/artifact_storage_service.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/skills/skill_registry.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/services/tool_registry.dart' as registry;
import 'package:chuk_chat/tool_handlers/calculate_handler.dart' as calculate;
import 'package:chuk_chat/tool_handlers/find_tools_handler.dart' as find_tools;
import 'package:chuk_chat/tool_handlers/image_tools.dart' as image_tools;
import 'package:chuk_chat/tool_handlers/map_tools.dart' as map_tools;
import 'package:chuk_chat/tool_handlers/notes_tools.dart' as notes_tools;
import 'package:chuk_chat/tool_handlers/qr_tools.dart' as qr_tools;
import 'package:chuk_chat/tool_handlers/crypto_tools.dart' as crypto_tools;
import 'package:chuk_chat/tool_handlers/weather_tools.dart' as weather_tools;
import 'package:chuk_chat/tool_handlers/web_tools.dart' as web_tools;
import 'package:chuk_chat/tool_handlers/platform_tools.dart' as platform_tools;
import 'package:chuk_chat/tool_handlers/chat_search_tools.dart'
    as chat_search_tools;
import 'package:chuk_chat/tool_handlers/nextcloud_tools.dart'
    as nextcloud_tools;
import 'package:chuk_chat/tool_handlers/typst_tools.dart' as typst_tools;
import 'package:chuk_chat/tool_handlers/sandbox_tools.dart' as sandbox_tools;
import 'package:chuk_chat/tool_handlers/cowork_tools.dart' as cowork_tools;
import 'package:chuk_chat/services/workspace_storage_service.dart';

class ToolExecutionResult {
  const ToolExecutionResult({
    required this.output,
    required this.isError,
    this.producedBlocks = const [],
  });

  final String output;
  final bool isError;

  /// Optional content blocks produced as a side-effect of this tool call.
  /// Currently used by `send_file_to_user` to attach a
  /// [ContentBlockType.sandboxArtifact] block to the streaming assistant
  /// message so the user sees the file inline as a downloadable artifact.
  final List<ContentBlock> producedBlocks;
}

/// Service to execute tools client-side.
///
/// This is the central coordinator that dispatches to individual tool
/// handlers. Adapted from the function_calling repo for chuk_chat.
class ToolExecutor {
  final Map<String, ClientTool> _tools = {};
  final Map<String, bool> _enabledTools = {};
  final Map<String, String> _customToolDescriptions = {};
  bool _mapVisualOutputEnabled = true;
  bool _chartVisualOutputEnabled = true;
  Future<void>? _loadPrefsFuture;

  /// The chat id for the current send/turn. Set by the send logic before
  /// every LLM invocation. Used by `artifact_manager` / `typst_compile`
  /// as the authoritative chat scope, with `ChatStorageService` as a
  /// fallback only. Avoids the static-state races where the parent
  /// widget's `selectedChatId` hasn't propagated yet on the first turn
  /// of a newly-created chat.
  String? currentChatId;

  static const String _kMapVisualOutputEnabledKey = 'visual_output_map_enabled';
  static const String _kChartVisualOutputEnabledKey =
      'visual_output_chart_enabled';
  static const String _kToolPrefsTable = 'user_tool_preferences';

  static const Set<String> _builtinExecutableToolNames = {
    'find_tools',
    'calculate',
    'get_time',
    'random_number',
    'flip_coin',
    'roll_dice',
    'countdown',
    'password_generator',
    'uuid_generator',
    'notes',
    'generate_qr',
    'ask_user',
    // Unconditional despite kFeatureSkills: this set asserts "an executor
    // exists for this name", it is not a feature gate. registerTool() throws
    // if a registered tool is missing here. Gating happens in tool_registry.
    'skill',
    'web_search',
    'web_crawl',
    'generate_image',
    'fetch_image',
    'view_chat_images',
    'crypto_data',
    'weather',
    'search_places',
    'search_restaurants',
    'geocode',
    'get_route',
    'spotify_control',
    'bash',
    'github',
    'slack',
    'google_calendar',
    'gmail',
    'email',
    'nextcloud',
    'whoop',
    'device',
    'calendar',
    'reminder',
    'search_chats',
    'artifact_manager',
    'artifact_schema',
    'update_project',
    'typst_compile',
    'code_run',
    'sandbox_list',
    'sandbox_read',
    'sandbox_write',
    'sandbox_reset',
    'send_file_to_user',
    // CoWork laptop-native tools (gated in tool_registry by kFeatureCoworkDemo).
    // Listed here unconditionally: this set asserts an executor exists for the
    // name, it is not the feature gate. registerTool() throws without it.
    'run_command',
    'read_file',
    'write_file',
    'list_directory',
  };

  static const Set<String> _defaultDisabledTools = {'whoop'};

  /// Server HTTP base URL for server-proxied tools (Brave search, crawl).
  String? get serverHttpUrl => ApiConfigService.apiBaseUrl;

  /// HTTP headers for server requests.
  Map<String, String> _serverHeaders({String? accessToken}) {
    final headers = <String, String>{'Content-Type': 'application/json'};
    if (accessToken != null && accessToken.isNotEmpty) {
      headers['Authorization'] = 'Bearer $accessToken';
    }
    return headers;
  }

  /// Map tool names to their categories (from tool_registry.dart).
  static const Map<String, ToolCategory> toolCategories =
      registry.toolCategoryMap;

  /// Read-only view of the internal tools map.
  Map<String, ClientTool> get tools =>
      Map<String, ClientTool>.unmodifiable(_tools);

  // ─── Tool registration ──────────────────────────────────────────────────

  void registerTool(ClientTool tool) {
    if (tool.type == ToolType.builtin &&
        !_builtinExecutableToolNames.contains(tool.name)) {
      throw StateError(
        'Tool "${tool.name}" is registered but has no executor implementation.',
      );
    }
    _tools[tool.name] = tool;
    _enabledTools.putIfAbsent(
      tool.name,
      () => !_defaultDisabledTools.contains(tool.name),
    );
  }

  void unregisterTool(String name) {
    _tools.remove(name);
  }

  /// Get all registered tools.
  List<ClientTool> get allRegisteredTools => _tools.values.toList();

  bool get mapVisualOutputEnabled => _mapVisualOutputEnabled;
  bool get chartVisualOutputEnabled => _chartVisualOutputEnabled;

  Future<void> loadPreferences() {
    _loadPrefsFuture ??= _loadPreferencesInternal();
    return _loadPrefsFuture!;
  }

  Future<void> _loadPreferencesInternal() async {
    final prefs = await SharedPreferences.getInstance();

    for (final name in _tools.keys) {
      final enabledKey = 'tool_enabled_$name';
      final defaultEnabled = !_defaultDisabledTools.contains(name);
      _enabledTools[name] = prefs.getBool(enabledKey) ?? defaultEnabled;

      final descKey = 'tool_desc_$name';
      final customDesc = prefs.getString(descKey);
      if (customDesc != null && customDesc.trim().isNotEmpty) {
        _customToolDescriptions[name] = customDesc;
      } else {
        _customToolDescriptions.remove(name);
      }
    }

    _mapVisualOutputEnabled =
        prefs.getBool(_kMapVisualOutputEnabledKey) ?? true;
    _chartVisualOutputEnabled =
        prefs.getBool(_kChartVisualOutputEnabledKey) ?? true;

    // Defer Supabase sync to avoid blocking UI at startup.
    // Local prefs are already loaded above — tools work immediately.
    unawaited(_deferredSupabaseSync(prefs));
  }

  Future<void> _deferredSupabaseSync(SharedPreferences prefs) async {
    // Wait for the UI to settle before hitting the network.
    await Future<void>.delayed(const Duration(seconds: 5));
    try {
      await _syncToolEnabledPreferencesFromSupabase(
        prefs,
      ).timeout(const Duration(seconds: 10));
    } catch (error) {
      if (kDebugMode) {
        debugPrint('Tool preferences Supabase sync skipped: $error');
      }
    }
  }

  String? _safeCurrentUserId() {
    try {
      return SupabaseService.auth.currentUser?.id;
    } catch (_) {
      return null;
    }
  }

  Future<void> _syncToolEnabledPreferencesFromSupabase(
    SharedPreferences prefs,
  ) async {
    final userId = _safeCurrentUserId();
    if (userId == null) {
      return;
    }

    try {
      final List<dynamic> remoteRows = await SupabaseService.client
          .from(_kToolPrefsTable)
          .select('tool_name, enabled')
          .eq('user_id', userId);

      final remoteByTool = <String, bool>{};
      for (final row in remoteRows) {
        if (row is! Map<String, dynamic>) {
          continue;
        }

        final name = row['tool_name'] as String?;
        if (name == null || name.isEmpty || name == 'find_tools') {
          continue;
        }
        if (!_tools.containsKey(name)) {
          continue;
        }

        final enabled = row['enabled'] == true;
        remoteByTool[name] = enabled;
        _enabledTools[name] = enabled;
        await prefs.setBool('tool_enabled_$name', enabled);
      }

      final missingRows = <Map<String, dynamic>>[];
      for (final name in _tools.keys) {
        if (name == 'find_tools') {
          continue;
        }
        if (remoteByTool.containsKey(name)) {
          continue;
        }

        final enabled =
            _enabledTools[name] ?? !_defaultDisabledTools.contains(name);
        missingRows.add({
          'user_id': userId,
          'tool_name': name,
          'enabled': enabled,
        });
      }

      if (missingRows.isNotEmpty) {
        await SupabaseService.client
            .from(_kToolPrefsTable)
            .upsert(missingRows, onConflict: 'user_id,tool_name');
      }
    } catch (error) {
      if (kDebugMode) {
        debugPrint('Failed to sync tool preferences from Supabase: $error');
      }
    }
  }

  Future<void> _syncSingleToolEnabledToSupabase(
    String name,
    bool enabled,
  ) async {
    final userId = _safeCurrentUserId();
    if (userId == null) {
      return;
    }

    try {
      await SupabaseService.client.from(_kToolPrefsTable).upsert({
        'user_id': userId,
        'tool_name': name,
        'enabled': enabled,
      }, onConflict: 'user_id,tool_name');
    } catch (error) {
      if (kDebugMode) {
        debugPrint('Failed to sync tool "$name" preference: $error');
      }
    }
  }

  Future<void> _syncAllToolEnabledToSupabase() async {
    final userId = _safeCurrentUserId();
    if (userId == null) {
      return;
    }

    final payload = <Map<String, dynamic>>[];
    for (final name in _tools.keys) {
      if (name == 'find_tools') {
        continue;
      }

      payload.add({
        'user_id': userId,
        'tool_name': name,
        'enabled': _enabledTools[name] ?? !_defaultDisabledTools.contains(name),
      });
    }

    if (payload.isEmpty) {
      return;
    }

    try {
      await SupabaseService.client
          .from(_kToolPrefsTable)
          .upsert(payload, onConflict: 'user_id,tool_name');
    } catch (error) {
      if (kDebugMode) {
        debugPrint('Failed to sync all tool preferences: $error');
      }
    }
  }

  Future<void> setMapVisualOutputEnabled(bool enabled) async {
    _mapVisualOutputEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kMapVisualOutputEnabledKey, enabled);
  }

  Future<void> setChartVisualOutputEnabled(bool enabled) async {
    _chartVisualOutputEnabled = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kChartVisualOutputEnabledKey, enabled);
  }

  Future<void> setToolEnabled(String name, bool enabled) async {
    if (!_tools.containsKey(name) || name == 'find_tools') {
      return;
    }

    _enabledTools[name] = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('tool_enabled_$name', enabled);
    await _syncSingleToolEnabledToSupabase(name, enabled);
  }

  bool isToolEnabled(String name) {
    if (name == 'find_tools') {
      return true;
    }

    return _enabledTools[name] ?? !_defaultDisabledTools.contains(name);
  }

  String getDefaultToolDescription(String name) {
    return _tools[name]?.description ?? '';
  }

  String getToolDescription(String name) {
    return _customToolDescriptions[name] ?? getDefaultToolDescription(name);
  }

  bool hasCustomDescription(String name) {
    return _customToolDescriptions.containsKey(name);
  }

  Future<void> setToolDescription(String name, String description) async {
    if (!_tools.containsKey(name) || name == 'find_tools') {
      return;
    }

    final trimmedDescription = description.trim();
    final defaultDescription = getDefaultToolDescription(name).trim();
    final prefs = await SharedPreferences.getInstance();

    if (trimmedDescription.isEmpty ||
        trimmedDescription == defaultDescription) {
      _customToolDescriptions.remove(name);
      await prefs.remove('tool_desc_$name');
      return;
    }

    _customToolDescriptions[name] = trimmedDescription;
    await prefs.setString('tool_desc_$name', trimmedDescription);
  }

  Future<void> resetToolDescription(String name) async {
    _customToolDescriptions.remove(name);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('tool_desc_$name');
  }

  Future<void> resetAllToolPreferences() async {
    final prefs = await SharedPreferences.getInstance();

    for (final name in _tools.keys) {
      if (name == 'find_tools') {
        continue;
      }

      final defaultEnabled = !_defaultDisabledTools.contains(name);
      _enabledTools[name] = defaultEnabled;
      _customToolDescriptions.remove(name);

      await prefs.setBool('tool_enabled_$name', defaultEnabled);
      await prefs.remove('tool_desc_$name');
    }

    _mapVisualOutputEnabled = true;
    _chartVisualOutputEnabled = true;
    await prefs.setBool(_kMapVisualOutputEnabledKey, true);
    await prefs.setBool(_kChartVisualOutputEnabledKey, true);
    await _syncAllToolEnabledToSupabase();
  }

  /// Get all enabled tools -- this is what gets sent to the LLM.
  ///
  /// Tools are included regardless of service connection status so the model
  /// always knows they exist and can instruct the user to connect.  The tool
  /// executor returns a helpful "please connect" message when an unconnected
  /// tool is called.
  List<ClientTool> get allTools {
    return _tools.values.where((tool) {
      if (tool.name == 'find_tools') return true; // Always available
      return isToolEnabled(tool.name);
    }).toList();
  }

  /// Check if a specific tool is available (enabled + connected).
  ///
  /// Used by the settings UI to show connection badges.  NOT used for
  /// filtering the LLM tool list (see [allTools]).
  bool isToolAvailable(String name) {
    if (!isToolEnabled(name)) {
      return false;
    }

    final category = toolCategories[name];
    if (category == null) return true;
    return isServiceConnected(category);
  }

  /// Check if a service category is connected.
  bool isServiceConnected(ToolCategory category) {
    switch (category) {
      case ToolCategory.basic:
        return true;
      case ToolCategory.search:
        return true; // Server-proxied APIs, always available
      case ToolCategory.map:
        return true; // Free APIs
      case ToolCategory.device:
        return true;
      case ToolCategory.spotify:
        return platform_tools.isPlatformServiceConnected('spotify');
      case ToolCategory.bash:
        return platform_tools.isPlatformServiceConnected('bash');
      case ToolCategory.github:
        return platform_tools.isPlatformServiceConnected('github');
      case ToolCategory.slack:
        return platform_tools.isPlatformServiceConnected('slack');
      case ToolCategory.google:
        return platform_tools.isPlatformServiceConnected('google');
      case ToolCategory.email:
        return platform_tools.isPlatformServiceConnected('email');
      case ToolCategory.nextcloud:
        return nextcloud_tools.isNextcloudConnected();
      case ToolCategory.whoop:
        return platform_tools.isPlatformServiceConnected('whoop');
      case ToolCategory.sandbox:
        return true; // Server-managed Docker sandbox
    }
  }

  // ─── Tool execution (dispatch to handlers) ──────────────────────────────

  Future<ToolExecutionResult> execute(
    String toolName,
    Map<String, dynamic> args, {
    String? accessToken,
  }) async {
    final tool = _tools[toolName];
    if (tool == null) {
      return ToolExecutionResult(
        output: 'Error: Unknown tool "$toolName"',
        isError: true,
      );
    }

    if (tool.type == ToolType.builtin &&
        !_builtinExecutableToolNames.contains(toolName)) {
      return ToolExecutionResult(
        output:
            'Error: Tool "$toolName" is registered but not executable. '
            'Missing executor implementation.',
        isError: true,
      );
    }

    if (tool.type != ToolType.builtin) {
      return ToolExecutionResult(
        output:
            'Error: Tool "$toolName" is not a builtin tool and cannot be '
            'executed client-side.',
        isError: true,
      );
    }

    try {
      return await _executeBuiltin(toolName, args, accessToken: accessToken);
    } catch (e) {
      return ToolExecutionResult(
        output: 'Error: Failed to execute "$toolName": $e',
        isError: true,
      );
    }
  }

  Future<ToolExecutionResult> _executeBuiltin(
    String name,
    Map<String, dynamic> args, {
    String? accessToken,
  }) async {
    switch (name) {
      // -- Basic tools (inline, too small for own file) --
      case 'calculate':
        return _wrapOutput(calculate.executeCalculate(args));
      case 'get_time':
        final now = DateTime.now();
        return ToolExecutionResult(
          output:
              'Current time: '
              '${now.hour.toString().padLeft(2, '0')}:'
              '${now.minute.toString().padLeft(2, '0')} on '
              '${now.year}-'
              '${now.month.toString().padLeft(2, '0')}-'
              '${now.day.toString().padLeft(2, '0')}',
          isError: false,
        );
      case 'random_number':
        final min = _coerceInt(args['min'], fallback: 1);
        final max = _coerceInt(args['max'], fallback: 100);
        if (max < min) {
          return ToolExecutionResult(
            output:
                'Error: random_number requires max >= min (min=$min, max=$max)',
            isError: true,
          );
        }
        final rng = Random.secure();
        final random = min + rng.nextInt(max - min + 1);
        return ToolExecutionResult(
          output: 'Random number: $random (range: $min-$max)',
          isError: false,
        );
      case 'flip_coin':
        final result = Random.secure().nextBool() ? 'Heads' : 'Tails';
        return ToolExecutionResult(
          output: 'Coin flip: $result',
          isError: false,
        );
      case 'roll_dice':
        final sides = _coerceInt(args['sides'], fallback: 6);
        final count = _coerceInt(args['count'], fallback: 1);
        if (sides <= 0) {
          return const ToolExecutionResult(
            output: 'Error: roll_dice requires sides > 0',
            isError: true,
          );
        }
        if (count <= 0) {
          return const ToolExecutionResult(
            output: 'Error: roll_dice requires count > 0',
            isError: true,
          );
        }
        if (count > 100) {
          return const ToolExecutionResult(
            output: 'Error: roll_dice count must be <= 100',
            isError: true,
          );
        }
        final rng = Random.secure();
        final rolls = List.generate(count, (_) => rng.nextInt(sides) + 1);
        final total = rolls.reduce((a, b) => a + b);
        return ToolExecutionResult(
          output: 'Dice roll (${count}d$sides): ${rolls.join(", ")} = $total',
          isError: false,
        );
      case 'countdown':
        try {
          final dateStr = args['date'] as String? ?? '';
          final target = DateTime.parse(dateStr);
          final now = DateTime.now();
          final diff = target.difference(now);
          if (diff.isNegative) {
            return ToolExecutionResult(
              output: 'That date was ${-diff.inDays} days ago',
              isError: false,
            );
          }
          return ToolExecutionResult(
            output: '${diff.inDays} days until $dateStr',
            isError: false,
          );
        } catch (e) {
          return const ToolExecutionResult(
            output:
                'Error: Invalid date format. Use ISO 8601, e.g. '
                '2024-12-25 or 2024-12-25T10:30:00Z',
            isError: true,
          );
        }
      case 'password_generator':
        final length = _coerceInt(args['length'], fallback: 16).clamp(4, 128);
        const chars =
            'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ'
            r'0123456789!@#$%^&*';
        final rng = Random.secure();
        final password = StringBuffer();
        for (int i = 0; i < length; i++) {
          password.write(chars[rng.nextInt(chars.length)]);
        }
        return ToolExecutionResult(
          output: 'Generated password: ${password.toString()}',
          isError: false,
        );
      case 'uuid_generator':
        return ToolExecutionResult(
          output: 'UUID: ${const Uuid().v4()}',
          isError: false,
        );
      case 'notes':
        return _wrapOutput(await notes_tools.executeNotes(args));
      case 'search_chats':
        return _wrapOutput(await chat_search_tools.executeSearchChats(args));
      case 'generate_qr':
        return _wrapOutput(await qr_tools.executeGenerateQr(args));
      case 'ask_user':
        return _wrapOutput(_executeAskUser(args));

      // -- Tool discovery --
      case 'find_tools':
        return _wrapOutput(
          find_tools.executeFindTools(
            args: args,
            tools: _tools,
            getDescription: getToolDescription,
            isAvailable: isToolAvailable,
          ),
        );

      // -- Web tools --
      case 'web_search':
        return _wrapOutput(
          await web_tools.executeWebSearch(
            serverHttpUrl: serverHttpUrl,
            serverHeaders: _serverHeaders(accessToken: accessToken),
            args: args,
          ),
        );
      case 'web_crawl':
        return _wrapOutput(
          await web_tools.executeWebCrawl(
            serverHttpUrl: serverHttpUrl,
            serverHeaders: _serverHeaders(accessToken: accessToken),
            args: args,
          ),
        );
      case 'generate_image':
        return _wrapOutput(
          await image_tools.executeGenerateImage(
            serverHttpUrl: serverHttpUrl,
            accessToken: accessToken,
            args: args,
          ),
        );
      case 'fetch_image':
        return _wrapOutput(await image_tools.executeFetchImage(args));
      case 'view_chat_images':
        return _wrapOutput(image_tools.executeViewChatImagesUnsupported());
      case 'crypto_data':
        return _wrapOutput(await crypto_tools.executeCryptoData(args));

      // -- Maps --
      case 'search_places':
        return _placesResult(
          await map_tools.searchPlacesWithMap(
            serverHttpUrl: serverHttpUrl,
            serverHeaders: _serverHeaders(accessToken: accessToken),
            args: args,
          ),
        );
      case 'search_restaurants':
        return _placesResult(
          await map_tools.searchRestaurantsWithMap(
            serverHttpUrl: serverHttpUrl,
            serverHeaders: _serverHeaders(accessToken: accessToken),
            args: args,
          ),
        );
      case 'geocode':
        return _wrapOutput(await map_tools.executeGeocode(args));
      case 'get_route':
        return _wrapOutput(await map_tools.executeGetRoute(args));

      // -- Weather --
      case 'weather':
        return _wrapOutput(
          await weather_tools.executeWeather(
            serverHttpUrl: serverHttpUrl,
            serverHeaders: _serverHeaders(accessToken: accessToken),
            args: args,
          ),
        );

      // -- Platform-specific tools (stub on web) --
      case 'spotify_control':
        return _wrapOutput(await platform_tools.executeSpotify(args));
      case 'bash':
        return _wrapOutput(await platform_tools.executeBash(args));
      case 'github':
        return _wrapOutput(await platform_tools.executeGitHub(args));
      case 'slack':
        return _wrapOutput(await platform_tools.executeSlack(args));
      case 'google_calendar':
        return _wrapOutput(await platform_tools.executeGoogleCalendar(args));
      case 'gmail':
        return _wrapOutput(await platform_tools.executeGmail(args));
      case 'email':
        return _wrapOutput(await platform_tools.executeEmail(args));
      case 'device':
        return _wrapOutput(await platform_tools.executeDevice(args));
      case 'calendar':
        return _wrapOutput(await platform_tools.executeCalendar(args));
      case 'reminder':
        return _wrapOutput(await platform_tools.executeReminder(args));
      case 'whoop':
        return _wrapOutput(await platform_tools.executeWhoop(args));

      // -- Nextcloud (web-safe) --
      case 'nextcloud':
        return _wrapOutput(await nextcloud_tools.executeNextcloud(args));

      // -- Workspace management --
      case 'artifact_manager':
        return _wrapOutput(await _executeArtifactManager(args));
      case 'artifact_schema':
        return _wrapOutput(_executeArtifactSchema(args));
      case 'skill':
        return _wrapOutput(_executeSkill(args));
      case 'update_project':
        return _wrapOutput(await _executeUpdateProject(args));

      // -- Sandbox: code execution + file I/O --
      case 'code_run':
        return _wrapOutput(
          await sandbox_tools.executeCodeRun(
            accessToken: accessToken,
            chatId:
                currentChatId ??
                ChatStorageService.selectedChatId ??
                ChatStorageService.activeMessageChatId,
            args: args,
          ),
        );
      case 'sandbox_list':
        return _wrapOutput(
          await sandbox_tools.executeSandboxListFiles(
            accessToken: accessToken,
            chatId:
                currentChatId ??
                ChatStorageService.selectedChatId ??
                ChatStorageService.activeMessageChatId,
            args: args,
          ),
        );
      case 'sandbox_read':
        // Raw file contents: a file whose first line starts with "Error"
        // must not be reported as a failed tool call.
        return _wrapOutput(
          sniff: false,
          await sandbox_tools.executeSandboxReadFile(
            accessToken: accessToken,
            chatId:
                currentChatId ??
                ChatStorageService.selectedChatId ??
                ChatStorageService.activeMessageChatId,
            args: args,
          ),
        );
      case 'sandbox_write':
        return _wrapOutput(
          await sandbox_tools.executeSandboxWriteFile(
            accessToken: accessToken,
            chatId:
                currentChatId ??
                ChatStorageService.selectedChatId ??
                ChatStorageService.activeMessageChatId,
            args: args,
          ),
        );
      case 'sandbox_reset':
        return _wrapOutput(
          await sandbox_tools.executeSandboxReset(
            accessToken: accessToken,
            chatId:
                currentChatId ??
                ChatStorageService.selectedChatId ??
                ChatStorageService.activeMessageChatId,
            args: args,
          ),
        );

      // `send_file_to_user` is a sandbox tool that also produces a
      // ContentBlock side-effect, so it returns its own ToolExecutionResult
      // (with `producedBlocks`) rather than going through `_wrapOutput`.
      case 'send_file_to_user':
        return sandbox_tools.executeSandboxSendFileToUser(
          accessToken: accessToken,
          chatId:
              currentChatId ??
              ChatStorageService.selectedChatId ??
              ChatStorageService.activeMessageChatId,
          args: args,
        );

      // -- Typst compile (server-sandboxed) --
      case 'typst_compile':
        return _wrapOutput(
          await typst_tools.executeTypstCompile(
            serverHttpUrl: serverHttpUrl,
            accessToken: accessToken,
            chatId:
                currentChatId ??
                ChatStorageService.selectedChatId ??
                ChatStorageService.activeMessageChatId,
            args: args,
          ),
        );

      // -- CoWork laptop-native tools (gated by kFeatureCoworkDemo) --
      case 'run_command':
        return _wrapOutput(await cowork_tools.executeRunCommand(args));
      case 'read_file':
        // Raw file contents: a file whose first line starts with "Error"
        // must not be reported as a failed tool call.
        return _wrapOutput(
          sniff: false,
          await cowork_tools.executeReadFile(args),
        );
      case 'write_file':
        return _wrapOutput(await cowork_tools.executeWriteFile(args));
      case 'list_directory':
        return _wrapOutput(await cowork_tools.executeListDirectory(args));

      default:
        return ToolExecutionResult(
          output: 'Error: Unknown builtin tool: $name',
          isError: true,
        );
    }
  }

  Future<String> _executeArtifactManager(Map<String, dynamic> args) async {
    final action = (args['action'] as String? ?? '').trim().toLowerCase();
    // Resolve the chat id with three layers of fallback so tool
    // invocations cannot race static-state propagation:
    //   1. `currentChatId` set by the send logic at the start of the turn.
    //   2. `ChatStorageService.selectedChatId` — parent widget state.
    //   3. `ChatStorageService.activeMessageChatId` — set by the resend
    //      path and mirrored by the send path for the same reason.
    final chatId =
        currentChatId ??
        ChatStorageService.selectedChatId ??
        ChatStorageService.activeMessageChatId;

    if (chatId == null || chatId.isEmpty) {
      if (kDebugMode) {
        debugPrint(
          '❌ [ToolExecutor] artifact_manager: no chat id resolvable '
          '(currentChatId=null, selectedChatId=${ChatStorageService.selectedChatId}, '
          'activeMessageChatId=${ChatStorageService.activeMessageChatId})',
        );
      }
      return 'Error: No active chat. Start or select a chat first.';
    }

    if (action.isEmpty) {
      return 'Error: "action" is required (create | update | rewrite).';
    }

    try {
      switch (action) {
        case 'create':
          final artifactId = (args['artifact_id'] as String? ?? '').trim();
          final title = (args['title'] as String? ?? '').trim();
          final typeRaw = (args['type'] as String? ?? '').trim();
          final content = args['content'] as String? ?? '';
          final language = (args['language'] as String?)?.trim();
          final messageId = (args['message_id'] as String?)?.trim();

          if (artifactId.isEmpty || title.isEmpty || typeRaw.isEmpty) {
            return 'Error: create requires artifact_id, title, and type.';
          }
          if (content.trim().isEmpty) {
            return 'Error: create requires non-empty content.';
          }

          final type = ArtifactTypeX.fromValue(typeRaw);
          if (type == ArtifactType.typst) {
            return 'Error: typst artifacts must be created via the '
                '`typst_compile` tool so the source is compiled and the '
                'rendered PDF is persisted. Call typst_compile with the '
                '`source` argument instead of artifact_manager.';
          }
          Future<String> rewriteExisting({
            required ArtifactDocument existing,
          }) async {
            if (existing.type == ArtifactType.typst) {
              return 'Error: artifact "$artifactId" is a typst artifact. '
                  'Rewrite it via `typst_compile` with the new `source` so '
                  'the compiler validates the changes before the PDF is '
                  'replaced.';
            }
            if (existing.chatId != chatId) {
              return 'Error: Artifact "$artifactId" already exists in a '
                  'different chat. Use a unique artifact_id for create, or '
                  'use rewrite in the original chat.';
            }
            final rewritten = await ArtifactStorageService.rewriteArtifact(
              artifactId: artifactId,
              content: content,
              title: title,
              type: type,
              language: language,
            );
            return 'Artifact "${rewritten.id}" rewritten to '
                'version ${rewritten.version} (create fallback).';
          }

          final existing = await ArtifactStorageService.loadArtifactById(
            artifactId,
          );
          if (existing != null) {
            return rewriteExisting(existing: existing);
          }

          try {
            final created = await ArtifactStorageService.createArtifact(
              chatId: chatId,
              artifactId: artifactId,
              title: title,
              type: type,
              content: content,
              language: language,
              messageId: messageId,
            );
            return 'Artifact "${created.id}" created '
                '(type: ${created.type.value}, version: ${created.version}).';
          } on StateError catch (error) {
            final message = error.message.toString();
            if (!message.contains('already exists')) {
              rethrow;
            }
            final raceExisting = await ArtifactStorageService.loadArtifactById(
              artifactId,
            );
            if (raceExisting != null) {
              return rewriteExisting(existing: raceExisting);
            }
            rethrow;
          }

        case 'update':
          final artifactId = (args['artifact_id'] as String? ?? '').trim();
          if (artifactId.isEmpty) {
            return 'Error: update requires artifact_id.';
          }

          final rawEdits = args['edits'];
          if (rawEdits is! List || rawEdits.isEmpty) {
            return 'Error: update requires non-empty edits list.';
          }

          final edits = <ArtifactEdit>[];
          for (final item in rawEdits) {
            if (item is! Map) {
              return 'Error: each edit must be an object with '
                  'old_str/new_str.';
            }

            final mapped = <String, dynamic>{};
            for (final entry in item.entries) {
              final key = entry.key;
              if (key is! String) {
                return 'Error: edit object keys must be strings.';
              }
              mapped[key] = entry.value;
            }

            edits.add(ArtifactEdit.fromMap(mapped));
          }

          final existingForUpdate =
              await ArtifactStorageService.loadArtifactById(artifactId);
          if (existingForUpdate != null &&
              existingForUpdate.type == ArtifactType.typst) {
            return 'Error: artifact "$artifactId" is a typst artifact. '
                'Small edits still need to go through `typst_compile` so '
                'the source is recompiled and the stored PDF stays in '
                'sync. Call typst_compile with the full corrected '
                '`source`.';
          }

          final updated = await ArtifactStorageService.updateArtifactWithEdits(
            artifactId: artifactId,
            edits: edits,
          );
          return 'Artifact "${updated.id}" updated to '
              'version ${updated.version} (${edits.length} edit(s)).';

        case 'rewrite':
          final artifactId = (args['artifact_id'] as String? ?? '').trim();
          final content = args['content'] as String? ?? '';
          if (artifactId.isEmpty) {
            return 'Error: rewrite requires artifact_id.';
          }
          if (content.trim().isEmpty) {
            return 'Error: rewrite requires non-empty content.';
          }

          final title = (args['title'] as String?)?.trim();
          final typeRaw = (args['type'] as String?)?.trim();
          final language = (args['language'] as String?)?.trim();
          final type = (typeRaw == null || typeRaw.isEmpty)
              ? null
              : ArtifactTypeX.fromValue(typeRaw);

          // Block rewriting typst artifacts through artifact_manager —
          // it would skip compile-time validation and leave the stored
          // attachment pointing at the OLD PDF. typst_compile must be
          // used so the new source is validated and the new PDF is
          // persisted.
          if (type == ArtifactType.typst) {
            return 'Error: typst artifacts must be rewritten via '
                '`typst_compile`, not artifact_manager. Call typst_compile '
                'with the same artifact_id and the new `source` — it will '
                'validate the compile and replace the saved PDF.';
          }
          final existing = await ArtifactStorageService.loadArtifactById(
            artifactId,
          );
          if (existing != null &&
              existing.type == ArtifactType.typst &&
              (type == null || type == ArtifactType.typst)) {
            return 'Error: artifact "$artifactId" is a typst artifact. '
                'Rewrite it via `typst_compile` with the new `source` so '
                'the compiler validates the changes before the PDF is '
                'replaced.';
          }

          final updated = await ArtifactStorageService.rewriteArtifact(
            artifactId: artifactId,
            content: content,
            title: title,
            type: type,
            language: language,
          );
          return 'Artifact "${updated.id}" rewritten to '
              'version ${updated.version}.';

        default:
          return 'Error: Unknown action "$action". '
              'Use create, update, or rewrite.';
      }
    } catch (e) {
      return 'Error: Artifact operation failed: $e';
    }
  }

  /// Returns the full content schema for a complex artifact type, so the
  /// AI can build a correct `content` field before calling
  /// `artifact_manager`. Moving these schemas out of the system prompt
  /// into an on-demand tool keeps the prompt small and forces the AI to
  /// have the current schema in context right when it generates the
  /// artifact content — which empirically yields fewer malformed
  /// payloads.
  String _executeArtifactSchema(Map<String, dynamic> args) {
    final type = (args['type'] as String? ?? '').trim().toLowerCase();
    if (type.isEmpty) {
      return 'Error: "type" is required (excalidraw | technical_drawing | '
          'typst | mermaid | svg).';
    }
    switch (type) {
      case 'excalidraw':
        return _excalidrawSchemaText;
      case 'technical_drawing':
        return _technicalDrawingSchemaText;
      case 'typst':
        return _typstSchemaText;
      case 'mermaid':
        return _mermaidSchemaText;
      case 'svg':
        return _svgSchemaText;
      default:
        return 'Error: Unknown artifact type "$type". Supported: '
            'excalidraw, technical_drawing, typst, mermaid, svg.';
    }
  }

  /// Activates a skill.
  ///
  /// Deliberately returns a short acknowledgement rather than the skill body.
  /// The body is injected into the NEXT system prompt rebuild (which the tool
  /// loop performs every round anyway) under `## ACTIVE SKILL`. Returning it
  /// here instead would look simpler but is broken: tool results are truncated
  /// to 4000 chars when they are replayed into the next user turn
  /// (`tool_history_formatter.dart`), so a skill would silently lose most of
  /// itself as soon as the user sent another message.
  ///
  /// This mirrors `find_tools`, which also returns names and lets the prompt
  /// rebuild carry the full payload.
  String _executeSkill(Map<String, dynamic> args) {
    final requested = (args['name'] as String? ?? '').trim();
    if (requested.isEmpty) {
      return 'Error: "name" is required. Available skills: '
          '${SkillRegistry.names.join(', ')}.';
    }

    final skill = SkillRegistry.byName(requested);
    if (skill == null) {
      return 'Error: Unknown skill "$requested". Available skills: '
          '${SkillRegistry.names.join(', ')}. Use the exact name from the '
          'SKILLS catalog.';
    }

    // A skill pre-approves tools; it must never resurrect one the user turned
    // off. Filtering here keeps disabled tools out of the activation state.
    final enabled = allTools.map((t) => t.name).toSet();
    final preApproved = skill.allowedTools
        .where(enabled.contains)
        .toList(growable: false);

    final buffer = StringBuffer()
      // First line is the scrape target, mirroring find_tools' `TOOL: <name>`.
      ..writeln('SKILL: ${skill.name}')
      ..writeln(
        'Loaded. Full instructions are now in your system prompt under '
        '"## ACTIVE SKILL: ${skill.name}".',
      )
      // The CONTINUATION block tells the model to give a final answer once
      // tool results satisfy the request. After a bare ack a model can read
      // that as "done" and skip the work the skill describes, so break that
      // reading explicitly.
      ..writeln(
        'This was a SETUP step, not the answer — follow those instructions '
        'now to complete the user\'s request.',
      );
    if (preApproved.isNotEmpty) {
      buffer.writeln(
        'Pre-approved tools (call directly, no find_tools): '
        '${preApproved.join(', ')}',
      );
    }
    return buffer.toString().trimRight();
  }

  /// Update the active workspace's instructions, name, or description.
  Future<String> _executeUpdateProject(Map<String, dynamic> args) async {
    final workspaceId = WorkspaceStorageService.selectedWorkspaceId;
    if (workspaceId == null) {
      return 'Error: No workspace is currently active. '
          'The user must select a workspace first.';
    }

    final instructions = (args['instructions'] as String?)?.trim();
    final name = (args['name'] as String?)?.trim();
    final description = (args['description'] as String?)?.trim();

    if ((instructions == null || instructions.isEmpty) &&
        (name == null || name.isEmpty) &&
        (description == null || description.isEmpty)) {
      return 'Error: At least one of "instructions", "name", or '
          '"description" must be provided.';
    }

    try {
      await WorkspaceStorageService.updateProject(
        workspaceId,
        name: (name != null && name.isNotEmpty) ? name : null,
        description: (description != null && description.isNotEmpty)
            ? description
            : null,
        customSystemPrompt: (instructions != null && instructions.isNotEmpty)
            ? instructions
            : null,
      );

      final parts = <String>[];
      if (instructions != null && instructions.isNotEmpty) {
        parts.add('instructions updated');
      }
      if (name != null && name.isNotEmpty) {
        parts.add('name changed to "$name"');
      }
      if (description != null && description.isNotEmpty) {
        parts.add('description updated');
      }
      return 'Workspace updated successfully: ${parts.join(', ')}. '
          'Changes take effect in the next message.';
    } catch (e) {
      return 'Error: Failed to update workspace: $e';
    }
  }

  /// Format a numbered list of options for the user to choose from.
  /// Returns the formatted question so the model can present it.
  String _executeAskUser(Map<String, dynamic> args) {
    final question = (args['question'] as String? ?? '').trim();
    if (question.isEmpty) {
      return 'Error: "question" parameter required';
    }

    final rawOptions = args['options'];
    List<String> options;
    if (rawOptions is List) {
      options = rawOptions.map((o) => o.toString().trim()).toList();
    } else if (rawOptions is String) {
      // Try JSON-decode in case model sends stringified list
      try {
        final decoded = jsonDecode(rawOptions);
        if (decoded is List) {
          options = decoded.map((o) => o.toString().trim()).toList();
        } else {
          return 'Error: "options" must be a list of strings';
        }
      } catch (_) {
        return 'Error: "options" must be a list of strings';
      }
    } else {
      return 'Error: "options" parameter required (list of 2-6 choices)';
    }

    if (options.length < 2 || options.length > 6) {
      return 'Error: provide 2-6 options, got ${options.length}';
    }

    final buf = StringBuffer();
    buf.writeln('QUESTION_FOR_USER: $question');
    buf.writeln();
    for (var i = 0; i < options.length; i++) {
      buf.writeln('${i + 1}) ${options[i]}');
    }
    buf.writeln();
    buf.writeln(
      'Present this question and these numbered options to the user. '
      'Wait for their reply before proceeding.',
    );
    return buf.toString().trimRight();
  }

  /// Wraps a handler's string output, inferring whether it reports a failure.
  ///
  /// The old rule was `output.startsWith('Error:')` — exact prefix, colon
  /// required. Around a hundred handler failure paths do not match it
  /// (`'Error getting route: …'`, `'Spotify error: …'`, `'Weather error: …'`,
  /// `'Failed to get Spotify access token.'`, …), so every one of them was
  /// reported to the user with a green success check AND handed to the model
  /// as a successful tool result — the model then answered from an error
  /// string as if it were data.
  ///
  /// This is still inference over prose and it is a stopgap. The real fix is
  /// for handlers to return `({String output, bool isError})` so the failure
  /// is stated rather than guessed; see [toolFailureSniffPattern] for what the
  /// stopgap actually matches. Handlers that return arbitrary upstream content
  /// (a file body, a raw API response) must pass `sniff: false`, otherwise a
  /// file that merely begins with the word "Error" is reported as a failure.

  /// A places lookup answers twice: text for the model, and a map card for
  /// the reader, attached as a produced block.
  ///
  /// The card comes from the same response the model reads, so it cannot
  /// disagree with the answer, and the model does not have to spend a turn
  /// copying coordinates into a `<map>` tag.
  ToolExecutionResult _placesResult(map_tools.PlacesToolResult result) {
    final mapTag = result.mapTag;
    return ToolExecutionResult(
      output: result.text,
      isError: false,
      producedBlocks: mapTag == null
          ? const []
          : <ContentBlock>[ContentBlock.text(mapTag)],
    );
  }

  ToolExecutionResult _wrapOutput(String output, {bool sniff = true}) {
    return ToolExecutionResult(
      output: output,
      isError: sniff && looksLikeToolFailure(output),
    );
  }

  /// Leading phrases the handlers actually use to report failure.
  ///
  /// Anchored at the start and deliberately narrow: `<Thing> error:` matches
  /// `Spotify error:` / `Weather error:` / `Web search error:` but not a
  /// sentence that merely mentions an error later on.
  static final RegExp toolFailureSniffPattern = RegExp(
    r'^\s*('
    r'Error\b'
    r'|Failed\b'
    r'|Unable to\b'
    r'|Unknown [A-Za-z_]+ (?:action|operation)\b'
    r'|Unknown operation\b'
    r'|Unsupported [A-Za-z]+ (?:method|action)\b'
    // "<Thing> error:" with at most three words before it, so a prose
    // sentence that merely reaches an "error:" later does not match.
    r'|[A-Z][A-Za-z0-9]*(?: [A-Za-z0-9]+){0,2} error(?: \(\d+\))?:'
    r'|[A-Za-z ]{0,20}not authenticated\b'
    r'|[A-Za-z ]{0,20}(?:token )?expired\b'
    r')',
  );

  @visibleForTesting
  static bool looksLikeToolFailure(String output) =>
      toolFailureSniffPattern.hasMatch(output);

  int _coerceInt(dynamic value, {required int fallback}) {
    if (value == null) return fallback;
    if (value is int) return value;
    if (value is num) return value.toInt();
    final parsed = int.tryParse(value.toString().trim());
    return parsed ?? fallback;
  }
}

// ---------------------------------------------------------------------------
// Artifact schema texts
// ---------------------------------------------------------------------------
//
// These strings are returned by the `artifact_schema` tool. They live here
// rather than in `tool_prompt_builder.dart` so the AI only sees the schema
// for the type it is actively producing — the system prompt stays small.

const String _excalidrawSchemaText = '''
# Excalidraw scene schema (content field for artifact_manager)

The `content` string MUST be valid JSON in the standard `.excalidraw`
file format (same shape as excalidraw.com export):

```json
{
  "type": "excalidraw",
  "version": 2,
  "source": "https://excalidraw.com",
  "elements": [
    {"type":"rectangle","id":"r1","x":100,"y":100,"width":200,"height":100,
     "strokeColor":"#1e1e1e","backgroundColor":"#a5d8ff","fillStyle":"solid",
     "strokeWidth":2,"roundness":{"type":3}},
    {"type":"text","id":"t1","x":150,"y":138,"width":100,"height":24,
     "text":"Client","fontSize":20,"fontFamily":1,"textAlign":"center",
     "strokeColor":"#1e1e1e"},
    {"type":"arrow","id":"a1","x":300,"y":150,"width":200,"height":0,
     "points":[[0,0],[200,0]],"endArrowhead":"arrow",
     "strokeColor":"#1e1e1e","strokeWidth":2}
  ],
  "appState":{"viewBackgroundColor":"#ffffff","gridSize":null},
  "files":{}
}
```

Rules:
- Top-level keys: type ("excalidraw"), version (2), source, elements (array, required), appState (object), files (object, usually {}).
- Coordinates: pixels, origin top-left, Y axis down.
- Required per element: type, id (unique string), x, y, width, height.
- Element types: rectangle, ellipse, diamond, line, arrow, text, freedraw, frame.
- Colours: hex ("#1e1e1e", "#a5d8ff") or "transparent".
  Stroke palette: #1e1e1e, #e03131, #2f9e44, #1971c2, #f08c00.
  Fill palette: #ffc9c9, #b2f2bb, #a5d8ff, #ffec99, #e9ecef.
- strokeWidth: 1 (thin), 2 (bold), 4 (extra bold).
- strokeStyle: "solid" | "dashed" | "dotted".
- fillStyle: "solid" | "hachure" (default) | "cross-hatch".
- roundness: {"type":3} for rounded corners, omit for sharp.
- angle: rotation in radians around element center (default 0).
- arrow points: array of [dx,dy] offsets relative to element x,y; start with [0,0]. endArrowhead: "arrow" (default) | "triangle" | "dot" | "bar" | null.
- text: text, fontSize (16/20/28/36), fontFamily (1=hand-drawn, 2=normal, 3=monospace), textAlign ("left"/"center"/"right"), verticalAlign ("top"/"middle").
- Do NOT include: seed, versionNonce, updated, groupIds (renderer ignores them).
- Target 5-30 elements per scene. >100 elements slow the renderer.

CRITICAL:
- Content must be VALID JSON — no trailing commas, no comments, no single quotes, no ```json fences around the JSON.
- Wrap the full JSON in the artifact_manager tool call as the `content` string argument. Do NOT wrap it in a code fence inside the content.
- PREFER `action: "rewrite"` over `action: "update"` for excalidraw artifacts. Excalidraw scenes have many repeated substrings (color hex codes, fontSize values, group IDs, identical "type": "rectangle" entries), so old_str matching almost always fails with "matches N places". Send the whole new scene JSON via rewrite — it is faster and more reliable than diffing.
''';

const String _technicalDrawingSchemaText = '''
# Technical drawing schema (content field for artifact_manager, type="technical_drawing")

DIN ISO 128-style engineering drawing. Content is JSON:

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
    {"type":"rect","lineStyle":"solid","weight":"thick","x":50,"y":30,"w":120,"h":80,"color":"#1e1e1e","fill":"#a5d8ff"},
    {"type":"circle","lineStyle":"solid","weight":"thick","cx":110,"cy":70,"r":15,"color":"#c92a2a"},
    {"type":"line","lineStyle":"centerline","weight":"thin","x1":85,"y1":70,"x2":135,"y2":70},
    {"type":"dimension","subtype":"linear_h","x1":50,"x2":170,"y":110,"offset":14,"value":"120"},
    {"type":"dimension","subtype":"linear_v","y1":30,"y2":110,"x":50,"offset":-14,"value":"80"},
    {"type":"dimension","subtype":"diameter","cx":110,"cy":70,"r":15,"angle":45,"value":"\\u00d8 30"},
    {"type":"note","x":50,"y":22,"text":"t = 10","color":"#2b8a3e"}
  ]
}
```

Rules:
- Coordinates in mm, origin top-left, Y-axis down.
- lineStyle: "solid" (visible edges), "dashed" (hidden edges), "centerline" (axes).
- weight: "thick" (body ~0.7mm) vs "thin" (dimensions/helpers ~0.25mm).
- Element types: rect (x,y,w,h), circle (cx,cy,r), line (x1,y1,x2,y2).
- Dimension subtypes: linear_h (x1,x2,y,offset,value), linear_v (y1,y2,x,offset,value), diameter (cx,cy,r,angle,value with \\u00d8 prefix).
- note: freeform text at (x,y).
- meta fields populate the DIN title block.
- Dimension all significant features, centerlines through circles and symmetry axes.
- Colors (optional): "color" sets stroke / text color on rect, circle, line, note. "fill" sets fill color on rect and circle (default: no fill). Both accept hex strings — "#RRGGBB", "#RGB", or "none". Default stroke/text color is black ("#000000"). Keep DIN drawings monochrome by default; only use color when the user asks for it (highlight features, layer-coded layouts, presentation drawings, schematics). Dimensions stay black per DIN convention.
''';

const String _typstSchemaText = '''
# Typst schema (source is the content for typst_compile, NOT artifact_manager)

Use the dedicated `typst_compile` tool for Typst — never `artifact_manager`. Source is plain Typst markup:

```typst
#set page(paper: "a4", margin: 2cm)
#set text(font: "Linux Libertine", size: 11pt)

= Titel
== Abschnitt

Fließtext mit Mathe: \$ a^2 + b^2 = c^2 \$

#table(
  columns: 2,
  [Name], [Wert],
  [Alpha], [1],
  [Beta], [2],
)
```

Rules:
- Start with #set page(paper: "a4") for A4 output.
- Math: \$ ... \$ inline, \$ ... \$ block.
- Headings: = Level 1, == Level 2.
- Use #set and #show for styling, never raw LaTeX.
- The server compiles the source and returns either the rendered PDF (stored encrypted) or the full compiler error — fix errors in-turn.
- artifact_id / title must describe CONTENT, not "pdf" / "document".
''';

const String _mermaidSchemaText = '''
# Mermaid schema (content for artifact_manager, type="mermaid")

Standard Mermaid diagram source. Example:

```
flowchart LR
    A[Client] -->|HTTP GET| B(Router)
    B --> C{DNS?}
    C -->|yes| D[DNS Server]
    C -->|no| E[Origin Server]
    D --> B
    E --> B
    B --> A
```

Supported graph types: flowchart, sequenceDiagram, classDiagram, stateDiagram-v2, erDiagram, journey, gantt, pie, mindmap, timeline.

Rules:
- Content is the Mermaid source ONLY (no code fence, no extra markdown).
- Keep diagrams under 40 nodes — anything bigger is hard to read.
- Use quoted node labels when the label contains spaces or punctuation: A["User Device"].
''';

const String _svgSchemaText = '''
# SVG schema (content for artifact_manager, type="svg")

Full SVG document as a string. Example:

```xml
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 400 300">
  <rect x="10" y="10" width="120" height="80" fill="#a5d8ff" stroke="#1e1e1e" stroke-width="2"/>
  <text x="70" y="55" font-family="sans-serif" font-size="16" text-anchor="middle">Client</text>
</svg>
```

Rules:
- Root <svg> MUST include xmlns="http://www.w3.org/2000/svg" and a viewBox.
- Avoid <script>, <foreignObject>, external <image href="https://...">, or remote fonts — the renderer is offline-only.
- Use viewBox (not width/height attrs) so the SVG scales in the artifact panel.
- For hand-drawn-style diagrams, use the excalidraw type instead.
''';
