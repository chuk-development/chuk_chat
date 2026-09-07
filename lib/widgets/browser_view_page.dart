import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_rfb/flutter_rfb.dart';

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
  const BrowserViewPage({super.key, required this.controller});

  final CoworkRelayController controller;

  /// The one way into the view (Bead cowork-vzm): a full-screen route on every
  /// form factor, never a side panel. `fullscreenDialog` gives the close
  /// affordance and the bottom-up transition of a modal surface.
  static Future<void> open(
    BuildContext context,
    CoworkRelayController controller,
  ) {
    return Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (context) => BrowserViewPage(controller: controller),
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
      await widget.controller.startBrowserView();
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
    final Widget frame = _buildFrame();
    if (_fullscreen) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            frame,
            if (_status == 'error')
              Positioned(
                left: 0,
                right: 0,
                top: 0,
                child: _StatusBanner(
                  status: _status,
                  message: _message,
                  leadingInset: 48,
                ),
              ),
            Positioned(
              top: 8,
              left: 8,
              child: Material(
                color: Colors.black.withValues(alpha: 0.45),
                shape: const CircleBorder(),
                child: CloseButton(color: Colors.white),
              ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: Material(
                color: Colors.black.withValues(alpha: 0.45),
                shape: const CircleBorder(),
                child: IconButton(
                  key: const Key('browser_view_exit_fullscreen'),
                  icon: const Icon(Icons.fullscreen_exit, color: Colors.white),
                  tooltip: 'Exit full screen',
                  onPressed: _toggleFullscreen,
                ),
              ),
            ),
          ],
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('Agent browser'),
        actions: [
          IconButton(
            key: const Key('browser_view_enter_fullscreen'),
            icon: const Icon(Icons.fullscreen),
            tooltip: 'Full screen',
            onPressed: _toggleFullscreen,
          ),
        ],
        bottom: PreferredSize(
          // Tall enough for one line of the banner at any text scale; the banner
          // itself clamps to a single ellipsised line so a long status message
          // can never overflow the bar (was a 30px RenderFlex overflow).
          preferredSize: const Size.fromHeight(28),
          child: _StatusBanner(status: _status, message: _message),
        ),
      ),
      body: frame,
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
    return Center(
      child: FittedBox(
        fit: BoxFit.contain,
        child: RemoteFrameBufferWidget(
          hostName: InternetAddress.loopbackIPv4.address,
          port: _port!,
          password: _password,
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
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({
    required this.status,
    required this.message,
    this.leadingInset = 0,
  });

  final String status;
  final String message;

  /// Room for whatever floats over the banner's left edge — in fullscreen the
  /// close button sits there and would otherwise cover the first words of an
  /// error, which is the one message the reader must not lose.
  final double leadingInset;

  @override
  Widget build(BuildContext context) {
    final (Color color, String label) = switch (status) {
      // A started stream with a message means it is live but has nothing to show
      // yet (no browser window on the display) — surface that instead of the
      // usual "you are in control", so a black screen is never a mystery.
      'started' || 'live' =>
        message.isEmpty
            ? (Colors.green, 'live — you are in control')
            : (Colors.orange, message),
      'stopped' => (Colors.grey, 'stopped'),
      'error' => (Colors.red, message.isEmpty ? 'error' : message),
      _ => (Colors.orange, 'connecting…'),
    };
    return Container(
      width: double.infinity,
      color: color.withValues(alpha: 0.15),
      padding: EdgeInsets.fromLTRB(12 + leadingInset, 4, 12, 4),
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
