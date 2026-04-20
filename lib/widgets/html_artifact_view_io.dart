// lib/widgets/html_artifact_view_io.dart
// Native implementation of HtmlArtifactView.
//
// On all native platforms (Android / iOS / macOS / Windows / Linux):
// renders the user-provided HTML inside an InAppWebView sandbox.
// JavaScript is allowed so that LLM output using <script> tags works,
// but file-system access, universal CORS, auto window-opening, and
// navigation away from the artifact content are all blocked. External
// http(s) links are opened via url_launcher in the system browser
// instead of navigating the WebView.
//
// Linux uses the WPE WebKit federation (flutter_inappwebview_linux).

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:chuk_chat/utils/theme_extensions.dart';

/// Returns true for schemes that are allowed to load inside the WebView
/// (i.e. the artifact's own content). Everything else is opened via
/// url_launcher so the artifact panel stays put.
bool shouldLoadInWebView(Uri? uri) {
  if (uri == null) return true;
  final scheme = uri.scheme.toLowerCase();
  return scheme.isEmpty ||
      scheme == 'about' ||
      scheme == 'data' ||
      scheme == 'blob';
}

class HtmlArtifactView extends StatelessWidget {
  const HtmlArtifactView({
    super.key,
    required this.html,
    this.captureKey,
  });

  final String html;

  /// RepaintBoundary key used by the artifact panel for PNG export.
  final GlobalKey? captureKey;

  @override
  Widget build(BuildContext context) {
    return _HtmlWebView(html: html, captureKey: captureKey);
  }
}

class _HtmlWebView extends StatelessWidget {
  const _HtmlWebView({required this.html, this.captureKey});

  final String html;
  final GlobalKey? captureKey;

  static final InAppWebViewSettings _settings = InAppWebViewSettings(
    javaScriptEnabled: true,
    javaScriptCanOpenWindowsAutomatically: false,
    allowFileAccessFromFileURLs: false,
    allowUniversalAccessFromFileURLs: false,
    mediaPlaybackRequiresUserGesture: true,
    supportZoom: true,
    transparentBackground: false,
  );

  @override
  Widget build(BuildContext context) {
    final iconFg = Theme.of(context).resolvedIconColor;
    return RepaintBoundary(
      key: captureKey,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: iconFg.withValues(alpha: 0.15)),
          borderRadius: BorderRadius.circular(8),
        ),
        clipBehavior: Clip.antiAlias,
        child: InAppWebView(
          initialData: InAppWebViewInitialData(
            data: html,
            baseUrl: WebUri('about:blank'),
          ),
          initialSettings: _settings,
          shouldOverrideUrlLoading: (controller, action) async {
            final url = action.request.url;
            if (shouldLoadInWebView(url)) {
              return NavigationActionPolicy.ALLOW;
            }
            final scheme = url!.scheme.toLowerCase();
            if (scheme == 'http' || scheme == 'https') {
              // Fire-and-forget launch; failures are swallowed so the
              // WebView stays on the artifact.
              // ignore: discarded_futures
              launchUrl(
                Uri.parse(url.toString()),
                mode: LaunchMode.externalApplication,
              );
            }
            return NavigationActionPolicy.CANCEL;
          },
        ),
      ),
    );
  }
}
