// lib/widgets/linux_webview.dart
//
// DEFAULT (slim) implementation of the Linux WebView shim.
//
// Linux desktop has no stable Flutter WebView backend that can be
// bundled without a ~120 MB Chromium runtime. The default chuk_chat
// codebase therefore ships a slim "WebView unavailable" card for HTML
// artifacts. Users who want real rendering should install the `-full`
// Linux build, which ships CEF via webview_cef and replaces this file
// via `ci/linux_full/apply.sh`.
//
// The public API — `LinuxWebView.html` — matches
// `ci/linux_full/lib/widgets/linux_webview.dart` so the call site in
// `html_artifact_view_io.dart` never changes across variants.

import 'package:flutter/material.dart';

class LinuxWebView extends StatelessWidget {
  const LinuxWebView._html({required this.htmlContent, required this.captureKey});

  final String htmlContent;
  final GlobalKey? captureKey;

  /// Renders user-provided HTML. Slim build: shows an unavailable card.
  static Widget html({required String html, GlobalKey? captureKey}) =>
      LinuxWebView._html(htmlContent: html, captureKey: captureKey);

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.web_asset_off, size: 48, color: Colors.grey),
            SizedBox(height: 12),
            Text(
              'HTML rendering requires the -full Linux build.',
              textAlign: TextAlign.center,
            ),
            SizedBox(height: 8),
            Text(
              'Install chuk_chat-linux-amd64-full.deb (or the matching '
              'AppImage / RPM) for real WebView-backed rendering.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}
