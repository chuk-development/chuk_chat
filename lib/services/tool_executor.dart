import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'package:chuk_chat/models/client_tool.dart';
import 'package:chuk_chat/services/api_config_service.dart';
import 'package:chuk_chat/services/tool_registry.dart' as registry;
import 'package:chuk_chat/tool_handlers/calculate_handler.dart' as calculate;
import 'package:chuk_chat/tool_handlers/find_tools_handler.dart' as find_tools;
import 'package:chuk_chat/tool_handlers/image_tools.dart' as image_tools;
import 'package:chuk_chat/tool_handlers/map_tools.dart' as map_tools;
import 'package:chuk_chat/tool_handlers/notes_tools.dart' as notes_tools;
import 'package:chuk_chat/tool_handlers/qr_tools.dart' as qr_tools;
import 'package:chuk_chat/tool_handlers/stock_tools.dart' as stock_tools;
import 'package:chuk_chat/tool_handlers/weather_tools.dart' as weather_tools;
import 'package:chuk_chat/tool_handlers/web_tools.dart' as web_tools;

class ToolExecutionResult {
  const ToolExecutionResult({required this.output, required this.isError});

  final String output;
  final bool isError;
}

/// Service to execute tools client-side.
///
/// This is the central coordinator that dispatches to individual tool
/// handlers. Adapted from the function_calling repo for chuk_chat.
class ToolExecutor {
  final Map<String, ClientTool> _tools = {};
  final Map<String, bool> _enabledTools = {};
  final Map<String, String> _customToolDescriptions = {};
  Future<void>? _loadPrefsFuture;

  static const Set<String> _builtinExecutableToolNames = {
    'find_tools',
    'calculate',
    'get_time',
    'get_device_info',
    'random_number',
    'flip_coin',
    'roll_dice',
    'countdown',
    'password_generator',
    'uuid_generator',
    'notes',
    'generate_qr',
    'ask_user',
    'web_search',
    'web_crawl',
    'generate_image',
    'edit_image',
    'fetch_image',
    'view_chat_images',
    'stock_data',
    'weather',
    'search_places',
    'search_restaurants',
    'geocode',
    'get_route',
  };

  static const Set<String> _defaultDisabledTools = {};

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
  }

  Future<void> setToolEnabled(String name, bool enabled) async {
    if (!_tools.containsKey(name) || name == 'find_tools') {
      return;
    }

    _enabledTools[name] = enabled;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('tool_enabled_$name', enabled);
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
  }

  /// Get only active tools -- this is what gets sent to the LLM.
  List<ClientTool> get allTools {
    return _tools.values.where((tool) {
      if (tool.name == 'find_tools') return true; // Always available
      return isToolAvailable(tool.name);
    }).toList();
  }

  /// Check if a specific tool is available.
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
      case 'get_device_info':
        return ToolExecutionResult(
          output:
              'Platform: ${_platformName()}\n'
              'Web: ${kIsWeb ? 'yes' : 'no'}\n'
              'Mode: ${kDebugMode ? 'debug' : 'release'}\n'
              'Framework: Flutter',
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
      case 'edit_image':
        return _wrapOutput(
          await image_tools.executeEditImage(
            serverHttpUrl: serverHttpUrl,
            accessToken: accessToken,
            args: args,
          ),
        );
      case 'fetch_image':
        return _wrapOutput(await image_tools.executeFetchImage(args));
      case 'view_chat_images':
        return _wrapOutput(image_tools.executeViewChatImagesUnsupported());
      case 'stock_data':
        return _wrapOutput(await stock_tools.executeStockData(args));

      // -- Maps --
      case 'search_places':
        return _wrapOutput(await map_tools.executeSearchPlaces(args));
      case 'search_restaurants':
        return _wrapOutput(await map_tools.executeSearchRestaurants(args));
      case 'geocode':
        return _wrapOutput(await map_tools.executeGeocode(args));
      case 'get_route':
        return _wrapOutput(await map_tools.executeGetRoute(args));

      // -- Weather --
      case 'weather':
        return _wrapOutput(await weather_tools.executeWeather(args));

      default:
        return ToolExecutionResult(
          output: 'Error: Unknown builtin tool: $name',
          isError: true,
        );
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

  ToolExecutionResult _wrapOutput(String output) {
    return ToolExecutionResult(
      output: output,
      isError: output.startsWith('Error:'),
    );
  }

  int _coerceInt(dynamic value, {required int fallback}) {
    if (value == null) return fallback;
    if (value is int) return value;
    if (value is num) return value.toInt();
    final parsed = int.tryParse(value.toString().trim());
    return parsed ?? fallback;
  }

  String _platformName() {
    if (kIsWeb) {
      return 'web';
    }

    return switch (defaultTargetPlatform) {
      TargetPlatform.android => 'android',
      TargetPlatform.iOS => 'ios',
      TargetPlatform.macOS => 'macos',
      TargetPlatform.windows => 'windows',
      TargetPlatform.linux => 'linux',
      TargetPlatform.fuchsia => 'fuchsia',
    };
  }
}
