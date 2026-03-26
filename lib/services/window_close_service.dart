// lib/services/window_close_service.dart
// Re-export platform-specific implementation.
export 'window_close_service_stub.dart'
    if (dart.library.io) 'window_close_service_io.dart';
