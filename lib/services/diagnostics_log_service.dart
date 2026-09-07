// lib/services/diagnostics_log_service.dart
// Conditional export: native file logger on IO, no-op on web.
export 'diagnostics_log_service_stub.dart'
    if (dart.library.io) 'diagnostics_log_service_io.dart';
