// lib/utils/io_helper.dart
// Conditional export: provides dart:io on native, stubs on web
export 'io_helper_stub.dart' if (dart.library.io) 'io_helper_io.dart';
