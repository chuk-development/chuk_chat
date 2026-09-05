import 'dart:io';
import 'dart:typed_data';

import 'package:dart_rfb/src/extensions/raw_socket_extensions.dart';
import 'package:fpdart/fpdart.dart';
import 'package:image/image.dart' as img;

/// Where a Tight rectangle's bytes come from: the live socket, or a byte
/// array in tests. Reads exactly [n] bytes or throws.
abstract class TightByteSource {
  Future<Uint8List> read(final int n);
}

/// Live source: the RFB socket. Same busy-poll read the raw path uses.
class RawSocketTightByteSource implements TightByteSource {
  RawSocketTightByteSource(this._socket);

  final RawSocket _socket;

  @override
  Future<Uint8List> read(final int n) async {
    if (n == 0) {
      return Uint8List(0);
    }
    final ByteData data = await _socket
        .readSync(length: n, readWaitDuration: const None<Duration>())
        .run();
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }
}

/// In-memory source for tests and vectors captured from a real server.
class BytesTightByteSource implements TightByteSource {
  BytesTightByteSource(this._data);

  final Uint8List _data;
  int _pos = 0;

  /// Bytes not yet consumed — a decoder that delimits correctly leaves 0.
  int get remaining => _data.length - _pos;

  @override
  Future<Uint8List> read(final int n) async {
    if (_pos + n > _data.length) {
      throw StateError(
        'tight: read past end ($n wanted, $remaining left)',
      );
    }
    final Uint8List out = Uint8List.sublistView(_data, _pos, _pos + n);
    _pos += n;
    return out;
  }
}

/// Decoder for the RFB "Tight" encoding (id 7) — the TightVNC extension that
/// x11vnc, TigerVNC and noVNC all speak. Output is always a `width*height*4`
/// bgra8888 buffer (`[B,G,R,0xFF]` per pixel), the layout the framebuffer and
/// `decodeImageFromPixels(PixelFormat.bgra8888)` consume, so a Tight rectangle
/// can be handed on as if it were `raw`.
///
/// Wire format per rectangle (pixel format 32 bpp / depth 24 / 8-bit maxes, so
/// a TPIXEL is 3 bytes in R,G,B order — libvncserver `Pack24`):
///
///   control byte
///     bits 0-3 : reset zlib stream i (applied BEFORE this rect's data)
///     bits 4-7 : 0x8 = fill (one TPIXEL), 0x9 = JPEG (compact len + data),
///                0x0-0x7 = basic: bits 4-5 = zlib stream id, bit 6 = an
///                explicit filter-id byte follows (else filter = copy)
///   basic filters: 0 copy (w*h TPIXELs), 1 palette (numColors-1, palette,
///                then 1 bit/px MSB-first row-padded if <=2 colours else
///                1 byte/px), 2 gradient (w*h TPIXEL residuals)
///   basic payload: if the filtered size < 12 it is inline and uncompressed,
///                otherwise compact len + zlib data continuing stream id
///
/// The four zlib streams persist for the whole connection (each rect appends
/// to one; a header appears only after a reset). The server sync-flushes, so
/// one rect's compressed bytes inflate to exactly its filtered size. That is
/// why this uses `RawZLibFilter` with `processed(flush: true, end: false)`:
/// the chunked `ZLibDecoder` sink does NOT hand output back synchronously
/// (verified), and a persistent stream can never be `close()`d.
class TightDecoder {
  static const int _fill = 8;
  static const int _jpeg = 9;
  // "Basic without zlib" (rfbTightNoZlib): libvncserver emits this for
  // compression level 0 without checking that the client advertised the
  // -317 pseudo-encoding. We never advertise a level, so it should not
  // arrive — but decode it anyway rather than desync (libvncclient does too).
  static const int _noZlib = 0xA;
  static const int _noZlibExplicitFilter = 0xE;

  /// libvncserver splits wider rects itself (TIGHT_MAX_RECT_WIDTH); anything
  /// above is corrupt input, not a real rectangle.
  static const int _maxRectWidth = 2048;

  /// Hard ceiling on pixels per rectangle. libvncserver never sends more than
  /// 65536 px per Tight rect; the caller also checks the rect against the
  /// negotiated framebuffer. Both together mean a corrupt header can never
  /// force a huge allocation before a single payload byte is validated.
  static const int _maxRectPixels = 4 * 1024 * 1024;

  static const int _filterCopy = 0;
  static const int _filterPalette = 1;
  static const int _filterGradient = 2;

  /// Below this many filtered bytes the payload is sent inline, uncompressed.
  static const int _minZlibSize = 12;

  final List<RawZLibFilter?> _streams = List<RawZLibFilter?>.filled(4, null);

  /// Drop every zlib stream — call on (re)connect so no stale state carries
  /// over into a new session.
  void resetAll() {
    for (int i = 0; i < _streams.length; i++) {
      _streams[i] = null;
    }
  }

  /// Read and decode one Tight rectangle of [width] x [height] from [source].
  Future<ByteData> readRect({
    required final TightByteSource source,
    required final int width,
    required final int height,
  }) async {
    if (width > _maxRectWidth) {
      throw StateError('tight: rect width $width exceeds $_maxRectWidth');
    }
    if (width * height > _maxRectPixels) {
      throw StateError(
        'tight: rect ${width}x$height exceeds $_maxRectPixels pixels',
      );
    }
    final int control = (await source.read(1))[0];
    for (int i = 0; i < 4; i++) {
      if (control & (1 << i) != 0) {
        _streams[i] = null;
      }
    }
    final int kind = control >> 4;
    final Uint8List out = Uint8List(width * height * 4);

    if (kind == _fill) {
      final Uint8List p = await source.read(3);
      for (int i = 0; i < out.length; i += 4) {
        out[i] = p[2]; // B
        out[i + 1] = p[1]; // G
        out[i + 2] = p[0]; // R
        out[i + 3] = 0xFF;
      }
      return ByteData.sublistView(out);
    }

    if (kind == _jpeg) {
      final int n = await _readCompactLength(source);
      final Uint8List jpeg = await source.read(n);
      _decodeJpegInto(jpeg, out, width, height);
      return ByteData.sublistView(out);
    }

    final bool noZlib = kind == _noZlib || kind == _noZlibExplicitFilter;
    if (kind > _jpeg && !noZlib) {
      throw StateError('tight: unsupported sub-encoding $kind');
    }

    // Basic compression.
    final int streamId = (control >> 4) & 0x03;
    int filter = _filterCopy;
    if (control & 0x40 != 0) {
      filter = (await source.read(1))[0];
    }

    Uint8List? palette;
    int paletteSize = 0;
    final int filteredSize;
    if (filter == _filterPalette) {
      paletteSize = (await source.read(1))[0] + 1;
      if (paletteSize < 2) {
        // A 1-colour palette is never emitted (servers send a fill); on the
        // 1-bit path a set bit would index past the palette.
        throw StateError('tight: palette with a single colour');
      }
      palette = await source.read(paletteSize * 3);
      final int rowBytes = paletteSize == 2 ? (width + 7) ~/ 8 : width;
      filteredSize = rowBytes * height;
    } else if (filter == _filterCopy || filter == _filterGradient) {
      filteredSize = width * height * 3;
    } else {
      throw StateError('tight: unknown filter $filter');
    }

    final Uint8List data;
    if (filteredSize < _minZlibSize) {
      data = await source.read(filteredSize);
    } else if (noZlib) {
      final int n = await _readCompactLength(source);
      if (n != filteredSize) {
        throw StateError(
          'tight: no-zlib payload is $n bytes, expected $filteredSize',
        );
      }
      data = await source.read(n);
    } else {
      final int n = await _readCompactLength(source);
      data = _inflate(streamId, await source.read(n), filteredSize);
    }

    switch (filter) {
      case _filterCopy:
        _copyInto(data, out);
        break;
      case _filterPalette:
        _paletteInto(data, out, palette!, paletteSize, width, height);
        break;
      case _filterGradient:
        _gradientInto(data, out, width, height);
        break;
    }
    return ByteData.sublistView(out);
  }

  /// Tight's 1-3 byte length: 7 bits per byte, low group first, high bit
  /// means another byte follows.
  Future<int> _readCompactLength(final TightByteSource source) async {
    int b = (await source.read(1))[0];
    int value = b & 0x7F;
    if (b & 0x80 != 0) {
      b = (await source.read(1))[0];
      value |= (b & 0x7F) << 7;
      if (b & 0x80 != 0) {
        b = (await source.read(1))[0];
        value |= b << 14;
      }
    }
    return value;
  }

  /// Inflate [compressed] on persistent stream [id]; must yield exactly
  /// [expected] bytes (the server sync-flushes per rectangle).
  Uint8List _inflate(
    final int id,
    final Uint8List compressed,
    final int expected,
  ) {
    final RawZLibFilter filter =
        _streams[id] ??= RawZLibFilter.inflateFilter();
    filter.process(compressed, 0, compressed.length);
    final BytesBuilder builder = BytesBuilder(copy: false);
    List<int>? chunk;
    while ((chunk = filter.processed(flush: true, end: false)) != null) {
      builder.add(chunk!);
      // Decompression bomb guard: stop the moment the stream yields more
      // than the rect can hold, instead of buffering an unbounded expansion
      // and comparing afterwards.
      if (builder.length > expected) {
        throw StateError(
          'tight: stream $id inflated past the expected $expected bytes',
        );
      }
    }
    if (builder.length != expected) {
      throw StateError(
        'tight: stream $id inflated ${builder.length} bytes, '
        'expected $expected',
      );
    }
    return builder.takeBytes();
  }

  static void _copyInto(final Uint8List rgb, final Uint8List out) {
    int o = 0;
    for (int i = 0; i < rgb.length; i += 3) {
      out[o] = rgb[i + 2];
      out[o + 1] = rgb[i + 1];
      out[o + 2] = rgb[i];
      out[o + 3] = 0xFF;
      o += 4;
    }
  }

  static void _paletteInto(
    final Uint8List data,
    final Uint8List out,
    final Uint8List palette,
    final int paletteSize,
    final int width,
    final int height,
  ) {
    int o = 0;
    if (paletteSize == 2) {
      final int rowBytes = (width + 7) ~/ 8;
      for (int y = 0; y < height; y++) {
        final int rowStart = y * rowBytes;
        for (int x = 0; x < width; x++) {
          final int bit = (data[rowStart + (x >> 3)] >> (7 - (x & 7))) & 1;
          final int p = bit * 3;
          out[o] = palette[p + 2];
          out[o + 1] = palette[p + 1];
          out[o + 2] = palette[p];
          out[o + 3] = 0xFF;
          o += 4;
        }
      }
      return;
    }
    for (int i = 0; i < width * height; i++) {
      final int index = data[i];
      if (index >= paletteSize) {
        // The palette is server-controlled; never index past it.
        throw StateError(
          'tight: palette index $index out of range ($paletteSize colours)',
        );
      }
      final int p = index * 3;
      out[o] = palette[p + 2];
      out[o + 1] = palette[p + 1];
      out[o + 2] = palette[p];
      out[o + 3] = 0xFF;
      o += 4;
    }
  }

  /// Gradient un-filter (libvncserver FilterGradient24 / noVNC): each byte is
  /// a residual against a prediction from already-decoded neighbours. First
  /// row predicts from the left pixel only; later rows use left + up - upleft
  /// clamped to 0..255, and the first column uses the pixel above.
  static void _gradientInto(
    final Uint8List data,
    final Uint8List out,
    final int width,
    final int height,
  ) {
    // Work in RGB (3 bytes/px) then swizzle into BGRA.
    final Uint8List rgb = Uint8List(width * height * 3);
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final int i = (y * width + x) * 3;
        for (int c = 0; c < 3; c++) {
          int prediction;
          if (y == 0) {
            prediction = x == 0 ? 0 : rgb[i - 3 + c];
          } else if (x == 0) {
            prediction = rgb[i - width * 3 + c];
          } else {
            final int left = rgb[i - 3 + c];
            final int up = rgb[i - width * 3 + c];
            final int upLeft = rgb[i - width * 3 - 3 + c];
            prediction = (left + up - upLeft).clamp(0, 255);
          }
          rgb[i + c] = (data[i + c] + prediction) & 0xFF;
        }
      }
    }
    _copyInto(rgb, out);
  }

  static void _decodeJpegInto(
    final Uint8List jpeg,
    final Uint8List out,
    final int width,
    final int height,
  ) {
    // Check the JPEG's own header dimensions BEFORE decoding: the SOF size is
    // server-controlled and independent of the rect header, so a tiny payload
    // must not be able to amplify into a huge decode.
    final img.DecodeInfo? info = img.JpegDecoder().startDecode(jpeg);
    if (info == null) {
      throw StateError('tight: JPEG rectangle has no readable header');
    }
    if (info.width != width || info.height != height) {
      throw StateError(
        'tight: JPEG header is ${info.width}x${info.height}, '
        'rect is ${width}x$height',
      );
    }
    img.Image? decoded = img.decodeJpg(jpeg);
    if (decoded == null) {
      throw StateError('tight: JPEG rectangle failed to decode');
    }
    if (decoded.width != width || decoded.height != height) {
      throw StateError(
        'tight: JPEG is ${decoded.width}x${decoded.height}, '
        'rect is ${width}x$height',
      );
    }
    // libjpeg-turbo on the server always emits 3-channel colour, but stay
    // robust: normalise anything else to packed 8-bit RGB first.
    if (decoded.numChannels != 3 || decoded.format != img.Format.uint8) {
      decoded = decoded.convert(numChannels: 3, format: img.Format.uint8);
    }
    // Interleaved R,G,B, stride width*3 — swizzle straight into BGRA with
    // one pass and no intermediate 4-channel copy.
    final Uint8List rgb = decoded.toUint8List();
    if (rgb.length != width * height * 3) {
      throw StateError(
        'tight: JPEG produced ${rgb.length} bytes, need ${width * height * 3}',
      );
    }
    _copyInto(rgb, out);
  }
}
