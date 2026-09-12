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
  // True once the first sealed `browser_data` frame has landed. It is the
  // difference between "the tunnel is quiet" and "the picture is on its way",
  // and the connecting note says which.
  bool _sawBytes = false;
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
  // The one thing the full-screen toggle must NOT rebuild.
  //
  // Full screen swaps a bare `Scaffold` for an `ExpressiveScreen`, so the
  // framebuffer widget changed position in the tree and Flutter threw its
  // element away: the RFB isolate was killed, the loopback socket closed, the
  // bridge latched `_bridgeClosed` — and the fresh RFB client that dialled
  // straight back in was refused by `_onRfbClient`. One tap on "full screen"
  // and the stream was dead for good, with the virtual cursor and the zoom
  // reset on top (Bead cowork-prsd). A global key moves the whole subtree to
  // the new parent instead of rebuilding it, so the isolate, the socket, the
  // cursor and the zoom all survive the toggle.
  final GlobalKey _frameHost = GlobalKey(debugLabel: 'browser view frame');
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
    // The note over the stream names the step it waits on, and the last two
    // steps are only visible on the RFB controller.
    _rfbController.addListener(_onStreamStateChanged);
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

  void _onStreamStateChanged() {
    if (mounted) setState(() {});
  }

  void _onInbound(CoworkRelayInbound event) {
    switch (event) {
      case CoworkRelayBrowserData(:final bytes):
        _meterBytes += bytes.length;
        _meterChunks++;
        if (!_sawBytes) {
          _sawBytes = true;
          if (mounted) setState(() {});
        }
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
    _rfbController.removeListener(_onStreamStateChanged);
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
    // Same widget, same element, both modes: see [_frameHost].
    final Widget frame = KeyedSubtree(key: _frameHost, child: _buildFrame());
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
        // The soft keyboard must not squeeze the remote screen: a resize would
        // change the fit, move every pixel under the virtual cursor and undo
        // the zoom the moment typing starts. The overlay lifts its own controls
        // over the keyboard inset instead.
        resizeToAvoidBottomInset: false,
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

  /// What the view is still waiting for, or null once there is a picture.
  ///
  /// The steps are the real ones: our end of the tunnel, the executor's
  /// `started` event (it carries the per-view VNC secret), the first bytes off
  /// the sealed channel, and the first decoded frame. A spinner that only turns
  /// says none of that.
  String? get _waitingFor {
    if (_status == 'error') return null;
    if (_port == null) return 'Opening the channel…';
    if (!_started) return 'Waiting for the sandbox screen…';
    if (!_sawBytes) return 'Connecting to the screen…';
    if (!_rfbController.isReady) return 'Waiting for the first picture…';
    return null;
  }

  /// The framebuffer and, over it, the note about what is still missing.
  ///
  /// The note used to be the RFB widget's `connectingWidget`: a 48 px spinner
  /// in a 1280x800 box, which the contain fit then scaled UP to the width of
  /// the window — a spinner the size of a fist that said nothing (Bead
  /// cowork-prsd). It is drawn in screen pixels now, small, and it names the
  /// step it waits on.
  Widget _buildFrame() {
    final String? waiting = _waitingFor;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        if (_port != null && _started) _buildStream(),
        if (waiting != null)
          Positioned.fill(
            child: IgnorePointer(child: _ConnectingNote(label: waiting)),
          ),
      ],
    );
  }

  /// The live stream. Both the loopback port and the executor's `started` event
  /// are in by the time this is built: the event carries the VNC secret and the
  /// RFB client needs it at handshake time. Server bytes that arrived meanwhile
  /// were buffered.
  Widget _buildStream() {
    final Widget stream = RemoteFrameBufferWidget(
      hostName: InternetAddress.loopbackIPv4.address,
      port: _port!,
      password: _password,
      // The controller is attached on every platform: touch drives the pointer
      // through it, and both platforms read `isReady` and the framebuffer size
      // off it. Only the built-in absolute tap mapping is platform-dependent.
      controller: _rfbController,
      enableBuiltInPointerInput: !_touchInput,
      // Deliberately empty, and deliberately a definite box: this placeholder
      // is laid out where the framebuffer will go and would be scaled with it,
      // so anything drawn here comes out the size of the window. The note in
      // [_buildFrame] is the one that talks.
      connectingWidget: const SizedBox(width: 1280, height: 800),
      onError: (error) {
        if (mounted) {
          setState(() {
            _status = 'error';
            _message = '$error';
          });
        }
      },
    );
    if (!_touchInput) {
      // Desktop keeps the plain contain fit and the real mouse. FittedBox lays
      // the RFB widget out under unbounded constraints, so RawImage keeps its
      // native framebuffer size and Flutter inverts the paint transform for
      // hit-testing — taps land on the right pixel at any scale.
      return Center(
        child: FittedBox(fit: BoxFit.contain, child: stream),
      );
    }
    // On touch the overlay owns the placement as well as the input, so the
    // zoom, the pan and the virtual cursor all read one transform
    // ([VncViewFit]). It must get the bare framebuffer widget, never one
    // already wrapped in a fit of its own.
    return VncTrackpadOverlay(controller: _rfbController, child: stream);
  }
}

/// The small, quiet note that says what the view is waiting for.
class _ConnectingNote extends StatelessWidget {
  const _ConnectingNote({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final ColorScheme cs = Theme.of(context).colorScheme;
    return Center(
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: cs.scrim.withValues(alpha: 0.55),
          borderRadius: BorderRadius.circular(18),
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 18, 12),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: cs.onInverseSurface,
                ),
              ),
              const SizedBox(width: 12),
              Flexible(
                child: Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: cs.onInverseSurface, fontSize: 13),
                ),
              ),
            ],
          ),
        ),
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
