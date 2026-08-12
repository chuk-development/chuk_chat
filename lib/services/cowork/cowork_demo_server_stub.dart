import 'dart:async';

/// Web stub for [CoworkDemoServer]. The demo is desktop-only; on web every
/// method is inert so shared UI code compiles without pulling in `dart:io`.
class CoworkDemoServer {
  Future<Uri> start({int port = 0}) async {
    throw UnsupportedError('The CoWork demo server is not available on web.');
  }

  Stream<String> get injectedMessages => const Stream<String>.empty();

  bool get isRunning => false;

  int get connectionCount => 0;

  void pushDelta(String text) {}

  void pushToolCall(String name, String argsPreview) {}

  void pushToolResult(String name, String resultPreview) {}

  void pushDone() {}

  void pushError(String message) {}

  Future<void> stop() async {}
}
