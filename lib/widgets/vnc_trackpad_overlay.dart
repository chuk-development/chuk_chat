import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:chuk_chat/platform_specific/mobile/mobile_layout.dart';
import 'package:chuk_chat/ui/expressive/icon_map.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';
import 'package:chuk_chat/widgets/vnc_view_fit.dart';
import 'package:flutter_rfb/flutter_rfb.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A touch trackpad over the agent's browser view, for phones and tablets.
///
/// The remote screen is a desktop; a fingertip is a blunt, imprecise pointer
/// and it hides the very pixel it lands on. So on touch platforms we do NOT
/// tap the remote where the finger lands. Instead this overlay keeps a virtual
/// mouse cursor and moves it RELATIVE to finger movement, like a laptop
/// trackpad — you can see the cursor, nudge it onto a small target, and tap to
/// click there. The parent switches the built-in absolute tap mapping off
/// ([RemoteFrameBufferWidget.enableBuiltInPointerInput] = false) so touch is
/// owned entirely here. Desktop keeps a normal mouse and never mounts this.
///
/// Gestures (mirrored from a desktop trackpad, not the remote surface):
///   one finger drag        move the cursor
///   one finger tap         left click at the cursor
///   double tap then hold   press and hold left, then drag to move the
///                          selection/window (release by lifting)
///   two finger drag        scroll
///   two finger pinch       zoom the picture in and out
///   two finger tap         right click at the cursor
///
/// This overlay also PLACES the framebuffer. It used to sit on top of a
/// `FittedBox(fit: BoxFit.contain)` and recompute that same contain fit by hand
/// so the cursor landed on the right remote pixel — two places that had to
/// agree, and neither could zoom. Now [VncViewFit] is the single mapping: the
/// picture is painted at `fit.rect` and every touch is converted through the
/// same object, so a click lands on the same remote pixel at any zoom.
///
/// The cursor lives in remote framebuffer pixels, so it sticks to the same spot
/// of the picture when the view is resized, zoomed or panned. It is DRAWN in
/// screen pixels at a fixed size: it is a control, not picture content, and a
/// control that grows with the zoom is just a bigger blob over the pixel you
/// were aiming at.
class VncTrackpadOverlay extends StatefulWidget {
  const VncTrackpadOverlay({
    super.key,
    required this.controller,
    required this.child,
    this.enabled = true,
  });

  /// The handle onto the RFB isolate that carries our pointer events.
  final RemoteFrameBufferController controller;

  /// The remote-screen widget (a bare [RemoteFrameBufferWidget]). It is laid
  /// out at its native framebuffer size and scaled by this overlay; do NOT wrap
  /// it in a `FittedBox` or a `Center` on the way in, or there are two fits
  /// again.
  final Widget child;

  /// When false the overlay is inert and only shows [child] (used while the
  /// stream is not connected).
  final bool enabled;

  @override
  State<VncTrackpadOverlay> createState() => _VncTrackpadOverlayState();
}

/// What a two-finger gesture turned out to be. It starts undecided: the same
/// two fingers can scroll the remote page or zoom our picture, and which one it
/// is only shows once they move.
enum _TwoFingerMode { undecided, scrolling, zooming }

class _VncTrackpadOverlayState extends State<VncTrackpadOverlay> {
  // Tuning. Screen-relative, so the feel is the same at any framebuffer size.
  static const double _moveSensitivity = 1.0;
  // One wheel notch per this many pixels of two-finger travel.
  static const double _scrollStepPx = 22.0;
  // A press that moves less than this is a tap, not a drag.
  static const double _tapSlopPx = 12.0;
  // The finger spread has to change by this much before two fingers mean zoom
  // instead of scroll. Below it, a slightly uneven two-finger swipe would
  // wobble the zoom on every scroll.
  static const double _pinchSlopPx = 18.0;
  // A second tap within this window (and close in space) starts a drag.
  static const int _doubleTapMs = 300;
  static const double _doubleTapSlopPx = 28.0;

  static const String _helpSeenKey = 'vnc_trackpad_help_seen_v1';

  // Virtual cursor in remote framebuffer pixels.
  double _cx = 0;
  double _cy = 0;
  bool _cursorSeeded = false;

  // The view: how much of the picture is shown, and where.
  double _zoom = 1;
  Offset _pan = Offset.zero;
  Size _box = Size.zero;
  VncViewFit _fit = VncViewFit.empty;

  // Active touch points in local (overlay) coordinates, by pointer id.
  final Map<int, Offset> _pointers = <int, Offset>{};

  // One gesture spans finger-count 0 -> ... -> 0.
  int _maxFingers = 0;
  bool _moved = false;
  bool _scrolled = false;
  bool _dragging = false;
  Offset _startPos = Offset.zero;
  Offset _lastPos = Offset.zero; // one-finger anchor
  Offset _lastCentroid = Offset.zero; // two-finger anchor
  double _scrollAccumY = 0;
  double _scrollAccumX = 0;

  // Two-finger state.
  _TwoFingerMode _twoFingers = _TwoFingerMode.undecided;
  double _startSpread = 0;
  Offset _startCentroid = Offset.zero;
  double _zoomAtPinchStart = 1;
  Offset _pinchAnchorFb = Offset.zero;

  int _lastTapEndMs = 0;
  Offset _lastTapPos = Offset.zero;

  bool _showHelp = false;

  // Remote typing. Android gives a soft keyboard no raw key stream worth
  // trusting, so a hidden field takes the text and we turn every character
  // into an X keysym ourselves.
  final FocusNode _keyFocus = FocusNode(debugLabel: 'vnc remote keyboard');
  final TextEditingController _keyText = TextEditingController();
  bool _keyboardOpen = false;
  // The field never really empties: it holds one invisible character, so a
  // backspace on an "empty" field still reaches onChanged and can be sent on.
  static const String _sentinel = '​';

  // X keysyms for the keys a browser actually needs from a phone.
  static const int _xkBackSpace = 0xff08;
  static const int _xkTab = 0xff09;
  static const int _xkReturn = 0xff0d;
  static const int _xkEscape = 0xff1b;
  static const int _xkLeft = 0xff51;
  static const int _xkUp = 0xff52;
  static const int _xkRight = 0xff53;
  static const int _xkDown = 0xff54;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    _keyFocus.addListener(_onKeyFocusChanged);
    _resetKeyField();
    _maybeShowHelp();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
    _keyFocus.removeListener(_onKeyFocusChanged);
    _keyFocus.dispose();
    _keyText.dispose();
    super.dispose();
  }

  Future<void> _maybeShowHelp() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      if (!(prefs.getBool(_helpSeenKey) ?? false) && mounted) {
        setState(() => _showHelp = true);
      }
    } catch (_) {
      // Storage unavailable: still show the card once this session.
      if (mounted) setState(() => _showHelp = true);
    }
  }

  Future<void> _dismissHelp() async {
    if (mounted) setState(() => _showHelp = false);
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_helpSeenKey, true);
    } catch (_) {
      // Best effort; the "?" button can always bring it back.
    }
  }

  void _onControllerChanged() {
    if (!_cursorSeeded) {
      _seedCursor();
    }
    if (mounted) setState(_recomputeFit); // readiness/size may have changed
  }

  void _seedCursor() {
    final Size? fb = widget.controller.frameBufferSize;
    if (fb == null || fb.isEmpty) return;
    _cx = fb.width / 2;
    _cy = fb.height / 2;
    _cursorSeeded = true;
  }

  Size get _frameBuffer => widget.controller.frameBufferSize ?? Size.zero;

  void _recomputeFit() {
    _fit = VncViewFit.compute(
      box: _box,
      frameBuffer: _frameBuffer,
      zoom: _zoom,
      pan: _pan,
    );
  }

  Offset get _cursorFb => Offset(_cx, _cy);

  void _clampCursor() {
    final Size fb = _frameBuffer;
    if (fb.isEmpty) return;
    _cx = _cx.clamp(0.0, fb.width - 1);
    _cy = _cy.clamp(0.0, fb.height - 1);
  }

  int get _ix => _cx.round();
  int get _iy => _cy.round();

  void _moveCursorBy(Offset screenDelta, {required bool pressed}) {
    if (_fit.scale <= 0) return;
    _cx += screenDelta.dx / _fit.scale * _moveSensitivity;
    _cy += screenDelta.dy / _fit.scale * _moveSensitivity;
    _clampCursor();
    _followCursor();
    widget.controller.pointer(
      x: _ix,
      y: _iy,
      buttons: pressed ? <int>{1} : <int>{},
    );
  }

  /// Zoomed in, the cursor can be nudged off the part of the remote screen that
  /// is on show. Losing it is the fastest way to make a zoom useless, so the
  /// view follows it instead — which is also the only pan a single finger
  /// needs.
  void _followCursor() {
    if (_zoom <= VncViewFit.minZoom + 0.001) return;
    final Size fb = _frameBuffer;
    if (fb.isEmpty || _box.isEmpty) return;
    _pan = VncViewFit.panToKeepVisible(
      box: _box,
      frameBuffer: fb,
      zoom: _zoom,
      pan: _pan,
      framebufferPoint: _cursorFb,
    );
    _recomputeFit();
  }

  void _setZoom(double zoom, {required Offset anchorScreen, Offset? anchorFb}) {
    final Size fb = _frameBuffer;
    if (fb.isEmpty || _box.isEmpty) return;
    final Offset keep = anchorFb ?? _fit.toFrameBuffer(anchorScreen);
    _zoom = zoom.clamp(VncViewFit.minZoom, VncViewFit.maxZoom);
    _pan = VncViewFit.panFor(
      box: _box,
      frameBuffer: fb,
      zoom: _zoom,
      framebufferPoint: keep,
      screenPoint: anchorScreen,
    );
    _recomputeFit();
  }

  void _fitToScreen() {
    setState(() {
      _zoom = 1;
      _pan = Offset.zero;
      _recomputeFit();
    });
  }

  Offset _centroid() {
    if (_pointers.isEmpty) return Offset.zero;
    double x = 0, y = 0;
    // Two fingers drive scroll and zoom; ignore any beyond the first two.
    final List<Offset> pts = _pointers.values.take(2).toList();
    for (final Offset p in pts) {
      x += p.dx;
      y += p.dy;
    }
    return Offset(x / pts.length, y / pts.length);
  }

  double _spread() {
    if (_pointers.length < 2) return 0;
    final List<Offset> pts = _pointers.values.take(2).toList();
    return (pts[1] - pts[0]).distance;
  }

  void _reanchor() {
    if (_pointers.length >= 2) {
      _lastCentroid = _centroid();
    } else if (_pointers.length == 1) {
      _lastPos = _pointers.values.first;
    }
  }

  void _emitScroll(Offset centroidDelta) {
    // Natural touch: content follows the fingers. Dragging the fingers up
    // moves the page up, i.e. a wheel-down notch. RFB wheel: 4 up, 5 down,
    // 6 left, 7 right.
    _scrollAccumY += centroidDelta.dy;
    _scrollAccumX += centroidDelta.dx;
    while (_scrollAccumY.abs() >= _scrollStepPx) {
      final bool up = _scrollAccumY > 0; // fingers moved down -> scroll up
      widget.controller.pointer(x: _ix, y: _iy, buttons: <int>{up ? 4 : 5});
      widget.controller.pointer(x: _ix, y: _iy);
      _scrollAccumY += up ? -_scrollStepPx : _scrollStepPx;
    }
    while (_scrollAccumX.abs() >= _scrollStepPx) {
      final bool left = _scrollAccumX > 0; // fingers moved right -> scroll left
      widget.controller.pointer(x: _ix, y: _iy, buttons: <int>{left ? 6 : 7});
      widget.controller.pointer(x: _ix, y: _iy);
      _scrollAccumX += left ? -_scrollStepPx : _scrollStepPx;
    }
    _scrolled = true;
  }

  void _onPointerDown(PointerDownEvent e) {
    if (!widget.controller.isReady) return;
    if (!_cursorSeeded) _seedCursor();
    _pointers[e.pointer] = e.localPosition;
    final int now = DateTime.now().millisecondsSinceEpoch;
    if (_pointers.length == 1) {
      // Fresh gesture.
      _maxFingers = 1;
      _moved = false;
      _scrolled = false;
      _dragging = false;
      _startPos = e.localPosition;
      _lastPos = e.localPosition;
      _scrollAccumY = 0;
      _scrollAccumX = 0;
      final bool doubleTap =
          now - _lastTapEndMs < _doubleTapMs &&
          (e.localPosition - _lastTapPos).distance < _doubleTapSlopPx;
      if (doubleTap) {
        // Press and hold left at the cursor; the follow-up drag moves it.
        _dragging = true;
        widget.controller.pointer(x: _ix, y: _iy, buttons: <int>{1});
      }
    } else {
      _maxFingers = math.max(_maxFingers, _pointers.length);
      // A second finger during a held drag: release the button and hand off
      // to the two-finger path so the button never sticks down.
      if (_dragging && _pointers.length >= 2) {
        widget.controller.pointer(x: _ix, y: _iy);
        _dragging = false;
      }
      _lastCentroid = _centroid();
      _startCentroid = _lastCentroid;
      _startSpread = _spread();
      _zoomAtPinchStart = _zoom;
      _twoFingers = _TwoFingerMode.undecided;
    }
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.localPosition;
    if (_pointers.length >= 2) {
      _handleTwoFingerMove();
    } else {
      final Offset delta = e.localPosition - _lastPos;
      _lastPos = e.localPosition;
      _moveCursorBy(delta, pressed: _dragging);
      if ((e.localPosition - _startPos).distance > _tapSlopPx) _moved = true;
    }
    setState(() {}); // redraw the cursor
  }

  void _handleTwoFingerMove() {
    final Offset centroid = _centroid();
    final double spread = _spread();
    if (_twoFingers == _TwoFingerMode.undecided) {
      if (_startSpread > 0 && (spread - _startSpread).abs() > _pinchSlopPx) {
        _twoFingers = _TwoFingerMode.zooming;
        // Anchor on the picture point the fingers started over, so the pinch
        // grows around what the user is looking at.
        _pinchAnchorFb = _fit.toFrameBuffer(_startCentroid);
      } else if ((centroid - _startCentroid).distance > _tapSlopPx) {
        _twoFingers = _TwoFingerMode.scrolling;
      } else {
        _lastCentroid = centroid;
        return;
      }
    }
    switch (_twoFingers) {
      case _TwoFingerMode.scrolling:
        _emitScroll(centroid - _lastCentroid);
      case _TwoFingerMode.zooming:
        if (_startSpread > 0) {
          _setZoom(
            _zoomAtPinchStart * (spread / _startSpread),
            anchorScreen: centroid,
            anchorFb: _pinchAnchorFb,
          );
        }
      case _TwoFingerMode.undecided:
        break;
    }
    _lastCentroid = centroid;
  }

  void _onPointerUp(PointerEvent e, {required bool canceled}) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers.remove(e.pointer);
    if (_pointers.isNotEmpty) {
      // Fingers remain (e.g. 2 -> 1): re-anchor and keep going.
      _reanchor();
      return;
    }
    // All fingers up: resolve the gesture.
    if (_dragging) {
      widget.controller.pointer(x: _ix, y: _iy); // release left
      _dragging = false;
    } else if (!canceled && _maxFingers >= 2) {
      if (!_scrolled && !_moved && _twoFingers == _TwoFingerMode.undecided) {
        widget.controller.click(x: _ix, y: _iy, button: 3); // two-finger tap
      }
    } else if (!canceled && _maxFingers == 1 && !_moved) {
      widget.controller.click(x: _ix, y: _iy); // tap -> left click at cursor
      _lastTapEndMs = DateTime.now().millisecondsSinceEpoch;
      _lastTapPos = e.localPosition;
    }
    _maxFingers = 0;
    _twoFingers = _TwoFingerMode.undecided;
    setState(() {});
  }

  // --- remote keyboard ------------------------------------------------------

  void _onKeyFocusChanged() {
    final bool open = _keyFocus.hasFocus;
    if (open != _keyboardOpen && mounted) {
      setState(() => _keyboardOpen = open);
    }
  }

  void _resetKeyField() {
    _keyText.value = const TextEditingValue(
      text: _sentinel,
      selection: TextSelection.collapsed(offset: _sentinel.length),
    );
  }

  void _toggleKeyboard() {
    if (_keyFocus.hasFocus) {
      _keyFocus.unfocus();
      return;
    }
    _resetKeyField();
    _keyFocus.requestFocus();
  }

  void _onKeyFieldChanged(String value) {
    if (value.length <= _sentinel.length) {
      // The sentinel itself was deleted: that keystroke was a backspace.
      if (value.length < _sentinel.length) _sendKeySym(_xkBackSpace);
      _resetKeyField();
      return;
    }
    for (final int rune in value.substring(_sentinel.length).runes) {
      _sendRune(rune);
    }
    _resetKeyField();
  }

  void _sendRune(int rune) {
    if (rune == 0x0a || rune == 0x0d) {
      _sendKeySym(_xkReturn);
      return;
    }
    // Latin-1 keysyms are the code point itself; everything else uses the
    // Unicode range X11 reserved for it.
    _sendKeySym(rune >= 0x20 && rune <= 0xff ? rune : 0x01000000 + rune);
  }

  void _sendKeySym(int keysym) {
    widget.controller.key(down: true, key: keysym);
    widget.controller.key(down: false, key: keysym);
  }

  // --- build ----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // The controls have to stay readable over a live web page, so they sit on
    // the scheme's scrim and carry its inverse foreground — the same chip the
    // close and full-screen targets use.
    final Color chip = scheme.scrim.withValues(alpha: 0.55);
    final Color onChip = scheme.onInverseSurface;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        _box = Size(constraints.maxWidth, constraints.maxHeight);
        _recomputeFit();
        final bool ready = widget.controller.isReady && _cursorSeeded;
        final double keyboardInset = MediaQuery.viewInsetsOf(context).bottom;
        return Stack(
          fit: StackFit.expand,
          children: <Widget>[
            _buildPicture(),
            // The touch surface. Opaque to hit-testing but visually clear.
            Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: _onPointerDown,
              onPointerMove: _onPointerMove,
              onPointerUp: (PointerEvent e) => _onPointerUp(e, canceled: false),
              onPointerCancel: (PointerEvent e) =>
                  _onPointerUp(e, canceled: true),
              child: const SizedBox.expand(),
            ),
            if (ready)
              Positioned(
                left: _fit.toScreen(_cursorFb).dx - _VncCursor.hotspot.dx,
                top: _fit.toScreen(_cursorFb).dy - _VncCursor.hotspot.dy,
                child: const IgnorePointer(child: _VncCursor()),
              ),
            // The zoom readout is only there when there is a zoom: at "whole
            // screen" it would be one more thing over the picture saying
            // nothing.
            if (ready && _zoom > VncViewFit.minZoom + 0.001)
              Positioned(
                left: 12,
                bottom: 12 + keyboardInset,
                child: _ZoomChip(
                  zoom: _zoom,
                  color: chip,
                  onColor: onChip,
                  onTap: _fitToScreen,
                ),
              ),
            // Typing and the cheat sheet, bottom right, clear of the top row.
            Positioned(
              right: 12,
              bottom: 12 + keyboardInset,
              child: IgnorePointer(
                ignoring: _showHelp,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    ExpressiveIconButton(
                      key: const Key('vnc_trackpad_keyboard_button'),
                      // The app's set has no keyboard glyph, so this one stays
                      // Material (same exception as the full-screen targets).
                      icon: _keyboardOpen
                          ? Icons.keyboard_hide
                          : Icons.keyboard_alt_outlined,
                      color: chip,
                      onColor: onChip,
                      size: MobileLayout.minTouchTarget,
                      tooltip: _keyboardOpen ? 'Hide the keys' : 'Type',
                      semanticsId: 'vnc_trackpad_keyboard',
                      onTap: widget.controller.isReady ? _toggleKeyboard : null,
                    ),
                    const SizedBox(width: 8),
                    ExpressiveIconButton(
                      key: const Key('vnc_trackpad_help_button'),
                      icon: Icons.help_outline,
                      color: chip,
                      onColor: onChip,
                      size: MobileLayout.minTouchTarget,
                      tooltip: 'How to control',
                      semanticsId: 'vnc_trackpad_help',
                      onTap: () => setState(() => _showHelp = true),
                    ),
                  ],
                ),
              ),
            ),
            if (_keyboardOpen)
              Positioned(
                left: 12,
                right: 12,
                bottom: 12 + keyboardInset + MobileLayout.minTouchTarget + 8,
                child: _SpecialKeyBar(
                  color: chip,
                  onColor: onChip,
                  onKey: _sendKeySym,
                  escape: _xkEscape,
                  tab: _xkTab,
                  enter: _xkReturn,
                  left: _xkLeft,
                  right: _xkRight,
                  up: _xkUp,
                  down: _xkDown,
                ),
              ),
            // The field that takes the soft keyboard. Never seen, never
            // tapped: the button above focuses it, and everything typed into
            // it is turned into X keysyms and forwarded.
            Positioned(
              left: 0,
              bottom: 0,
              width: 1,
              height: 1,
              child: Opacity(
                opacity: 0,
                child: EditableText(
                  key: const Key('vnc_trackpad_key_field'),
                  controller: _keyText,
                  focusNode: _keyFocus,
                  style: const TextStyle(fontSize: 1),
                  cursorColor: const Color(0x00000000),
                  backgroundCursorColor: const Color(0x00000000),
                  autocorrect: false,
                  enableSuggestions: false,
                  keyboardType: TextInputType.multiline,
                  maxLines: null,
                  onChanged: _onKeyFieldChanged,
                ),
              ),
            ),
            if (_showHelp)
              _TrackpadHelpCard(
                remoteSize: widget.controller.frameBufferSize,
                onDismiss: _dismissHelp,
              ),
          ],
        );
      },
    );
  }

  /// The framebuffer, painted at the fit's rectangle.
  ///
  /// `BoxFit.fill` inside a box that is already the framebuffer size times the
  /// scale keeps the aspect ratio by construction — the fit computed it — and
  /// it lets the child lay out at its native size, which is what the RFB widget
  /// needs to draw an unscaled `RawImage`.
  Widget _buildPicture() {
    if (_frameBuffer.isEmpty || _fit.size.isEmpty) {
      // No framebuffer yet: nothing to place, so let the child have the box.
      return widget.child;
    }
    return ClipRect(
      child: Stack(
        children: <Widget>[
          Positioned(
            left: _fit.origin.dx,
            top: _fit.origin.dy,
            width: _fit.size.width,
            height: _fit.size.height,
            child: FittedBox(fit: BoxFit.fill, child: widget.child),
          ),
        ],
      ),
    );
  }
}

/// The virtual mouse cursor: an arrow you can actually see.
///
/// It was a 26 px ring with a 4 px dot, and over a busy page it was easy to
/// lose. This is a real pointer, big, white with a dark outline so it reads on
/// white and on black alike, with a ringed dot on its own hot spot — the pixel
/// a tap will click. Its size is in SCREEN pixels and never follows the zoom:
/// it is a control, not picture content.
class _VncCursor extends StatelessWidget {
  const _VncCursor();

  /// The painted box, and where inside it the pointing tip sits.
  static const Size box = Size(52, 52);
  static const Offset hotspot = Offset(12, 12);

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: box.width,
      height: box.height,
      child: CustomPaint(painter: _VncCursorPainter()),
    );
  }
}

class _VncCursorPainter extends CustomPainter {
  // The classic pointer outline in a 24-unit space, tip at (0, 0).
  static const List<Offset> _arrow = <Offset>[
    Offset(0, 0),
    Offset(0, 17.4),
    Offset(4.3, 13.3),
    Offset(7.1, 19.8),
    Offset(10.2, 18.4),
    Offset(7.3, 12.1),
    Offset(12.6, 11.7),
  ];

  static const double _arrowScale = 1.65;
  static const double _hotspotRadius = 4.6;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset tip = _VncCursor.hotspot;
    final Path path = Path()..moveTo(tip.dx, tip.dy);
    for (final Offset p in _arrow.skip(1)) {
      path.lineTo(tip.dx + p.dx * _arrowScale, tip.dy + p.dy * _arrowScale);
    }
    path.close();

    // A neutral drop shadow so the white body never melts into white content.
    canvas.drawShadow(path, const Color(0xCC000000), 3, false);

    canvas.drawPath(path, Paint()..color = const Color(0xFFFFFFFF));
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.2
        ..strokeJoin = StrokeJoin.round
        ..color = const Color(0xFF101010),
    );

    // The hot spot: the exact remote pixel a tap clicks.
    canvas.drawCircle(
      tip,
      _hotspotRadius,
      Paint()..color = const Color(0xFF101010),
    );
    canvas.drawCircle(
      tip,
      _hotspotRadius - 1.7,
      Paint()..color = const Color(0xFFFFFFFF),
    );
  }

  @override
  bool shouldRepaint(_VncCursorPainter oldDelegate) => false;
}

/// The zoom readout. It says how far in the picture is and takes it back to
/// "whole screen" on a tap, so a zoom is never a trap.
class _ZoomChip extends StatelessWidget {
  const _ZoomChip({
    required this.zoom,
    required this.color,
    required this.onColor,
    required this.onTap,
  });

  final double zoom;
  final Color color;
  final Color onColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MorphTap(
      key: const Key('vnc_trackpad_zoom_chip'),
      onTap: onTap,
      color: color,
      shape: const StadiumBorder(),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          AppIcon(Icons.zoom_out_map, size: 16, color: onColor),
          const SizedBox(width: 8),
          Text(
            '${(zoom * 100).round()}%',
            style: TextStyle(
              color: onColor,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// The keys a phone keyboard does not give you, and a browser needs: escape a
/// dialog, tab between fields, walk a list, submit.
class _SpecialKeyBar extends StatelessWidget {
  const _SpecialKeyBar({
    required this.color,
    required this.onColor,
    required this.onKey,
    required this.escape,
    required this.tab,
    required this.enter,
    required this.left,
    required this.right,
    required this.up,
    required this.down,
  });

  final Color color;
  final Color onColor;
  final void Function(int keysym) onKey;
  final int escape;
  final int tab;
  final int enter;
  final int left;
  final int right;
  final int up;
  final int down;

  @override
  Widget build(BuildContext context) {
    Widget key(String label, int keysym) => MorphTap(
      onTap: () => onKey(keysym),
      color: color,
      shape: const StadiumBorder(),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Text(
        label,
        style: TextStyle(
          color: onColor,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
    return Align(
      alignment: Alignment.centerLeft,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            key('Esc', escape),
            const SizedBox(width: 8),
            key('Tab', tab),
            const SizedBox(width: 8),
            key('←', left),
            const SizedBox(width: 8),
            key('↑', up),
            const SizedBox(width: 8),
            key('↓', down),
            const SizedBox(width: 8),
            key('→', right),
            const SizedBox(width: 8),
            key('Enter', enter),
          ],
        ),
      ),
    );
  }
}

/// The gesture cheat-sheet shown on first use and behind the "?" button.
class _TrackpadHelpCard extends StatelessWidget {
  const _TrackpadHelpCard({required this.onDismiss, this.remoteSize});

  final VoidCallback onDismiss;

  /// The remote screen in pixels, printed at the foot of the card. It answers
  /// "how big is what I am looking at" without a second chip over the picture.
  final Size? remoteSize;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Size? size = remoteSize;
    return Positioned.fill(
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.6),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 340),
            child: Card(
              margin: const EdgeInsets.all(24),
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          AppIcon(
                            Icons.touch_app,
                            color: theme.colorScheme.primary,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Touch controls',
                            style: theme.textTheme.titleMedium,
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'The screen works like a laptop trackpad, not a '
                        'touchscreen. Move the arrow cursor, then tap to click '
                        'where it points.',
                        style: theme.textTheme.bodySmall,
                      ),
                      const SizedBox(height: 14),
                      const _HelpRow(
                        icon: Icons.pan_tool_alt,
                        title: 'Drag one finger',
                        body: 'Move the cursor',
                      ),
                      const _HelpRow(
                        icon: Icons.touch_app,
                        title: 'Tap',
                        body: 'Left click at the cursor',
                      ),
                      const _HelpRow(
                        icon: Icons.ads_click,
                        title: 'Double tap, then hold and drag',
                        body: 'Hold the button down and drag',
                      ),
                      const _HelpRow(
                        icon: Icons.swipe_vertical,
                        title: 'Drag two fingers',
                        body: 'Scroll',
                      ),
                      const _HelpRow(
                        icon: Icons.zoom_in,
                        title: 'Pinch two fingers',
                        body: 'Zoom in and out; tap the zoom chip to fit again',
                      ),
                      const _HelpRow(
                        icon: Icons.back_hand,
                        title: 'Tap two fingers',
                        body: 'Right click at the cursor',
                      ),
                      const _HelpRow(
                        icon: Icons.keyboard_alt_outlined,
                        title: 'Keyboard button',
                        body: 'Type into the remote screen',
                      ),
                      if (size != null && !size.isEmpty) ...<Widget>[
                        const SizedBox(height: 10),
                        Text(
                          'Remote screen: '
                          '${size.width.round()} × ${size.height.round()} px',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ],
                      const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          key: const Key('vnc_trackpad_help_dismiss'),
                          onPressed: onDismiss,
                          child: const Text('Got it'),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HelpRow extends StatelessWidget {
  const _HelpRow({required this.icon, required this.title, required this.body});

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          AppIcon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(title, style: theme.textTheme.labelLarge),
                Text(body, style: theme.textTheme.bodySmall),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
