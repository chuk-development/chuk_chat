// lib/services/system_tray_service_stub.dart
// No-op implementation for unsupported platforms.
class SystemTrayService {
  SystemTrayService._();

  static final SystemTrayService instance = SystemTrayService._();

  Future<void> initialize() async {}

  Future<void> showWindow() async {}

  Future<void> hideWindow() async {}

  Future<void> dispose() async {}
}
