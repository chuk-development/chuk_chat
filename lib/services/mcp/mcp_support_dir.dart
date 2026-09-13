// lib/services/mcp/mcp_support_dir.dart
//
// Where the connector icon cache keeps its files. Native builds resolve the
// app support directory through path_provider; the web build has no disk, so
// it resolves to a stub and the disk half of the icon cache turns into a
// no-op. The conditional export keeps `dart:io`/path_provider out of the web
// bundle, exactly as the rest of Agents does through `utils/io_helper.dart`.

export 'mcp_support_dir_stub.dart'
    if (dart.library.io) 'mcp_support_dir_io.dart';
