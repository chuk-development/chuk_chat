// lib/widgets/linux_webview.dart
//
// DEFAULT (slim) implementation of the Linux WebView shim.
//
// Linux desktop has no stable Flutter WebView backend that can be
// bundled without a ~120 MB Chromium runtime. The default chuk_chat
// codebase therefore ships a slim fallback: Excalidraw renders via the
// native CustomPainter (`ExcalidrawWidget`), and HTML artifacts show a
// read-only source view (`HtmlSourceFallback`).
//
// The CI "full" Linux workflow (see `ci/linux_full/` and
// `.github/workflows/build-cross-platform.yml`) overwrites this file
// with a `webview_cef`-backed version that renders the real Excalidraw
// React bundle and live HTML. The public API — `LinuxWebView.excalidraw`
// and `LinuxWebView.html` — is identical across both variants so the
// call sites in `excalidraw_view_io.dart` and `html_artifact_view_io.dart`
// never change.
//
// If you change the public API here, update `ci/linux_full/lib/widgets/
// linux_webview.dart` in lock-step or CI "full" builds will fail.

import 'package:flutter/material.dart';

import 'package:chuk_chat/widgets/excalidraw_widget.dart';
import 'package:chuk_chat/widgets/html_artifact_view_source_fallback.dart';

class LinuxWebView extends StatelessWidget {
  const LinuxWebView._excalidraw({required this.excalidrawJson})
      : htmlContent = null,
        captureKey = null;

  const LinuxWebView._html({required this.htmlContent, required this.captureKey})
      : excalidrawJson = null;

  final String? excalidrawJson;
  final String? htmlContent;
  final GlobalKey? captureKey;

  /// Renders an Excalidraw scene. Slim build: CustomPainter fallback.
  static Widget excalidraw({required String jsonString}) =>
      LinuxWebView._excalidraw(excalidrawJson: jsonString);

  /// Renders user-provided HTML. Slim build: read-only source view.
  static Widget html({required String html, GlobalKey? captureKey}) =>
      LinuxWebView._html(htmlContent: html, captureKey: captureKey);

  @override
  Widget build(BuildContext context) {
    final scene = excalidrawJson;
    if (scene != null) {
      return ExcalidrawWidget(jsonString: scene);
    }
    final body = htmlContent;
    if (body != null) {
      return RepaintBoundary(
        key: captureKey,
        child: HtmlSourceFallback(html: body),
      );
    }
    return const SizedBox.shrink();
  }
}
