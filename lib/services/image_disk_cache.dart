// lib/services/image_disk_cache.dart
//
// Decrypted images and their small thumbnails, kept on disk in the app's
// private support directory (never the gallery). Before this, the only cache
// was a 50 MB in-memory LRU: every app start, and every media manager open
// past 50 MB, downloaded, decrypted and decoded each picture in full again.
//
// Why plaintext: the chat cache already stores payloads in plaintext SQLite
// for the same reason - the key lives on the same device, so local encryption
// would be theater (see CLAUDE.md, "Local Cache Architecture").
//
// Layout: `<support>/image_cache/<hash>.img` (full picture) and
// `<hash>.thumb` (longest side [thumbMaxSide]). The hash is the SHA-256 of the
// bucket path, so names leak nothing about the path. Web has no file system:
// every call is a no-op there.
import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import 'package:chuk_chat/utils/io_helper.dart' show Directory, File;
import 'package:chuk_chat/utils/path_provider_stub.dart'
    if (dart.library.io) 'package:path_provider/path_provider.dart';

class ImageDiskCache {
  const ImageDiskCache._();

  /// Longest side of a stored thumbnail. The media grid draws tiles of about
  /// 200 logical pixels; 512 keeps them sharp on a 2x screen.
  static const int thumbMaxSide = 512;

  /// Upper bound for the whole cache. Above it, the oldest files go first.
  static const int maxBytes = 1024 * 1024 * 1024; // 1 GB

  /// Test hook: a directory to use instead of the app support directory.
  @visibleForTesting
  static Directory? debugRootOverride;

  static Future<Directory?>? _dirFuture;

  static Future<Directory?> _dir() {
    final Directory? override = debugRootOverride;
    if (override != null) return Future<Directory?>.value(override);
    if (kIsWeb) return Future<Directory?>.value(null);
    return _dirFuture ??= _openDir();
  }

  static Future<Directory?> _openDir() async {
    try {
      final support = await getApplicationSupportDirectory();
      final dir = Directory('${support.path}/image_cache');
      if (!await dir.exists()) await dir.create(recursive: true);
      unawaited(_prune(dir));
      return dir;
    } catch (_) {
      _dirFuture = null;
      return null;
    }
  }

  @visibleForTesting
  static void debugReset() {
    _dirFuture = null;
  }

  static String _key(String storagePath) =>
      sha256.convert(utf8.encode(storagePath)).toString();

  static Future<File?> _file(String storagePath, String ext) async {
    final dir = await _dir();
    if (dir == null) return null;
    return File('${dir.path}/${_key(storagePath)}.$ext');
  }

  static Future<Uint8List?> _read(String storagePath, String ext) async {
    try {
      final file = await _file(storagePath, ext);
      if (file == null || !await file.exists()) return null;
      final bytes = await file.readAsBytes();
      return bytes.isEmpty ? null : bytes;
    } catch (_) {
      return null;
    }
  }

  static Future<void> _write(
    String storagePath,
    String ext,
    Uint8List bytes,
  ) async {
    try {
      final file = await _file(storagePath, ext);
      if (file == null) return;
      // Write to a side file and rename, so a crash mid-write never leaves a
      // truncated picture that later reads as valid.
      final tmp = File('${file.path}.part');
      await tmp.writeAsBytes(bytes, flush: true);
      await tmp.rename(file.path);
    } catch (e) {
      if (kDebugMode) debugPrint('[ImageDiskCache] write failed: $e');
    }
  }

  /// The decrypted picture for [storagePath], or null when not on disk.
  static Future<Uint8List?> read(String storagePath) =>
      _read(storagePath, 'img');

  /// Stores the decrypted picture for [storagePath].
  static Future<void> write(String storagePath, Uint8List bytes) =>
      _write(storagePath, 'img', bytes);

  /// The stored thumbnail for [storagePath], or null.
  static Future<Uint8List?> readThumb(String storagePath) =>
      _read(storagePath, 'thumb');

  /// Stores a thumbnail for [storagePath].
  static Future<void> writeThumb(String storagePath, Uint8List bytes) =>
      _write(storagePath, 'thumb', bytes);

  /// What is known about where [storagePath] came from (see
  /// MediaProvenanceService), or null when it was not worked out yet.
  static Future<Map<String, dynamic>?> readMeta(String storagePath) async {
    final Uint8List? bytes = await _read(storagePath, 'meta');
    if (bytes == null) return null;
    try {
      final Object? decoded = jsonDecode(utf8.decode(bytes));
      return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
    } catch (_) {
      return null;
    }
  }

  /// Stores the provenance record for [storagePath].
  static Future<void> writeMeta(
    String storagePath,
    Map<String, dynamic> meta,
  ) => _write(
    storagePath,
    'meta',
    Uint8List.fromList(utf8.encode(jsonEncode(meta))),
  );

  /// Records that [storagePath] holds a PDF, not a picture. Old uploads gave
  /// files the same `.enc` ending as images, so the bucket listing cannot tell
  /// them apart; only the decrypted bytes can, once. The mark lets the media
  /// manager sort the file under Pages on every later open without loading it.
  static Future<void> markPdf(String storagePath) =>
      _write(storagePath, 'pdf', Uint8List.fromList(const <int>[1]));

  /// Whether [storagePath] was found to be a PDF earlier.
  static Future<bool> isPdf(String storagePath) async =>
      await _read(storagePath, 'pdf') != null;

  /// Removes the picture and its thumbnail, e.g. after the image was deleted.
  static Future<void> remove(String storagePath) async {
    for (final ext in const ['img', 'thumb', 'pdf', 'meta']) {
      try {
        final file = await _file(storagePath, ext);
        if (file != null && await file.exists()) await file.delete();
      } catch (_) {}
    }
  }

  /// Shrinks [bytes] so the longest side is at most [maxSide], off the UI
  /// isolate. Returns null when [bytes] are not a picture the `image` package
  /// can decode. Pictures already small enough come back unchanged.
  static Future<Uint8List?> makeThumbnail(
    Uint8List bytes, {
    int maxSide = thumbMaxSide,
  }) => compute(_makeThumbnailSync, _ThumbJob(bytes, maxSide));

  /// Deletes the oldest files while the cache is larger than [limit].
  @visibleForTesting
  static Future<void> pruneForTest(Directory dir, int limit) =>
      _prune(dir, limit: limit);

  static Future<void> _prune(Directory dir, {int limit = maxBytes}) async {
    try {
      final entries = <({File file, int size, DateTime modified})>[];
      int total = 0;
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final int size = await entity.length();
        final DateTime modified = await entity.lastModified();
        entries.add((file: entity, size: size, modified: modified));
        total += size;
      }
      if (total <= limit) return;
      entries.sort((a, b) => a.modified.compareTo(b.modified));
      for (final entry in entries) {
        if (total <= limit) break;
        try {
          await entry.file.delete();
          total -= entry.size;
        } catch (_) {}
      }
    } catch (_) {}
  }
}

class _ThumbJob {
  final Uint8List bytes;
  final int maxSide;
  const _ThumbJob(this.bytes, this.maxSide);
}

Uint8List? _makeThumbnailSync(_ThumbJob job) {
  final img.Image? decoded = img.decodeImage(job.bytes);
  if (decoded == null) return null;
  final int longest = decoded.width > decoded.height
      ? decoded.width
      : decoded.height;
  if (longest <= job.maxSide) return job.bytes;
  final img.Image resized = decoded.width >= decoded.height
      ? img.copyResize(
          decoded,
          width: job.maxSide,
          interpolation: img.Interpolation.average,
        )
      : img.copyResize(
          decoded,
          height: job.maxSide,
          interpolation: img.Interpolation.average,
        );
  // JPEG is a fraction of PNG's size, but drops transparency (a transparent
  // logo would turn black). Keep PNG for pictures with an alpha channel.
  if (resized.hasAlpha) return img.encodePng(resized, level: 6);
  return img.encodeJpg(resized, quality: 85);
}
