/// The file-saving seam: the interface on every platform, and the one
/// implementation that fits the platform being built.
///
/// `path_provider` and `dart:io` are native-only, so the concrete saver is
/// chosen by conditional export exactly like `io_helper.dart` does.
library;

export 'agent_file_saver_base.dart';
export 'agent_file_saver_stub.dart'
    if (dart.library.io) 'agent_file_saver_io.dart';
