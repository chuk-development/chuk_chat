# test/vnc · Signaturen

## test/vnc/live_auth_probe.dart  (54 Z.)
- L16 `Future<String> attempt(int port, String? password)`
- L39 `Future<void> main(List<String> args)`

## test/vnc/size_tracking_test.dart  (26 Z.)
- L8 `void main()`

## test/vnc/socket_read_test.dart  (70 Z.)
- L11 `Future<(RawSocket, Socket)> _pair()`
- L20 `void main()`

## test/vnc/tight_decoder_test.dart  (350 Z.)
- L22 `Uint8List _encodeTinyJpeg()`  — A 4x4 baseline JPEG, small enough for a 1-byte compact length.
- L28 `_encTight = 7`
- L29 `_subJpeg = 9`
- L31 `class _Vector`
  - L32 `_Vector(this.name, this.meta, this.raw)`
  - L33 `final String name`
  - L34 `final Map<String, dynamic> meta`
  - L35 `final Uint8List raw`
  - L37 `int get x0`
  - L38 `int get y0`
  - L39 `int get w`
  - L40 `int get h`
  - L41 `List<Map<String, dynamic>> get rects`
- L45 `_Vector _load(String name)`
- L56 `Future<(Uint8List, List<bool>)> _decodeAll(_Vector v)`  — Decode every rect of a vector in order (one decoder = one connection's
- L85 `double _rectMeanError(_Vector v, Uint8List decoded, Map<String, dynamic> r)`  — Mean absolute error over R,G,B of one rect vs the raw capture.
- L100 `void _expectRectExact(_Vector v, Uint8List decoded, Map<String, dynamic> r)`
- L118 `void main()`

## test/vnc/trackpad_overlay_test.dart  (320 Z.)
- L10 `class _SpyController extends RemoteFrameBufferController`  — Records the pointer/click/key calls the overlay makes, standing in for
  - L11 `final List<String> events = <String>[]`
  - L14 `bool get isReady`
  - L17 `Size? get frameBufferSize`
  - L20 `void pointer({ required int x, required int y, Set<int> buttons = const <int>{}, })`
  - L30 `void click({ required int x, required int y, int button = 1, })`
  - L39 `void key({required bool down, required int key})`
  - L44 `String? get lastLeftClick`  — The last left click, as a framebuffer point.
- L48 `Future<void> _pump(WidgetTester tester, _SpyController c)`
- L77 `Future<void> _pinch(WidgetTester tester, double factor)`  — Pinches the two fingers apart (or together) by [factor] about the centre of
- L99 `void main()`

## test/vnc/view_fit_test.dart  (184 Z.)
- L12 `void main()`  — The mapping the whole browser view rests on: a touch has to reach the remote

## test/vnc/vnc_local_server_test.dart  (308 Z.)
- L15 `void main()`  — The loopback server behind the noVNC viewer.
