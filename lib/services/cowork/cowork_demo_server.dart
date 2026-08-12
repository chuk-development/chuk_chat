// CoWork demo loopback server — platform barrel.
//
// The real implementation is `dart:io`-only (`HttpServer` +
// `WebSocketTransformer`). Web gets a no-op stub so the shared UI code that
// references [CoworkDemoServer] still compiles for `flutter build web`. The
// demo itself is desktop-only (`kFeatureCoworkDemo`), so the stub is never
// exercised — it exists purely to keep the web build green.
export 'cowork_demo_server_stub.dart'
    if (dart.library.io) 'cowork_demo_server_io.dart';
