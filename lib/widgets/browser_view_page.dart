import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

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

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    _sub = widget.controller.inbound.listen(_onInbound);
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
    _rfbSocket = socket;
    // Drain the write-side result: a broken pipe on this socket lands here, and
    // if we do not catch it Dart reports it as an unhandled exception and the
    // app dies. Same for the client bytes stream's error/done.
    socket.done.then((_) => _teardownBridge(), onError: (_) => _teardownBridge());
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
        _safeAdd(bytes);
      case CoworkRelayBrowserView(:final status, :final message):
        if (mounted) {
          setState(() {
            _status = status;
            _message = message;
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
    _sub?.cancel();
    _teardownBridge();
    _server?.close().then((_) {}, onError: (_) {});
    // Best-effort: tell the executor to tear the stream down.
    widget.controller.stopBrowserView().catchError((_) {});
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Agent browser'),
        bottom: PreferredSize(
          // Tall enough for one line of the banner at any text scale; the banner
          // itself clamps to a single ellipsised line so a long status message
          // can never overflow the bar (was a 30px RenderFlex overflow).
          preferredSize: const Size.fromHeight(28),
          child: _StatusBanner(status: _status, message: _message),
        ),
      ),
      body: _port == null
          ? const Center(child: CircularProgressIndicator())
          : RemoteFrameBufferWidget(
              hostName: InternetAddress.loopbackIPv4.address,
              port: _port!,
              connectingWidget: const Center(child: CircularProgressIndicator()),
              onError: (error) {
                if (mounted) {
                  setState(() {
                    _status = 'error';
                    _message = '$error';
                  });
                }
              },
            ),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  const _StatusBanner({required this.status, required this.message});

  final String status;
  final String message;

  @override
  Widget build(BuildContext context) {
    final (Color color, String label) = switch (status) {
      // A started stream with a message means it is live but has nothing to show
      // yet (no browser window on the display) — surface that instead of the
      // usual "you are in control", so a black screen is never a mystery.
      'started' || 'live' => message.isEmpty
          ? (Colors.green, 'live — you are in control')
          : (Colors.orange, message),
      'stopped' => (Colors.grey, 'stopped'),
      'error' => (Colors.red, message.isEmpty ? 'error' : message),
      _ => (Colors.orange, 'connecting…'),
    };
    return Container(
      width: double.infinity,
      color: color.withValues(alpha: 0.15),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
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
