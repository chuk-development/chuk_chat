// Platform tools barrel file.
//
// On native (dart:io available): imports real implementations.
// On web: imports stubs that return "not available on web".
export 'platform_tools_stub.dart'
    if (dart.library.io) 'platform_tools_native.dart';
