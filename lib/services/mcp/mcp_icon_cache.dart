// lib/services/mcp/mcp_icon_cache.dart
//
// Connector logos, fetched once.
//
// The logos come from favicon services, so without a cache the list asks
// the network for the same sixteen images on every open — slow on a phone,
// and blank squares whenever the connection is poor. They are kept on disk
// under the app's own directory and read from memory after the first use.

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

// Connectors are native-only, but this file is reached from the settings
// tree that the web build also compiles — so no `dart:io` and no direct
// `path_provider` here. On web both resolve to stubs and the disk half of
// the cache turns into a no-op, leaving the memory cache.
import 'package:chuk_chat/utils/io_helper.dart';
import 'package:chuk_chat/utils/path_provider_stub.dart'
    if (dart.library.io) 'package:path_provider/path_provider.dart';

class McpIconCache {
  McpIconCache._();

  static const int _maxBytes = 256 * 1024;

  static final Map<String, Uint8List> _memory = <String, Uint8List>{};
  static Directory? _directory;

  /// Injected in tests, so nothing is downloaded.
  @visibleForTesting
  static http.Client? httpClient;

  /// The bytes of [url], from memory, then disk, then the network.
  /// Returns null when it cannot be had — the caller shows a fallback.
  static Future<Uint8List?> load(String url) async {
    final cached = _memory[url];
    if (cached != null) return cached;

    final file = await _fileFor(url);
    if (file != null && file.existsSync()) {
      try {
        final bytes = await file.readAsBytes();
        if (bytes.isNotEmpty) return _memory[url] = bytes;
      } catch (_) {
        // A half-written file is worth no more than a missing one.
      }
    }

    // Only a successful download is remembered. Caching the failure would
    // pin the icon to its fallback for the rest of the session, even once
    // the network is back.
    final bytes = await _download(url);
    if (bytes == null) return null;

    _memory[url] = bytes;
    if (file != null) {
      try {
        await file.writeAsBytes(bytes, flush: false);
      } catch (e) {
        if (kDebugMode) debugPrint('⚠️ [MCP] Could not cache an icon: $e');
      }
    }
    return bytes;
  }

  static Future<Uint8List?> _download(String url) async {
    final client = httpClient ?? http.Client();
    try {
      final response = await client
          .get(Uri.parse(url))
          .timeout(const Duration(seconds: 12));
      if (response.statusCode != 200) return null;
      if (response.bodyBytes.isEmpty ||
          response.bodyBytes.length > _maxBytes) {
        return null;
      }
      return response.bodyBytes;
    } catch (_) {
      return null;
    } finally {
      if (httpClient == null) client.close();
    }
  }

  static Future<File?> _fileFor(String url) async {
    if (kIsWeb) return null;
    try {
      final dir = _directory ??= await _openDirectory();
      final name = sha1.convert(utf8.encode(url)).toString();
      return File('${dir.path}/$name');
    } catch (_) {
      return null;
    }
  }

  static Future<Directory> _openDirectory() async {
    final support = await getApplicationSupportDirectory();
    final dir = Directory('${support.path}/mcp_icons');
    if (!dir.existsSync()) await dir.create(recursive: true);
    return dir;
  }

  /// Forget everything, on disk and in memory.
  static Future<void> clear() async {
    _memory.clear();
    final dir = _directory;
    if (dir != null && dir.existsSync()) {
      try {
        await dir.delete(recursive: true);
      } catch (_) {
        // Nothing to do — the cache is a convenience, not a store.
      }
      _directory = null;
    }
  }
}
