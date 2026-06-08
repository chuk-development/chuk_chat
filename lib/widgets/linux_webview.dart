// lib/widgets/linux_webview.dart
//
// DEFAULT (slim) implementation of the Linux WebView shim.
//
// Linux desktop has no stable Flutter WebView backend that can be bundled
// without a ~120 MB Chromium runtime, so the slim chuk_chat build does not
// render HTML inline. Instead of a dead-end "unavailable" card, it renders the
// HTML at full fidelity in the user's own default browser: the content is
// written to a temp file and opened via url_launcher. No bundled engine, full
// JS + CSS. The `-full` Linux build still swaps in a webview_cef-backed view
// (via `ci/linux_full/apply.sh`) for true inline rendering.
//
// The public API — `LinuxWebView.html` — matches
// `ci/linux_full/lib/widgets/linux_webview.dart` so the call site in
// `html_artifact_view_io.dart` never changes across variants.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

class LinuxWebView extends StatelessWidget {
  const LinuxWebView._html({
    required this.htmlContent,
    required this.captureKey,
  });

  final String htmlContent;
  final GlobalKey? captureKey;

  /// Renders user-provided HTML. Slim build: opens it in the system browser.
  static Widget html({required String html, GlobalKey? captureKey}) =>
      LinuxWebView._html(htmlContent: html, captureKey: captureKey);

  Future<void> _openInBrowser(BuildContext context) async {
    try {
      final dir = await Directory.systemTemp.createTemp('chuk_html_');
      final file = File('${dir.path}/artifact.html');
      await file.writeAsString(htmlContent);
      final launched = await launchUrl(
        Uri.file(file.path),
        mode: LaunchMode.externalApplication,
      );
      if (!launched && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open the system browser.')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Open failed: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.public, size: 48, color: Colors.grey),
            const SizedBox(height: 12),
            const Text(
              'Open this HTML in your browser',
              textAlign: TextAlign.center,
              style: TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 6),
            const Text(
              'The slim Linux build has no embedded WebView. Your default '
              'browser renders it with full JS + CSS. Install the -full Linux '
              'build to render inline instead.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () => _openInBrowser(context),
              icon: const Icon(Icons.open_in_browser, size: 18),
              label: const Text('Open in browser'),
            ),
          ],
        ),
      ),
    );
  }
}
