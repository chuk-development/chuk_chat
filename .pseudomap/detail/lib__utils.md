# lib/utils · Signatures

## lib/utils/api_rate_limiter.dart  (248 Z.)

- L4 `class RateLimitConfig`  — API rate limiting configuration for different endpoint types.
  - L5 `final int maxRequests`
  - L6 `final Duration timeWindow`
  - L7 `final Duration minRequestInterval`
  - L9 `const RateLimitConfig({ required this.maxRequests, required this.timeWindow, this.minRequestInterval = const Duration(milliseconds: 100), })`
  - L16 `static const chat = RateLimitConfig( maxRequests: 30, timeWindow: Duration(minutes: 1), minRequestInterval: Duration(milliseconds: 500), )`  — Default config for chat API requests (30 requests per minute)
  - L23 `static const fileConversion = RateLimitConfig( maxRequests: 10, timeWindow: Duration(minutes: 5), minRequestInterval: Duration(seconds: 1), )`  — Config for file conversion API (10 requests per 5 minutes)
  - L30 `static const general = RateLimitConfig( maxRequests: 60, timeWindow: Duration(minutes: 1), minRequestInterval: Duration(milliseconds: 200), )`  — Config for general API requests (60 requests per minute)
- L38 `class RateLimitResult`  — Result of a rate limit check.
  - L39 `final bool allowed`
  - L40 `final String? errorMessage`
  - L41 `final Duration? retryAfter`
  - L42 `final int requestsRemaining`
  - L44 `const RateLimitResult({ required this.allowed, this.errorMessage, this.retryAfter, required this.requestsRemaining, })`
  - L51 `factory RateLimitResult.allowed(int requestsRemaining)`
  - L55 `factory RateLimitResult.denied({ required String message, required Duration retryAfter, required int requestsRemaining, })`
- L70 `class ApiRateLimiter`  — Manages API rate limiting with per-endpoint and per-user tracking.
  - L71 `ApiRateLimiter._()`
  - L73 `static final ApiRateLimiter _instance = ApiRateLimiter._()`
  - L74 `factory ApiRateLimiter()`
  - L77 `final Map<String, Map<String, List<DateTime>>> _requestHistory = {}`  — Track requests by endpoint and user
  - L80 `final Map<String, DateTime> _lastRequestTime = {}`  — Track last request time for minimum interval enforcement
  - L83 `RateLimitResult checkRateLimit({ required String endpoint, required String userId, required RateLimitConfig config, })`  — Check if a request is allowed based on rate limits.
  - L135 `void recordRequest({required String endpoint, required String userId})`  — Record a successful request.
  - L149 `int getRequestsRemaining({ required String endpoint, required String userId, required RateLimitConfig config, })`  — Get the number of requests remaining for a user on an endpoint.
  - L166 `Duration? getTimeUntilReset({ required String endpoint, required String userId, required RateLimitConfig config, })`  — Get time until rate limit resets.
  - L193 `void clearUserHistory(String userId)`  — Clear rate limit history for a user (useful for testing or admin actions).
  - L201 `void clearAllHistory()`  — Clear all rate limit history.
  - L207 `String _formatDuration(Duration duration)`  — Format duration for user-friendly display.
  - L218 `void logRateLimitStatus({ required String endpoint, required String userId, required RateLimitConfig config, })`  — Log rate limit status (debug mode only).

## lib/utils/arch_helper.dart  (4 Z.)

- conditional export: 'arch_helper_stub.dart' if (dart.library.ffi) 'arch_helper_native.dart'

## lib/utils/arch_helper_native.dart  (43 Z.)

- L12 `String getCurrentArch()`  — Returns the CPU architecture string for the current platform.

## lib/utils/arch_helper_stub.dart  (7 Z.)

- L6 `String getCurrentArch()`  — Returns the CPU architecture string for the current platform.

## lib/utils/artifact_tag_parser.dart  (141 Z.)

- L18 `class ParsedArtifactTag`  — A single `<artifact>` tag parsed out of assistant text.
  - L19 `ParsedArtifactTag({ required this.id, required this.type, required this.title, required this.content, this.language, required this.matchStart, required this.matchEnd, })`
  - L29 `final String id`
  - L30 `final String type`
  - L31 `final String title`
  - L32 `final String content`
  - L33 `final String? language`
  - L34 `final int matchStart`
  - L35 `final int matchEnd`
- L44 `_artifactBlockPattern = RegExp( r'''<\s*artifact\b((?:[^>"'\u201C\u201D\u2018\u2019]|"[^"]*"|'[^']*'|\u201C[^\u201D]*\u2`
- L49 `_artifactStartPattern = RegExp( r'<\s*artifact\b', caseSensitive: false, )`
- L55 `_attrPattern = RegExp( r'''(\w+)\s*=\s*(?:"([^"]*)"|'([^']*)'|\u201C([^\u201D]*)\u201D|\u2018([^\u2019]*)\u2019)''', )`
- L61 `_leadingCodeFence = RegExp( r'^\s*```(?:[a-zA-Z_][\w+\-]*)?\s*\r?\n', )`
- L64 `_trailingCodeFence = RegExp(r'\r?\n\s*```\s*$')`
- L68 `List<ParsedArtifactTag> parseArtifactTags(String text)`  — Returns all complete `<artifact>` blocks found in [text]. Partial
- L118 `String _stripWrappingFence(String content)`  — Strip a single surrounding "```lang\n … \n```" fence if present. Leaves
- L128 `String stripArtifactTagsForDisplay( String content, { bool stripIncomplete = true, })`  — Strips complete `<artifact>...</artifact>` blocks from [content]. When

## lib/utils/build_info.dart  (44 Z.)

- L12 `class BuildInfo`
  - L13 `BuildInfo._()`
  - L16 `static const String buildTimestampRaw = String.fromEnvironment('BUILD_TIMESTAMP')`  — Raw value from --dart-define=BUILD_TIMESTAMP=...
  - L20 `static DateTime? get buildTimestamp`  — Parsed UTC build timestamp, or null if not provided / invalid.
  - L33 `static String? formatted({DateTime? now})`  — Formatted display string `yyyy-MM-dd HH:mm UTC`, or null when

## lib/utils/certificate_pinning.dart  (127 Z.)

- L6 `class CertificatePin`  — Certificate pin configuration for a domain.
  - L7 `final String domain`
  - L8 `final List<String> sha256Hashes`
  - L9 `final bool includeSubdomains`
  - L11 `const CertificatePin({ required this.domain, required this.sha256Hashes, this.includeSubdomains = false, })`
- L30 `class CertificatePinning`  — Manages SSL certificate pinning for secure API communications.
  - L31 `CertificatePinning._()`
  - L34 `static bool get isEnabled`  — Whether certificate pinning is enabled (production only).
  - L38 `static void Function(Dio dio, List<CertificatePin> pins)? _nativeConfigurator`  — IO-level Dio configurator. Set by [registerNativeConfigurator] from
  - L42 `static void registerNativeConfigurator( void Function(Dio dio, List<CertificatePin> pins) configurator, )`  — Register the native (dart:io) Dio configurator.
  - L53 `static final List<CertificatePin> _pins = [ CertificatePin( domain: 'api.chuk.chat', sha256Hashes: [ 'KmvfH2LK5C+SyrlN/6GezJzEQ0JHBMRgDkfPxpp5tGU=', // Leaf certificate 'HfwWBfutNY2LyET3bRUgP6ycpcGnn9SFf/ryhk++v5Y=', // Intermediate CA (backup) ], includeSubdomains: true, ), ]`  — Certificate pins for known domains.
  - L69 `static void configureDio(Dio dio)`  — Configure Dio instance with certificate pinning.
  - L102 `static Dio createSecureDio({ String? baseUrl, Map<String, dynamic>? headers, Duration? connectTimeout, Duration? receiveTimeout, Duration? sendTimeout, })`  — Create a Dio instance with certificate pinning pre-configured.
  - L124 `static List<CertificatePin> get configuredPins`  — Get all configured pins.

## lib/utils/certificate_pinning_io.dart  (83 Z.)

- L23 `void configureDioWithPinning(Dio dio, List<CertificatePin> pins)`  — Configure Dio with a [badCertificateCallback] that validates
- L35 `void _installBadCertCallback(HttpClient client, List<CertificatePin> pins)`
- L72 `List<int> _sha256Sync(List<int> data)`  — Synchronous SHA-256 hash.
- L78 `HttpClient createPinnedHttpClient(List<CertificatePin> pins)`  — Create an [HttpClient] with certificate pinning configured.

## lib/utils/certificate_pinning_register.dart  (9 Z.)

- conditional export: 'certificate_pinning_register_stub.dart' if (dart.library.io) 'certificate_pinning_register_io.dart'

## lib/utils/certificate_pinning_register_io.dart  (80 Z.)

- L19 `_trustedToolApiHosts = { // OpenStreetMap / Nominatim (maps, geocoding) 'nominatim.openstreetmap.org', // OSRM (routing)`  — Trusted public API hosts used by built-in tools (weather, maps, etc.).
- L39 `class _WindowsCertOverrides extends HttpOverrides`  — [HttpOverrides] that accepts certificates for known trusted public API
  - L41 `HttpClient createHttpClient(SecurityContext? context)`
- L62 `void registerCertificatePinning()`  — Register the native certificate pinning configurator.

## lib/utils/certificate_pinning_register_stub.dart  (10 Z.)

- L7 `void registerCertificatePinning()`  — No-op on web. The browser's TLS stack validates certificates.

## lib/utils/chat_font_resolver.dart  (72 Z.)

- L11 `kFontFamilyArimo = 'Arimo'`  — Family name of the bundled Arimo font (see `pubspec.yaml`).
- L14 `kFontFamilyMerriweather = 'Merriweather'`  — Family name of the bundled Merriweather font (see `pubspec.yaml`).
- L17 `kFontFamilyJetBrainsMono = 'JetBrains Mono'`  — Family name of the bundled JetBrains Mono font (see `pubspec.yaml`).
- L22 `String? resolveChatFontFamily(String id)`  — Map a stored identifier (e.g. `'arimo'`) to a font family string usable
- L39 `String sanitizeChatFontFamily(String? id)`  — Normalize an unknown id (e.g. from Supabase) back to a known value so the
- L50 `String? resolveUiFontFamily(String? id)`  — Map a stored UI-font identifier to a font family string for
- L66 `String sanitizeUiFontFamily(String? id)`  — Normalize an unknown UI-font id back to a supported value. Defaults to the

## lib/utils/client_platform.dart  (26 Z.)

- L9 `String clientPlatformName()`  — Human-readable name of the current client platform.

## lib/utils/clipboard_text_sanitizer.dart  (64 Z.)

- L3 `class ClipboardTextSanitizer`
  - L4 `const ClipboardTextSanitizer._()`
  - L6 `static final RegExp _markdownImageDataUrlPattern = RegExp( r'!\[[^\]]*\]\(\s*data:image\\?/[a-zA-Z0-9.+-]+;base64,[^)]+\)', caseSensitive: false, )`
  - L11 `static final RegExp _imageDataUrlPattern = RegExp( r'''data:image\\?/[a-zA-Z0-9.+-]+;base64,[^"'\s)\]]+''', caseSensitive: false, )`
  - L16 `static bool containsImageData(String text)`
  - L25 `static String sanitize(String text)`
  - L50 `static Future<void> sanitizeClipboardInPlace()`  — Reads the current clipboard text and, if it contains embedded base64 image

## lib/utils/color_extensions.dart  (62 Z.)

- L5 `extension ColorExtension on Color`  — Helper extension to subtly lighten or darken colors.
  - L6 `Color lighten([double amount = .1])`
  - L15 `Color darken([double amount = .1])`
  - L23 `String toHexString()`
  - L31 `static Color fromHexString(String? hexString, {Color? fallback})`

## lib/utils/debug_chat_formatter.dart  (260 Z.)

- L13 `class DebugChatFormatter`  — Formats the full chat message list as a debug-friendly text string.
  - L14 `const DebugChatFormatter._()`
  - L16 `static const int _maxContextValueChars = 220`
  - L17 `static const int _maxReasoningChars = 400`
  - L18 `static const int _maxMessageTextChars = 2200`
  - L19 `static const int _maxToolArgsChars = 320`
  - L20 `static const int _maxToolResultChars = 250`
  - L21 `static const int _maxAttachmentsChars = 420`
  - L24 `static void _noop(Object? _)`
  - L26 `static int _countImages(String rawImages)`
  - L41 `static String _truncateForExport(String value, {required int maxChars})`
  - L60 `static String format( List<Map<String, String>> messages, { Map<String, String>? context, })`  — Format a list of message maps (as used by chat UIs) into a debug string.

## lib/utils/desktop_drop_stub.dart  (36 Z.)

- L5 `class DropTarget extends StatelessWidget`
  - L6 `final Widget child`
  - L7 `final void Function(DropDoneDetails)? onDragDone`
  - L8 `final void Function(DropEventDetails)? onDragEntered`
  - L9 `final void Function(DropEventDetails)? onDragExited`
  - L11 `const DropTarget({ super.key, required this.child, this.onDragDone, this.onDragEntered, this.onDragExited, })`
  - L20 `Widget build(BuildContext context)`
- L23 `class DropDoneDetails`
  - L24 `final List<XFile> files`
  - L25 `DropDoneDetails({required this.files})`
- L28 `class DropEventDetails`
  - L29 `DropEventDetails()`
- L32 `class XFile`
  - L33 `final String path`
  - L34 `XFile(this.path)`

## lib/utils/exponential_backoff.dart  (205 Z.)

- L5 `class BackoffConfig`  — Configuration for exponential backoff retry logic.
  - L6 `final int maxRetries`
  - L7 `final Duration initialDelay`
  - L8 `final Duration maxDelay`
  - L9 `final double multiplier`
  - L10 `final double jitter`
  - L12 `const BackoffConfig({ this.maxRetries = 3, this.initialDelay = const Duration(seconds: 1), this.maxDelay = const Duration(seconds: 30), this.multiplier = 2.0, this.jitter = 0.1, })`
  - L21 `static const chat = BackoffConfig( maxRetries: 3, initialDelay: Duration(milliseconds: 500), maxDelay: Duration(seconds: 10), )`  — Default config for chat requests
  - L28 `static const fileUpload = BackoffConfig( maxRetries: 3, initialDelay: Duration(seconds: 2), maxDelay: Duration(minutes: 1), )`  — Config for file uploads (longer delays)
  - L35 `static const critical = BackoffConfig( maxRetries: 5, initialDelay: Duration(milliseconds: 500), maxDelay: Duration(seconds: 30), )`  — Config for critical operations (more retries)
- L43 `class BackoffResult<T>`  — Result of a backoff operation.
  - L44 `final T? data`
  - L45 `final bool success`
  - L46 `final String? error`
  - L47 `final int attempts`
  - L48 `final Duration totalDuration`
  - L50 `const BackoffResult({ this.data, required this.success, this.error, required this.attempts, required this.totalDuration, })`
  - L58 `factory BackoffResult.success(T data, int attempts, Duration duration)`
  - L67 `factory BackoffResult.failure(String error, int attempts, Duration duration)`
- L78 `class ExponentialBackoff`  — Handles exponential backoff for failed API requests.
  - L85 `static Future<BackoffResult<T>> execute<T>({ required Future<T> Function() operation, BackoffConfig config = const BackoffConfig(), bool Function(dynamic error)? shouldRetry, void Function(int attempt, Duration delay, dynamic error)? onRetry, })`  — Execute an operation with exponential backoff retry logic.
  - L146 `static Duration _calculateDelay(int attempt, BackoffConfig config)`  — Calculate delay for a given attempt with exponential backoff and jitter.
  - L169 `static bool shouldRetryError(dynamic error)`  — Determine if an error should trigger a retry based on common scenarios.

## lib/utils/file_upload_validator.dart  (461 Z.)

- L8 `class FileValidationResult`  — File upload validation result.
  - L9 `final bool isValid`
  - L10 `final String? errorMessage`
  - L11 `final int? fileSizeBytes`
  - L12 `final String? mimeType`
  - L14 `const FileValidationResult({ required this.isValid, this.errorMessage, this.fileSizeBytes, this.mimeType, })`
  - L21 `factory FileValidationResult.success({ required int fileSizeBytes, String? mimeType, })`
  - L32 `factory FileValidationResult.error(String message)`
- L38 `class FileUploadValidator`  — Utility for validating file uploads to prevent security issues.
  - L39 `FileUploadValidator._()`
  - L42 `static const int maxFileSizeBytes = 10 * 1024 * 1024`  — Maximum file size in bytes (10MB)
  - L45 `static const int maxArchiveEntries = 1000`  — Maximum number of files in an archive
  - L48 `static const int maxArchiveUncompressedSize = 50 * 1024 * 1024`  — Maximum uncompressed size for archives (50MB)
  - L51 `static const Map<String, List<String>> extensionToMimeTypes = { // Documents 'pdf': ['application/pdf'], 'doc': ['application/msword'], 'docx': [ 'application/vnd.openxmlformats-officedocument.wordprocessingml.document', ], 'xls': ['application/vnd.ms-excel'], 'xlsx': [ 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', ], 'ppt': ['application/vnd.ms-powerpoint'], 'pptx': [ 'application/vnd.openxmlformats-officedocument.presentationml.presentation', ], 'odt': ['application/vnd.oasis.opendocument.text'], 'ods': ['application/vnd.oasis.opendocument.spreadsheet'], 'odp': ['application/vnd.oasis.opendocument.presentation'], // Text formats 'txt': ['text/plain'], 'csv': ['text/csv', 'application/csv'], 'json': ['application/json'], 'xml': ['application/xml', 'text/xml'], 'html': ['text/html'], 'htm': ['text/html'], 'md': ['text/markdown', 'text/plain'], 'markdown': ['text/markdown', 'text/plain'], // Images 'png': ['image/png'], 'jpg': ['image/jpeg'], 'jpeg': ['image/jpeg'], 'gif': ['image/gif'], 'bmp': ['image/bmp'], 'tiff': ['image/tiff'], 'tif': ['image/tiff'], 'webp': ['image/webp'], // Audio 'wav': ['audio/wav', 'audio/wave'], 'mp3': ['audio/mpeg'], 'm4a': ['audio/mp4', 'audio/x-m4a'], 'aac': ['audio/aac'], 'flac': ['audio/flac'], 'ogg': ['audio/ogg'], // Archives 'zip': ['application/zip', 'application/x-zip-compressed'], // E-books 'epub': ['application/epub+zip'], // Email 'msg': ['application/vnd.ms-outlook'], 'eml': ['message/rfc822'], // Code files 'py': ['text/x-python', 'text/plain'], 'js': ['application/javascript', 'text/javascript', 'text/plain'], 'ts': ['application/typescript', 'text/typescript', 'text/plain'], 'java': ['text/x-java-source', 'text/plain'], 'c': ['text/x-c', 'text/plain'], 'cpp': ['text/x-c++', 'text/plain'], 'go': ['text/x-go', 'text/plain'], 'rs': ['text/x-rust', 'text/plain'], 'rb': ['text/x-ruby', 'text/plain'], 'php': ['application/x-php', 'text/x-php', 'text/plain'], 'yaml': ['application/x-yaml', 'text/yaml', 'text/plain'], 'yml': ['application/x-yaml', 'text/yaml', 'text/plain'], }`  — MIME type mappings for common file extensions
  - L130 `static Future<FileValidationResult> validateFile(String filePath)`  — Validates a file before upload.
  - L205 `static Future<String?> _detectMimeType(File file, String extension)`  — Detects MIME type by reading file magic bytes.
  - L274 `static bool _isLikelyTextFile(List<int> bytes)`  — Checks if bytes are likely from a text file.
  - L297 `static Future<FileValidationResult> _validateArchive(File file)`  — Validates archive files to prevent zip bombs and malicious content.
  - L352 `static const int maxImageFileSizeBytes = 20 * 1024 * 1024`  — Maximum image file size in bytes (20MB — images are compressed before upload,
  - L362 `static FileValidationResult validateImageBytes( Uint8List bytes, String fileName, )`  — Validates image bytes by checking magic bytes and size.
  - L391 `static String? _detectImageMimeFromBytes(Uint8List bytes)`  — Detects image MIME type from raw bytes using magic byte signatures.
  - L451 `static String formatFileSize(int bytes)`  — Formats file size in human-readable format.

## lib/utils/format_bytes.dart  (21 Z.)

- L7 `String formatBytes(int bytes)`  — Formats a byte count for a reader: `842 B`, `1.5 KB`, `12 MB`.

## lib/utils/highlight_registry.dart  (98 Z.)

- L42 `allLanguages = { 'dart': dart, 'json': json, 'python': python, 'py': python, 'javascript': javascript, 'js': javascript,`

## lib/utils/image_clipboard_service.dart  (37 Z.)

- L7 `class ImageClipboardService`
  - L8 `const ImageClipboardService._()`
  - L10 `static Future<bool> copyImageBytes(Uint8List bytes)`

## lib/utils/input_validator.dart  (374 Z.)

- L2 `enum PasswordStrength`  — Password strength levels.
  - L2 `weak`
  - L2 `fair`
  - L2 `good`
  - L2 `strong`
- L5 `class PasswordValidationResult`  — Result of password validation with detailed feedback.
  - L6 `final bool isValid`
  - L7 `final PasswordStrength strength`
  - L8 `final String? errorMessage`
  - L9 `final List<String> suggestions`
  - L10 `final bool hasMinLength`
  - L11 `final bool hasUppercase`
  - L12 `final bool hasLowercase`
  - L13 `final bool hasDigit`
  - L14 `final bool hasSpecialChar`
  - L16 `const PasswordValidationResult({ required this.isValid, required this.strength, this.errorMessage, required this.suggestions, required this.hasMinLength, required this.hasUppercase, required this.hasLowercase, required this.hasDigit, required this.hasSpecialChar, })`
- L33 `class InputValidator`  — Input validation and sanitization utilities for security.
  - L34 `InputValidator._()`
  - L38 `static const int maxMessageLength = 20000000`  — Maximum message length (20 million characters).
  - L41 `static const int maxEmailLength = 320`  — Maximum email length (reasonable limit for email addresses).
  - L44 `static const int maxFileNameLength = 255`  — Maximum file name length (reasonable limit for file names).
  - L47 `static const int minPasswordLength = 8`  — Minimum password length (matches Supabase auth setting: config.toml).
  - L51 `static final RegExp _emailRegex = RegExp( r"^[a-zA-Z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(?:\.[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*$", )`  — RFC 5322 compliant email validation regex (simplified).
  - L58 `static String? validateEmail(String? email)`  — Validates email address format and length.
  - L79 `static String? validateMessageLength(String message)`  — Validates message length.
  - L90 `static String sanitizeFileName(String fileName)`  — Sanitizes a file name by removing or escaping potentially dangerous characters.
  - L131 `static String escapeFileNameForDisplay(String fileName)`  — Escapes special characters in file name for safe display in messages.
  - L153 `static Map<String, dynamic> validateAndSanitizeMessage(String message)`  — Validates and sanitizes user message input before sending to API.
  - L169 `static String _getFileExtension(String fileName)`  — Gets the file extension from a file name (including the dot).
  - L178 `static String _formatNumber(int number)`  — Formats a large number with commas for readability.
  - L195 `static PasswordValidationResult validatePasswordStrength(String? password)`  — Validates password strength and returns detailed feedback.
  - L285 `static String? validatePassword(String? password)`  — Simple password validation for forms.
  - L299 `static Uri? safeHttpUri(String? raw)`  — Build a safe `Uri` from an AI-supplied website string for use with
  - L341 `static Uri? safeTelUri(String? raw)`  — Build a safe `tel:` URI from an AI-supplied phone number. Accepts only
  - L354 `static Uri? safeGeoUri({ required double lat, required double lon, String? label, })`  — Build a safe RFC 5870 `geo:` URI for handing coordinates off to an

## lib/utils/io_helper.dart  (4 Z.)

- conditional export: 'io_helper_stub.dart' if (dart.library.io) 'io_helper_io.dart'

## lib/utils/io_helper_io.dart  (5 Z.)

- conditional export: 'dart:io' show File, Directory, Platform, Process, SocketException, HttpException

## lib/utils/io_helper_stub.dart  (79 Z.)

- L7 `class File`  — Stub File class for web
  - L8 `final String path`
  - L9 `File(this.path)`
  - L10 `Future<bool> exists()`
  - L11 `bool existsSync()`
  - L12 `Future<int> length()`
  - L13 `int lengthSync()`
  - L14 `Future<Uint8List> readAsBytes()`
  - L15 `Uint8List readAsBytesSync()`
  - L16 `Future<String> readAsString()`
  - L17 `String readAsStringSync()`
  - L18 `Future<File> writeAsBytes(List<int> bytes, {bool flush = false})`
  - L20 `Future<File> writeAsString(String contents, {bool flush = false})`
  - L22 `Future<void> delete({bool recursive = false})`
  - L23 `Stream<List<int>> openRead([int? start, int? end])`
- L27 `class Directory`  — Stub Directory class for web
  - L28 `final String path`
  - L29 `Directory(this.path)`
  - L30 `Future<bool> exists()`
  - L31 `bool existsSync()`
  - L32 `Future<Directory> create({bool recursive = false})`
  - L33 `Future<void> delete({bool recursive = false})`
- L37 `class Platform`  — Stub Platform class for web
  - L38 `static const bool isAndroid = false`
  - L39 `static const bool isIOS = false`
  - L40 `static const bool isMacOS = false`
  - L41 `static const bool isWindows = false`
  - L42 `static const bool isLinux = false`
  - L43 `static const String pathSeparator = '/'`
  - L44 `static final Map<String, String> environment = {}`
  - L45 `static String get operatingSystem`
- L49 `class ProcessResult`  — Stub ProcessResult for web
  - L50 `final int exitCode`
  - L51 `final dynamic stdout`
  - L52 `final dynamic stderr`
  - L53 `final int pid`
  - L54 `ProcessResult(this.pid, this.exitCode, this.stdout, this.stderr)`
- L58 `class Process`  — Stub Process class for web
  - L59 `static ProcessResult runSync(String executable, List<String> arguments)`
- L65 `class SocketException implements Exception`  — Stub SocketException for web
  - L66 `final String message`
  - L67 `const SocketException(this.message)`
  - L69 `String toString()`
- L73 `class HttpException implements Exception`  — Stub HttpException for web
  - L74 `final String message`
  - L75 `const HttpException(this.message)`
  - L77 `String toString()`

## lib/utils/json_helpers.dart  (72 Z.)

- L14 `Map<String, dynamic>? tryDecodeJsonObject(String body)`  — Decodes [body] into a JSON object, or returns null when it is not one.
- L32 `dynamic tryParseLenientJson(String raw)`  — Lenient JSON parse for model output, which makes two mistakes often
- L60 `bool looksLikeEncryptedPayload(String raw)`  — True when [raw] is one of our AES-GCM envelopes rather than plaintext.

## lib/utils/lru_byte_cache.dart  (86 Z.)

- L10 `class LruByteCache`  — LRU (Least Recently Used) cache with a maximum total byte size.
  - L12 `final int maxSizeBytes`  — Maximum total bytes the cache may hold.
  - L17 `final LinkedHashMap<String, Uint8List> _entries = LinkedHashMap<String, Uint8List>()`  — Insertion-ordered map: oldest entries first, newest last.
  - L20 `int _currentSizeBytes = 0`
  - L22 `LruByteCache({required this.maxSizeBytes})`
  - L25 `int get currentSizeBytes`  — Current total bytes stored in the cache.
  - L28 `int get length`  — Number of entries in the cache.
  - L32 `Uint8List? get(String key)`  — Returns the cached bytes for [key], or null if not present.
  - L41 `bool containsKey(String key)`  — Returns true if [key] is in the cache (without promoting it).
  - L46 `void put(String key, Uint8List value)`  — Stores [value] under [key]. If the single entry exceeds [maxSizeBytes],
  - L66 `void remove(String key)`  — Removes [key] from the cache.
  - L74 `void clear()`  — Removes all entries.
  - L79 `void _evictOldest()`

## lib/utils/map_geometry.dart  (30 Z.)

- L12 `bool hasPointSpread(List<LatLng> points)`  — True when [points] cover more than one place on the map.
- L27 `double _shortestLonDelta(double a, double b)`  — Degrees between two longitudes the short way round.

## lib/utils/path_provider_stub.dart  (8 Z.)

- L5 `Future<Directory> getTemporaryDirectory()`
- L6 `Future<Directory> getApplicationDocumentsDirectory()`
- L7 `Future<Directory> getApplicationSupportDirectory()`

## lib/utils/permission_handler_stub.dart  (24 Z.)

- L4 `class Permission`
  - L5 `static final Permission microphone = Permission._()`
  - L7 `const Permission._()`
  - L9 `Future<PermissionStatus> request()`
  - L10 `Future<PermissionStatus> get status`
- L13 `enum PermissionStatus`
  - L14 `granted`
  - L15 `denied`
  - L16 `permanentlyDenied`
  - L17 `restricted`
  - L18 `limited`
  - L19 `provisional`
  - L21 `bool get isGranted`
  - L22 `bool get isPermanentlyDenied`

## lib/utils/phone_linkify.dart  (95 Z.)

- L21 `_scanPattern = RegExp( // Fenced code blocks. r'```[\s\S]*?```' r'|~~~[\s\S]*?~~~' // Inline code span. r'|`[^`\n]*`' //`  — One pass over the text. Each alternative is a region copied through
- L45 `_minDigits = 7`  — Digit count of a dialable international number, per E.164.
- L46 `_maxDigits = 15`
- L53 `String linkifyPhoneNumbers(String markdown)`  — Rewrites every bare phone number in [markdown] as `[display](tel:+…)`.
- L90 `String? telUriForDisplay(String display)`  — Normalises a written number to a `tel:` URI, or returns `null` when the

## lib/utils/privacy_logger.dart  (73 Z.)

- L18 `class PrivacyLogger`  — Privacy-aware logging utility.
  - L19 `const PrivacyLogger._()`
  - L22 `static void call(String message)`  — Log a message (only in debug mode)
  - L29 `static void info(String message)`  — Log info message
  - L36 `static void success(String message)`  — Log success message
  - L43 `static void warning(String message)`  — Log warning message
  - L50 `static void error(String message, [Object? error, StackTrace? stackTrace])`  — Log error message
  - L63 `static void custom(String prefix, String message)`  — Log with custom emoji/prefix
- L72 `void pLog(String message)`  — Shorthand for PrivacyLogger.call()

## lib/utils/secure_token_handler.dart  (148 Z.)

- L9 `class SecureTokenHandler`  — Utility for secure handling of authentication tokens.
  - L10 `SecureTokenHandler._()`
  - L16 `static String maskToken(String? token)`  — Masks a token for safe display in logs and error messages.
  - L35 `static bool isTokenValid(String? token)`  — Validates if a token is present and non-empty.
  - L41 `static String maskAuthHeader(String authHeader)`  — Creates a masked authorization header value for logging.
  - L50 `static String? validateTokenForRequest( String? token, { String context = 'Request', })`  — Validates token and returns a safe error message if invalid.
  - L75 `static String createSafeErrorMessage(String baseMessage, {String? token})`  — Creates a safe error message that doesn't expose tokens.
  - L86 `static void logApiRequest({ required String endpoint, required String method, String? accessToken, Map<String, dynamic>? payload, })`  — Logs an API request with masked tokens.
  - L121 `static void logApiResponse({ required String endpoint, required int statusCode, String? error, bool success = true, })`  — Logs an API response with masked tokens.

## lib/utils/service_error_handler.dart  (178 Z.)

- L6 `class ServiceErrorHandler`  — Centralized error handling for service operations
  - L7 `const ServiceErrorHandler._()`
  - L10 `static String handleDioException(DioException error, {String? context})`  — Handle Dio exceptions and return user-friendly error messages
  - L48 `static String _handleHttpStatusCode(int? statusCode, dynamic responseData)`  — Handle HTTP status codes and return appropriate messages
  - L93 `static String handleGenericException(Object error, {String? context})`  — Handle generic exceptions
  - L108 `static Future<T?> tryAsync<T>({ required Future<T> Function() operation, required String context, void Function(String error)? onError, })`  — Wrap an async operation with error handling
  - L127 `static bool isNetworkError(Object error)`  — Check if an error is due to network connectivity
  - L138 `static bool isAuthError(Object error)`  — Check if an error is due to authentication failure
  - L147 `static bool isRateLimitError(Object error)`  — Check if an error is due to rate limiting
  - L155 `static bool isServerError(Object error)`  — Check if an error is a server error (5xx)
  - L164 `static Duration? getRetryDelay(Object error, int attemptNumber)`  — Get retry delay for an error (used with exponential backoff)

## lib/utils/shift_key_tracker.dart  (6 Z.)

- conditional export: 'shift_key_tracker_native.dart' if (dart.library.js_interop) 'shift_key_tracker_web.dart'

## lib/utils/shift_key_tracker_native.dart  (10 Z.)

- L5 `void initShiftKeyTracker()`

## lib/utils/shift_key_tracker_web.dart  (38 Z.)

- L9 `_shiftDown = false`
- L10 `_initialized = false`
- L12 `void initShiftKeyTracker()`

## lib/utils/stream_error_sanitizer.dart  (38 Z.)

- L15 `String sanitizeStreamError(Object error)`  — Turns a transport exception into something safe and readable to show.

## lib/utils/theme_extensions.dart  (216 Z.)

- L3 `extension ThemeDataIconColorX on ThemeData`
  - L4 `Color get resolvedIconColor`
  - L20 `Color accentButtonForeground(Color fill)`  — The glyph colour for a button that is filled with the accent — the send
- L25 `@immutable class MaterialYouTokens extends ThemeExtension<MaterialYouTokens>`  — Material You extension tokens that aren't exposed on the default
  - L27 `const MaterialYouTokens({ required this.surfaceContainerLow, required this.surfaceContainer, required this.surfaceContainerHigh, required this.surfaceContainerHighest, required this.primaryContainer, required this.onPrimaryContainer, required this.secondaryContainer, required this.onSecondaryContainer, required this.tertiaryContainer, required this.onTertiaryContainer, required this.outline, required this.outlineVariant, required this.onSurfaceVariant, required this.success, required this.onSuccess, required this.successContainer, required this.onSuccessContainer, required this.warning, required this.warningContainer, required this.onWarningContainer, })`
  - L50 `final Color surfaceContainerLow`
  - L51 `final Color surfaceContainer`
  - L52 `final Color surfaceContainerHigh`
  - L53 `final Color surfaceContainerHighest`
  - L54 `final Color primaryContainer`
  - L55 `final Color onPrimaryContainer`
  - L56 `final Color secondaryContainer`
  - L57 `final Color onSecondaryContainer`
  - L58 `final Color tertiaryContainer`
  - L59 `final Color onTertiaryContainer`
  - L60 `final Color outline`
  - L61 `final Color outlineVariant`
  - L62 `final Color onSurfaceVariant`
  - L63 `final Color success`
  - L64 `final Color onSuccess`
  - L65 `final Color successContainer`
  - L66 `final Color onSuccessContainer`
  - L67 `final Color warning`
  - L68 `final Color warningContainer`
  - L69 `final Color onWarningContainer`
  - L72 `MaterialYouTokens copyWith({ Color? surfaceContainerLow, Color? surfaceContainer, Color? surfaceContainerHigh, Color? surfaceContainerHighest, Color? primaryContainer, Color? onPrimaryContainer, Color? secondaryContainer, Color? onSecondaryContainer, Color? tertiaryContainer, Color? onTertiaryContainer, Color? outline, Color? outlineVariant, Color? onSurfaceVariant, Color? success, Color? onSuccess, Color? successContainer, Color? onSuccessContainer, Color? warning, Color? warningContainer, Color? onWarningContainer, })`
  - L120 `MaterialYouTokens lerp( covariant ThemeExtension<MaterialYouTokens>? other, double t, )`
- L168 `extension MaterialYouTokensX on ThemeData`
  - L171 `MaterialYouTokens get m3`  — Returns Material You extension tokens. Falls back to sensible defaults

## lib/utils/token_estimator.dart  (58 Z.)

- L3 `class TokenEstimator`
  - L4 `const TokenEstimator._()`
  - L6 `static const int _perMessageOverhead = 8`
  - L7 `static const int _systemPromptOverhead = 24`
  - L8 `static final RegExp _tokenishPattern = RegExp(r'\w+|[^\s\w]')`
  - L10 `static int estimateTokens(String text)`
  - L18 `static int estimatePromptTokens({ required List<Map<String, dynamic>> history, required String currentMessage, String? systemPrompt, })`

## lib/utils/tool_detail_format.dart  (91 Z.)

- L15 `enum ToolBodyKind`  — How a tool-detail body should be shown.
  - L17 `text`
  - L20 `json`
  - L23 `markdown`
- L27 `class ToolBody`  — A tool body together with how to show it.
  - L28 `const ToolBody(this.kind, this.text)`
  - L30 `final ToolBodyKind kind`
  - L34 `final String text`  — The text to show. For [ToolBodyKind.json] this is the indented form,
- L41 `_markdownMarkers = [ RegExp(r'^#{1,6}\s+\S', multiLine: true), RegExp(r'^\s*[-*+]\s+\S', multiLine: true), RegExp(r'^\s*`  — Markers that only appear in text meant to be rendered: a heading, a
- L57 `ToolBody classifyToolBody(String raw)`  — Decide how [raw] should be shown, and hand back the text to show.
- L75 `String? prettyJsonOrNull(String raw)`  — [raw] indented, or null when it is not a JSON object or array.

## lib/utils/tool_helpers.dart  (21 Z.)

- L2 `double toDouble(dynamic v)`  — Safely parse a coordinate value that may be num or String.
- L9 `String formatDuration(int ms)`  — Format milliseconds duration as mm:ss string.
- L17 `String truncate(String text, int maxLength)`  — Truncate text with ellipsis if it exceeds maxLength.

## lib/utils/tool_history_formatter.dart  (100 Z.)

- L8 `_maxResultChars = 4000`
- L9 `_maxTotalChars = 16000`
- L16 `String? formatAssistantContent( Map<String, String> message, { bool includeReasoning = false, bool includeToolResults = true, })`  — Builds the assistant `content` string for one stored message, optionally
- L51 `String _buildPreviousToolResultsBlock(String? toolCallsJson)`

## lib/utils/tool_parser.dart  (774 Z.)

- L5 `toolCallStart = '<tool_call>'`
- L6 `toolCallEnd = '</tool_call>'`
- L8 `_xmlToolCallBlockPattern = RegExp( r'<tool_call>[\s\S]*?</tool_call>', caseSensitive: false, )`
- L12 `_xmlDirectToolTagBlockPattern = RegExp( r'<([a-zA-Z][a-zA-Z0-9_]*_[a-zA-Z0-9_]+)>\s*([\s\S]*?)\s*</\1>', caseSensitive:`
- L16 `_xmlToolCallStartPattern = RegExp( r'<tool_call>', caseSensitive: false, )`
- L23 `_kimiToolCallStartPattern = RegExp( r'<\|tool_calls?(?:_section)?_begin', caseSensitive: false, )`
- L35 `_previousToolResultsBlockPattern = RegExp( r'<+\s*previous_tool_results\s*>[\s\S]*?<\s*/\s*previous_tool_results\s*>', c`
- L39 `_previousToolResultsStartPattern = RegExp( r'<+\s*previous_tool_results\b', caseSensitive: false, )`
- L64 `_foreignToolTagNames = r'(?:tool_calls?|toolcalls?|function_calls?|invoke)'`
- L69 `_foreignToolTagNamespace = r'(?:[a-zA-Z][a-zA-Z0-9_.-]*\s*:\s*)?'`
- L74 `_notCanonicalToolCallTag = r'(?!tool_call\b)(?!toolcall\b)'`
- L79 `_foreignToolProtocolBlockPattern = RegExp( '<\\s*$_notCanonicalToolCallTag$_foreignToolTagNamespace' '($_foreignToolTagN`
- L95 `_invokeToolCallPattern = RegExp( '<\\s*$_foreignToolTagNamespace' //`\b`before`name`: without it the non-greedy scan`
- L106 `_invokeParameterPattern = RegExp( '<\\s*$_foreignToolTagNamespace' r'''parameter\b[^>]*?\bname\s*=\s*["']([^"']+)["'][^>`
- L118 `_foreignToolProtocolStartPattern = RegExp( '<\\s*$_notCanonicalToolCallTag$_foreignToolTagNamespace' '$_foreignToolTagNa`
- L126 `_knownDirectXmlToolNames = <String>{ 'ask_user', 'web_search', 'web_crawl', 'generate_image', 'fetch_image', 'view_chat_`
- L153 `Map<String, dynamic>? tryParseToolJson(String raw)`  — Try to parse JSON from a tool call, with repair for common LLM errors:
- L186 `Map<String, dynamic>? _parseLegacyToolCallSyntax(String raw)`
- L234 `Map<String, dynamic>? _extractEmbeddedToolJson(String raw)`
- L257 `Map<String, dynamic>? _extractInlineArgumentsObject(String s)`
- L278 `String? _extractBalancedObject(String s, int startIndex)`
- L319 `int _countUnclosedBracesOutsideStrings(String s)`
- L358 `Map<String, dynamic> _coerceStringKeyedMap(dynamic rawArgs)`
- L384 `bool hasToolCallStartMarker(String content)`  — Returns true when a response has started emitting a tool-call marker,
- L394 `bool hasForeignToolProtocolMarker(String content)`  — True when the text carries a tool-call protocol this app does not parse
- L408 `List<({int start, int end})> _codeSpanRanges(String content)`  — Start/end offsets of fenced blocks and inline code spans.
- L437 `bool _isInsideCode(int index, List<({int start, int end})> codeRanges)`
- L444 `Match? _firstMatchOutsideCode( RegExp pattern, String content, List<({int start, int end})> codeRanges, )`
- L459 `String _stripForeignToolProtocol( String content, { required bool stripIncomplete, })`  — Removes foreign tool-call protocol text so it never reaches the user.
- L496 `String stripToolCallBlocksForDisplay( String content, { bool stripIncomplete = true, })`  — Removes tool-call XML blocks from user-visible text.
- L589 `int _earliestCaseInsensitiveIndex(String haystack, String needle)`
- L595 `List<Map<String, dynamic>> parseToolCalls(String content)`  — Parse ALL tool calls from LLM response content (supports multiple).
- L686 `dynamic _decodeInvokeParameterValue(String raw)`  — `<parameter>` bodies are untyped text. Only unambiguous JSON shapes are
- L706 `bool hasToolCalls(String content)`  — Check if the content contains any tool call tags.
- L727 `bool _isKnownDirectXmlToolName(String tagName)`
- L731 `Map<String, dynamic> _parseDirectXmlToolArgs(String inner)`
- L762 `int _earliestDirectXmlToolStart(String content)`

## lib/utils/tool_sanitizer.dart  (45 Z.)

- L6 `String sanitizeResultForModel(String result)`  — Strip large binary/base64 data from tool results before sending to the

## lib/utils/upload_rate_limiter.dart  (95 Z.)

- L2 `class UploadRateLimiter`  — Upload rate limiter to prevent DoS attacks via excessive file uploads.
  - L3 `UploadRateLimiter._()`
  - L5 `static final UploadRateLimiter _instance = UploadRateLimiter._()`
  - L6 `factory UploadRateLimiter()`
  - L9 `static const int maxUploadsPerWindow = 10`  — Maximum uploads per time window
  - L12 `static const int timeWindowMinutes = 5`  — Time window in minutes
  - L15 `final Map<String, List<DateTime>> _uploadHistory = {}`  — Track upload timestamps per user
  - L20 `bool isUploadAllowed(String userId)`  — Check if an upload is allowed for a user.
  - L39 `void recordUpload(String userId)`  — Record an upload attempt for a user.
  - L46 `int getUploadsRemaining(String userId)`  — Get the number of uploads remaining for a user in the current window.
  - L61 `int? getTimeUntilReset(String userId)`  — Get time until rate limit resets (in seconds).
  - L86 `void clearUserHistory(String userId)`  — Clear upload history for a user (useful for testing or admin actions).
  - L91 `void clearAllHistory()`  — Clear all upload history (useful for testing).

## lib/utils/url_launcher_helper.dart  (22 Z.)

- L12 `Future<void> launchExternalUrl(String url)`  — Opens [url] in the system browser.
