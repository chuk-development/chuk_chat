// lib/services/diagnostics_log_service_stub.dart
// No-op diagnostics logger for web/unsupported platforms.

class DiagnosticsLogService {
  const DiagnosticsLogService._();

  static void setAppInForeground(bool isForeground) {}

  static Future<void> initialize() async {}

  static Future<bool> isEnabled() async => false;

  static Future<void> setEnabled(bool enabled) async {}

  static Future<void> info(
    String area,
    String message, {
    Map<String, Object?>? data,
  }) async {}

  static Future<void> warning(
    String area,
    String message, {
    Map<String, Object?>? data,
  }) async {}

  static Future<void> error(
    String area,
    String message, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?>? data,
  }) async {}

  static Future<void> timing(
    String area,
    String operation,
    int elapsedMs, {
    Map<String, Object?>? data,
  }) async {}

  static Future<String?> getLogFilePath() async => null;

  static Future<String> readRecentLogs({int maxLines = 250}) async => '';

  static Future<void> clearLogs() async {}
}
