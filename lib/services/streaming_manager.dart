// lib/services/streaming_manager.dart
// Re-export platform-specific implementation
export 'streaming_manager_stub.dart'
    if (dart.library.io) 'streaming_manager_io.dart';
