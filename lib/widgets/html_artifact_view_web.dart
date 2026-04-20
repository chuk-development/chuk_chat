// lib/widgets/html_artifact_view_web.dart
// Web implementation of HtmlArtifactView.
//
// Renders the user-provided HTML inside a sandboxed <iframe srcdoc>.
// Sandbox value is "allow-scripts" ONLY — crucially NOT
// "allow-same-origin", so scripts cannot read our cookies, local
// storage, or fetch from our origin. The iframe also cannot navigate
// the top frame or auto-open popups.

import 'dart:js_interop';
import 'dart:ui_web' as ui_web;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

import 'package:chuk_chat/utils/theme_extensions.dart';

/// Matches the native predicate so the test surface is shared.
bool shouldLoadInWebView(Uri? uri) {
  if (uri == null) return true;
  final scheme = uri.scheme.toLowerCase();
  return scheme.isEmpty ||
      scheme == 'about' ||
      scheme == 'data' ||
      scheme == 'blob';
}

class HtmlArtifactView extends StatefulWidget {
  const HtmlArtifactView({
    super.key,
    required this.html,
    this.captureKey,
  });

  final String html;

  /// Unused on web (PNG export of iframe contents is blocked by the
  /// browser sandbox anyway), kept for API parity.
  final GlobalKey? captureKey;

  @override
  State<HtmlArtifactView> createState() => _HtmlArtifactViewState();
}

class _HtmlArtifactViewState extends State<HtmlArtifactView> {
  String? _viewType;
  bool _registered = false;
  static int _instanceCounter = 0;

  @override
  void initState() {
    super.initState();
    _registerFactory(widget.html);
  }

  @override
  void didUpdateWidget(covariant HtmlArtifactView old) {
    super.didUpdateWidget(old);
    if (old.html != widget.html) {
      // HtmlElementView caches the DOM produced by a view-type factory, so
      // a new factory under a fresh id is the cleanest way to swap the
      // iframe contents when the user switches between artifact versions.
      // Note: ui_web.platformViewRegistry has no public unregister API, so
      // factories from prior versions persist until page reload. That's a
      // very small per-version leak (one closure + one viewType string)
      // and acceptable for typical chat sessions.
      _registerFactory(widget.html);
      if (mounted) setState(() {});
    }
  }

  void _registerFactory(String html) {
    final candidate = 'chuk-html-artifact-${_instanceCounter + 1}';
    try {
      ui_web.platformViewRegistry.registerViewFactory(
        candidate,
        (int viewId) => _buildIframe(html),
      );
      _instanceCounter++;
      _viewType = candidate;
      _registered = true;
    } catch (error) {
      _registered = false;
      _viewType = null;
      if (kDebugMode) {
        debugPrint('Failed to register HTML artifact view factory: $error');
      }
    }
  }

  web.HTMLIFrameElement _buildIframe(String html) {
    final iframe = web.HTMLIFrameElement()
      ..style.border = '0'
      ..style.width = '100%'
      ..style.height = '100%'
      ..setAttribute('sandbox', 'allow-scripts')
      ..setAttribute('referrerpolicy', 'no-referrer')
      ..srcdoc = html.toJS;
    return iframe;
  }

  @override
  Widget build(BuildContext context) {
    final iconFg = Theme.of(context).resolvedIconColor;
    final viewType = _viewType;
    if (!_registered || viewType == null) {
      return Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.errorContainer
              .withValues(alpha: 0.3),
          border: Border.all(color: iconFg.withValues(alpha: 0.15)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          'Unable to render HTML preview in this browser.',
          style: TextStyle(
            fontSize: 12,
            color: Theme.of(context).colorScheme.error,
          ),
        ),
      );
    }
    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: iconFg.withValues(alpha: 0.15)),
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: HtmlElementView(viewType: viewType),
    );
  }
}
