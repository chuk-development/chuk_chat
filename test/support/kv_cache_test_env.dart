// Shared test harness for anything that reads or writes the SQLite
// `kv_cache` through LocalChatCacheService — model catalogue cache, MCP
// connections and the sidebar title list all moved there out of
// SharedPreferences. Points the cache DB at a throwaway temp dir per test.

import 'dart:io';

import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:chuk_chat/services/local_chat_cache_service.dart';

class _FakePathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _FakePathProvider(this.dir);

  final String dir;

  @override
  Future<String?> getApplicationSupportPath() async => dir;

  @override
  Future<String?> getApplicationDocumentsPath() async => dir;

  @override
  Future<String?> getTemporaryPath() async => dir;
}

/// Initialise the sqflite FFI backend once. Safe to call repeatedly.
void initSqfliteFfi() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
}

/// Point LocalChatCacheService's SQLite DB at a fresh temp dir and drop any
/// cached handle from a previous test. Returns the temp dir so the caller can
/// delete it in tearDown.
Future<Directory> useTempKvCache() async {
  initSqfliteFfi();
  final tempDir = await Directory.systemTemp.createTemp('kv_cache_test');
  PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
  await LocalChatCacheService.debugReset();
  return tempDir;
}

/// Drop the cached DB handle and remove [tempDir]. Call from tearDown.
Future<void> disposeTempKvCache(Directory tempDir) async {
  await LocalChatCacheService.debugReset();
  if (tempDir.existsSync()) {
    tempDir.deleteSync(recursive: true);
  }
}
