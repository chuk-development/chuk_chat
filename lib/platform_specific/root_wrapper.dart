// lib/platform_specific/root_wrapper.dart
// Central platform-adaptive wrapper that conditionally imports the correct implementation

export 'root_wrapper_stub.dart'
    if (dart.library.io) 'root_wrapper_io.dart';
