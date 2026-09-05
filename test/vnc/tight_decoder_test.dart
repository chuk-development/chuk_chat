// Tight (RFB encoding 7) decoder — verified against REAL x11vnc output.
//
// The fixtures in test/vnc/fixtures were captured with
// `executor/tests/live_vnc_speed_probe.py --dump` from the agent's own
// container: for one screen region it recorded a raw (uncompressed) capture,
// then the Tight-encoded rectangles for the same region, then raw again, and
// only kept the vector when both raw captures were byte-identical. So the
// Tight bytes provably encode exactly the raw pixels saved next to them.
//
// Non-JPEG rectangles (copy / palette / fill / gradient) must decode
// pixel-exact. JPEG rectangles are lossy by design, so they are held to a
// small mean error against the raw pixels instead.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dart_rfb/src/protocol/tight_decoder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

/// A 4x4 baseline JPEG, small enough for a 1-byte compact length.
Uint8List _encodeTinyJpeg() {
  final im = img.Image(width: 4, height: 4);
  im.clear(img.ColorRgb8(200, 100, 50));
  return Uint8List.fromList(img.encodeJpg(im, quality: 50));
}

const int _encTight = 7;
const int _subJpeg = 9;

class _Vector {
  _Vector(this.name, this.meta, this.raw);
  final String name;
  final Map<String, dynamic> meta;
  final Uint8List raw;

  int get x0 => meta['region']['x'] as int;
  int get y0 => meta['region']['y'] as int;
  int get w => meta['region']['w'] as int;
  int get h => meta['region']['h'] as int;
  List<Map<String, dynamic>> get rects =>
      (meta['rects'] as List).cast<Map<String, dynamic>>();
}

_Vector _load(String name) {
  final dir = Directory('test/vnc/fixtures');
  final meta = jsonDecode(File('${dir.path}/$name.tight.json').readAsStringSync())
      as Map<String, dynamic>;
  final raw = File('${dir.path}/${meta['raw_file']}').readAsBytesSync();
  return _Vector(name, meta, raw);
}

/// Decode every rect of a vector in order (one decoder = one connection's
/// zlib streams) into a region-sized BGRA buffer. Returns the buffer plus,
/// per rect, whether it was JPEG.
Future<(Uint8List, List<bool>)> _decodeAll(_Vector v) async {
  final decoder = TightDecoder();
  final out = Uint8List(v.w * v.h * 4);
  final jpegFlags = <bool>[];
  for (final r in v.rects) {
    final rw = r['w'] as int, rh = r['h'] as int;
    final rx = (r['x'] as int) - v.x0, ry = (r['y'] as int) - v.y0;
    final body = base64Decode(r['body_b64'] as String);
    expect(r['encoding'], _encTight, reason: 'fixture must be Tight rects');
    jpegFlags.add((body[0] >> 4) == _subJpeg);

    final src = BytesTightByteSource(Uint8List.fromList(body));
    final pixels = await decoder.readRect(source: src, width: rw, height: rh);
    // A correct delimiter consumes the rect body exactly — nothing left over,
    // nothing read past the end (that would have thrown).
    expect(src.remaining, 0,
        reason: '${v.name}: rect at ($rx,$ry) ${rw}x$rh left ${src.remaining} B');
    expect(pixels.lengthInBytes, rw * rh * 4);

    final px = pixels.buffer.asUint8List(pixels.offsetInBytes, pixels.lengthInBytes);
    for (var row = 0; row < rh; row++) {
      final dst = ((ry + row) * v.w + rx) * 4;
      out.setRange(dst, dst + rw * 4, px, row * rw * 4);
    }
  }
  return (out, jpegFlags);
}

/// Mean absolute error over R,G,B of one rect vs the raw capture.
double _rectMeanError(_Vector v, Uint8List decoded, Map<String, dynamic> r) {
  final rw = r['w'] as int, rh = r['h'] as int;
  final rx = (r['x'] as int) - v.x0, ry = (r['y'] as int) - v.y0;
  var sum = 0;
  for (var row = 0; row < rh; row++) {
    var o = ((ry + row) * v.w + rx) * 4;
    for (var col = 0; col < rw; col++, o += 4) {
      sum += (decoded[o] - v.raw[o]).abs() +
          (decoded[o + 1] - v.raw[o + 1]).abs() +
          (decoded[o + 2] - v.raw[o + 2]).abs();
    }
  }
  return sum / (rw * rh * 3);
}

void _expectRectExact(_Vector v, Uint8List decoded, Map<String, dynamic> r) {
  final rw = r['w'] as int, rh = r['h'] as int;
  final rx = (r['x'] as int) - v.x0, ry = (r['y'] as int) - v.y0;
  for (var row = 0; row < rh; row++) {
    var o = ((ry + row) * v.w + rx) * 4;
    for (var col = 0; col < rw; col++, o += 4) {
      // B, G, R must match the raw capture; alpha is ours (0xFF).
      if (decoded[o] != v.raw[o] ||
          decoded[o + 1] != v.raw[o + 1] ||
          decoded[o + 2] != v.raw[o + 2]) {
        fail('${v.name}: pixel mismatch at rect ($rx,$ry) +($col,$row): '
            'got ${decoded.sublist(o, o + 3)} want ${v.raw.sublist(o, o + 3)}');
      }
      expect(decoded[o + 3], 0xFF);
    }
  }
}

void main() {
  for (final name in ['chrome_top', 'nyt_mixed', 'nyt_nojpeg']) {
    test('$name: real x11vnc Tight rects decode to the raw pixels', () async {
      final v = _load(name);
      final (decoded, jpegFlags) = await _decodeAll(v);
      var exact = 0, lossy = 0;
      for (var i = 0; i < v.rects.length; i++) {
        final r = v.rects[i];
        if (jpegFlags[i]) {
          // JPEG at quality 6: visually clean, numerically lossy. A broken
          // decoder (wrong byte order, wrong offset) lands far above this.
          final err = _rectMeanError(v, decoded, r);
          expect(err, lessThan(8.0),
              reason: '$name: JPEG rect mean abs error $err too high');
          lossy++;
        } else {
          _expectRectExact(v, decoded, r);
          exact++;
        }
      }
      // ignore: avoid_print
      print('$name: ${v.rects.length} rects — $exact exact, $lossy jpeg');
    });
  }

  test('nyt_nojpeg covers zlib copy-filter rects (no JPEG at all)', () async {
    final v = _load('nyt_nojpeg');
    final subs = v.rects.map((r) => base64Decode(r['body_b64'] as String)[0] >> 4);
    expect(subs.any((s) => s == _subJpeg), isFalse);
  });

  test('chrome_top covers a basic rect with an explicit filter', () async {
    final v = _load('chrome_top');
    final ctls = v.rects.map((r) => base64Decode(r['body_b64'] as String)[0]);
    // 0x40 = explicit filter-id byte follows (palette/gradient).
    expect(ctls.any((c) => (c >> 4) < 8 && (c & 0x40) != 0), isTrue);
  });

  group('synthetic', () {
    test('fill paints the whole rect in R,G,B -> B,G,R,FF', () async {
      final decoder = TightDecoder();
      final src = BytesTightByteSource(Uint8List.fromList([0x80, 10, 20, 30]));
      final px = await decoder.readRect(source: src, width: 3, height: 2);
      final b = px.buffer.asUint8List(px.offsetInBytes, px.lengthInBytes);
      expect(src.remaining, 0);
      for (var i = 0; i < b.length; i += 4) {
        expect(b.sublist(i, i + 4), [30, 20, 10, 0xFF]);
      }
    });

    test('inline copy below 12 bytes is read uncompressed', () async {
      // 2x1 copy filter = 6 filtered bytes < 12 -> inline, no length prefix.
      final decoder = TightDecoder();
      final src = BytesTightByteSource(
          Uint8List.fromList([0x00, 1, 2, 3, 4, 5, 6]));
      final px = await decoder.readRect(source: src, width: 2, height: 1);
      final b = px.buffer.asUint8List(px.offsetInBytes, px.lengthInBytes);
      expect(src.remaining, 0);
      expect(b, [3, 2, 1, 0xFF, 6, 5, 4, 0xFF]);
    });

    test('2-colour palette packs 1 bit/pixel MSB-first per row', () async {
      // 9x2 rect: rows of 2 bytes each (9 bits -> 2 bytes), filtered 4 B.
      // ctl 0x40 = basic, stream 0, explicit filter; filter 1; 1 colour-1 = 1
      final decoder = TightDecoder();
      final bytes = <int>[
        0x40, 1, 1, // basic+filter, palette, numColors-1 = 1
        0, 0, 0, 255, 255, 255, // palette[0]=black, [1]=white (R,G,B)
        0x80, 0x00, // row 0: only first pixel set
        0xFF, 0x80, // row 1: all 9 set
      ];
      final src = BytesTightByteSource(Uint8List.fromList(bytes));
      final px = await decoder.readRect(source: src, width: 9, height: 2);
      final b = px.buffer.asUint8List(px.offsetInBytes, px.lengthInBytes);
      expect(src.remaining, 0);
      expect(b.sublist(0, 4), [255, 255, 255, 0xFF]); // (0,0) white
      expect(b.sublist(4, 8), [0, 0, 0, 0xFF]); // (1,0) black
      expect(b.sublist(9 * 4, 9 * 4 + 4), [255, 255, 255, 0xFF]); // (0,1)
      expect(b.sublist(17 * 4, 17 * 4 + 4), [255, 255, 255, 0xFF]); // (8,1)
    });

    test('gradient un-filter inverts the reference prediction', () async {
      // Build a 5x3 RGB image, filter it exactly as TightVNC does, feed the
      // residuals inline (< 12 bytes is impossible here: 45 B) — so wrap them
      // in the no-zlib sub-encoding (0xE = explicit filter, uncompressed).
      const w = 5, h = 3;
      final rgb = Uint8List(w * h * 3);
      for (var i = 0; i < rgb.length; i++) {
        rgb[i] = (i * 37 + 11) & 0xFF;
      }
      final residuals = Uint8List(rgb.length);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          final i = (y * w + x) * 3;
          for (var c = 0; c < 3; c++) {
            int p;
            if (y == 0) {
              p = x == 0 ? 0 : rgb[i - 3 + c];
            } else if (x == 0) {
              p = rgb[i - w * 3 + c];
            } else {
              p = (rgb[i - 3 + c] + rgb[i - w * 3 + c] - rgb[i - w * 3 - 3 + c])
                  .clamp(0, 255);
            }
            residuals[i + c] = (rgb[i + c] - p) & 0xFF;
          }
        }
      }
      final bytes = <int>[0xE0, 2, residuals.length, ...residuals];
      final decoder = TightDecoder();
      final src = BytesTightByteSource(Uint8List.fromList(bytes));
      final px = await decoder.readRect(source: src, width: w, height: h);
      final b = px.buffer.asUint8List(px.offsetInBytes, px.lengthInBytes);
      expect(src.remaining, 0);
      for (var i = 0; i < w * h; i++) {
        expect(b.sublist(i * 4, i * 4 + 3),
            [rgb[i * 3 + 2], rgb[i * 3 + 1], rgb[i * 3]]);
      }
    });

    test('reset bits drop a stream so a fresh zlib header is accepted',
        () async {
      // Two rects on stream 0, the second starts a NEW zlib stream (has its
      // own header) and sets reset bit 0 — must decode. Without honouring
      // the reset the continuation would be a corrupt-stream error.
      final decoder = TightDecoder();
      Uint8List zlib(List<int> plain) => Uint8List.fromList(
          ZLibCodec(level: 6).encode(plain));
      final plainA = List<int>.generate(30, (i) => i);
      final plainB = List<int>.generate(30, (i) => 100 + i);
      final za = zlib(plainA);
      final zb = zlib(plainB);
      // 10x1 copy rect = 30 filtered bytes >= 12 -> compact length + zlib.
      final rectA = <int>[0x00, za.length, ...za];
      final rectB = <int>[0x01, zb.length, ...zb]; // bit 0 = reset stream 0
      final a = BytesTightByteSource(Uint8List.fromList(rectA));
      final pa = await decoder.readRect(source: a, width: 10, height: 1);
      expect(pa.getUint8(2), 0); // R of pixel 0
      final b = BytesTightByteSource(Uint8List.fromList(rectB));
      final pb = await decoder.readRect(source: b, width: 10, height: 1);
      expect(pb.getUint8(2), 100);
      expect(a.remaining + b.remaining, 0);
    });

    test('an absurd rect size is rejected before any allocation', () async {
      // w/h come off the wire as uint16; a corrupt header must not be able
      // to force a multi-hundred-MB buffer.
      final decoder = TightDecoder();
      final src = BytesTightByteSource(Uint8List.fromList([0x80, 1, 2, 3]));
      expect(
        () => decoder.readRect(source: src, width: 2048, height: 65535),
        throwsA(isA<StateError>()),
      );
      expect(
        () => decoder.readRect(source: src, width: 4096, height: 1),
        throwsA(isA<StateError>()),
      );
      expect(src.remaining, 4); // nothing consumed
    });

    test('a JPEG whose header disagrees with the rect is rejected', () async {
      // Real 2x2 baseline JPEG (from the fixtures' server, cropped) would be
      // ideal; a hand-rolled minimal JPEG is fragile, so use package:image
      // to make one and claim a different rect size.
      final decoder = TightDecoder();
      final tiny = _encodeTinyJpeg();
      final body = <int>[0x90, tiny.length, ...tiny];
      final src = BytesTightByteSource(Uint8List.fromList(body));
      expect(
        () => decoder.readRect(source: src, width: 64, height: 64),
        throwsA(isA<StateError>()),
      );
    });

    test('a zlib bomb is cut off at the expected size, not buffered', () async {
      // 4x1 copy rect = 12 filtered bytes (>= 12 -> zlib path), but the
      // stream inflates to 200 KiB. Must throw as soon as it overshoots.
      final decoder = TightDecoder();
      final bomb = ZLibCodec(level: 9).encode(List<int>.filled(200 * 1024, 0));
      final body = <int>[0x00, 0x80 | (bomb.length & 0x7F), bomb.length >> 7, ...bomb];
      final src = BytesTightByteSource(Uint8List.fromList(body));
      expect(
        () => decoder.readRect(source: src, width: 4, height: 1),
        throwsA(isA<StateError>()),
      );
    });

    test('a 1-colour palette is rejected', () async {
      final decoder = TightDecoder();
      final src = BytesTightByteSource(
          Uint8List.fromList([0x40, 1, 0, 9, 9, 9, 0x00]));
      expect(
        () => decoder.readRect(source: src, width: 8, height: 1),
        throwsA(isA<StateError>()),
      );
    });

    test('a zlib stream that yields too little is a protocol error', () async {
      // 8x1 copy = 24 filtered bytes, but the stream only holds 12.
      final decoder = TightDecoder();
      final z = ZLibCodec(level: 6).encode(List<int>.filled(12, 7));
      final src = BytesTightByteSource(Uint8List.fromList([0x00, z.length, ...z]));
      expect(
        () => decoder.readRect(source: src, width: 8, height: 1),
        throwsA(isA<StateError>()),
      );
    });

    test('the area cap is inclusive at exactly 4 Mpx', () async {
      // Boundary: 2048x2048 (4,194,304 px = the cap) is allowed, one row more
      // is not.
      final decoder = TightDecoder();
      final ok = BytesTightByteSource(Uint8List.fromList([0x80, 1, 2, 3]));
      final px = await decoder.readRect(source: ok, width: 2048, height: 2048);
      expect(px.lengthInBytes, 2048 * 2048 * 4);
      final bad = BytesTightByteSource(Uint8List.fromList([0x80, 1, 2, 3]));
      expect(
        () => decoder.readRect(source: bad, width: 2048, height: 2049),
        throwsA(isA<StateError>()),
      );
    });

    test('a truncated rect fails loudly instead of desyncing', () async {
      final decoder = TightDecoder();
      final src = BytesTightByteSource(Uint8List.fromList([0x90, 0x05, 1, 2]));
      expect(
        () => decoder.readRect(source: src, width: 4, height: 4),
        throwsA(isA<StateError>()),
      );
    });
  });
}
