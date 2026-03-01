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
}

/// Type of tool.
enum ToolType {
  builtin, // Built-in tools (calculator, time, weather, etc.)
}

/// Tool categories for grouping and enabling/disabling.
enum ToolCategory {
  basic, // calculate, time, device info, random, etc.
  search, // Web search, web crawl, stock data, weather
  map, // Map search, geocoding, routing
  device, // Device features (GPS, calendar, alarms)
}
