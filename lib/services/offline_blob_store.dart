// lib/services/offline_blob_store.dart
//
// Byte storage for the outbox on web, where there is no file system: voice
// recordings and offline images (docs/OFFLINE_SEND.md, "Web"). IndexedDB on
// web; on native platforms [OfflineBlobStore.isSupported] is false and the
// callers use their files as before.
export 'offline_blob_store_stub.dart'
    if (dart.library.js_interop) 'offline_blob_store_web.dart';
