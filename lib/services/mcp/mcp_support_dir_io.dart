// lib/services/mcp/mcp_support_dir_io.dart
//
// Native path for the connector icon cache directory.

import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// The absolute path of the app support directory on a native build.
Future<String?> mcpSupportDirPath() async {
  final dir = await getApplicationSupportDirectory();
  return dir.path;
}

/// Delete the directory at [path] and everything under it. Native-only, so the
/// `dart:io`-only `Directory.delete` stays out of the web bundle.
Future<void> mcpDeleteDir(String path) async {
  final dir = Directory(path);
  if (dir.existsSync()) await dir.delete(recursive: true);
}
