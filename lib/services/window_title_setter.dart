// lib/services/window_title_setter.dart
// Re-export platform-specific implementation.
export 'window_title_setter_stub.dart'
    if (dart.library.io) 'window_title_setter_io.dart';
