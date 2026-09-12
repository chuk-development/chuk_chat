import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode, kIsWeb;
import 'package:flutter/material.dart';

import 'package:cowork/platform_specific/mobile/mobile_layout.dart';
import 'package:cowork/ui/expressive/motion.dart';
import 'package:cowork/ui/expressive/expressive_screen.dart';
import 'package:cowork/ui/expressive/huge_icon.dart';
import 'package:flutter_rfb/flutter_rfb.dart';

import 'package:cowork/utils/theme_extensions.dart';
import 'package:cowork/widgets/vnc_trackpad_overlay.dart';

import 'package:cowork/services/cowork/cowork_relay_client.dart';

/// The live browser view (§9.1): watch and control the agent's sandbox Chromium.
///
/// The agent's browser runs headless-on-Xvfb in its container; x11vnc serves it
/// and the executor streams the raw RFB bytes to us as sealed `browser_data`
/// frames (and takes our input the same way). We do not parse RFB — we run the
/// pure-Dart [RemoteFrameBufferWidget], which dials a plain TCP host:port, and
/// bridge that loopback socket to the `browser_data` frames both ways. So the
/// VNC stream is a transparent tunnel over the app's existing sealed channel,
/// with no webview and no open port anywhere.
///
/// Use it to sign in to a site the agent cannot: open this view, log in
/// yourself (the agent's loop is not watching), close it, and tell the agent
/// you are done.
///
/// Crash-safety: the loopback socket can break at any moment (x11vnc closes, the
/// RFB widget disconnects, the container goes away). A `Socket.add` failure
/// surfaces on the socket's `done` future, not on the read stream's `onError`,
/// so every write is guarded AND `done` is drained — otherwise a "Broken pipe"
/// becomes an unhandled exception and takes the whole app down (seen live).
class BrowserViewPage extends StatefulWidget {
  const BrowserViewPage({
    super.key,
    required this.controller,
    this.sessionKey,
  });

  final CoworkRelayController controller;

  /// The thread whose box holds the browser. Without it the executor has to
  /// guess, and it guesses the primary environment — with one container per
  /// coworker that is almost never the right one (bead cowork-5eo6).
  final String? sessionKey;

  /// The one way into the view (Bead cowork-vzm): a full-screen route on every
  /// form factor, never a side panel. `fullscreenDialog` gives the close
  /// affordance and the bottom-up transition of a modal surface.
  static Future<void> open(
    BuildContext context,
    CoworkRelayController controller, {
    String? sessionKey,
  }) {
    return Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (context) =>
            BrowserViewPage(controller: controller, sessionKey: sessionKey),
      ),
    );
  }

  @override
  State<BrowserViewPage> createState() => _BrowserViewPageState();
}

class _BrowserViewPageState extends State<BrowserViewPage> {
  StreamSubscription<CoworkRelayInbound>? _sub;
  ServerSocket? _server;
  Socket? _rfbSocket;
  int? _port;
  bool _bridgeClosed = false;
  // The RFB server (x11vnc) speaks first, so its greeting can arrive before the
  // RFB client has dialed our loopback socket. Hold those bytes until it does.
  final List<Uint8List> _pending = <Uint8List>[];
  String _status = 'connecting';
  String _message = '';
  // Per-view VNC secret from the executor's `started` event (§9.1 hardening):
  // x11vnc inside the sandbox now requires it, so the agent's own code cannot
  // watch or drive the screen. The RFB widget is only built once it is known.
  String? _password;
  bool _started = false;
  // Full-screen mode: the app bar and status banner go away and the frame gets
  // the whole window; a small floating button (and the same toggle) brings the
  // chrome back. Errors still surface as an overlay so a dead stream is never
  // a silent black screen.
  bool _fullscreen = true;
  // CoWork: on touch platforms the built-in absolute tap mapping is switched
  // off and a relative trackpad overlay drives this controller instead. On
  // desktop the controller stays null and the normal mouse/keyboard path runs.
  final bool _touchInput = !kIsWeb && (Platform.isAndroid || Platform.isIOS);
  final RemoteFrameBufferController _rfbController =
      RemoteFrameBufferController();
  // End-to-end bandwidth meter (debug builds only): what this view really
  // receives off the sealed channel, after base64 decode. Logged every 2 s so
  // "is it compressed?" is a number in the console, not a feeling.
  int _meterBytes = 0;
  int _meterChunks = 0;
  Timer? _meter;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    _sub = widget.controller.inbound.listen(_onInbound);
    if (kDebugMode) {
      _meter = Timer.periodic(const Duration(seconds: 2), (_) {
        if (_meterChunks == 0) return;
        debugPrint(
          '[vnc-meter] ${(_meterBytes / 1024 / 2).toStringAsFixed(1)} KiB/s '
          'in, ${_meterChunks ~/ 2} chunks/s',
        );
        _meterBytes = 0;
        _meterChunks = 0;
      });
    }
    try {
      await widget.controller.startBrowserView(
        sessionKey: widget.sessionKey,
      );
      final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      _server = server;
      server.listen(_onRfbClient, onError: (_) {}, cancelOnError: false);
      if (mounted) setState(() => _port = server.port);
    } catch (error) {
      if (mounted) {
        setState(() {
          _status = 'error';
          _message = '$error';
        });
      }
    }
  }

  // The RFB client (RemoteFrameBufferWidget) connected to our loopback socket.
  void _onRfbClient(Socket socket) {
    // Accept exactly one client. The RFB widget in this app is the only thing
    // meant to dial this ephemeral loopback port; any second connection (a
    // stray local process on a shared host) would otherwise be able to read the
    // agent's screen or inject RFB bytes, and would clobber `_rfbSocket`. Drop
    // every connection after the first.
    if (_rfbSocket != null || _bridgeClosed) {
      socket.destroy();
      return;
    }
    _rfbSocket = socket;
    // Drain the write-side result: a broken pipe on this socket lands here, and
    // if we do not catch it Dart reports it as an unhandled exception and the
    // app dies. Same for the client bytes stream's error/done.
    socket.done.then(
      (_) => _teardownBridge(),
      onError: (_) => _teardownBridge(),
    );
    for (final chunk in _pending) {
      _safeAdd(chunk);
    }
    _pending.clear();
    socket.listen(
      (data) {
        // The controller send is fire-and-forget; swallow its failures too, so a
        // dropped sealed channel never surfaces as an unhandled future error.
        widget.controller
            .sendBrowserData(Uint8List.fromList(data))
            .catchError((_) {});
      },
      onError: (_) => _teardownBridge(),
      onDone: _teardownBridge,
      cancelOnError: true,
    );
  }

  // Write RFB-server bytes to the loopback socket, or buffer them until the RFB
  // client dials in. Never throws: a failed write tears the bridge down instead.
  void _safeAdd(Uint8List bytes) {
    final socket = _rfbSocket;
    if (socket == null) {
      _pending.add(bytes);
      return;
    }
    if (_bridgeClosed) return;
    try {
      socket.add(bytes);
    } catch (_) {
      _teardownBridge();
    }
  }

  void _onInbound(CoworkRelayInbound event) {
    switch (event) {
      case CoworkRelayBrowserData(:final bytes):
        _meterBytes += bytes.length;
        _meterChunks++;
        _safeAdd(bytes);
      case CoworkRelayBrowserView(
        :final status,
        :final message,
        :final password,
      ):
        if (mounted) {
          setState(() {
            _status = status;
            _message = message;
            if (status == 'started') {
              _started = true;
              _password = password;
            }
          });
        }
      default:
        break; // not a browser-view event
    }
  }

  // Idempotent: drop the loopback socket without letting any close-time error
  // escape. Called from the socket's done/onError/onDone and from dispose.
  void _teardownBridge() {
    if (_bridgeClosed) return;
    _bridgeClosed = true;
    final socket = _rfbSocket;
    _rfbSocket = null;
    try {
      socket?.destroy();
    } catch (_) {}
  }

  @override
  void dispose() {
    _meter?.cancel();
    _rfbController.dispose();
    _sub?.cancel();
    _teardownBridge();
    _server?.close().then((_) {}, onError: (_) {});
    // Best-effort: tell the executor to tear the stream down.
    widget.controller.stopBrowserView().catchError((_) {});
    super.dispose();
  }

  void _toggleFullscreen() => setState(() => _fullscreen = !_fullscreen);

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    final Widget frame = _buildFrame();
    if (_fullscreen) {
      // Full screen means the stream owns every pixel — it does NOT mean the
      // system bars go away. On a phone the status bar still paints over the
      // top of the window, so chrome pinned to `top: 0` lands half under the
      // clock and the notification shade, cut off and only half tappable
      // (Bead cowork-d4po). Start the row below that inset instead, and give
      // the two targets the header height the rest of the app uses.
      final double topInset = MediaQuery.paddingOf(context).top;
      const double gap = 8;
      final double controlTop = topInset + gap;
      final double controlSize = MobileLayout.controlHeight;
      // A chip that has to stay readable over a live web page: the scrim
      // behind it, the inverse foreground on top.
      final Color chip = cs.scrim.withValues(alpha: 0.55);
      return Scaffold(
        // The darkest ground the scheme has, not a hard black: the stream sits
        // on it and the scheme still owns the colour.
        backgroundColor: cs.surfaceContainerLowest,
        body: Stack(
          fit: StackFit.expand,
          children: [
            frame,
            if (_status == 'error')
              Positioned(
                left: 0,
                right: 0,
                // Under the row, not behind it: an error is the one message
                // the reader must not lose to a button sitting on top of it.
                top: controlTop + controlSize + gap,
                child: _StatusBanner(status: _status, message: _message),
              ),
            Positioned(
              top: controlTop,
              left: 12,
              right: 12,
              child: Row(
                children: <Widget>[
                  ExpressiveIconButton(
                    key: const Key('browser_view_close'),
                    hugeIcon: HugeIcons.cancel01,
                    size: controlSize,
                    color: chip,
                    onColor: cs.onInverseSurface,
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).closeButtonTooltip,
                    semanticsId: 'browser_view_close',
                    onTap: () => Navigator.of(context).maybePop(),
                  ),
                  const Spacer(),
                  ExpressiveIconButton(
                    key: const Key('browser_view_exit_fullscreen'),
                    // The set has no full-screen glyph, so this one stays
                    // Material.
                    icon: Icons.fullscreen_exit,
                    size: controlSize,
                    color: chip,
                    onColor: cs.onInverseSurface,
                    tooltip: 'Exit full screen',
                    semanticsId: 'browser_view_exit_fullscreen',
                    onTap: _toggleFullscreen,
                  ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    return ExpressiveScreen(
      title: 'Agent browser',
      actions: <Widget>[
        ExpressiveIconButton(
          key: const Key('browser_view_enter_fullscreen'),
          // The set has no full-screen glyph, so this one stays Material.
          icon: Icons.fullscreen,
          tooltip: 'Full screen',
          onTap: _toggleFullscreen,
        ),
      ],
      builder: (BuildContext context) => Stack(
        fit: StackFit.expand,
        children: <Widget>[
          Padding(
            // The banner sits under the floating bar, and the stream under
            // the banner.
            padding: EdgeInsets.only(
              top: MediaQuery.paddingOf(context).top + 28,
              bottom: MediaQuery.paddingOf(context).bottom,
            ),
            child: frame,
          ),
          Positioned(
            left: 0,
            right: 0,
            // Tall enough for one line of the banner at any text scale; the
            // banner itself clamps to a single ellipsised line so a long
            // status message can never overflow (was a 30px RenderFlex
            // overflow).
            top: MediaQuery.paddingOf(context).top,
            child: _StatusBanner(status: _status, message: _message),
          ),
        ],
      ),
    );
  }

  /// The framebuffer (or the spinner while it is not ready), independent of
  /// the chrome around it so full-screen and windowed mode share one widget.
  Widget _buildFrame() {
    // Wait for BOTH the loopback port and the executor's `started` event: the
    // event carries the per-view VNC secret, and the RFB client needs it at
    // handshake time. Server bytes that arrive meanwhile are buffered.
    if (_port == null || !_started) {
      return const Center(child: CircularProgressIndicator());
    }
    // Scale the framebuffer to fit the viewport (phone or wide window).
    // FittedBox lays the RFB widget out under unbounded constraints, so
    // RawImage keeps its native framebuffer size and SizeTrackingWidget
    // still measures that size — which is what the gesture detector maps
    // input against. FittedBox only scales at paint time, and Flutter
    // inverts that transform for hit-testing, so taps land on the right
    // pixel at any scale.
    final Widget frame = Center(
      child: FittedBox(
        fit: BoxFit.contain,
        child: RemoteFrameBufferWidget(
          hostName: InternetAddress.loopbackIPv4.address,
          port: _port!,
          password: _password,
          // On touch platforms the trackpad overlay owns pointer input, so the
          // built-in absolute tap/wheel mapping is switched off and the overlay
          // drives this controller instead. Desktop keeps the normal mouse.
          controller: _touchInput ? _rfbController : null,
          enableBuiltInPointerInput: !_touchInput,
          // A bare Center() would ask for infinite size under
          // FittedBox's unbounded constraints and throw. Give the
          // connecting placeholder a definite footprint so it scales
          // like the live frame and the spinner stays a sane size.
          connectingWidget: const SizedBox(
            width: 1280,
            height: 800,
            child: Center(
              child: SizedBox(
                width: 48,
                height: 48,
                child: CircularProgressIndicator(),
              ),
            ),
          ),
          onError: (error) {
            if (mounted) {
              setState(() {
                _status = 'error';
                _message = '$error';
              });
            }
          },
        ),
      ),
    );
    if (!_touchInput) return frame;
    // The overlay fills the same box the framebuffer is contain-fit into, so
    // its virtual cursor maps back onto the exact remote pixel at any scale.
    return VncTrackpadOverlay(controller: _rfbController, child: frame);
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.status, required this.message});

  final String status;
  final String message;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final MaterialYouTokens m3 = theme.m3;
    final (Color color, String label) = switch (status) {
      // A started stream with a message means it is live but has nothing to show
      // yet (no browser window on the display) — surface that instead of the
      // usual "you are in control", so a black screen is never a mystery.
      'started' || 'live' =>
        message.isEmpty
            ? (m3.success, 'live — you are in control')
            : (m3.warning, message),
      'stopped' => (cs.outline, 'stopped'),
      'error' => (cs.error, message.isEmpty ? 'error' : message),
      _ => (m3.warning, 'connecting…'),
    };
    return Container(
      width: double.infinity,
      color: color.withValues(alpha: 0.15),
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      alignment: Alignment.centerLeft,
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        softWrap: false,
        style: TextStyle(color: color, fontSize: 12),
      ),
    );
  }
}
