// lib/services/notification_service.dart
// Re-export platform-specific implementation
export 'notification_service_stub.dart'
    if (dart.library.io) 'notification_service_io.dart';
