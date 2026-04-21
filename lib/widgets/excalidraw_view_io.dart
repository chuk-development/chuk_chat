// lib/widgets/excalidraw_view_io.dart
//
// Native (non-web) renderer for Excalidraw artifacts. Uses
// flutter_inappwebview to host a bundled HTML shell that loads the real
// @excalidraw/excalidraw React component from
// `assets/excalidraw/bundle.js`. No network access is required.
//
// Desktop Linux builds don't ship a stable WebView backend in this
// default codebase, so Linux shows an error card with a link to open
// the scene in excalidraw.com. The `-full` Linux CI variant swaps in a
// `webview_cef`-backed LinuxWebView that loads the same bundle via an
// in-process Chromium iframe.

import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'package:chuk_chat/widgets/linux_webview.dart';

class ExcalidrawView extends StatefulWidget {
  const ExcalidrawView({
    super.key,
    required this.jsonString,
    this.viewMode = ExcalidrawViewMode.readOnly,
  });

  final String jsonString;
  final ExcalidrawViewMode viewMode;

  @override
  State<ExcalidrawView> createState() => _ExcalidrawViewState();
}

enum ExcalidrawViewMode { readOnly, edit }

enum _LoadState { loading, ready, failed }

class _ExcalidrawViewState extends State<ExcalidrawView> {
  InAppWebViewController? _controller;
  _LoadState _state = _LoadState.loading;
  Object? _lastError;

  /// Prevents a race where setScene arrives before the JS bundle finishes
  /// hydrating and registers `window.chukExcalidraw`.
  bool _jsReady = false;

  /// Latest scene we were asked to render. Used on `ready` and on
  /// `didUpdateWidget` to push the scene down to JS.
  late String _pendingScene;

  @override
  void initState() {
    super.initState();
    _pendingScene = widget.jsonString;
  }

  @override
  void didUpdateWidget(covariant ExcalidrawView old) {
    super.didUpdateWidget(old);
    if (old.jsonString != widget.jsonString) {
      _pendingScene = widget.jsonString;
      _pushScene();
    }
    if (old.viewMode != widget.viewMode) {
      _pushViewMode();
    }
  }

  Future<void> _pushScene() async {
    final ctrl = _controller;
    if (ctrl == null || !_jsReady) return;
    try {
      await ctrl.evaluateJavascript(
        source:
            'window.chukExcalidraw && window.chukExcalidraw.setScene(${jsonEncode(_pendingScene)});',
      );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Excalidraw push scene failed: $e');
      }
    }
  }

  Future<void> _pushViewMode() async {
    final ctrl = _controller;
    if (ctrl == null || !_jsReady) return;
    final mode = widget.viewMode == ExcalidrawViewMode.edit ? 'edit' : 'readOnly';
    try {
      await ctrl.evaluateJavascript(
        source:
            "window.chukExcalidraw && window.chukExcalidraw.setViewMode('$mode');",
      );
    } catch (_) {
      // non-fatal
    }
  }

  void _onBridgeMessage(List<dynamic> args) {
    if (args.isEmpty) return;
    final raw = args.first;
    if (raw is! String) return;
    Map<String, dynamic>? msg;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        msg = decoded;
      }
    } catch (_) {
      return;
    }
    if (msg == null) return;

    final type = msg['type'];
    if (type == 'ready') {
      _jsReady = true;
      if (mounted) setState(() => _state = _LoadState.ready);
      _pushScene();
      _pushViewMode();
    } else if (type == 'scene-loaded') {
      // Optional telemetry; ignore in release.
      if (kDebugMode) {
        debugPrint(
          'Excalidraw scene loaded, elements=${msg['elementCount']}',
        );
      }
    } else if (type == 'error') {
      if (mounted) {
        setState(() {
          _state = _LoadState.failed;
          _lastError = msg?['message'];
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // Linux: delegate to LinuxWebView. The default implementation (in
    // lib/widgets/linux_webview.dart) returns the CustomPainter fallback;
    // the `-full` CI build swaps that file with a webview_cef-backed
    // version that renders the real Excalidraw React bundle.
    if (Platform.isLinux) {
      return LinuxWebView.excalidraw(jsonString: widget.jsonString);
    }
    return Stack(
      children: [
        Positioned.fill(
          child: InAppWebView(
            initialFile: 'assets/excalidraw/index.html',
            initialSettings: InAppWebViewSettings(
              // Security: no network; script disabled for about: navigations.
              javaScriptEnabled: true,
              javaScriptCanOpenWindowsAutomatically: false,
              // WebView features we don't need — turn them off so an
              // attacker-shaped scene JSON cannot exploit them.
              mediaPlaybackRequiresUserGesture: true,
              allowsInlineMediaPlayback: false,
              allowFileAccessFromFileURLs: false,
              allowUniversalAccessFromFileURLs: false,
              // Transparent so the artifact panel's background shows while
              // the bundle initialises.
              transparentBackground: true,
              // Desktop-only: surface console logs in debug builds.
              isInspectable: kDebugMode,
              // Prevent arbitrary url navigation away from our shell.
              useShouldOverrideUrlLoading: true,
              supportZoom: false,
            ),
            shouldOverrideUrlLoading: (controller, action) async {
              // Only allow our own bundled assets; everything else is blocked.
              // The asset-path check is scoped to `file://` so external hosts
              // cannot smuggle navigation in with a crafted
              // `https://attacker.com/assets/excalidraw/...` URL.
              final uri = action.request.url;
              if (uri == null) return NavigationActionPolicy.CANCEL;
              final scheme = uri.scheme.toLowerCase();
              if (scheme == 'about' ||
                  scheme == 'data' ||
                  scheme == 'blob') {
                return NavigationActionPolicy.ALLOW;
              }
              if (scheme == 'file' &&
                  uri.path.contains('/assets/excalidraw/')) {
                return NavigationActionPolicy.ALLOW;
              }
              return NavigationActionPolicy.CANCEL;
            },
            onWebViewCreated: (controller) {
              _controller = controller;
              controller.addJavaScriptHandler(
                handlerName: 'chukBridge',
                callback: _onBridgeMessage,
              );
              // Inject a tiny shim that exposes `window.chukBridge.post(msg)`
              // which proxies to the Dart handler via the official
              // flutter_inappwebview message-channel.
              controller.evaluateJavascript(source: r'''
                window.chukBridge = {
                  post(msg) {
                    try {
                      window.flutter_inappwebview.callHandler('chukBridge', msg);
                    } catch (e) {
                      /* bridge not ready */
                    }
                  },
                };
              ''');
            },
            onConsoleMessage: (controller, message) {
              if (kDebugMode) {
                debugPrint('Excalidraw [${message.messageLevel}]: '
                    '${message.message}');
              }
            },
            onReceivedError: (controller, request, error) {
              if (mounted) {
                setState(() {
                  _state = _LoadState.failed;
                  _lastError = error.description;
                });
              }
            },
            onLoadStop: (controller, url) async {
              // Re-register the bridge after navigations in case the
              // previous frame was discarded.
              await controller.evaluateJavascript(source: r'''
                if (!window.chukBridge) {
                  window.chukBridge = {
                    post(msg) {
                      try { window.flutter_inappwebview.callHandler('chukBridge', msg); } catch (_) {}
                    },
                  };
                }
              ''');
            },
          ),
        ),
        if (_state == _LoadState.loading)
          const Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        if (_state == _LoadState.failed) _WebViewFailedFallback(error: _lastError),
      ],
    );
  }
}

/// Shown when the WebView can't initialise. The app no longer ships a
/// custom Flutter-painter fallback renderer — the scene is either
/// rendered by the real Excalidraw bundle via a native/CEF WebView, or
/// not at all. Users get a clear error card instead of a silent
/// degraded drawing.
class _WebViewFailedFallback extends StatelessWidget {
  const _WebViewFailedFallback({required this.error});

  final Object? error;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Container(
        color: Theme.of(context).scaffoldBackgroundColor,
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 12),
              const Text(
                'Excalidraw WebView failed to initialise.',
                textAlign: TextAlign.center,
              ),
              if (kDebugMode && error != null) ...[
                const SizedBox(height: 8),
                Text(
                  '$error',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 11, color: Colors.red),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
