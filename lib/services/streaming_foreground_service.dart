// lib/services/streaming_foreground_service.dart
// Re-export platform-specific implementation
export 'streaming_foreground_service_stub.dart'
    if (dart.library.io) 'streaming_foreground_service_io.dart';
