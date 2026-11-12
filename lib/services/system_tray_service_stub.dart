// lib/services/system_tray_service_stub.dart
// No-op implementation for unsupported platforms.
import 'package:chuk_chat/services/app_mode_service.dart';

class SystemTrayService {
  SystemTrayService._();

  static final SystemTrayService instance = SystemTrayService._();

  Future<void> initialize() async {}

  void attachAppMode(AppModeService appMode) {}

  Future<void> showWindow() async {}

  Future<void> hideWindow() async {}

  Future<void> dispose({bool resetQuitFlag = true}) async {}
}
