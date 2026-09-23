# test · Signaturen

## test/chat_cache_no_eager_full_read_test.dart  (80 Z.)
- L17 `File _lib(String relative)`
- L19 `Iterable<File> _dartFilesIn(String directory)`
- L29 `void main()`

## test/fastlane_metadata_test.dart  (162 Z.)
- L10 `_metadataRoot = 'fastlane/metadata/android'`
- L13 `_titleLimit = 30`  — Play's own limits for a store listing.
- L14 `_shortDescriptionLimit = 80`
- L15 `_fullDescriptionLimit = 4000`
- L16 `_changelogLimit = 500`
- L19 `_minScreenshotSide = 320`  — Play rejects a screenshot with any side below 320 px or above 3840 px.
- L20 `_maxScreenshotSide = 3840`
- L22 `List<Directory> _locales()`
- L30 `_pngSignature = <int>[ 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, ]`  — The first eight bytes of every PNG.
- L38 `({int width, int height}) _pngSize(File file)`  — Width and height out of a PNG's IHDR chunk, which always starts at byte 16.
- L54 `void main()`

## test/local_chat_cache_compression_test.dart  (271 Z.)
- L16 `class _FakePathProvider extends PathProviderPlatform with MockPlatformInterfaceMixin`
  - L18 `_FakePathProvider(this.dir)`
  - L20 `final String dir`
  - L23 `Future<String?> getApplicationSupportPath()`
  - L26 `Future<String?> getApplicationDocumentsPath()`
  - L29 `Future<String?> getTemporaryPath()`
- L34 `String _buildPayload({int messages = 6, int resultChars = 20000})`  — A chat payload of roughly [messages] messages carrying a fat tool
- L50 `void main()`

## test/token_activity_stats_test.dart  (424 Z.)
- L8 `UsageLogEntry _entry(DateTime? createdAt, {int tokens = 10})`  — Minimal usage entry for the stats math: only [createdAt] and the token
- L22 `DateTime _d(int year, int month, int day)`  — A local-date midnight, so tests never depend on the machine timezone.
- L24 `void main()`

## test/tray_action_bus_test.dart  (30 Z.)
- L5 `void main()`

## test/verify_languages.dart  (19 Z.)
- L4 `void main()`
