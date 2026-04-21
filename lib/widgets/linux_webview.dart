// lib/widgets/linux_webview.dart
//
// DEFAULT (slim) implementation of the Linux WebView shim.
//
// Linux desktop has no stable Flutter WebView backend that can be
// bundled without a ~120 MB Chromium runtime. The default chuk_chat
// codebase therefore ships a slim "WebView unavailable" card for both
// Excalidraw and HTML artifacts. Users who want real rendering should
// install the `-full` Linux build, which ships CEF via webview_cef and
// replaces this file via `ci/linux_full/apply.sh`.
//
// The public API — `LinuxWebView.excalidraw` and `LinuxWebView.html` —
// matches `ci/linux_full/lib/widgets/linux_webview.dart` so the call
// sites in `excalidraw_view_io.dart` and `html_artifact_view_io.dart`
// never change across variants.

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

class LinuxWebView extends StatelessWidget {
  const LinuxWebView._excalidraw({required this.excalidrawJson})
      : htmlContent = null,
        captureKey = null;

  const LinuxWebView._html({required this.htmlContent, required this.captureKey})
      : excalidrawJson = null;

  final String? excalidrawJson;
  final String? htmlContent;
  final GlobalKey? captureKey;

  /// Renders an Excalidraw scene. Slim build: shows an unavailable card
  /// with a link to open the scene in the system browser.
  static Widget excalidraw({required String jsonString}) =>
      LinuxWebView._excalidraw(excalidrawJson: jsonString);

  /// Renders user-provided HTML. Slim build: shows an unavailable card.
  static Widget html({required String html, GlobalKey? captureKey}) =>
      LinuxWebView._html(htmlContent: html, captureKey: captureKey);

  @override
  Widget build(BuildContext context) {
    final isExcalidraw = excalidrawJson != null;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.web_asset_off, size: 48, color: Colors.grey),
            const SizedBox(height: 12),
            Text(
              isExcalidraw
                  ? 'Excalidraw rendering requires the -full Linux build.'
                  : 'HTML rendering requires the -full Linux build.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            const Text(
              'Install chuk_chat-linux-amd64-full.deb (or the matching '
              'AppImage / RPM) for real WebView-backed rendering.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            if (isExcalidraw) ...[
              const SizedBox(height: 16),
              TextButton.icon(
                onPressed: () => unawaitedLaunch(
                  Uri.parse('https://excalidraw.com/'),
                ),
                icon: const Icon(Icons.open_in_new),
                label: const Text('Open excalidraw.com'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Fire-and-forget `launchUrl` that swallows failures — used only by
/// the slim-Linux error card for an "open excalidraw.com" button.
void unawaitedLaunch(Uri uri) {
  // ignore: discarded_futures
  launchUrl(uri, mode: LaunchMode.externalApplication);
}
