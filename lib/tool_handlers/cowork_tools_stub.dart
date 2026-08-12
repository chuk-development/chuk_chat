// Web stubs for the CoWork laptop-native tools.
//
// These tools require dart:io (filesystem + process) and are not available on
// web builds. The config setters are no-ops so shared code can reference them
// unconditionally.

const String _unsupported =
    'CoWork laptop-native tools are not available on web.';

/// No-op on web. See the native implementation for the real behaviour.
set coworkJailRoot(String value) {}

/// Empty on web.
String get coworkJailRoot => '';

/// No-op on web.
set coworkCommandTimeout(Duration value) {}

/// Zero on web.
Duration get coworkCommandTimeout => Duration.zero;

Future<String> executeRunCommand(Map<String, dynamic> args) async =>
    'Error: $_unsupported';

Future<String> executeReadFile(Map<String, dynamic> args) async =>
    'Error: $_unsupported';

Future<String> executeWriteFile(Map<String, dynamic> args) async =>
    'Error: $_unsupported';

Future<String> executeListDirectory(Map<String, dynamic> args) async =>
    'Error: $_unsupported';
