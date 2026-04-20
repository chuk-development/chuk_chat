// ci/linux_full/lib/widgets/linux_webview.dart
//
// FULL implementation of the Linux WebView shim, swapped in by the
// `build-linux-x64-full` / `build-linux-arm64-full` CI jobs. Uses
// `webview_cef` (Chromium Embedded Framework) to render Excalidraw
// scenes and user-provided HTML artifacts in a real browser engine.
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
// and libsecret handles. The Excalidraw artifact is a trusted local
// bundle (we ship bundle.js ourselves) so running it is safe. User-
// provided HTML is LLM-generated and must be treated as untrusted, so
// we do two things:
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
//
// Asset handling
// --------------
// The Excalidraw shell (`assets/excalidraw/index.html` + `bundle.js` +
// `bundle.css` + `fonts/*`) is packed into the Flutter asset bundle at
// build time. CEF can only load `file://` URLs, so on first use we
// extract the directory to the app's temp dir. Extraction guards
// against asset-manifest path traversal by resolving each destination
// and asserting it stays under the target directory.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_cef/webview_cef.dart';

import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/excalidraw_widget.dart';
import 'package:chuk_chat/widgets/html_artifact_view_source_fallback.dart';

/// One-shot CEF bootstrap. Idempotent and safe to call from multiple
/// widgets — the underlying manager guards against double init.
Future<void> _ensureCefInitialised() async {
  await WebviewManager().initialize(userAgent: 'chuk_chat');
}

/// Writes `assets/excalidraw/*` to a per-app temp dir the first time it
/// is called. Returns the path to the extracted `index.html`. Guards
/// against path-traversal in the AssetManifest (which would require a
/// supply-chain compromise, but the check is cheap and defensive).
Future<String?> _extractExcalidrawBundle() async {
  try {
    final tmp = await getTemporaryDirectory();
    final dir = Directory(p.join(tmp.path, 'chuk_chat_excalidraw'));
    final indexFile = File(p.join(dir.path, 'index.html'));
    if (await indexFile.exists()) return indexFile.path;
    await dir.create(recursive: true);
    final dirReal = p.normalize(dir.absolute.path);

    final manifestJson = await rootBundle.loadString('AssetManifest.json');
    final manifest = jsonDecode(manifestJson) as Map<String, dynamic>;
    final assetPaths = manifest.keys
        .where((k) => k.startsWith('assets/excalidraw/'))
        .toList();
    for (final asset in assetPaths) {
      final relative = asset.substring('assets/excalidraw/'.length);
      if (relative.isEmpty) continue;
      final dest = File(p.join(dir.path, relative));
      final destReal = p.normalize(dest.absolute.path);
      // Defence in depth: refuse entries that would escape the target
      // directory. Normal Flutter assets cannot contain `..`, but a
      // compromised AssetManifest should not be able to write arbitrary
      // files on disk.
      if (!p.isWithin(dirReal, destReal) && destReal != dirReal) {
        if (kDebugMode) {
          debugPrint('Skipping asset with suspicious path: $asset');
        }
        continue;
      }
      await dest.parent.create(recursive: true);
      final data = await rootBundle.load(asset);
      await dest.writeAsBytes(data.buffer.asUint8List(), flush: true);
    }
    return indexFile.path;
  } catch (e) {
    if (kDebugMode) debugPrint('Excalidraw asset extract failed: $e');
    return null;
  }
}

/// Wraps user-supplied HTML in a document whose top frame enforces a
/// strict Content-Security-Policy and whose body is a sandboxed
/// `<iframe>` carrying the user HTML via `srcdoc`. Because the iframe
/// omits `allow-same-origin`, it runs in an opaque origin and has no
/// access to cookies, localStorage, or the outer frame. Without
/// `allow-top-navigation`, a malicious payload also cannot redirect
/// the top frame to a phishing URL.
String _wrapSandboxedHtml(String userHtml) {
  // srcdoc attribute lives inside a double-quoted HTML attribute, so
  // the minimum escapes needed are `&` and `"`. `<`/`>` are fine inside
  // attribute values (they become plain text) and preserving them
  // keeps the inner HTML intact.
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
  const LinuxWebView._excalidraw({required this.excalidrawJson})
      : htmlContent = null,
        captureKey = null;

  const LinuxWebView._html({required this.htmlContent, required this.captureKey})
      : excalidrawJson = null;

  final String? excalidrawJson;
  final String? htmlContent;
  final GlobalKey? captureKey;

  static Widget excalidraw({required String jsonString}) =>
      LinuxWebView._excalidraw(excalidrawJson: jsonString);

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
    try {
      await _ensureCefInitialised();
      final controller = WebviewManager().createWebView();
      _controller = controller;

      controller.setWebviewListener(
        WebviewEventsListener(
          onUrlChanged: _onUrlChanged,
        ),
      );

      final scene = widget.excalidrawJson;
      final body = widget.htmlContent;

      String initialUrl;
      if (scene != null) {
        final indexPath = await _extractExcalidrawBundle();
        if (indexPath == null) throw StateError('asset extract failed');
        initialUrl = Uri.file(indexPath).toString();
      } else if (body != null) {
        final wrapped = _wrapSandboxedHtml(body);
        final encoded = base64Encode(utf8.encode(wrapped));
        initialUrl = 'data:text/html;charset=utf-8;base64,$encoded';
      } else {
        initialUrl = 'about:blank';
      }

      await controller.initialize(initialUrl);
      if (scene != null) {
        await controller.setJavaScriptChannels({
          JavascriptChannel(
            name: 'chukBridge',
            onMessageReceived: (m) => _onBridgeMessage(m.message, scene),
          ),
        });
      }
      if (!mounted) return;
      setState(() => _state = _LoadState.ready);
    } catch (e) {
      if (kDebugMode) debugPrint('LinuxWebView bootstrap failed: $e');
      // Tear down any half-created controller so build() doesn't treat
      // it as ready and try to render against an uninitialised native
      // browser handle.
      unawaited(_controller?.dispose() ?? Future<void>.value());
      _controller = null;
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
  /// URL to the system browser via url_launcher. This mirrors the
  /// `shouldOverrideUrlLoading` policy on mobile/macOS/Windows.
  void _onUrlChanged(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    final scheme = uri.scheme.toLowerCase();
    // Trusted schemes for our own content.
    if (scheme == 'file' || scheme == 'about' ||
        scheme == 'data' || scheme == 'blob' || scheme.isEmpty) {
      return;
    }
    // Anything else (http, https, javascript, file-outside-bundle) is
    // redirected away and, if it was an external web link, surfaced in
    // the system browser.
    unawaited(_controller?.loadUrl('about:blank') ?? Future<void>.value());
    if (scheme == 'http' || scheme == 'https') {
      unawaited(
        launchUrl(uri, mode: LaunchMode.externalApplication).catchError(
          (_) => false,
        ),
      );
    }
  }

  Future<void> _pushScene(String json) async {
    final ctrl = _controller;
    if (ctrl == null) return;
    // NOTE: `jsonEncode(json)` produces a JS string literal. The inner
    // scene JSON is already escaped once by the caller, so what we send
    // is `setScene("{\"elements\":...}")` — a quoted string that the
    // browser's JSON.parse in entry.jsx reads. If you ever change this
    // injection point to splice into an inline `<script>` tag, audit
    // for U+2028/U+2029 and `</script>` sequences — jsonEncode does
    // not escape them.
    try {
      await ctrl.executeJavaScript(
        'window.chukExcalidraw && window.chukExcalidraw.setScene(${jsonEncode(json)});',
      );
    } catch (e) {
      if (kDebugMode) debugPrint('Excalidraw push scene failed: $e');
    }
  }

  void _onBridgeMessage(String raw, String pendingScene) {
    Map<String, dynamic>? msg;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) msg = decoded;
    } catch (_) {
      return;
    }
    if (msg == null) return;
    if (msg['type'] == 'ready') {
      unawaited(_pushScene(pendingScene));
    }
  }

  @override
  void didUpdateWidget(covariant LinuxWebView old) {
    super.didUpdateWidget(old);
    final next = widget.excalidrawJson;
    if (next != null && old.excalidrawJson != next && _controller != null) {
      unawaited(_pushScene(next));
    }
  }

  @override
  void dispose() {
    // `dispose()` on WebViewController is async and tears down the CEF
    // browser. We can't await inside State.dispose, so fire-and-forget;
    // webview_cef's manager cleans up on app quit regardless.
    unawaited(_controller?.dispose() ?? Future<void>.value());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (_state == _LoadState.failed || controller == null) {
      return _Fallback(
        excalidrawJson: widget.excalidrawJson,
        htmlContent: widget.htmlContent,
        captureKey: widget.captureKey,
        error: _lastError,
      );
    }
    if (_state == _LoadState.loading) {
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
    required this.excalidrawJson,
    required this.htmlContent,
    required this.captureKey,
    required this.error,
  });

  final String? excalidrawJson;
  final String? htmlContent;
  final GlobalKey? captureKey;
  final Object? error;

  @override
  Widget build(BuildContext context) {
    final scene = excalidrawJson;
    final body = htmlContent;
    Widget child;
    if (scene != null) {
      child = ExcalidrawWidget(jsonString: scene);
    } else if (body != null) {
      child = HtmlSourceFallback(html: body);
    } else {
      child = const SizedBox.shrink();
    }
    return RepaintBoundary(
      key: captureKey,
      child: Stack(
        children: [
          Positioned.fill(child: child),
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
