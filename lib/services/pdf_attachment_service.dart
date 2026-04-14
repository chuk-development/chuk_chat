// lib/services/pdf_attachment_service.dart
//
// Uploads and downloads encrypted PDF bytes (or any binary artifact
// attachment) to Supabase Storage. Bytes are AES-encrypted client-side
// so the server only ever sees ciphertext — same trust model as chat
// messages and images.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/utils/lru_byte_cache.dart';

String _utf8DecodeInBackground(Uint8List bytes) => utf8.decode(bytes);

class PdfAttachmentService {
  const PdfAttachmentService._();

  /// We reuse the `images` bucket for artifact attachments — the bucket
  /// is already created, RLS'd per-user, and just stores encrypted
  /// opaque bytes. No point splitting storage for the same trust model.
  static const String bucketName = 'images';
  static const Uuid _uuid = Uuid();

  static const int _maxCacheSizeBytes = 50 * 1024 * 1024;
  static final LruByteCache _cache =
      LruByteCache(maxSizeBytes: _maxCacheSizeBytes);
  static final Map<String, Future<Uint8List>> _pending = {};

  static Uint8List? getCached(String path) => _cache.get(path);
  static void clearFromCache(String path) => _cache.remove(path);
  static void clearCache() => _cache.clear();

  /// Encrypts the given bytes with the active encryption key and uploads
  /// them to Supabase Storage. Returns the storage path (relative to the
  /// bucket) which must be persisted alongside the artifact row.
  static Future<String> upload(Uint8List bytes) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw Exception('User must be authenticated to upload attachments');
    }
    if (!EncryptionService.hasKey) {
      throw Exception('Encryption key not available');
    }

    final encryptedJson = await EncryptionService.encryptBytes(bytes);
    final encryptedBytes = Uint8List.fromList(utf8.encode(encryptedJson));

    // The `images` bucket has an image/* MIME allow-list. Our payload is
    // ciphertext, so we just advertise image/png — the bytes on disk are
    // opaque either way. Extension stays `.enc` so the file is obviously
    // encrypted, not an actual image.
    final path = '${user.id}/${_uuid.v4()}.enc';

    try {
      await SupabaseService.client.storage.from(bucketName).uploadBinary(
            path,
            encryptedBytes,
            fileOptions: const FileOptions(
              contentType: 'image/png',
              upsert: false,
            ),
          );
    } catch (e) {
      if (kDebugMode) {
        debugPrint('PdfAttachmentService upload failed: $e');
      }
      rethrow;
    }

    _cache.put(path, bytes);
    return path;
  }

  /// Downloads and decrypts the attachment at the given storage path.
  /// Deduplicates concurrent requests and caches successful results.
  static Future<Uint8List> download(
    String path, {
    bool bypassCache = false,
  }) async {
    if (!bypassCache) {
      final cached = _cache.get(path);
      if (cached != null) return cached;
    }

    final inflight = _pending[path];
    if (inflight != null && !bypassCache) return inflight;

    final future = _downloadInternal(path);
    _pending[path] = future;
    try {
      return await future;
    } finally {
      _pending.remove(path);
    }
  }

  static Future<Uint8List> _downloadInternal(String path) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw Exception('User must be authenticated to download attachments');
    }
    if (!EncryptionService.hasKey) {
      throw Exception('Encryption key not available');
    }

    try {
      final encryptedBytes =
          await SupabaseService.client.storage.from(bucketName).download(path);
      final encryptedJson =
          await compute(_utf8DecodeInBackground, encryptedBytes);
      final decrypted = await EncryptionService.decryptBytes(encryptedJson);
      _cache.put(path, decrypted);
      return decrypted;
    } catch (e) {
      _cache.remove(path);
      rethrow;
    }
  }

  /// Best-effort cleanup. Ignores errors — the storage row may already
  /// have been removed out-of-band.
  static Future<void> delete(String path) async {
    try {
      await SupabaseService.client.storage.from(bucketName).remove([path]);
    } catch (_) {
      // ignore
    }
    _cache.remove(path);
  }
}
