// lib/services/payload_compression.dart
//
// Compression of chat payloads, for the cloud (before encryption) and for
// the SQLite cache.
//
// A compressed payload is a frame:
//
//   byte 0      0x00             frame marker
//   byte 1      codec id         1 = raw deflate, 2 = bzip2
//   bytes 2..5  length           uncompressed length, uint32 little endian
//   bytes 6..   compressed data
//
// JSON text never starts with 0x00 and gzip starts with 0x1f 0x8b, so the
// reader tells the three stored forms apart by their first byte: a frame, a
// gzip blob (the SQLite cache before v3) or plain UTF-8 JSON (v1/v2 cloud
// payloads and old cache rows).
//
// Both codecs come from `package:archive`, which is pure Dart: the same code
// runs on Android, iOS, Linux, Windows, macOS and the web. The cloud frame
// takes whichever of the two is smaller for the payload (on 939 real chats:
// bzip2 for a third of them, the long ones with repeated tool output;
// deflate for the rest). The cache takes deflate at a lower level, because a
// chat is opened from the cache and bzip2 decodes several times slower.
// Brotli-11 and zstd-19 compress about 10-15 % better than this, but no
// encoder for them runs on every platform, the web included; see
// docs/CHAT_PAYLOAD_FORMAT.md for the numbers.

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Codec ids of the frame. Never reuse a number: stored data carries it.
class PayloadCodec {
  const PayloadCodec._();

  static const int deflate = 1;
  static const int bzip2 = 2;
}

const int _frameMarker = 0x00;
const int _headerLength = 6;

/// Payloads below this size are not worth a bzip2 attempt: its block header
/// alone is larger than what it saves over deflate.
const int _bzip2MinBytes = 2048;

/// Whether [bytes] is a compressed payload frame.
bool isPayloadFrame(List<int> bytes) =>
    bytes.length >= _headerLength && bytes[0] == _frameMarker;

/// The strongest frame for [text]: bzip2 or deflate level 9, whichever is
/// smaller. With [allowBzip2] false only deflate is used (the web, for a
/// large payload: there is no isolate there, and bzip2 is slow in
/// JavaScript).
///
/// Every bzip2 frame is decoded again before it is returned; a codec fault
/// falls back to deflate instead of storing data that cannot be read.
Uint8List compressPayloadStrong(String text, {bool allowBzip2 = true}) {
  final raw = utf8.encode(text);
  var best = _frame(PayloadCodec.deflate, raw, _deflate(raw, 9));
  if (allowBzip2 && raw.length >= _bzip2MinBytes) {
    try {
      final data = BZip2Encoder().encodeBytes(raw);
      if (data.length + _headerLength < best.length) {
        final candidate = _frame(PayloadCodec.bzip2, raw, data);
        if (_sameBytes(decompressPayloadFrame(candidate), raw)) {
          best = candidate;
        }
      }
    } catch (_) {
      // Keep deflate.
    }
  }
  return best;
}

/// A fast deflate frame for [text] (the local cache).
Uint8List compressPayloadFast(String text) {
  final raw = utf8.encode(text);
  return _frame(PayloadCodec.deflate, raw, _deflate(raw, 6));
}

/// The uncompressed bytes of a frame. Throws [FormatException] for an
/// unknown codec or a length that does not match.
Uint8List decompressPayloadFrame(List<int> frame) {
  if (!isPayloadFrame(frame)) {
    throw const FormatException('Not a payload frame');
  }
  final codec = frame[1];
  final length =
      frame[2] | (frame[3] << 8) | (frame[4] << 16) | (frame[5] << 24);
  final data = frame is Uint8List
      ? Uint8List.sublistView(frame, _headerLength)
      : Uint8List.fromList(frame.sublist(_headerLength));
  final Uint8List out;
  switch (codec) {
    case PayloadCodec.deflate:
      out = Inflate(data).getBytes();
    case PayloadCodec.bzip2:
      out = BZip2Decoder().decodeBytes(data, verify: true);
    default:
      throw FormatException('Unknown payload codec: $codec');
  }
  if (out.length != length) {
    throw const FormatException('Payload frame length does not match');
  }
  return out;
}

/// The text of a stored payload in any of its forms: a frame, a gzip blob
/// or plain UTF-8.
String decodeStoredPayload(List<int> bytes) {
  if (isPayloadFrame(bytes)) {
    return utf8.decode(decompressPayloadFrame(bytes));
  }
  if (bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b) {
    return utf8.decode(GZipDecoder().decodeBytes(bytes));
  }
  return utf8.decode(bytes);
}

Uint8List _deflate(List<int> raw, int level) =>
    Deflate(raw, level: level).getBytes();

Uint8List _frame(int codec, List<int> raw, List<int> data) {
  final length = raw.length;
  final out = Uint8List(_headerLength + data.length);
  out[0] = _frameMarker;
  out[1] = codec;
  out[2] = length & 0xff;
  out[3] = (length >> 8) & 0xff;
  out[4] = (length >> 16) & 0xff;
  out[5] = (length >> 24) & 0xff;
  out.setRange(_headerLength, out.length, data);
  return out;
}

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
