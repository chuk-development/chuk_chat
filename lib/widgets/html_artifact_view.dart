// lib/widgets/html_artifact_view.dart
// Conditional wrapper: renders a user-provided HTML string inside a
// sandboxed container. Native (non-Linux) uses flutter_inappwebview,
// web uses an HtmlElementView iframe with sandbox="allow-scripts",
// Linux falls back to a SelectableText source view.
export 'html_artifact_view_io.dart'
    if (dart.library.js_interop) 'html_artifact_view_web.dart';
