import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:cowork/ui/expressive/icon_map.dart';
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
///   two finger tap         right click at the cursor
///
/// The cursor lives in remote framebuffer pixels so it stays put when the view
/// is resized or rescaled; it is drawn back onto the screen through the same
/// contain-fit transform the framebuffer image uses.
class VncTrackpadOverlay extends StatefulWidget {
  const VncTrackpadOverlay({
    super.key,
    required this.controller,
    required this.child,
    this.enabled = true,
  });

  /// The handle onto the RFB isolate that carries our pointer events.
  final RemoteFrameBufferController controller;

  /// The remote-screen widget (a [RemoteFrameBufferWidget], usually wrapped in
  /// a `FittedBox(fit: BoxFit.contain)`), laid out to fill this overlay.
  final Widget child;

  /// When false the overlay is inert and only shows [child] (used while the
  /// stream is not connected).
  final bool enabled;

  @override
  State<VncTrackpadOverlay> createState() => _VncTrackpadOverlayState();
}

class _VncTrackpadOverlayState extends State<VncTrackpadOverlay> {
  // Tuning. Screen-relative, so the feel is the same at any framebuffer size.
  static const double _moveSensitivity = 1.0;
  // One wheel notch per this many pixels of two-finger travel.
  static const double _scrollStepPx = 22.0;
  // A press that moves less than this is a tap, not a drag.
  static const double _tapSlopPx = 12.0;
  // A second tap within this window (and close in space) starts a drag.
  static const int _doubleTapMs = 300;
  static const double _doubleTapSlopPx = 28.0;

  static const String _helpSeenKey = 'vnc_trackpad_help_seen_v1';

  // Virtual cursor in remote framebuffer pixels.
  double _cx = 0;
  double _cy = 0;
  bool _cursorSeeded = false;

  // The contain-fit transform from the last layout: framebuffer px -> screen.
  double _scale = 1;
  Offset _origin = Offset.zero;

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

  int _lastTapEndMs = 0;
  Offset _lastTapPos = Offset.zero;

  bool _showHelp = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onControllerChanged);
    _maybeShowHelp();
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onControllerChanged);
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
    if (mounted) setState(() {}); // readiness/size may have changed
  }

  void _seedCursor() {
    final Size? fb = widget.controller.frameBufferSize;
    if (fb == null || fb.isEmpty) return;
    _cx = fb.width / 2;
    _cy = fb.height / 2;
    _cursorSeeded = true;
  }

  // Compute the contain-fit transform for the current box and framebuffer.
  void _updateFit(Size box) {
    final Size? fb = widget.controller.frameBufferSize;
    if (fb == null || fb.isEmpty || box.isEmpty) return;
    final double scale = math.min(box.width / fb.width, box.height / fb.height);
    final double shownW = fb.width * scale;
    final double shownH = fb.height * scale;
    _scale = scale;
    _origin = Offset((box.width - shownW) / 2, (box.height - shownH) / 2);
  }

  Offset _cursorToScreen() =>
      Offset(_origin.dx + _cx * _scale, _origin.dy + _cy * _scale);

  void _clampCursor() {
    final Size? fb = widget.controller.frameBufferSize;
    if (fb == null || fb.isEmpty) return;
    _cx = _cx.clamp(0.0, fb.width - 1);
    _cy = _cy.clamp(0.0, fb.height - 1);
  }

  int get _ix => _cx.round();
  int get _iy => _cy.round();

  void _moveCursorBy(Offset screenDelta, {required bool pressed}) {
    if (_scale <= 0) return;
    _cx += screenDelta.dx / _scale * _moveSensitivity;
    _cy += screenDelta.dy / _scale * _moveSensitivity;
    _clampCursor();
    widget.controller.pointer(
      x: _ix,
      y: _iy,
      buttons: pressed ? <int>{1} : <int>{},
    );
  }

  Offset _centroid() {
    if (_pointers.isEmpty) return Offset.zero;
    double x = 0, y = 0;
    // Two fingers drive scroll; ignore any beyond the first two.
    final List<Offset> pts = _pointers.values.take(2).toList();
    for (final Offset p in pts) {
      x += p.dx;
      y += p.dy;
    }
    return Offset(x / pts.length, y / pts.length);
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
    }
  }

  void _onPointerMove(PointerMoveEvent e) {
    if (!_pointers.containsKey(e.pointer)) return;
    _pointers[e.pointer] = e.localPosition;
    if (_pointers.length >= 2) {
      final Offset c = _centroid();
      _emitScroll(c - _lastCentroid);
      _lastCentroid = c;
    } else {
      final Offset delta = e.localPosition - _lastPos;
      _lastPos = e.localPosition;
      _moveCursorBy(delta, pressed: _dragging);
      if ((e.localPosition - _startPos).distance > _tapSlopPx) _moved = true;
    }
    setState(() {}); // redraw the cursor
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
      if (!_scrolled && !_moved) {
        widget.controller.click(x: _ix, y: _iy, button: 3); // two-finger tap
      }
    } else if (!canceled && _maxFingers == 1 && !_moved) {
      widget.controller.click(x: _ix, y: _iy); // tap -> left click at cursor
      _lastTapEndMs = DateTime.now().millisecondsSinceEpoch;
      _lastTapPos = e.localPosition;
    }
    _maxFingers = 0;
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    return LayoutBuilder(
      builder: (context, constraints) {
        _updateFit(Size(constraints.maxWidth, constraints.maxHeight));
        final bool ready = widget.controller.isReady && _cursorSeeded;
        return Stack(
          fit: StackFit.expand,
          children: [
            widget.child,
            // The touch surface. Opaque to hit-testing but visually clear.
            Listener(
              behavior: HitTestBehavior.opaque,
              onPointerDown: _onPointerDown,
              onPointerMove: _onPointerMove,
              onPointerUp: (e) => _onPointerUp(e, canceled: false),
              onPointerCancel: (e) => _onPointerUp(e, canceled: true),
              child: const SizedBox.expand(),
            ),
            if (ready)
              Positioned(
                left: _cursorToScreen().dx - _VncCursor.size / 2,
                top: _cursorToScreen().dy - _VncCursor.size / 2,
                child: const IgnorePointer(child: _VncCursor()),
              ),
            // Persistent "how to" button, bottom-right, clear of the top chrome.
            Positioned(
              right: 12,
              bottom: 12,
              child: IgnorePointer(
                ignoring: _showHelp,
                child: _HelpButton(
                  onPressed: () => setState(() => _showHelp = true),
                ),
              ),
            ),
            if (_showHelp) _TrackpadHelpCard(onDismiss: _dismissHelp),
          ],
        );
      },
    );
  }
}

/// The virtual mouse cursor: a small ring with a dot, readable on any content.
class _VncCursor extends StatelessWidget {
  const _VncCursor();

  static const double size = 26;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: Colors.white.withValues(alpha: 0.18),
        border: Border.all(color: Colors.white, width: 1.5),
        boxShadow: const [
          BoxShadow(color: Colors.black54, blurRadius: 3, spreadRadius: 0.5),
        ],
      ),
      child: Center(
        child: Container(
          width: 4,
          height: 4,
          decoration: const BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}

class _HelpButton extends StatelessWidget {
  const _HelpButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.black.withValues(alpha: 0.45),
      shape: const CircleBorder(),
      child: IconButton(
        key: const Key('vnc_trackpad_help_button'),
        icon: const AppIcon(Icons.help_outline, color: Colors.white),
        tooltip: 'How to control',
        onPressed: onPressed,
      ),
    );
  }
}

/// The gesture cheat-sheet shown on first use and behind the "?" button.
class _TrackpadHelpCard extends StatelessWidget {
  const _TrackpadHelpCard({required this.onDismiss});

  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Positioned.fill(
      child: ColoredBox(
        color: Colors.black.withValues(alpha: 0.6),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 340),
            child: Card(
              margin: const EdgeInsets.all(24),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
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
                      'touchscreen. Move the ring cursor, then tap to click '
                      'where it sits.',
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
                      icon: Icons.back_hand,
                      title: 'Tap two fingers',
                      body: 'Right click at the cursor',
                    ),
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
        children: [
          AppIcon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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
