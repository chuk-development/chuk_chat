/// Asking the host to dial the connectors now.
///
/// The device signs an MCP server in (an OAuth consent screen needs a person in
/// front of it) but never speaks MCP: the host does, with the credentials the
/// device forwards. So the device cannot know what a connector holds, and the
/// connector list said "0 tools" about servers that were connected and working.
///
/// This is the request half. The answer arrives as one terminal `mcp_tools`
/// frame and lands in [McpService.applyToolsFrame].
library;

abstract interface class McpProbeControl {
  /// Dial [servers] (the same projection the task frame carries) and answer
  /// with what each one holds.
  Future<void> probeMcpServers(List<Map<String, dynamic>> servers);
}
