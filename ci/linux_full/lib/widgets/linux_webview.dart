// ci/linux_full/lib/widgets/linux_webview.dart
//
// FULL implementation of the Linux WebView shim, swapped in by the
// `build-linux-x64-full` / `build-linux-arm64-full` CI jobs. Uses
// `webview_cef` (Chromium Embedded Framework) to render
// user-provided HTML artifacts in a real browser engine.
//
// Public API matches `lib/widgets/linux_webview.dart` (slim) — keep
// both files in lock-step when changing the surface, or CI "full"
// builds will fail.
//
// Security posture
// ----------------
// CEF on Linux via webview_cef 0.2.2 runs in a single-process model —
// a renderer compromise lands inside the Flutter app process, which
// also holds the user's Supabase session, the local encryption key,
// and libsecret handles. User-provided HTML is LLM-generated and must
// be treated as untrusted, so we do two things:
//
//   1. Wrap it in an outer document with a strict Content-Security-
//      Policy and render it inside an `<iframe sandbox="allow-scripts
//      allow-forms">`. The iframe has no `allow-same-origin` flag, so
//      it runs in an opaque origin — no access to cookies, localStorage,
//      or the outer document. `allow-top-navigation` is withheld, so a
//      malicious payload cannot navigate the top frame to a phishing
//      URL.
//
//   2. Install a URL-change listener that snaps the top frame back to
//      `about:blank` and opens any attempted http(s) navigation in the
//      system browser via `url_launcher`. This matches the policy used
//      by the flutter_inappwebview path on Android/iOS/macOS/Windows.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_cef/webview_cef.dart';

import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/html_artifact_view_source_fallback.dart';

/// One-shot CEF bootstrap. Idempotent and safe to call from multiple
/// widgets — the underlying manager guards against double init.
Future<void> _ensureCefInitialised() async {
  await WebviewManager().initialize(userAgent: 'chuk_chat');
}

/// Wraps user-supplied HTML in a document whose top frame enforces a
/// strict Content-Security-Policy and whose body is a sandboxed
/// `<iframe>` carrying the user HTML via `srcdoc`. Because the iframe
/// omits `allow-same-origin`, it runs in an opaque origin and has no
/// access to cookies, localStorage, or the outer frame. Without
/// `allow-top-navigation`, a malicious payload also cannot redirect
/// the top frame to a phishing URL.
String _wrapSandboxedHtml(String userHtml) {
  final escaped = userHtml.replaceAll('&', '&amp;').replaceAll('"', '&quot;');
  return '''<!doctype html>
<html>
<head>
<meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; frame-src data:; style-src 'unsafe-inline'; img-src data: blob:; form-action 'none'; base-uri 'none'; frame-ancestors 'none';">
<style>html,body,iframe{margin:0;padding:0;border:0;width:100%;height:100%;background:#fff}</style>
</head>
<body>
<iframe sandbox="allow-scripts allow-forms" srcdoc="$escaped"></iframe>
</body>
</html>''';
}

class LinuxWebView extends StatefulWidget {
  const LinuxWebView._html({required this.htmlContent, required this.captureKey});

  final String htmlContent;
  final GlobalKey? captureKey;

  static Widget html({required String html, GlobalKey? captureKey}) =>
      LinuxWebView._html(htmlContent: html, captureKey: captureKey);

  @override
  State<LinuxWebView> createState() => _LinuxWebViewState();
}

enum _LoadState { loading, ready, failed }

class _LinuxWebViewState extends State<LinuxWebView> {
  WebViewController? _controller;
  _LoadState _state = _LoadState.loading;
  Object? _lastError;

  @override
  void initState() {
    super.initState();
    unawaited(_bootstrap());
  }

  Future<void> _bootstrap() async {
    WebViewController? pending;
    String stage = 'cef-init';
    try {
      // ignore: avoid_print
      print('[LinuxWebView] bootstrap start');
      await _ensureCefInitialised();
      stage = 'create-webview';
      // ignore: avoid_print
      print('[LinuxWebView] cef ready — creating browser');
      pending = WebviewManager().createWebView();
      pending.setWebviewListener(
        WebviewEventsListener(onUrlChanged: _onUrlChanged),
      );

      stage = 'resolve-initial-url';
      final wrapped = _wrapSandboxedHtml(widget.htmlContent);
      final encoded = base64Encode(utf8.encode(wrapped));
      final initialUrl = 'data:text/html;charset=utf-8;base64,$encoded';

      // ignore: avoid_print
      print('[LinuxWebView] loading $initialUrl');
      stage = 'controller-initialize';
      await pending.initialize(initialUrl);
      // ignore: avoid_print
      print('[LinuxWebView] controller initialised');
      _controller = pending;
      pending = null;

      if (!mounted) return;
      setState(() => _state = _LoadState.ready);
    } catch (e, stack) {
      // ignore: avoid_print
      print('[LinuxWebView] bootstrap failed at stage="$stage": $e\n$stack');
      final owned = _controller;
      _controller = null;
      if (pending == null && owned != null) {
        unawaited(() async {
          try {
            await owned.dispose();
          } catch (_) {
            // Best-effort cleanup on failed bootstrap.
          }
        }());
      }
      if (!mounted) return;
      setState(() {
        _state = _LoadState.failed;
        _lastError = e;
      });
    }
  }

  /// CEF's URL-change hook fires AFTER a navigation starts. webview_cef
  /// 0.2.2 exposes no pre-commit cancellation, so when the user clicks
  /// an external link inside an artifact we redirect the top frame to
  /// `about:blank` (interrupting the bad page) and hand the original
  /// URL to the system browser via url_launcher.
  void _onUrlChanged(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    final scheme = uri.scheme.toLowerCase();
    if (scheme == 'file' ||
        scheme == 'about' ||
        scheme == 'data' ||
        scheme == 'blob' ||
        scheme.isEmpty) {
      return;
    }
    unawaited(_controller?.loadUrl('about:blank') ?? Future<void>.value());
    if (scheme == 'http' || scheme == 'https') {
      unawaited(
        launchUrl(uri, mode: LaunchMode.externalApplication).catchError(
          (_) => false,
        ),
      );
    }
  }

  @override
  void dispose() {
    final owned = _controller;
    _controller = null;
    if (owned != null) {
      unawaited(() async {
        try {
          await owned.dispose();
        } catch (_) {
          // Safety net — if the widget is removed before initialize
          // completes, dispose races with a half-built controller.
        }
      }());
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (_state == _LoadState.failed) {
      return _Fallback(
        htmlContent: widget.htmlContent,
        captureKey: widget.captureKey,
        error: _lastError,
      );
    }
    if (_state == _LoadState.loading || controller == null) {
      return const Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    final iconFg = Theme.of(context).resolvedIconColor;
    return RepaintBoundary(
      key: widget.captureKey,
      child: Container(
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: iconFg.withValues(alpha: 0.15)),
          borderRadius: BorderRadius.circular(8),
        ),
        clipBehavior: Clip.antiAlias,
        child: WebView(controller),
      ),
    );
  }
}

class _Fallback extends StatelessWidget {
  const _Fallback({
    required this.htmlContent,
    required this.captureKey,
    required this.error,
  });

  final String htmlContent;
  final GlobalKey? captureKey;
  final Object? error;

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      key: captureKey,
      child: Stack(
        children: [
          Positioned.fill(child: HtmlSourceFallback(html: htmlContent)),
          if (kDebugMode && error != null)
            Positioned(
              left: 8,
              bottom: 8,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.red.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  'CEF failed: $error',
                  style: const TextStyle(fontSize: 10, color: Colors.red),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
