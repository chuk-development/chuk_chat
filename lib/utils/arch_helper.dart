// lib/utils/arch_helper.dart
// Conditional export: provides dart:ffi Abi on native, stub on web.
export 'arch_helper_stub.dart' if (dart.library.ffi) 'arch_helper_native.dart';
