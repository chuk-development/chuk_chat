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
import 'package:flutter/services.dart' show AssetManifest, rootBundle;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_cef/webview_cef.dart';

import 'package:chuk_chat/utils/theme_extensions.dart';
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

    // Flutter 3.38+ serves the new binary `AssetManifest.bin` by
    // default and removes `AssetManifest.json`. Try the binary format
    // first via AssetManifest.loadFromAssetBundle, fall back to the
    // legacy JSON for older bundles.
    List<String> assetPaths = const [];
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(rootBundle);
      assetPaths = manifest
          .listAssets()
          .where((k) => k.startsWith('assets/excalidraw/'))
          .toList();
    } catch (_) {
      try {
        final manifestJson =
            await rootBundle.loadString('AssetManifest.json');
        final manifest = jsonDecode(manifestJson) as Map<String, dynamic>;
        assetPaths = manifest.keys
            .where((k) => k.startsWith('assets/excalidraw/'))
            .toList();
      } catch (e) {
        // ignore: avoid_print
        print('[LinuxWebView] asset manifest unreadable: $e');
        rethrow;
      }
    }

    if (assetPaths.isEmpty) {
      // ignore: avoid_print
      print('[LinuxWebView] no assets under assets/excalidraw/ in manifest');
      return null;
    }

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
        // ignore: avoid_print
        print('[LinuxWebView] skipping asset with suspicious path: $asset');
        continue;
      }
      await dest.parent.create(recursive: true);
      final data = await rootBundle.load(asset);
      await dest.writeAsBytes(data.buffer.asUint8List(), flush: true);
    }
    if (!await indexFile.exists()) {
      // ignore: avoid_print
      print('[LinuxWebView] extracted bundle but index.html missing at '
          '${indexFile.path}');
      return null;
    }
    return indexFile.path;
  } catch (e, stack) {
    // ignore: avoid_print
    print('[LinuxWebView] Excalidraw asset extract failed: $e\n$stack');
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
  String? _currentScene;
  bool _sceneInjected = false;

  @override
  void initState() {
    super.initState();
    _currentScene = widget.excalidrawJson;
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
        WebviewEventsListener(
          onUrlChanged: _onUrlChanged,
          onLoadEnd: (_, __) => _onLoadEnd(),
        ),
      );

      final scene = widget.excalidrawJson;
      final body = widget.htmlContent;

      stage = 'resolve-initial-url';
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

      // ignore: avoid_print
      print('[LinuxWebView] loading $initialUrl');
      stage = 'controller-initialize';
      await pending.initialize(initialUrl);
      // ignore: avoid_print
      print('[LinuxWebView] controller initialised');
      // Only expose the controller to the widget tree once initialize()
      // has completed — webview_cef's internal `_creatingCompleter` is
      // not set before initialize runs, so calling `dispose()` on a
      // half-built controller throws LateInitializationError.
      _controller = pending;
      pending = null;

      if (scene != null) {
        stage = 'js-channels';
        // webview_cef injects `window.<name> = (e,r) => external...` as a
        // FUNCTION (not an object). The Excalidraw bundle expects
        // `window.chukBridge.post(msg)`, so the shim in _onLoadEnd
        // repacks the function into `{ post: fn }` after every load.
        await _controller!.setJavaScriptChannels({
          JavascriptChannel(
            name: 'chukBridge',
            onMessageReceived: (m) => _onBridgeMessage(m.message),
          ),
        });
      }
      if (!mounted) return;
      setState(() => _state = _LoadState.ready);
    } catch (e, stack) {
      // Always log to stderr so release builds surface the reason on
      // the tty — kDebugMode-only logging hid the cause behind an
      // unlabelled red-icon card.
      // ignore: avoid_print
      print('[LinuxWebView] bootstrap failed at stage="$stage": $e\n$stack');
      // If initialize completed but a later step failed, dispose the
      // now-owned controller. If initialize never ran, pending is still
      // set and webview_cef has no teardown for it — leaking the
      // JS-side browser slot is cheaper than crashing on dispose.
      final owned = _controller;
      _controller = null;
      if (pending == null && owned != null) {
        unawaited(() async {
          try {
            await owned.dispose();
          } catch (_) {
            // Swallow LateInitializationError etc. — this is best-effort
            // cleanup on a failed bootstrap.
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
      _sceneInjected = true;
    } catch (e) {
      if (kDebugMode) debugPrint('Excalidraw push scene failed: $e');
    }
  }

  /// Runs after every page load inside the CEF frame. We reach this
  /// point AFTER webview_cef's `setJavaScriptChannels` injection ran, so
  /// `window.chukBridge` exists as a bare function. The bundle expects
  /// `window.chukBridge.post(...)`, so we repack it here, then push the
  /// scene — relying on the bundle's own `ready` ping is racy because it
  /// fires before the channel is wired.
  Future<void> _onLoadEnd() async {
    final ctrl = _controller;
    if (ctrl == null) return;
    try {
      await ctrl.executeJavaScript(
        '(function(){'
        'var fn = window.chukBridge;'
        'if (typeof fn === "function") {'
        'window.chukBridge = { post: function(m){ try { fn(m); } catch(_){} } };'
        '}'
        '})();',
      );
    } catch (e) {
      if (kDebugMode) debugPrint('chukBridge shim injection failed: $e');
    }
    // Re-read after the await — didUpdateWidget may have swapped
    // _currentScene while the JS injection was in flight, in which case
    // pushing the older capture would overwrite the fresh scene.
    final scene = _currentScene;
    if (scene != null) {
      await _pushScene(scene);
    }
  }

  void _onBridgeMessage(String raw) {
    Map<String, dynamic>? msg;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) msg = decoded;
    } catch (_) {
      return;
    }
    if (msg == null) return;
    final type = msg['type'];
    if (type == 'ready') {
      final scene = _currentScene;
      if (scene != null && !_sceneInjected) unawaited(_pushScene(scene));
    } else if (type == 'error' && kDebugMode) {
      debugPrint('Excalidraw bundle error: ${msg['message']}');
    }
  }

  @override
  void didUpdateWidget(covariant LinuxWebView old) {
    super.didUpdateWidget(old);
    final next = widget.excalidrawJson;
    if (next != null && old.excalidrawJson != next) {
      _currentScene = next;
      _sceneInjected = false;
      if (_controller != null) unawaited(_pushScene(next));
    }
  }

  @override
  void dispose() {
    // `dispose()` on WebViewController is async and tears down the CEF
    // browser. We can't await inside State.dispose, so fire-and-forget;
    // webview_cef's manager cleans up on app quit regardless.
    final owned = _controller;
    _controller = null;
    if (owned != null) {
      unawaited(() async {
        try {
          await owned.dispose();
        } catch (_) {
          // Safety net for the same LateInitializationError handled in
          // _bootstrap — if the widget is removed before initialize
          // completes, dispose races with a half-built controller.
        }
      }());
    }
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
    final isExcalidraw = excalidrawJson != null;
    // HTML artifacts can still fall back to the read-only source view
    // (it's plain text, not a re-implementation of the browser). For
    // Excalidraw there is no fallback — we refuse to render a
    // fake/simplified version and surface the error directly.
    Widget child;
    if (isExcalidraw) {
      child = Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 12),
              const Text(
                'Excalidraw WebView (CEF) failed to initialise.',
                textAlign: TextAlign.center,
              ),
              if (error != null) ...[
                const SizedBox(height: 8),
                SelectableText(
                  '$error',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 11, color: Colors.red),
                ),
              ],
            ],
          ),
        ),
      );
    } else if (htmlContent != null) {
      child = HtmlSourceFallback(html: htmlContent!);
    } else {
      child = const SizedBox.shrink();
    }
    return RepaintBoundary(
      key: captureKey,
      child: Stack(
        children: [
          Positioned.fill(child: child),
          if (kDebugMode && error != null && !isExcalidraw)
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
