// lib/widgets/excalidraw_view.dart
//
// Public entry point for rendering an Excalidraw artifact. Picks the
// platform-specific implementation via conditional import:
//   - native (mobile + desktop) → InAppWebView shell
//   - web → <iframe> via HtmlElementView
//
// Both backends load the same bundled `assets/excalidraw/index.html` and
// speak the same JSON postMessage protocol, so callers just use
// `ExcalidrawView(jsonString: ...)` and stay platform-agnostic.

export 'excalidraw_view_io.dart' if (dart.library.js_interop) 'excalidraw_view_web.dart';
