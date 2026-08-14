// lib/services/mcp/mcp_tool_bridge.dart
//
// Connected servers become ordinary tools.
//
// Nothing about MCP reaches the model: its tools are registered with the
// same executor the built-in ones use, so they are found through
// `find_tools` and called through the same path. That also keeps them out
// of every prompt — a server with forty tools costs nothing until the
// model goes looking for one.

import 'package:chuk_chat/models/client_tool.dart';
import 'package:chuk_chat/services/mcp/mcp_service.dart';
import 'package:chuk_chat/services/tool_executor.dart';

/// Register the tools of every connected server, replacing whatever was
/// registered before.
void syncMcpTools(ToolExecutor executor) {
  for (final tool in executor.allRegisteredTools) {
    if (tool.type == ToolType.mcp) executor.unregisterTool(tool.name);
  }

  for (final connection in McpService.connections.value) {
    for (final tool in connection.tools) {
      final name = connection.toolNameFor(tool.name);
      executor.registerTool(
        ClientTool(
          name: name,
          description: tool.description.trim().isEmpty
              ? '${connection.name}: ${tool.name}'
              : '${connection.name}: ${tool.description}',
          parameters: tool.inputSchema,
          type: ToolType.mcp,
          tags: _tagsFor(connection.name, connection.id, tool.name),
        ),
      );
    }
  }
}

/// Keep an executor in step with the connections for as long as it lives.
void watchMcpConnections(ToolExecutor executor) {
  McpService.connections.addListener(() => syncMcpTools(executor));
}

/// What `find_tools` matches on: the server, and the words of the tool name.
List<String> _tagsFor(String serverName, String id, String toolName) {
  final words = toolName
      .toLowerCase()
      .split(RegExp(r'[^a-z0-9]+'))
      .where((w) => w.length > 2);
  return <String>{
    id,
    ...serverName.toLowerCase().split(RegExp(r'\s+')),
    ...words,
    'mcp',
    'connector',
  }.where((tag) => tag.isNotEmpty).toList();
}
