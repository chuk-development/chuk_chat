import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode, kIsWeb;
import 'package:flutter/material.dart';

import 'package:cowork/platform_specific/mobile/mobile_layout.dart';
import 'package:cowork/ui/expressive/expressive_screen.dart';
import 'package:cowork/ui/expressive/motion.dart';
import 'package:cowork/ui/expressive/huge_icon.dart';
import 'package:flutter_rfb/flutter_rfb.dart';

import 'package:cowork/utils/theme_extensions.dart';
import 'package:cowork/widgets/vnc_local_server.dart';
import 'package:cowork/widgets/vnc_webview_controls.dart';
import 'package:cowork/widgets/vnc_webview_screen.dart';

import 'package:cowork/services/cowork/cowork_relay_client.dart';

/// The live browser view (§9.1): watch and control the agent's sandbox
/// Chromium.
///
/// The agent's browser runs headless-on-Xvfb in its container; x11vnc serves
/// it and the executor streams the raw RFB bytes to us as sealed
/// `browser_data` frames (and takes our input the same way). This view is the
/// other end of that tunnel. It never opens a port to the network.
///
/// Two clients, one tunnel
/// -----------------------
/// On phones and tablets the RFB stream goes to **noVNC inside a WebView**
/// (bead cowork-dvsw). The pure-Dart client understands raw and copyRect
/// only, so every full 1280x800 frame cost about 4 MB and the view felt like
/// a bad connection; noVNC decodes Tight and ZRLE and draws the agent's real
/// mouse pointer from the cursor pseudo-encoding. [VncLocalServer] serves the
/// viewer page and the vendored library from the app bundle and carries the
/// RFB bytes as a WebSocket, because that is what noVNC speaks.
///
/// On desktop the pure-Dart [RemoteFrameBufferWidget] stays: there is no
/// Linux or Windows WebView plugin, and desktop has a real mouse and keyboard
/// anyway, which is the half the WebView was needed for.
///
/// Use the view to sign in to a site the agent cannot: open it, log in
/// yourself (the agent's loop is not watching), close it, and tell the agent
/// you are done.
///
/// Crash-safety, desktop path: the loopback socket can break at any moment. A
/// `Socket.add` failure surfaces on the socket's `done` future, not on the
/// read stream's `onError`, so every write is guarded AND `done` is drained —
/// otherwise a "Broken pipe" becomes an unhandled exception and takes the
/// whole app down (seen live).
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
  /// Touch platforms get noVNC in a WebView; desktop keeps the Dart client.
  static final bool _useWebView =
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  StreamSubscription<CoworkRelayInbound>? _sub;
  String _status = 'connecting';
  String _message = '';
  // Per-view VNC secret from the executor's `started` event (§9.1 hardening):
  // x11vnc inside the sandbox requires it, so the agent's own code cannot
  // watch or drive the screen. The client is only handed it once it is known,
  // and it is never logged.
  String? _password;
  bool _started = false;
  // True once the first sealed `browser_data` frame has landed. It is the
  // difference between "the tunnel is quiet" and "the picture is on its way".
  bool _sawBytes = false;
  // Full-screen mode: the app bar and status banner go away and the frame gets
  // the whole window; a small floating button brings the chrome back. Errors
  // still surface as an overlay so a dead stream is never a silent black
  // screen.
  bool _fullscreen = true;

  // --- The WebView path -----------------------------------------------------
  VncLocalServer? _local;
  StreamSubscription<Uint8List>? _fromPage;
  final VncWebViewController _vnc = VncWebViewController();
  final FocusNode _keyFocus = FocusNode(debugLabel: 'vnc remote keyboard');
  final TextEditingController _keyText = TextEditingController();
  bool _keyboardOpen = false;
  // Guards the executor-side restart a lost page asks for, so a teardown does
  // not start a stream nobody will read.
  bool _disposed = false;

  // --- The desktop path -----------------------------------------------------
  ServerSocket? _server;
  Socket? _rfbSocket;
  int? _port;
  bool _bridgeClosed = false;
  // The RFB server (x11vnc) speaks first, so its greeting can arrive before
  // the RFB client has dialed our loopback socket. Hold those bytes until it
  // does.
  final List<Uint8List> _pending = <Uint8List>[];
  // Which RFB session the loopback bridge is carrying.
  //
  // The executor re-handshakes with the agent's x11vnc by itself and rotates
  // the per-view secret when it does, so a view can outlive several RFB
  // sessions. Every socket callback carries the generation it was opened for,
  // and a teardown from an OLD generation is ignored — otherwise the dying
  // socket of session N latches `_bridgeClosed` again just after session N+1
  // has opened, and the view is dead for good (bead cowork-zlbn).
  int _generation = 0;
  // CoWork: on touch platforms the built-in absolute tap mapping is switched
  // off and a relative trackpad overlay drives this controller instead. Only
  // reachable on the desktop path now.
  final RemoteFrameBufferController _rfbController =
      RemoteFrameBufferController();

  // The one thing the full-screen toggle must NOT rebuild.
  //
  // Full screen swaps a bare `Scaffold` for an `ExpressiveScreen`, so the
  // stream widget changed position in the tree and Flutter threw its element
  // away: the client died, the socket closed, and the fresh client that
  // dialled straight back in was refused. One tap on "full screen" and the
  // stream was dead for good, with the cursor and the zoom reset on top (Bead
  // cowork-prsd). A global key moves the whole subtree to the new parent
  // instead of rebuilding it, so the socket, the zoom and the pointer all
  // survive the toggle. It matters just as much for the WebView: rebuilding
  // that would reload the page.
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
    if (_useWebView) {
      _vnc.addListener(_onStreamStateChanged);
    } else {
      // The note over the stream names the step it waits on, and the last two
      // steps are only visible on the RFB controller.
      _rfbController.addListener(_onStreamStateChanged);
    }
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
      await widget.controller.startBrowserView(sessionKey: widget.sessionKey);
      if (_useWebView) {
        await _startLocalServer();
      } else {
        await _startLoopbackSocket();
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _status = 'error';
          _message = '$error';
        });
      }
    }
  }

  Future<void> _startLocalServer() async {
    final VncLocalServer local = await VncLocalServer.start(
      onStreamRestartNeeded: _restartStream,
    );
    _local = local;
    _fromPage = local.fromPage.listen(
      (Uint8List bytes) {
        // Fire-and-forget: a dropped sealed channel must never surface as an
        // unhandled future error.
        widget.controller.sendBrowserData(bytes).catchError((_) {});
      },
      onError: (Object _) {},
    );
    if (mounted) setState(() {});
  }

  /// The viewer page lost its socket, so the executor's pipe into x11vnc is
  /// stranded mid-protocol. Tear it down and open a fresh one; the page is
  /// already retrying and will find it.
  Future<void> _restartStream() async {
    if (_disposed) return;
    try {
      await widget.controller.stopBrowserView();
      if (_disposed) return;
      await widget.controller.startBrowserView(sessionKey: widget.sessionKey);
    } catch (_) {
      // The page keeps retrying; a failed restart is not fatal here.
    }
  }

  Future<void> _startLoopbackSocket() async {
    final ServerSocket server =
        await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    server.listen(_onRfbClient, onError: (_) {}, cancelOnError: false);
    if (mounted) setState(() => _port = server.port);
  }

  // The RFB client (RemoteFrameBufferWidget) connected to our loopback socket.
  void _onRfbClient(Socket socket) {
    final int generation = _generation;
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
      (_) => _teardownBridge(generation),
      onError: (_) => _teardownBridge(generation),
    );
    for (final chunk in _pending) {
      _safeAdd(chunk);
    }
    _pending.clear();
    socket.listen(
      (data) {
        widget.controller
            .sendBrowserData(Uint8List.fromList(data))
            .catchError((_) {});
      },
      onError: (_) => _teardownBridge(generation),
      onDone: () => _teardownBridge(generation),
      cancelOnError: true,
    );
  }

  /// A fresh RFB session arrived on the tunnel. Let the client dial in again.
  ///
  /// x11vnc starts every session at the version line, so the old one cannot be
  /// resumed: the widget is rebuilt under a new key and handed the rotated
  /// secret, and the buffered tail of the dead session is dropped.
  void _resetBridge() {
    _generation++;
    final Socket? socket = _rfbSocket;
    _rfbSocket = null;
    _bridgeClosed = false;
    _pending.clear();
    try {
      socket?.destroy();
    } catch (_) {}
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
      _teardownBridge(_generation);
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
        if (_useWebView) {
          _local?.send(bytes);
        } else {
          _safeAdd(bytes);
        }
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
              // A second `started` is the executor's own recovery: it
              // re-handshakes with the box by itself and rotates the per-view
              // secret every time (`reason: reconnected`). The bytes now
              // arriving are a FRESH RFB session that begins at the version
              // line, so whichever client we run has to start over with the
              // new secret — and the old buffered tail must not reach it.
              final bool again = _started;
              _started = true;
              _password = password;
              // The page needs the secret at handshake time and gets it by a
              // JavaScript call, so it never rides a URL.
              if (_useWebView) {
                _vnc.password = password;
                if (again) _local?.resetStream();
              } else if (again) {
                _resetBridge();
              }
            }
          });
        }
      default:
        break; // not a browser-view event
    }
  }

  // Idempotent: drop the loopback socket without letting any close-time error
  // escape. Called from the socket's done/onError/onDone and from dispose.
  void _teardownBridge(int generation) {
    if (generation != _generation) return;
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
    _disposed = true;
    _meter?.cancel();
    if (_useWebView) {
      _vnc.removeListener(_onStreamStateChanged);
    } else {
      _rfbController.removeListener(_onStreamStateChanged);
    }
    _vnc.dispose();
    _rfbController.dispose();
    _keyFocus.dispose();
    _keyText.dispose();
    _sub?.cancel();
    _fromPage?.cancel();
    _local?.close();
    _teardownBridge(_generation);
    _server?.close().then((_) {}, onError: (_) {});
    // Best-effort: tell the executor to tear the stream down.
    widget.controller.stopBrowserView().catchError((_) {});
    super.dispose();
  }

  void _toggleFullscreen() => setState(() => _fullscreen = !_fullscreen);

  void _toggleKeyboard() {
    if (_keyFocus.hasFocus) {
      _keyFocus.unfocus();
      setState(() => _keyboardOpen = false);
      return;
    }
    VncKeyboardField.reset(_keyText);
    _keyFocus.requestFocus();
    setState(() => _keyboardOpen = true);
  }

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
        // change the fit, move every pixel under the pointer and undo the zoom
        // the moment typing starts. The controls lift themselves over the
        // keyboard inset instead.
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
            if (_useWebView) ..._webViewChrome(context),
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
          if (_useWebView) ..._webViewChrome(context),
        ],
      ),
    );
  }

  /// The controls the WebView path owns: the bar, the reconnect note and the
  /// invisible field the soft keyboard types into.
  List<Widget> _webViewChrome(BuildContext context) {
    final double keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
    final double bottomInset = MediaQuery.paddingOf(context).bottom;
    return <Widget>[
      if (_vnc.phase == VncPhase.reconnecting && _vnc.frameAsOf != null)
        Positioned(
          left: 0,
          right: 0,
          bottom: bottomInset + keyboardInset + MobileLayout.controlHeight + 32,
          child: Center(child: VncReconnectingNote(since: _vnc.frameAsOf!)),
        ),
      Positioned(
        left: 0,
        right: 0,
        bottom: bottomInset + keyboardInset + 12,
        child: Center(
          child: VncControlBar(
            controller: _vnc,
            keyboardOpen: _keyboardOpen,
            onToggleKeyboard: _toggleKeyboard,
          ),
        ),
      ),
      VncKeyboardField(
        controller: _vnc,
        focusNode: _keyFocus,
        text: _keyText,
      ),
    ];
  }

  /// True once there is a picture on screen, whichever client draws it.
  bool get _hasPicture => _useWebView
      ? _vnc.phase == VncPhase.connected ||
          _vnc.phase == VncPhase.reconnecting
      : _rfbController.isReady;

  /// The stream and, over it, the two named steps that say what is missing.
  ///
  /// The steps used to be a 48 px spinner in a 1280x800 box, which the contain
  /// fit then scaled UP to the width of the window — a spinner the size of a
  /// fist that said nothing (Bead cowork-prsd).
  Widget _buildFrame() {
    final bool ready = _useWebView ? _local != null : _port != null;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        if (ready && _started) _buildStream(),
        if (_status != 'error' && !_hasPicture)
          Positioned.fill(
            child: IgnorePointer(
              child: VncLoadingSteps(
                machineReady: _started && _sawBytes,
                screenReady: _hasPicture,
              ),
            ),
          ),
      ],
    );
  }

  /// The live stream. Both the local server and the executor's `started` event
  /// are in by the time this is built: the event carries the VNC secret and
  /// the client needs it at handshake time. Server bytes that arrived
  /// meanwhile were buffered.
  Widget _buildStream() {
    if (_useWebView) {
      return VncWebView(viewerUrl: _local!.viewerUrl, controller: _vnc);
    }
    final Widget stream = RemoteFrameBufferWidget(
      // A new key for every RFB session: the widget holds the handshake and
      // the secret, so a rotated secret means a new one.
      key: ValueKey<int>(_generation),
      hostName: InternetAddress.loopbackIPv4.address,
      port: _port!,
      password: _password,
      controller: _rfbController,
      // Desktop has a real mouse; the built-in mapping is the right one.
      enableBuiltInPointerInput: true,
      // Deliberately empty, and deliberately a definite box: this placeholder
      // is laid out where the framebuffer will go and would be scaled with it,
      // so anything drawn here comes out the size of the window. The steps in
      // [_buildFrame] are what talk.
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
    // Desktop keeps the plain contain fit and the real mouse. FittedBox lays
    // the RFB widget out under unbounded constraints, so RawImage keeps its
    // native framebuffer size and Flutter inverts the paint transform for
    // hit-testing — clicks land on the right pixel at any scale.
    return Center(child: FittedBox(fit: BoxFit.contain, child: stream));
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
