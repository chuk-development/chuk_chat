import 'dart:typed_data';

import 'package:freezed_annotation/freezed_annotation.dart';

part 'encoding_type.freezed.dart';

/// Encoding types as defined by RFC 6143.
///
/// See: https://www.rfc-editor.org/rfc/rfc6143.html#section-7.7
///
/// Agents fork: the `unsupported` variant now round-trips its numeric id
/// (upstream serialised it as -1), so it doubles as the carrier for encodings
/// this union has no dedicated variant for — Tight (7) and the Tight
/// pseudo-encodings (JPEG quality, compression level). Adding real variants
/// would require regenerating every `*.freezed.dart` with a toolchain that no
/// longer resolves against this SDK; carrying the id is enough because Tight
/// is decoded inside the client and surfaces as a plain `raw` rectangle.
@freezed
class RemoteFrameBufferEncodingType with _$RemoteFrameBufferEncodingType {
  const factory RemoteFrameBufferEncodingType.copyRect() =
      RemoteFrameBufferEncodingTypeCopyRect;
  const factory RemoteFrameBufferEncodingType.raw() =
      RemoteFrameBufferEncodingTypeRaw;
  const factory RemoteFrameBufferEncodingType.unsupported({
    required final ByteData bytes,
  }) = RemoteFrameBufferEncodingTypeUnsupported;

  /// Tight encoding (TightVNC / libvncserver extension). Sent by x11vnc when
  /// advertised: zlib'd copy/palette/gradient rectangles, solid fills, and
  /// JPEG for photographic areas. 10-20x smaller than raw on browser content.
  static const int tightId = 7;

  /// Tight JPEG quality pseudo-encoding: -32 + quality, quality 0..9.
  static int tightQualityId(final int quality) =>
      -32 + quality.clamp(0, 9);

  /// Tight compression-level pseudo-encoding: -256 + level, level 0..9.
  static int tightCompressionLevelId(final int level) =>
      -256 + level.clamp(0, 9);

  /// An encoding named only by its id (no dedicated variant).
  factory RemoteFrameBufferEncodingType.fromId(final int id) =>
      RemoteFrameBufferEncodingType.unsupported(
        bytes: ByteData(4)..setInt32(0, id),
      );

  /// Parse [bytes].
  factory RemoteFrameBufferEncodingType.fromBytes({
    required final ByteData bytes,
  }) {
    switch (bytes.getInt32(0)) {
      case 0:
        return const RemoteFrameBufferEncodingType.raw();
      case 1:
        return const RemoteFrameBufferEncodingType.copyRect();
      default:
        return RemoteFrameBufferEncodingType.unsupported(bytes: bytes);
    }
  }

  /// The numeric encoding id, for every variant.
  int get id => map(
        copyRect: (final _) => 1,
        raw: (final _) => 0,
        unsupported: (final RemoteFrameBufferEncodingTypeUnsupported u) =>
            u.bytes.getInt32(0),
      );

  /// Generate byte representation of thie encoding type.
  ByteData toBytes() => ByteData(4)..setInt32(0, id);

  const RemoteFrameBufferEncodingType._();
}
