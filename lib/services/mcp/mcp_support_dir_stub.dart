// lib/services/mcp/mcp_support_dir_stub.dart
//
// Web stub for the connector icon cache directory. The web build has no disk
// support directory, so this always returns null and the icon cache keeps
// only its in-memory half.

/// Null on web: there is no disk support directory to cache into.
Future<String?> mcpSupportDirPath() async => null;

/// No-op on web: there is no disk cache directory to delete.
Future<void> mcpDeleteDir(String path) async {}
