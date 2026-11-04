// lib/services/offline_blob_store_stub.dart
//
// Native platforms keep outbox files on disk; this store is web only.
import 'dart:typed_data';

abstract final class OfflineBlobStore {
  static bool get isSupported => false;

  static Future<void> put(String key, Uint8List bytes) async =>
      throw UnsupportedError('OfflineBlobStore is web only');

  static Future<Uint8List?> get(String key) async => null;

  static Future<bool> exists(String key) async => false;

  static Future<void> delete(String key) async {}

  static Future<void> deletePrefix(String prefix) async {}

  static Future<List<({String key, DateTime modified})>> list(
    String prefix,
  ) async => const [];
}
