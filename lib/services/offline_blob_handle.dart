// lib/services/offline_blob_handle.dart
//
// [OfflineBlobStore] as an object, so a test can put an in-memory store in
// its place. Used by the voice spool and the offline image store on web.
import 'dart:typed_data';

import 'package:chuk_chat/services/offline_blob_store.dart';

class OfflineBlobHandle {
  const OfflineBlobHandle();

  bool get isSupported => OfflineBlobStore.isSupported;
  Future<void> put(String key, Uint8List bytes) =>
      OfflineBlobStore.put(key, bytes);
  Future<Uint8List?> get(String key) => OfflineBlobStore.get(key);
  Future<bool> exists(String key) => OfflineBlobStore.exists(key);
  Future<void> delete(String key) => OfflineBlobStore.delete(key);
  Future<void> deletePrefix(String prefix) =>
      OfflineBlobStore.deletePrefix(prefix);
  Future<List<({String key, DateTime modified})>> list(String prefix) =>
      OfflineBlobStore.list(prefix);
}
