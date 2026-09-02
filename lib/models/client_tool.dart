import 'package:uuid/uuid.dart';

/// Represents a tool that can be executed client-side.
///
/// Tools are registered in [ToolRegistry] and executed by [ToolExecutor].
/// Each tool has tags for keyword-based discovery via the `find_tools` meta-tool.
class ClientTool {
  ClientTool({
    String? id,
    required this.name,
    required this.description,
    this.parameters = const {},
    this.type = ToolType.builtin,
    this.config = const {},
    this.tags = const [],
  }) : id = id ?? const Uuid().v4();

  final String id;
  final String name;
  final String description;
  final Map<String, dynamic> parameters;
  final ToolType type;
  final Map<String, String> config;
  final List<String> tags;

  Map<String, dynamic> toJson() => {
    'name': name,
    'description': description,
    'parameters': parameters,
    'type': type.name,
  };

  /// OpenAI-compatible function tool definition for native tool calling.
  ///
  /// [parameters] is expected to already be a JSON Schema object
  /// (`{type: object, properties: {...}, required: [...]}`). Built-in tools
  /// carry this shape directly; MCP tools pass through their native
  /// `inputSchema`. When a tool declares no parameters, a valid empty object
  /// schema is emitted so providers still accept the function definition.
  Map<String, dynamic> toOpenAiFunction() => {
    'type': 'function',
    'function': {
      'name': name,
      'description': description,
      'parameters': parameters.isEmpty
          ? {'type': 'object', 'properties': <String, dynamic>{}}
          : parameters,
    },
  };
}

/// Type of tool.
enum ToolType {
  builtin, // Built-in tools (calculator, time, weather, etc.)
  mcp, // Tools a connected remote MCP server offers
}

/// Tool categories for grouping and enabling/disabling.
enum ToolCategory {
  basic, // calculate, time, device info, random, etc.
  search, // Web search, web crawl, stock data, weather
  map, // Map search, geocoding, routing
  device, // Device features (GPS, calendar, alarms)
  bash, // Sandboxed shell commands (desktop only)
  github, // GitHub repos, issues, PRs
  slack, // Slack messaging
  google, // Google Calendar + Gmail
  email, // IMAP/SMTP email
  nextcloud, // Nextcloud files, calendar, contacts
  mcp, // Tools from connected remote MCP servers
  sandbox, // Code execution sandbox (Python/shell + files)
}
