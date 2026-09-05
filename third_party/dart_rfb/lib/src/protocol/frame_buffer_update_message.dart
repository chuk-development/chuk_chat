import 'dart:io';
import 'dart:typed_data';

import 'package:dart_rfb/src/client/config.dart';
import 'package:dart_rfb/src/client/remote_frame_buffer_client.dart';
import 'package:dart_rfb/src/extensions/raw_socket_extensions.dart';
import 'package:dart_rfb/src/protocol/encoding_type.dart';
import 'package:dart_rfb/src/protocol/tight_decoder.dart';
import 'package:fpdart/fpdart.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

part 'frame_buffer_update_message.freezed.dart';

/// A framebuffer update message.
///
/// See: https://www.rfc-editor.org/rfc/rfc6143.html#section-7.6.1
@freezed
class RemoteFrameBufferFrameBufferUpdateMessage
    with _$RemoteFrameBufferFrameBufferUpdateMessage {
  const factory RemoteFrameBufferFrameBufferUpdateMessage({
    required final Iterable<RemoteFrameBufferFrameBufferUpdateMessageRectangle>
        rectangles,
  }) = _RemoteFrameBufferFrameBufferUpdateMessage;

  /// Read and parse incoming message from [socket].
  static TaskEither<Object,
      RemoteFrameBufferFrameBufferUpdateMessage> readFromSocket({
    required final Config config,
    required final RawSocket socket,
    required final TightDecoder tightDecoder,
  }) =>
      TaskEither<Object, RemoteFrameBufferFrameBufferUpdateMessage>.tryCatch(
        () async {
          final TightByteSource tightSource = RawSocketTightByteSource(socket);
          final int numberOfRectangles =
              (await socket.readSync(length: 2).run()).getUint16(0);
          RemoteFrameBufferClient.logger
              .fine('< $numberOfRectangles rectangles');
          final List<RemoteFrameBufferFrameBufferUpdateMessageRectangle>
              rectangles =
              List<RemoteFrameBufferFrameBufferUpdateMessageRectangle>.empty(
            growable: true,
          );
          for (int i = 0; i < numberOfRectangles; i++) {
            final RemoteFrameBufferFrameBufferUpdateMessageRectangleHeader
                rectangleHeader =
                RemoteFrameBufferFrameBufferUpdateMessageRectangleHeader
                    .fromBytes(
              bytes: await socket.readSync(length: 12).run(),
            );
            RemoteFrameBufferClient.logger.fine('< $rectangleHeader');
            // A rectangle must fit the negotiated framebuffer. Without this a
            // corrupt header (w/h are raw uint16s) would size a multi-hundred-
            // MB buffer, or park the reader waiting for gigabytes that never
            // come. Fail the update instead; the client reconnects.
            if (rectangleHeader.x + rectangleHeader.width >
                    config.frameBufferWidth ||
                rectangleHeader.y + rectangleHeader.height >
                    config.frameBufferHeight) {
              throw StateError(
                'rectangle ${rectangleHeader.width}x${rectangleHeader.height}'
                '@${rectangleHeader.x},${rectangleHeader.y} exceeds the '
                '${config.frameBufferWidth}x${config.frameBufferHeight} '
                'framebuffer',
              );
            }
            // Tight (7) is decoded right here — its zlib streams live in the
            // client for the whole connection — and handed on as a plain
            // `raw` rectangle of bgra8888 pixels, so consumers need no new
            // variant. Any other unknown encoding is a protocol error: the
            // upstream behaviour (read 0 body bytes and carry on) silently
            // desynchronised the stream.
            final int encodingId = rectangleHeader.encodingType.id;
            if (encodingId == RemoteFrameBufferEncodingType.tightId) {
              rectangles.add(
                RemoteFrameBufferFrameBufferUpdateMessageRectangle(
                  encodingType: const RemoteFrameBufferEncodingType.raw(),
                  height: rectangleHeader.height,
                  pixelData: await tightDecoder.readRect(
                    source: tightSource,
                    width: rectangleHeader.width,
                    height: rectangleHeader.height,
                  ),
                  width: rectangleHeader.width,
                  x: rectangleHeader.x,
                  y: rectangleHeader.y,
                ),
              );
              continue;
            }
            final int numberOfDataBytes = rectangleHeader.encodingType.map(
              copyRect: (final _) => 4,
              raw: (final _) => (rectangleHeader.width *
                      rectangleHeader.height *
                      (config.pixelFormat.bitsPerPixel / 8))
                  .toInt(),
              unsupported: (final _) => throw StateError(
                'unsupported encoding $encodingId in framebuffer update',
              ),
            );
            rectangles.add(
              RemoteFrameBufferFrameBufferUpdateMessageRectangle(
                encodingType: rectangleHeader.encodingType,
                height: rectangleHeader.height,
                pixelData: await socket
                    .readSync(
                      length: numberOfDataBytes,
                      readWaitDuration: none(),
                    )
                    .run(),
                width: rectangleHeader.width,
                x: rectangleHeader.x,
                y: rectangleHeader.y,
              ),
            );
          }
          return RemoteFrameBufferFrameBufferUpdateMessage(
            rectangles: rectangles,
          );
        },
        (final Object error, final _) => error,
      );

  const RemoteFrameBufferFrameBufferUpdateMessage._();
}

@freezed
class RemoteFrameBufferFrameBufferUpdateMessageRectangle
    with _$RemoteFrameBufferFrameBufferUpdateMessageRectangle {
  const factory RemoteFrameBufferFrameBufferUpdateMessageRectangle({
    required final RemoteFrameBufferEncodingType encodingType,
    required final int height,
    required final ByteData pixelData,
    required final int width,
    required final int x,
    required final int y,
  }) = _RemoteFrameBufferFrameBufferUpdateMessageRectangle;
}

@freezed
class RemoteFrameBufferFrameBufferUpdateMessageRectangleHeader
    with _$RemoteFrameBufferFrameBufferUpdateMessageRectangleHeader {
  const factory RemoteFrameBufferFrameBufferUpdateMessageRectangleHeader({
    required final RemoteFrameBufferEncodingType encodingType,
    required final int height,
    required final int width,
    required final int x,
    required final int y,
  }) = _RemoteFrameBufferFrameBufferUpdateMessageRectangleHeader;

  factory RemoteFrameBufferFrameBufferUpdateMessageRectangleHeader.fromBytes({
    required final ByteData bytes,
  }) =>
      RemoteFrameBufferFrameBufferUpdateMessageRectangleHeader(
        encodingType: RemoteFrameBufferEncodingType.fromBytes(
          bytes: ByteData.sublistView(bytes, 8, 12),
        ),
        height: bytes.getUint16(6),
        width: bytes.getUint16(4),
        x: bytes.getUint16(0),
        y: bytes.getUint16(2),
      );

  const RemoteFrameBufferFrameBufferUpdateMessageRectangleHeader._();
}
