// lib/utils/certificate_pinning_register.dart
//
// Certificate pinning registration — conditional export.
// On native (dart:io) platforms, exports the IO implementation.
// On web, exports a no-op stub.

export 'certificate_pinning_register_stub.dart'
    if (dart.library.io) 'certificate_pinning_register_io.dart';
