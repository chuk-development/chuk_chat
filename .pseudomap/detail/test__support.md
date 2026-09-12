# test/support · Signatures

## test/support/kv_cache_test_env.dart  (54 Z.)

- L14 `class _FakePathProvider extends PathProviderPlatform with MockPlatformInterfaceMixin`
  - L16 `_FakePathProvider(this.dir)`
  - L18 `final String dir`
  - L21 `Future<String?> getApplicationSupportPath()`
  - L24 `Future<String?> getApplicationDocumentsPath()`
  - L27 `Future<String?> getTemporaryPath()`
- L31 `void initSqfliteFfi()`  — Initialise the sqflite FFI backend once. Safe to call repeatedly.
- L39 `Future<Directory> useTempKvCache()`  — Point LocalChatCacheService's SQLite DB at a fresh temp dir and drop any
- L48 `Future<void> disposeTempKvCache(Directory tempDir)`  — Drop the cached DB handle and remove [tempDir]. Call from tearDown.
