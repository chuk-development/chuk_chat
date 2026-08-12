// CoWork laptop-native tools barrel file.
//
// On native (dart:io available): imports the real filesystem/process
// implementation. On web: imports stubs that return "not available on web".
//
// The four tools (`run_command`, `read_file`, `write_file`, `list_directory`)
// act on the local machine and are gated behind `kFeatureCoworkDemo`. They are
// registered in `tool_registry.dart` and dispatched from `tool_executor.dart`.
export 'cowork_tools_stub.dart'
    if (dart.library.io) 'cowork_tools_native.dart';
