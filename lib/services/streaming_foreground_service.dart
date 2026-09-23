// AGENTS STUB. Upstream: chuk_chat/lib/services/streaming_foreground_service.dart
// (conditional export of streaming_foreground_service_io.dart / _stub.dart)
// @ d31526a229fdde27c82adf3661d5d3a149db8340.
// Reason: replaced by relay — upstream keeps an Android foreground service alive
// so a stream survives backgrounding. In Agents the run lives on the host and
// keeps going with no client attached, so the client needs no foreground
// service at all. Permanent no-op.
// Keep the public API signature-compatible with upstream so the imported chat UI compiles unchanged. Do not "improve" this file.

class StreamingForegroundService {
  static bool get isRunning => false;

  static bool get hasKeepAliveLock => false;

  static Future<void> initialize() async {}

  static Future<void> startService() async {}

  static Future<void> acquireKeepAliveLock({
    String? title,
    String? content,
    bool startIfNeeded = true,
  }) async {}

  static Future<void> releaseKeepAliveLock() async {}

  static Future<void> updateNotification({
    required String content,
    String? title,
  }) async {}

  static Future<void> stopService({
    bool force = false,
    bool preserveLocks = false,
  }) async {}

  static Future<bool> canStart() async => false;

  static Future<bool> isIgnoringBatteryOptimizations() async => true;

  static Future<bool> requestIgnoreBatteryOptimization() async => true;
}
