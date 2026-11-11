// lib/utils/image_token_estimator.dart
//
// How many prompt tokens one image costs, per model family, from its pixel
// size. Used by the context estimate (TokenEstimator). The provider's own
// usage count is always the real number; this only has to be close.
//
// - DeepSeek: the published calculator (14 px patches, 3:1 downsampling to a
//   42 px cell, `gridH * (gridW + 1) + 2` tokens, at most 1024 per image,
//   small images scaled up to 544x544 pixels first). Ported from
//   deepseek-harness `llm-deepseek/src/image-tokens.ts`.
// - Anthropic: `width * height / 750`, after scaling the long edge to 1568
//   px (about 1600 tokens at most).
// - OpenAI and the rest: 512 px tiles. Fit into 2048x2048, short edge to
//   768, then 85 + 170 per tile.

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

/// Tokens of an image whose size is not known.
const int kUnknownImageTokens = 1000;

/// The model family that decides the image formula.
enum ImageTokenFamily { deepseek, anthropic, openai }

class ImageTokenEstimator {
  const ImageTokenEstimator._();

  /// The family of [modelId] (`vendor/model`). Unknown vendors use the
  /// tile formula, which most OpenAI-compatible vision models follow.
  static ImageTokenFamily familyOf(String? modelId) {
    final id = (modelId ?? '').toLowerCase();
    if (id.contains('deepseek')) return ImageTokenFamily.deepseek;
    if (id.startsWith('anthropic/') || id.contains('claude')) {
      return ImageTokenFamily.anthropic;
    }
    return ImageTokenFamily.openai;
  }

  /// Tokens one [width] x [height] image costs on [modelId]. Falls back to
  /// [kUnknownImageTokens] when the size is unknown or not positive.
  static int tokensFor(String? modelId, int? width, int? height) {
    if (width == null || height == null || width <= 0 || height <= 0) {
      return kUnknownImageTokens;
    }
    switch (familyOf(modelId)) {
      case ImageTokenFamily.deepseek:
        return deepSeekImageTokens(width, height);
      case ImageTokenFamily.anthropic:
        return anthropicImageTokens(width, height);
      case ImageTokenFamily.openai:
        return openAiImageTokens(width, height);
    }
  }

  // ── Anthropic ──────────────────────────────────────────────────────

  /// `w * h / 750` after the long edge is scaled down to 1568 px.
  static int anthropicImageTokens(int width, int height) {
    var w = width.toDouble();
    var h = height.toDouble();
    final longEdge = math.max(w, h);
    if (longEdge > 1568) {
      final scale = 1568 / longEdge;
      w *= scale;
      h *= scale;
    }
    return math.max(1, (w * h / 750).ceil());
  }

  // ── OpenAI (512 px tiles, high detail) ─────────────────────────────

  static int openAiImageTokens(int width, int height) {
    var w = width.toDouble();
    var h = height.toDouble();
    final fit = math.min(1.0, 2048 / math.max(w, h));
    w *= fit;
    h *= fit;
    final shortEdge = math.min(w, h);
    if (shortEdge > 768) {
      final scale = 768 / shortEdge;
      w *= scale;
      h *= scale;
    }
    final tiles = (w / 512).ceil() * (h / 512).ceil();
    return 85 + 170 * tiles;
  }

  // ── DeepSeek ───────────────────────────────────────────────────────

  static const int _patch = 14;
  static const int _downsample = 3;
  static const int _maxTokens = 1024;
  static const int _minPixels = 544 * 544;
  static const int _cell = _patch * _downsample;

  static int _ceilDiv(int value, int divisor) =>
      (value + divisor - 1) ~/ divisor;

  static int _gridTokens(int gridH, int gridW) => gridH * (gridW + 1) + 2;

  static int _gridCells(int padded) => _ceilDiv(padded ~/ _patch, _downsample);

  static _Grid _solve(int height, int width, int budget) {
    final aspect = height / width;
    final idealW = math.sqrt((budget - 2) / aspect + 0.25) - 0.5;
    final idealH = idealW * aspect;
    int bestH;
    int bestW;
    if (idealW < 1) {
      bestW = _cell;
      bestH = ((budget - 2) ~/ 2) * _cell;
    } else if (idealH < 1) {
      bestW = ((budget - 2) - 1) * _cell;
      bestH = _cell;
    } else {
      final solvedW = idealW.truncate();
      final solvedH = idealH.truncate();
      final scale = math.min(solvedW * _cell / width, solvedH * _cell / height);
      bestW = (width * scale / _patch).truncate() * _patch;
      bestH = (height * scale / _patch).truncate() * _patch;
    }
    final gridH = _gridCells(bestH);
    final gridW = _gridCells(bestW);
    return _Grid(gridH, gridW, bestH, bestW, _gridTokens(gridH, gridW));
  }

  static _Grid _resizeOnce(int width, int height) {
    var w = width;
    var h = height;
    final pixels = w * h;
    if (pixels < _minPixels && pixels > 0) {
      final scale = math.sqrt(_minPixels / pixels);
      w = (w * scale).truncate();
      h = (h * scale).truncate();
    }
    final paddedW = _ceilDiv(w, _patch) * _patch;
    final paddedH = _ceilDiv(h, _patch) * _patch;
    final gridH = _gridCells(paddedH);
    final gridW = _gridCells(paddedW);
    final direct = _Grid(
      gridH,
      gridW,
      paddedH,
      paddedW,
      _gridTokens(gridH, gridW),
    );
    if (direct.tokens <= _maxTokens) return direct;
    return _solve(h, w, _maxTokens);
  }

  /// DeepSeek's vision tokens for one image, at most 1024.
  static int deepSeekImageTokens(int width, int height) {
    var result = _resizeOnce(width, height);
    for (var i = 1; i < 10; i++) {
      final next = _resizeOnce(result.width, result.height);
      if (next == result) return result.tokens;
      result = next;
    }
    return result.tokens;
  }

  // ── Image size from the bytes ──────────────────────────────────────

  /// Width and height of a PNG, JPEG, GIF or WebP from its header, or null.
  static (int, int)? dimensionsOf(Uint8List bytes) {
    try {
      return _dimensions(bytes);
    } on RangeError {
      return null;
    }
  }

  /// [dimensionsOf] for a `data:image/...;base64,` URL. Only the head of
  /// the data is decoded (JPEG may need more; it reads up to 256 KB).
  static (int, int)? dimensionsOfDataUrl(String url) {
    if (!url.startsWith('data:')) return null;
    final comma = url.indexOf(',');
    if (comma < 0) return null;
    final data = url.substring(comma + 1);
    var take = math.min(data.length, 349528); // 256 KiB of bytes
    take -= take % 4;
    if (take <= 0) return null;
    try {
      return dimensionsOf(base64Decode(data.substring(0, take)));
    } on FormatException {
      return null;
    }
  }

  static (int, int)? _dimensions(Uint8List b) {
    if (b.length < 24) return null;
    // PNG: IHDR width/height big-endian at 16..23.
    if (b[0] == 0x89 && b[1] == 0x50 && b[2] == 0x4E && b[3] == 0x47) {
      return (_be32(b, 16), _be32(b, 20));
    }
    // GIF: logical screen size little-endian at 6..9.
    if (b[0] == 0x47 && b[1] == 0x49 && b[2] == 0x46) {
      return (b[6] | (b[7] << 8), b[8] | (b[9] << 8));
    }
    // WebP: RIFF....WEBP + VP8 / VP8L / VP8X chunk.
    if (b[0] == 0x52 &&
        b[1] == 0x49 &&
        b[2] == 0x46 &&
        b[3] == 0x46 &&
        b[8] == 0x57 &&
        b[9] == 0x45 &&
        b[10] == 0x42 &&
        b[11] == 0x50) {
      final chunk = String.fromCharCodes(b.sublist(12, 16));
      if (chunk == 'VP8X') {
        final w = 1 + (b[24] | (b[25] << 8) | (b[26] << 16));
        final h = 1 + (b[27] | (b[28] << 8) | (b[29] << 16));
        return (w, h);
      }
      if (chunk == 'VP8L') {
        final bits = b[21] | (b[22] << 8) | (b[23] << 16) | (b[24] << 24);
        return (1 + (bits & 0x3FFF), 1 + ((bits >> 14) & 0x3FFF));
      }
      if (chunk == 'VP8 ') {
        final w = (b[26] | (b[27] << 8)) & 0x3FFF;
        final h = (b[28] | (b[29] << 8)) & 0x3FFF;
        return (w, h);
      }
      return null;
    }
    // JPEG: walk the segments to the first SOFn.
    if (b[0] == 0xFF && b[1] == 0xD8) {
      var i = 2;
      while (i + 9 < b.length) {
        if (b[i] != 0xFF) {
          i++;
          continue;
        }
        final marker = b[i + 1];
        if (marker == 0xFF) {
          i++;
          continue;
        }
        final isSof =
            marker >= 0xC0 &&
            marker <= 0xCF &&
            marker != 0xC4 &&
            marker != 0xC8 &&
            marker != 0xCC;
        if (isSof) {
          final h = (b[i + 5] << 8) | b[i + 6];
          final w = (b[i + 7] << 8) | b[i + 8];
          return (w, h);
        }
        final length = (b[i + 2] << 8) | b[i + 3];
        if (length < 2) return null;
        i += 2 + length;
      }
    }
    return null;
  }

  static int _be32(Uint8List b, int o) =>
      (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];
}

class _Grid {
  const _Grid(this.gridH, this.gridW, this.height, this.width, this.tokens);
  final int gridH;
  final int gridW;
  final int height;
  final int width;
  final int tokens;

  @override
  bool operator ==(Object other) =>
      other is _Grid &&
      other.gridH == gridH &&
      other.gridW == gridW &&
      other.height == height &&
      other.width == width &&
      other.tokens == tokens;

  @override
  int get hashCode => Object.hash(gridH, gridW, height, width, tokens);
}
