import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui';

import 'package:dart_rfb/dart_rfb.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart' hide Image;
import 'package:flutter/services.dart';
import 'package:flutter_rfb/src/child_size_notifier_widget.dart';
import 'package:flutter_rfb/src/extensions/logical_keyboard_key_extensions.dart';
import 'package:flutter_rfb/src/remote_frame_buffer_client_isolate.dart';
import 'package:flutter_rfb/src/remote_frame_buffer_controller.dart';
import 'package:flutter_rfb/src/remote_frame_buffer_gesture_detector.dart';
import 'package:flutter_rfb/src/remote_frame_buffer_isolate_messages.dart';
import 'package:fpdart/fpdart.dart' hide State;
import 'package:logging/logging.dart';

final Logger _logger = Logger('RemoteFrameBufferWidget');

/// This widget displays the framebuffer associated with the RFB session.
/// On creation, it tries to establish a connection with the remote server
/// in an isolate. On success, it runs the read loop in that isolate.
class RemoteFrameBufferWidget extends StatefulWidget {
  final Option<Widget> _connectingWidget;
  final String _hostName;
  final Option<void Function(Object error)> _onError;
  final Option<String> _password;
  final int _port;

  /// CoWork fork: an optional handle onto the RFB isolate so app-side UI (the
  /// mobile trackpad overlay) can drive the pointer in remote coordinates.
  final RemoteFrameBufferController? _controller;

  /// CoWork fork: when false, the widget stops mapping local taps and wheel to
  /// remote input itself. The mobile overlay sets this so touch is owned solely
  /// by its virtual cursor; on desktop it stays true (normal mouse behaviour).
  final bool _enableBuiltInPointerInput;

  /// Immediately tries to establish a connection to a remote server at
  /// [hostName]:[port], optionally using [password].
  RemoteFrameBufferWidget({
    super.key,
    final Widget? connectingWidget,
    required final String hostName,
    final void Function(Object error)? onError,
    final String? password,
    final int port = 5900,
    final RemoteFrameBufferController? controller,
    final bool enableBuiltInPointerInput = true,
  })  : _connectingWidget = optionOf(connectingWidget),
        _hostName = hostName,
        _onError = optionOf(onError),
        _password = optionOf(password),
        _port = port,
        _controller = controller,
        _enableBuiltInPointerInput = enableBuiltInPointerInput;

  @override
  State<RemoteFrameBufferWidget> createState() =>
      RemoteFrameBufferWidgetState();
}

@visibleForTesting
class RemoteFrameBufferWidgetState extends State<RemoteFrameBufferWidget> {
  Option<ByteData> _frameBuffer = none();
  Option<Image> _image = none();
  Option<Isolate> _isolate = none();
  Option<SendPort> _isolateSendPort = none();
  final ValueNotifier<Size> _sizeValueNotifier = ValueNotifier<Size>(Size.zero);
  Option<StreamSubscription<Object?>> _streamSubscription = none();
  Option<ReceivePort> _receivePort = none();

  @override
  Widget build(final BuildContext context) => _frameBuffer
      .flatMap(
        (final ByteData frameBuffer) => frameBuffer.buffer
                .asUint8List(
                  frameBuffer.offsetInBytes,
                  frameBuffer.lengthInBytes,
                )
                .where((final int byte) => byte != 0)
                .isNotEmpty
            ? _image
            : none<Image>(),
      )
      .match(
        _buildConnecting,
        (final Image image) => _buildImage(image: image),
      );

  @override
  void dispose() {
    _streamSubscription.match(
      () {},
      (final StreamSubscription<Object?> subscription) =>
          unawaited(subscription.cancel()),
    );
    _image.match(
      () {},
      (final Image image) => image.dispose(),
    );
    _isolate.match(
      () {},
      (final Isolate isolate) => isolate.kill(),
    );
    RawKeyboard.instance.removeListener(_rawKeyEventListener);
    _receivePort.match(() {}, (final ReceivePort port) => port.close());
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    // Clipboard sync removed on purpose: this VNC tunnel is a pure sealed pipe.
    // The upstream package polled the local OS clipboard once a second and sent
    // it into the sandbox as an RFB ClientCutText (and wrote the sandbox's
    // clipboard back onto the local one). That both leaked host data across the
    // boundary and crashed on non-latin1 text. See the isolate patch too.
    RawKeyboard.instance.addListener(_rawKeyEventListener);
    unawaited(_initAsync());
  }

  Widget _buildConnecting() => widget._connectingWidget.getOrElse(
        () => const Center(
          child: CircularProgressIndicator(),
        ),
      );

  SizeTrackingWidget _buildImage({required final Image image}) =>
      SizeTrackingWidget(
        sizeValueNotifier: _sizeValueNotifier,
        // CoWork fork: on mobile the trackpad overlay owns all touch input, so
        // the built-in local-tap and wheel mapping is switched off to avoid a
        // finger firing an absolute tap AND a cursor move. The framebuffer is
        // still measured for the overlay's own coordinate maths.
        child: widget._enableBuiltInPointerInput
            ? _buildInteractiveImage(image: image)
            : RawImage(image: image),
      );

  Widget _buildInteractiveImage({required final Image image}) =>
        // CoWork fork: mouse-wheel / trackpad scroll. Upstream only forwards
        // taps, so a page in the agent's browser could not be scrolled from
        // the app. RFB carries wheel as pointer buttons 4/5 (vertical) and
        // 6/7 (horizontal), pressed and released at the pointer position.
        Listener(
          onPointerSignal: (final PointerSignalEvent event) {
            if (event is! PointerScrollEvent) {
              return;
            }
            // The tracked size is written in a post-frame callback and only
            // lands on the NEXT rebuild; on a still screen it can stay
            // Size.zero and every wheel event would be silently dropped. Under
            // FittedBox the child lays out at the image's own size, so the
            // image size IS the local coordinate space — use it as fallback.
            final Size size = _inputSize(image);
            final int x =
                (event.localPosition.dx / size.width * image.width).toInt();
            final int y =
                (event.localPosition.dy / size.height * image.height).toInt();
            final double dy = event.scrollDelta.dy;
            final double dx = event.scrollDelta.dx;
            _isolateSendPort.match(
              () {},
              (final SendPort sendPort) {
                void send({
                  final bool b4 = false,
                  final bool b5 = false,
                  final bool b6 = false,
                  final bool b7 = false,
                }) =>
                    sendPort.send(
                      RemoteFrameBufferIsolateSendMessage.pointerEvent(
                        button1Down: false,
                        button2Down: false,
                        button3Down: false,
                        button4Down: b4,
                        button5Down: b5,
                        button6Down: b6,
                        button7Down: b7,
                        button8Down: false,
                        x: x,
                        y: y,
                      ),
                    );
                if (dy != 0) {
                  send(b4: dy < 0, b5: dy > 0);
                  send();
                }
                if (dx != 0) {
                  send(b6: dx < 0, b7: dx > 0);
                  send();
                }
              },
            );
          },
          child: RemoteFrameBufferGestureDetector(
            image: image,
            // Same fallback for taps: a stale Size.zero made the first tap
            // divide by zero (NaN.toInt() throws from a gesture callback).
            remoteFrameBufferWidgetSize: _inputSize(image),
            sendPort: _isolateSendPort,
            child: RawImage(image: image),
          ),
        );

  /// The size input coordinates are relative to: the measured child size, or
  /// the image's own size while the measurement has not landed yet.
  Size _inputSize(final Image image) {
    final Size measured = _sizeValueNotifier.value;
    return measured.isEmpty
        ? Size(image.width.toDouble(), image.height.toDouble())
        : measured;
  }

  void _decodeAndUpdateImage({
    required final ByteData frameBuffer,
    required final RemoteFrameBufferIsolateReceiveMessageFrameBufferUpdate
        message,
  }) =>
      decodeImageFromPixels(
        frameBuffer.buffer.asUint8List(),
        message.frameBufferWidth,
        message.frameBufferHeight,
        PixelFormat.bgra8888,
        (final Image result) {
          if (mounted) {
            setState(
              () {
                _image.match(
                  () {},
                  (final Image image) => image.dispose(),
                );
                _image = some(result);
              },
            );
            _isolateSendPort.match(
              () {},
              (final SendPort sendPort) => sendPort.send(
                const RemoteFrameBufferIsolateSendMessage
                    .frameBufferUpdateRequest(),
              ),
            );
          }
        },
      );

  Task<void> _handleFrameBufferUpdateMessage({
    required final RemoteFrameBufferIsolateReceiveMessageFrameBufferUpdate
        update,
  }) =>
      Task<void>(() async {
        _logger.finer(
          'Received new update message with ${update.update.rectangles.length} rectangles',
        );
        _isolateSendPort = some(update.sendPort);
        // CoWork fork: hand the isolate port and the current framebuffer size
        // to the app-side controller so the mobile trackpad overlay can drive
        // the pointer. Cheap and idempotent; only notifies on a real change.
        widget._controller?.attach(
          sendPort: update.sendPort,
          size: Size(
            update.frameBufferWidth.toDouble(),
            update.frameBufferHeight.toDouble(),
          ),
        );
        if (_frameBuffer.isNone()) {
          _frameBuffer = some(
            ByteData(
              update.frameBufferHeight * update.frameBufferWidth * 4,
            ),
          );
        }
        unawaited(
          _frameBuffer.match(
            () async {},
            (final ByteData frameBuffer) async {
              for (final RemoteFrameBufferClientUpdateRectangle rectangle
                  in update.update.rectangles) {
                await rectangle.encodingType.when(
                  copyRect: () async {
                    final int sourceX = rectangle.byteData.getUint16(0);
                    final int sourceY = rectangle.byteData.getUint16(2);
                    // CoWork fork: the SOURCE rect comes off the wire too and
                    // was never bounds-checked — an out-of-range source threw
                    // a RangeError outside any catch and killed the view.
                    // Reject it; and copy whole rows, not one 4-byte view per
                    // pixel (a full-page scroll is all copyRect).
                    if (sourceX + rectangle.width > update.frameBufferWidth ||
                        sourceY + rectangle.height > update.frameBufferHeight) {
                      // ignore: avoid_print
                      print('copyRect source out of bounds, rect dropped');
                      return;
                    }
                    final Uint8List fb = frameBuffer.buffer.asUint8List(
                      frameBuffer.offsetInBytes,
                      frameBuffer.lengthInBytes,
                    );
                    final int rowBytes = rectangle.width * 4;
                    final Uint8List copied =
                        Uint8List(rowBytes * rectangle.height);
                    for (int row = 0; row < rectangle.height; row++) {
                      final int src =
                          ((sourceY + row) * update.frameBufferWidth + sourceX) *
                              4;
                      copied.setRange(
                        row * rowBytes,
                        (row + 1) * rowBytes,
                        fb,
                        src,
                      );
                    }
                    return (await updateFrameBuffer(
                      frameBuffer: frameBuffer,
                      frameBufferSize: Size(
                        update.frameBufferWidth.toDouble(),
                        update.frameBufferHeight.toDouble(),
                      ),
                      rectangle: rectangle.copyWith(
                        encodingType: const RemoteFrameBufferEncodingType.raw(),
                        byteData: ByteData.sublistView(copied),
                      ),
                    ).run())
                        .match(
                      (final Object error) =>
                          // ignore: avoid_print
                          print('Error updating frame buffer: $error'),
                      (final _) {},
                    );
                  },
                  raw: () async => (await updateFrameBuffer(
                    frameBuffer: frameBuffer,
                    frameBufferSize: Size(
                      update.frameBufferWidth.toDouble(),
                      update.frameBufferHeight.toDouble(),
                    ),
                    rectangle: rectangle,
                  ).run())
                      .match(
                    (final Object error) =>
                        // ignore: avoid_print
                        print('Error updating frame buffer: $error'),
                    (final _) {},
                  ),
                  unsupported: (final ByteData bytes) async {},
                );
              }
              _decodeAndUpdateImage(
                frameBuffer: frameBuffer,
                message: update,
              );
            },
          ),
        );
      });

  /// Initializes logic that requires to be run asynchronous.
  Future<void> _initAsync() async {
    final ReceivePort receivePort = ReceivePort();
    _receivePort = some(receivePort);
    _streamSubscription = some(
      receivePort.listen(
        (final Object? message) {
          // Error, first is error, second is stacktrace or null
          if (message is List) {
            widget._onError.match(
              () {},
              (final void Function(Object error) onError) =>
                  onError(message.first),
            );
          } else if (message is RemoteFrameBufferIsolateReceiveMessage) {
            message.map(
              // Clipboard sync removed: never write the sandbox clipboard onto
              // the local one. Drain the event and do nothing.
              clipBoardUpdate: (
                final RemoteFrameBufferIsolateReceiveMessageClipBoardUpdate
                    _,
              ) {},
              frameBufferUpdate: (
                final RemoteFrameBufferIsolateReceiveMessageFrameBufferUpdate
                    update,
              ) {
                _handleFrameBufferUpdateMessage(update: update).run();
              },
            );
          }
        },
      ),
    );
    _logger.info('Spawning new isolate for RFB client');
    _isolate = some(
      await Isolate.spawn(
        startRemoteFrameBufferClient,
        RemoteFrameBufferIsolateInitMessage(
          hostName: widget._hostName,
          password: widget._password,
          port: widget._port,
          sendPort: receivePort.sendPort,
        ),
        onError: receivePort.sendPort,
      ),
    );
  }

  void _rawKeyEventListener(final RawKeyEvent rawKeyEvent) {
    // CoWork fork: the keyboard listener is global. If anything is pushed on
    // top of this page (a dialog, a sheet with a text field) the page stays
    // mounted and every keystroke typed there would be forwarded into the
    // sandbox as a KeyEvent. Only forward while this route is the current one.
    if (!mounted || !(ModalRoute.of(context)?.isCurrent ?? true)) {
      return;
    }
    _forwardKey(rawKeyEvent);
  }

  void _forwardKey(final RawKeyEvent rawKeyEvent) =>
      _isolateSendPort.match(
        () {},
        (final SendPort sendPort) => sendPort.send(
          RemoteFrameBufferIsolateSendMessage.keyEvent(
            down: rawKeyEvent.isKeyPressed(rawKeyEvent.logicalKey),
            key: rawKeyEvent.logicalKey.asXWindowSystemKey(),
          ),
        ),
      );

  /// Updates [frameBuffer] with the given [rectangle]s.
  @visibleForTesting
  static TaskEither<Object, void> updateFrameBuffer({
    required final ByteData frameBuffer,
    required final Size frameBufferSize,
    required final RemoteFrameBufferClientUpdateRectangle rectangle,
  }) =>
      TaskEither<Object, void>.tryCatch(
        () async {
          // CoWork fork: blit whole rows with setRange instead of one
          // getUint32/setUint32 pair per pixel (~1M calls per full frame on
          // the UI isolate). Byte-exact copy, same [B,G,R,A] layout.
          final int fbWidth = frameBufferSize.width.toInt();
          final int fbHeight = frameBufferSize.height.toInt();
          if (rectangle.x + rectangle.width > fbWidth ||
              rectangle.y + rectangle.height > fbHeight) {
            throw StateError('rectangle exceeds the framebuffer');
          }
          final Uint8List fb = frameBuffer.buffer.asUint8List(
            frameBuffer.offsetInBytes,
            frameBuffer.lengthInBytes,
          );
          final Uint8List src = rectangle.byteData.buffer.asUint8List(
            rectangle.byteData.offsetInBytes,
            rectangle.byteData.lengthInBytes,
          );
          final int rowBytes = rectangle.width * 4;
          for (int y = 0; y < rectangle.height; y++) {
            final int dst = ((rectangle.y + y) * fbWidth + rectangle.x) * 4;
            fb.setRange(dst, dst + rowBytes, src, y * rowBytes);
          }
        },
        (final Object error, final _) => error,
      );
}
