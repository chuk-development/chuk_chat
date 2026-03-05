// lib/services/system_tray_service.dart
// Re-export platform-specific implementation.
export 'system_tray_service_stub.dart'
    if (dart.library.io) 'system_tray_service_io.dart';
