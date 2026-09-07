import 'dart:isolate';
import 'dart:ui';

import 'package:flutter/foundation.dart';
import 'package:flutter_rfb/src/remote_frame_buffer_isolate_messages.dart';
import 'package:fpdart/fpdart.dart';

/// CoWork fork addition. A thin handle onto the RFB isolate so app-side UI can
/// drive the remote pointer and keyboard directly, in REMOTE framebuffer
/// coordinates. The built-in `RemoteFrameBufferGestureDetector` maps a local
/// tap straight to an absolute remote point — fine for a mouse, wrong for a
/// fingertip. The mobile trackpad overlay keeps its own virtual cursor and
/// pushes absolute points through this controller instead.
///
/// The controller is only live once the first framebuffer update has arrived
/// (that update carries both the isolate [SendPort] and the framebuffer size),
/// so [isReady] starts false. Listeners are notified when it becomes ready and
/// whenever the framebuffer size changes (a resolution change reallocates it).
class RemoteFrameBufferController extends ChangeNotifier {
  Option<SendPort> _sendPort = none();
  Size? _frameBufferSize;

  /// True once the isolate is connected and the framebuffer size is known.
  bool get isReady => _sendPort.isSome() && _frameBufferSize != null;

  /// Remote framebuffer size in pixels, or null before the first update.
  Size? get frameBufferSize => _frameBufferSize;

  /// Called by `RemoteFrameBufferWidget` on every framebuffer update. Cheap and
  /// idempotent; only fires listeners when readiness or size actually changes.
  void attach({required final SendPort sendPort, required final Size size}) {
    final bool wasReady = isReady;
    final Size? oldSize = _frameBufferSize;
    _sendPort = some(sendPort);
    _frameBufferSize = size;
    if (isReady != wasReady || oldSize != size) {
      notifyListeners();
    }
  }

  /// Sends a raw pointer event at remote pixel ([x], [y]) with the given set of
  /// pressed [buttons] (1 = left, 2 = middle, 3 = right, 4/5 = wheel up/down,
  /// 6/7 = wheel left/right, 8 = extra). Coordinates are clamped to the
  /// framebuffer so a stray point can never index off the remote screen.
  void pointer({
    required final int x,
    required final int y,
    final Set<int> buttons = const <int>{},
  }) =>
      _sendPort.match(
        () {},
        (final SendPort sendPort) {
          final Size? size = _frameBufferSize;
          final int cx = size == null
              ? x
              : x.clamp(0, (size.width - 1).toInt());
          final int cy = size == null
              ? y
              : y.clamp(0, (size.height - 1).toInt());
          sendPort.send(
            RemoteFrameBufferIsolateSendMessage.pointerEvent(
              button1Down: buttons.contains(1),
              button2Down: buttons.contains(2),
              button3Down: buttons.contains(3),
              button4Down: buttons.contains(4),
              button5Down: buttons.contains(5),
              button6Down: buttons.contains(6),
              button7Down: buttons.contains(7),
              button8Down: buttons.contains(8),
              x: cx,
              y: cy,
            ),
          );
        },
      );

  /// Presses and immediately releases [button] at ([x], [y]). Default is a
  /// left click (button 1); pass 3 for a right click.
  void click({
    required final int x,
    required final int y,
    final int button = 1,
  }) {
    pointer(x: x, y: y, buttons: <int>{button});
    pointer(x: x, y: y);
  }

  /// One wheel notch at ([x], [y]). RFB carries the wheel as a button press +
  /// release: 4 up, 5 down, 6 left, 7 right. [dy] < 0 scrolls up, [dx] < 0
  /// scrolls left; magnitude is ignored (one notch per call).
  void scroll({
    required final int x,
    required final int y,
    final double dx = 0,
    final double dy = 0,
  }) {
    if (dy != 0) {
      final int button = dy < 0 ? 4 : 5;
      pointer(x: x, y: y, buttons: <int>{button});
      pointer(x: x, y: y);
    }
    if (dx != 0) {
      final int button = dx < 0 ? 6 : 7;
      pointer(x: x, y: y, buttons: <int>{button});
      pointer(x: x, y: y);
    }
  }

  /// Sends a raw key event. [key] is an X keysym (see
  /// `LogicalKeyboardKey.asXWindowSystemKey`).
  void key({required final bool down, required final int key}) =>
      _sendPort.match(
        () {},
        (final SendPort sendPort) => sendPort.send(
          RemoteFrameBufferIsolateSendMessage.keyEvent(down: down, key: key),
        ),
      );
}
