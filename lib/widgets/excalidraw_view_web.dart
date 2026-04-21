// lib/widgets/excalidraw_view_web.dart
//
// Flutter Web renderer for Excalidraw artifacts. Embeds the same bundled
// HTML shell via an `<iframe>` using HtmlElementView, and uses
// window.postMessage with JSON-string payloads for the Dart <-> JS
// bridge. Falls back to the native CustomPainter when the iframe fails.

import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;


enum ExcalidrawViewMode { readOnly, edit }

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

/// Monotonic counter so every widget instance registers a unique view
/// type — Flutter web asserts that factories are registered only once
/// per identifier.
int _factoryCounter = 0;

class _ExcalidrawViewState extends State<ExcalidrawView> {
  late final String _viewType;
  web.HTMLIFrameElement? _iframe;
  StreamSubscription<web.MessageEvent>? _messagesSub;
  bool _jsReady = false;
  bool _failed = false;
  Object? _lastError;

  @override
  void initState() {
    super.initState();
    _viewType = 'chuk-excalidraw-${++_factoryCounter}';
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int viewId) {
      final iframe = web.HTMLIFrameElement()
        ..src = 'assets/assets/excalidraw/index.html'
        ..style.border = 'none'
        ..style.width = '100%'
        ..style.height = '100%'
        ..setAttribute(
          'sandbox',
          'allow-scripts allow-same-origin',
        );
      _iframe = iframe;
      return iframe;
    });
    _messagesSub = web.window.onMessage.listen(_onMessage);
  }

  @override
  void didUpdateWidget(covariant ExcalidrawView old) {
    super.didUpdateWidget(old);
    if (old.jsonString != widget.jsonString) {
      _pushScene();
    }
    if (old.viewMode != widget.viewMode) {
      _pushViewMode();
    }
  }

  @override
  void dispose() {
    _messagesSub?.cancel();
    super.dispose();
  }

  void _onMessage(web.MessageEvent evt) {
    // Only trust messages coming from the iframe instance we created.
    // Otherwise any other frame on the page can spoof readiness or force
    // the fallback renderer by posting a crafted "error" payload.
    final expected = _iframe?.contentWindow;
    if (expected == null || evt.source != expected) return;

    // The iframe sends JSON strings — parse into a Dart map here so the
    // web side never has to poke at JS object properties.
    final raw = evt.data;
    if (raw == null) return;
    final String payload;
    try {
      payload = (raw as JSString).toDart;
    } catch (_) {
      return;
    }
    Map<String, dynamic>? decoded;
    try {
      final parsed = jsonDecode(payload);
      if (parsed is Map<String, dynamic>) decoded = parsed;
    } catch (_) {
      return;
    }
    if (decoded == null) return;

    switch (decoded['type']) {
      case 'ready':
        _jsReady = true;
        _pushScene();
        _pushViewMode();
        if (mounted) setState(() {});
      case 'error':
        if (mounted) {
          setState(() {
            _failed = true;
            _lastError = decoded?['message'];
          });
        }
    }
  }

  void _pushScene() {
    final iframe = _iframe;
    if (iframe == null || !_jsReady) return;
    final window = iframe.contentWindow;
    if (window == null) return;
    try {
      window.postMessage(
        jsonEncode({'type': 'scene', 'payload': widget.jsonString}).toJS,
        '*'.toJS,
      );
    } catch (e) {
      if (kDebugMode) debugPrint('Excalidraw postMessage failed: $e');
    }
  }

  void _pushViewMode() {
    final iframe = _iframe;
    if (iframe == null || !_jsReady) return;
    final window = iframe.contentWindow;
    if (window == null) return;
    final mode =
        widget.viewMode == ExcalidrawViewMode.edit ? 'edit' : 'readOnly';
    try {
      window.postMessage(
        jsonEncode({'type': 'viewMode', 'mode': mode}).toJS,
        '*'.toJS,
      );
    } catch (_) {
      // non-fatal
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_failed) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 48, color: Colors.red),
              const SizedBox(height: 12),
              const Text(
                'Excalidraw iframe failed to initialise.',
                textAlign: TextAlign.center,
              ),
              if (kDebugMode && _lastError != null) ...[
                const SizedBox(height: 8),
                Text(
                  '$_lastError',
                  textAlign: TextAlign.center,
                  style: const TextStyle(fontSize: 11, color: Colors.red),
                ),
              ],
            ],
          ),
        ),
      );
    }
    return Stack(
      children: [
        Positioned.fill(child: HtmlElementView(viewType: _viewType)),
        if (!_jsReady)
          const Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
      ],
    );
  }
}
