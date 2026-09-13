import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;
import 'package:webview_flutter/webview_flutter.dart';

/// What the viewer page says about its socket.
enum VncPhase {
  /// The page is not loaded yet.
  loading,

  /// First handshake, nothing on screen.
  connecting,

  /// The socket dropped under a painted frame. The picture is still there and
  /// is being refreshed.
  reconnecting,

  /// Live.
  connected,

  /// A recovery failed in front of the user. There is no picture.
  disconnected,
}

/// The host side of the noVNC viewer page.
///
/// It owns the [WebViewController], forwards the page's bridge messages, and
/// exposes the few calls the app's own controls need. It draws no chrome of
/// its own: the page is the picture, and every button lives in the Flutter
/// screen around it.
class VncWebViewController extends ChangeNotifier {
  VncWebViewController();

  WebViewController? _web;
  String? _password;
  bool _pageReady = false;
  bool _started = false;

  VncPhase _phase = VncPhase.loading;
  bool _zoomed = false;
  bool _trackpad = false;
  DateTime? _frameAsOf;

  /// The viewer's own state, as the page reports it.
  VncPhase get phase => _phase;

  /// True while the desktop is magnified, so "Zoom to fit" can light up.
  bool get zoomed => _zoomed;

  /// True while the relative-pointer mode is on. Off is the default: a tap
  /// lands where the finger lands.
  bool get trackpad => _trackpad;

  /// When the picture on screen was last live. Null while it is live now.
  DateTime? get frameAsOf => _frameAsOf;

  /// Text the agent's desktop put on its clipboard.
  final StreamController<String> _clipboard =
      StreamController<String>.broadcast();
  Stream<String> get clipboard => _clipboard.stream;

  /// A PNG data URL of the live desktop, one per [screenshot] call.
  final StreamController<String> _screenshots =
      StreamController<String>.broadcast();
  Stream<String> get screenshots => _screenshots.stream;

  /// The password the page needs at handshake time. It is given to the page
  /// by a JavaScript call, never through the URL, and it is never logged.
  ///
  /// It can change while the view is open: the executor re-handshakes with the
  /// box on its own and rotates the per-view secret every time, so a page that
  /// still held the old one would be refused.
  set password(String? value) {
    if (_password == value) return;
    _password = value;
    if (_started && value != null) {
      _call('agents.setPassword(${jsonEncode(value)})');
      return;
    }
    _maybeStart();
  }

  void attach(WebViewController web) {
    _web = web;
    _maybeStart();
  }

  void _maybeStart() {
    if (_started || !_pageReady || _password == null || _web == null) return;
    _started = true;
    _call('agents.start(${jsonEncode(_password)})');
  }

  void _call(String expression) {
    final WebViewController? web = _web;
    if (web == null) return;
    web.runJavaScript(expression).catchError((Object error) {
      // A call into a page that has gone away is not an app failure.
      if (kDebugMode) debugPrint('[vnc] js call failed: $error');
    });
  }

  /// Handles one message from the page's `AgentsVncBridge` channel.
  void handleBridgeMessage(String raw) {
    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {
      return;
    }
    if (decoded is! Map<String, dynamic>) return;
    switch (decoded['event']) {
      case 'ready':
        _pageReady = true;
        _maybeStart();
      case 'state':
        final VncPhase next = switch (decoded['state']) {
          'connecting' => VncPhase.connecting,
          'reconnecting' => VncPhase.reconnecting,
          'connected' => VncPhase.connected,
          _ => VncPhase.disconnected,
        };
        if (next == VncPhase.connected) {
          _frameAsOf = null;
        } else if (_phase == VncPhase.connected) {
          // The moment the picture stopped being live. It is the age the
          // reconnect note counts from.
          _frameAsOf = DateTime.now();
        }
        _phase = next;
        notifyListeners();
      case 'zoom':
        _zoomed = decoded['zoomed'] == true;
        notifyListeners();
      case 'hold':
        // The one thing a still desktop cannot show: the moment the left
        // button went down under a held finger. Grok's viewer reports this
        // event and its app does nothing with it; a tick of haptic is the
        // whole feedback the gesture has.
        HapticFeedback.selectionClick();
      case 'clipboard':
        final Object? text = decoded['text'];
        if (text is String && !_clipboard.isClosed) _clipboard.add(text);
      case 'screenshot':
        final Object? data = decoded['data'];
        if (data is String && !_screenshots.isClosed) _screenshots.add(data);
    }
  }

  /// Back to the fitted view.
  void zoomToFit() => _call('agents.zoomToFit()');

  /// Try the handshake again after a failed recovery.
  void reconnect() => _call('cowork.reconnect()');

  /// Switch between direct touch (default) and the relative pointer.
  void setTrackpad(bool on) {
    if (_trackpad == on) return;
    _trackpad = on;
    _call('agents.setTrackpad($on)');
    notifyListeners();
  }

  /// Put the virtual pointer back in the middle. The agent moves the real one
  /// with xdotool, so the two drift apart.
  void recenterPointer() => _call('cowork.recenterPointer()');

  /// Printable text from the soft keyboard.
  void typeText(String text) {
    if (text.isEmpty) return;
    _call('agents.typeText(${jsonEncode(text)})');
  }

  /// One non-printable key, as an X11 keysym.
  void sendKeysym(int keysym) => _call('agents.sendKeysym($keysym)');

  /// X11 keysyms the on-screen keyboard sends by name.
  static const int keysymBackspace = 0xff08;
  static const int keysymReturn = 0xff0d;
  static const int keysymTab = 0xff09;
  static const int keysymEscape = 0xff1b;

  /// Stage [text] on the remote clipboard and fire one Ctrl+V.
  void paste(String text) {
    if (text.isEmpty) return;
    _call('cowork.pasteText(${jsonEncode(text)})');
  }

  /// Fire one Ctrl+C. The text comes back on [clipboard].
  void copySelection() => _call('cowork.copySelection()');

  /// Ask for a PNG of the live desktop. It arrives on [screenshots].
  void screenshot() => _call('cowork.screenshot()');

  @override
  void dispose() {
    _clipboard.close();
    _screenshots.close();
    _web = null;
    super.dispose();
  }
}

/// The WebView that runs the viewer page.
///
/// Nothing but the page lives in here. It is deliberately a thin widget: the
/// host screen keeps it in one place in the tree across a full-screen toggle,
/// because rebuilding it would throw the WebView away and with it the socket,
/// the zoom and the pointer.
class VncWebView extends StatefulWidget {
  const VncWebView({
    super.key,
    required this.viewerUrl,
    required this.controller,
  });

  final Uri viewerUrl;
  final VncWebViewController controller;

  @override
  State<VncWebView> createState() => _VncWebViewState();
}

class _VncWebViewState extends State<VncWebView> {
  late final WebViewController _web;

  @override
  void initState() {
    super.initState();
    _web = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      // The letterbox around the desktop must be black, not the WebView's
      // default white: a white flash on every load reads as a broken view.
      ..setBackgroundColor(const Color(0xFF000000))
      ..addJavaScriptChannel(
        'AgentsVncBridge',
        onMessageReceived: (JavaScriptMessage message) {
          widget.controller.handleBridgeMessage(message.message);
        },
      )
      ..setNavigationDelegate(
        NavigationDelegate(
          // The page is a viewer, not a browser. The only URL it may ever be
          // at is the one we handed it; a navigation anywhere else would take
          // the session token with it.
          onNavigationRequest: (NavigationRequest request) {
            final Uri? target = Uri.tryParse(request.url);
            final bool sameOrigin = target != null &&
                target.scheme == widget.viewerUrl.scheme &&
                target.host == widget.viewerUrl.host &&
                target.port == widget.viewerUrl.port;
            return sameOrigin
                ? NavigationDecision.navigate
                : NavigationDecision.prevent;
          },
        ),
      )
      ..loadRequest(widget.viewerUrl);
    widget.controller.attach(_web);
  }

  @override
  Widget build(BuildContext context) => WebViewWidget(controller: _web);
}
