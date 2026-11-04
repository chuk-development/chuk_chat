// lib/services/image_storage_service.dart
// MERGE NOTE: upstream's Supabase bucket and the Agents local blob store both
// live here now. A path that starts with [scheme] (`cowork://blob/`) is a file
// under the app-support directory — that is where the relay lands host files —
// and every read/delete dispatches on it. Uploads still go to Supabase whenever
// there is a signed-in user and a key; without one they fall back to the blob
// store instead of throwing, which is what keeps the relay working offline.
//
// A path that starts with [offlineScheme] (`offline://img/<userId>/<id>`) is
// an image the user attached while the network was down: compressed and
// encrypted exactly like a bucket object, but written to the app-support
// directory until [promoteOfflineImage] uploads it. See docs/OFFLINE_SEND.md.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/image_compression_service.dart';
import 'package:chuk_chat/services/offline_blob_handle.dart';
import 'package:chuk_chat/utils/lru_byte_cache.dart';
import 'package:chuk_chat/utils/io_helper.dart' show Directory, File;
import 'package:chuk_chat/utils/path_provider_stub.dart'
    if (dart.library.io) 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

/// Represents a stored image with metadata
class StoredImage {
  final String path;
  final String name;
  final DateTime? createdAt;
  final int? size;

  const StoredImage({
    required this.path,
    required this.name,
    this.createdAt,
    this.size,
  });
}

/// Represents a chat that uses a specific image
class ChatUsingImage {
  final String chatId;
  final String chatName;

  const ChatUsingImage({required this.chatId, required this.chatName});
}

/// Top-level function for UTF-8 decoding in background isolate
String _utf8DecodeInBackground(Uint8List bytes) => utf8.decode(bytes);

/// Service for storing and retrieving encrypted images in Supabase Storage
class ImageStorageService {
  const ImageStorageService._();

  static const String bucketName = 'images';

  /// The scheme of a locally stored blob. Files delivered by the Agents relay
  /// never reach the Supabase bucket: they are written under the app-support
  /// directory and addressed `cowork://blob/<id>`.
  static const String scheme = 'cowork://blob/';

  static bool _isLocalBlob(String storagePath) =>
      storagePath.startsWith(scheme);
  static const Uuid _uuid = Uuid();

  /// Stream controller for notifying when images are deleted
  static final StreamController<String> _deletedImagesController =
      StreamController<String>.broadcast();

  /// Stream of deleted image paths - widgets can listen to this to update
  static Stream<String> get onImageDeleted => _deletedImagesController.stream;

  /// In-memory LRU cache for decrypted images (max 50 MB).
  /// When the limit is reached, the least recently used images are evicted.
  static const int _maxCacheSizeBytes = 50 * 1024 * 1024; // 50 MB
  static final LruByteCache _imageCache = LruByteCache(
    maxSizeBytes: _maxCacheSizeBytes,
  );

  /// In-flight request deduplication - prevents duplicate downloads for the same image
  static final Map<String, Future<Uint8List>> _pendingRequests = {};

  /// Clear a specific image from cache
  static void clearFromCache(String storagePath) {
    _imageCache.remove(storagePath);
  }

  /// Clear all cached images
  static void clearCache() {
    _imageCache.clear();
  }

  /// Get cached image if available
  static Uint8List? getCached(String storagePath) {
    return _imageCache.get(storagePath);
  }

  /// Uploads an encrypted image to Supabase Storage
  /// Steps:
  /// 1. Compress image to JPEG (max 1920x1920, ~2MB target, no hard limit)
  /// 2. Encrypt the compressed image bytes
  /// 3. Upload encrypted data to storage bucket
  /// 4. Return the storage path
  static Future<String> uploadEncryptedImage(Uint8List imageBytes) async {
    final user = SupabaseService.auth.currentUser;
    // No signed-in user or no key: write a local blob instead of throwing.
    // This is the Agents path — the relay delivers host files while the app may
    // never have talked to Supabase at all.
    if (user == null || !EncryptionService.hasKey) {
      return uploadLocalBlob(imageBytes);
    }

    // Step 1: Compress image
    final compressedBytes = await ImageCompressionService.compressImage(
      imageBytes,
    );
    return _encryptAndUpload(user.id, compressedBytes);
  }

  /// Uploads [bytes] encrypted, exactly as given: no image compression.
  ///
  /// For files that are not images (a PDF, a ZIP). [uploadEncryptedImage]
  /// rejects those, because its compressor only accepts image formats.
  /// Same storage, same `{user_id}/{uuid}.enc` path, same download.
  ///
  /// Without a signed-in user or a key the bytes go to the plain local blob
  /// store, which is what an Agents host delivery needs. A caller holding
  /// data the user did not hand over itself (a fetched file) passes
  /// [requireEncryption] and gets an exception instead.
  static Future<String> uploadEncryptedBytes(
    Uint8List bytes, {
    bool requireEncryption = false,
  }) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null || !EncryptionService.hasKey) {
      if (requireEncryption) {
        throw StateError('not signed in or no encryption key');
      }
      return uploadLocalBlob(bytes);
    }
    return _encryptAndUpload(user.id, bytes, suffix: fileSuffix);
  }

  /// Name ending of files stored by [uploadEncryptedBytes]. They share the
  /// image folder, so [listUserImages] skips this ending: a ZIP or a PDF is
  /// not a picture for the media library.
  static const String fileSuffix = '.file.enc';

  static Future<String> _encryptAndUpload(
    String userId,
    Uint8List bytes, {
    String suffix = '.enc',
  }) async {
    // Step 2: Encrypt the bytes
    final encryptedJson = await EncryptionService.encryptBytes(bytes);
    final encryptedBytes = Uint8List.fromList(utf8.encode(encryptedJson));

    // Step 3: Generate unique filename
    final fileId = _uuid.v4();
    final fileName = '$fileId$suffix'; // .enc marks encrypted files

    // Step 4: Upload to Supabase Storage
    final path = '$userId/$fileName';

    try {
      await _uploadRaw(path, encryptedBytes);

      // Pre-warm the in-memory cache with the image we just uploaded, keyed by
      // its storage path. `downloadAndDecryptImage(path)` returns exactly these
      // (decrypted == compressed) bytes, so the first render reads them
      // instantly instead of re-downloading and decrypting the file we already
      // have in hand — this redundant Supabase round-trip + decrypt is the main
      // cause of the multi-second lag between "image generated" and display.
      _imageCache.put(path, bytes);

      // Return the storage path (not the public URL, since files are encrypted)
      return path;
    } catch (e) {
      throw Exception('Failed to upload encrypted image: $e');
    }
  }

  /// Writes already encrypted bytes (UTF-8 of the `encryptBytes` JSON) to
  /// [path] in the bucket. The single upload call of this service.
  static Future<void> _uploadRaw(String path, Uint8List encryptedBytes) {
    final override = uploadOverride;
    if (override != null) return override(path, encryptedBytes);
    return SupabaseService.client.storage
        .from(bucketName)
        .uploadBinary(
          path,
          encryptedBytes,
          fileOptions: const FileOptions(
            contentType: 'application/octet-stream',
            upsert: false,
          ),
        );
  }

  /// Downloads and decrypts an image from Supabase Storage
  /// Returns the decrypted image bytes
  /// Uses in-memory cache and request deduplication to avoid redundant work
  static Future<Uint8List> downloadAndDecryptImage(
    String storagePath, {
    bool bypassCache = false,
  }) async {
    if (_isLocalBlob(storagePath)) {
      return _readLocalBlob(storagePath, bypassCache: bypassCache);
    }
    if (isOfflinePath(storagePath)) {
      return _readOfflineImage(storagePath, bypassCache: bypassCache);
    }
    // Check cache first (unless bypassing)
    if (!bypassCache) {
      final cached = _imageCache.get(storagePath);
      if (cached != null) {
        return cached;
      }
    }

    // Deduplicate: if this image is already being downloaded, share the future
    final pending = _pendingRequests[storagePath];
    if (pending != null && !bypassCache) {
      return pending;
    }

    final future = _downloadAndDecryptImageInternal(storagePath);
    _pendingRequests[storagePath] = future;

    try {
      final result = await future;
      return result;
    } finally {
      _pendingRequests.remove(storagePath);
    }
  }

  static Future<Uint8List> _downloadAndDecryptImageInternal(
    String storagePath,
  ) async {
    // Ensure user is authenticated
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw Exception('User must be authenticated to download images');
    }

    // Ensure encryption key is available
    if (!EncryptionService.hasKey) {
      throw Exception('Encryption key not available');
    }

    try {
      // Download encrypted file
      final encryptedBytes = await SupabaseService.client.storage
          .from(bucketName)
          .download(storagePath);

      // UTF-8 decode in background isolate to avoid blocking UI on large images
      final encryptedJson = await compute(
        _utf8DecodeInBackground,
        encryptedBytes,
      );

      // Decrypt the image (already runs in isolate via EncryptionService)
      final decryptedBytes = await EncryptionService.decryptBytes(
        encryptedJson,
      );

      // Cache the result (LRU evicts oldest if over 50 MB)
      _imageCache.put(storagePath, decryptedBytes);

      return decryptedBytes;
    } catch (e) {
      // Remove from cache if download fails (image might be deleted)
      _imageCache.remove(storagePath);
      throw Exception('Failed to download or decrypt image: $e');
    }
  }

  /// Deletes an encrypted image from Supabase Storage
  /// Also clears cache and notifies listeners
  static Future<void> deleteEncryptedImage(String storagePath) async {
    if (_isLocalBlob(storagePath)) {
      return _deleteLocalBlob(storagePath);
    }
    if (isOfflinePath(storagePath)) {
      return deleteOfflineImage(storagePath);
    }
    try {
      await SupabaseService.client.storage.from(bucketName).remove([
        storagePath,
      ]);

      // Clear from cache
      _imageCache.remove(storagePath);

      // Notify listeners that this image was deleted
      _deletedImagesController.add(storagePath);

      if (kDebugMode) {
        debugPrint('🗑️ [ImageStorage] Deleted and notified: $storagePath');
      }
    } catch (e) {
      throw Exception('Failed to delete encrypted image: $e');
    }
  }

  /// Lists all images stored by the current user
  /// Returns a list of StoredImage objects with metadata
  static Future<List<StoredImage>> listUserImages() async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw Exception('User must be authenticated to list images');
    }

    try {
      // Storage.list() returns at most 100 entries per call, newest last.
      // Without paging the library silently stopped at 100 files, so every
      // image generated after that never appeared — the file was there, the
      // listing just never reached it.
      const int pageSize = 100;
      final List<FileObject> files = <FileObject>[];
      for (int offset = 0; ; offset += pageSize) {
        final List<FileObject> page = await SupabaseService.client.storage
            .from(bucketName)
            .list(
              path: user.id,
              searchOptions: SearchOptions(
                limit: pageSize,
                offset: offset,
                sortBy: const SortBy(column: 'created_at', order: 'desc'),
              ),
            );
        files.addAll(page);
        if (page.length < pageSize) break;
      }

      final List<StoredImage> images = files
          .where(
            (file) =>
                file.name.endsWith('.enc') && !file.name.endsWith(fileSuffix),
          )
          .map(
            (file) => StoredImage(
              path: '${user.id}/${file.name}',
              name: file.name,
              createdAt: file.createdAt != null
                  ? DateTime.tryParse(file.createdAt!)
                  : null,
              size: file.metadata?['size'] as int?,
            ),
          )
          .toList();

      // Newest first, whatever the storage backend decides to sort by: a
      // freshly generated image has to be the first tile in the grid.
      images.sort((a, b) {
        final DateTime? left = a.createdAt;
        final DateTime? right = b.createdAt;
        if (left == null && right == null) return 0;
        if (left == null) return 1;
        if (right == null) return -1;
        return right.compareTo(left);
      });
      return images;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Failed to list user images: $e');
      }
      throw Exception('Failed to list images: $e');
    }
  }

  /// Finds all chats that use a specific image
  /// Returns a list of ChatUsingImage with chat ID and name
  static Future<List<ChatUsingImage>> findChatsUsingImage(
    String storagePath,
  ) async {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw Exception('User must be authenticated');
    }

    try {
      // Query encrypted_chats where image_paths contains this path
      // Using the PostgreSQL array contains operator
      final rows = await SupabaseService.client
          .from('encrypted_chats')
          .select('id, encrypted_payload')
          .eq('user_id', user.id)
          .contains('image_paths', [storagePath]);

      final List<ChatUsingImage> result = [];

      for (final row in rows) {
        final chatId = row['id'] as String;
        String chatName = 'Unnamed Chat';

        // Try to decrypt the payload to get the chat name
        final encryptedPayload = row['encrypted_payload'] as String?;
        if (encryptedPayload != null && EncryptionService.hasKey) {
          try {
            final decrypted = await EncryptionService.decrypt(encryptedPayload);
            final payload = jsonDecode(decrypted) as Map<String, dynamic>;
            chatName = payload['customName'] as String? ?? 'Unnamed Chat';

            // If no custom name, try to derive from first message
            if (chatName == 'Unnamed Chat') {
              final messages = payload['messages'] as List<dynamic>?;
              if (messages != null && messages.isNotEmpty) {
                final firstUserMsg = messages.firstWhere(
                  (m) => m['role'] == 'user',
                  orElse: () => null,
                );
                if (firstUserMsg != null) {
                  final text = firstUserMsg['text'] as String? ?? '';
                  chatName = text.length > 30
                      ? '${text.substring(0, 30)}...'
                      : text;
                }
              }
            }
          } catch (e) {
            if (kDebugMode) {
              debugPrint('Failed to decrypt chat name: $e');
            }
          }
        }

        result.add(ChatUsingImage(chatId: chatId, chatName: chatName));
      }

      return result;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Failed to find chats using image: $e');
      }
      throw Exception('Failed to find chats using image: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // The local blob store (Agents). One file per blob under the app-support
  // directory, addressed `cowork://blob/<id>`. No network, no encryption at
  // rest beyond what the filesystem gives.
  // ---------------------------------------------------------------------------

  /// Writes [imageBytes] to the local blob store and returns its
  /// `cowork://blob/<id>` path.
  static Future<String> uploadLocalBlob(Uint8List imageBytes) async {
    final id = _uuid.v4();
    final storagePath = '$scheme$id';
    final dir = await _blobDir();
    if (dir != null) {
      await File('${dir.path}/$id').writeAsBytes(imageBytes, flush: true);
    }
    _imageCache.put(storagePath, imageBytes);
    return storagePath;
  }

  static Future<Uint8List> _readLocalBlob(
    String storagePath, {
    bool bypassCache = false,
  }) async {
    if (!bypassCache) {
      final cached = _imageCache.get(storagePath);
      if (cached != null) return cached;
    }
    final file = await _fileFor(storagePath);
    if (file == null || !await file.exists()) {
      throw Exception('Blob not found: $storagePath');
    }
    final bytes = await file.readAsBytes();
    _imageCache.put(storagePath, bytes);
    return bytes;
  }

  static Future<void> _deleteLocalBlob(String storagePath) async {
    _imageCache.remove(storagePath);
    final file = await _fileFor(storagePath);
    if (file != null && await file.exists()) {
      await file.delete();
    }
    if (!_deletedImagesController.isClosed) {
      _deletedImagesController.add(storagePath);
    }
  }

  /// Size of a stored image. Exact for a local blob; for a bucket path it
  /// answers from the cache only, because the bucket has no cheap stat.
  static Future<int> getImageSize(String storagePath) async {
    final cached = _imageCache.get(storagePath);
    if (cached != null) return cached.length;
    if (isOfflinePath(storagePath)) {
      final file = await _offlineFileFor(storagePath);
      if (file == null || !await file.exists()) return 0;
      return file.length();
    }
    if (!_isLocalBlob(storagePath)) return 0;
    final file = await _fileFor(storagePath);
    if (file == null || !await file.exists()) return 0;
    return file.length();
  }

  /// Whether the bytes behind [storagePath] are here. Exact for a local blob;
  /// for a bucket path it answers from the cache only.
  static Future<bool> imageExists(String storagePath) async {
    if (_imageCache.get(storagePath) != null) return true;
    if (isOfflinePath(storagePath)) {
      final file = await _offlineFileFor(storagePath);
      if (file == null) return false;
      return file.exists();
    }
    if (!_isLocalBlob(storagePath)) return false;
    final file = await _fileFor(storagePath);
    if (file == null) return false;
    return file.exists();
  }

  static String _idOf(String storagePath) => storagePath.startsWith(scheme)
      ? storagePath.substring(scheme.length)
      : storagePath.replaceAll('/', '_');

  static Future<Directory?> _blobDir() async {
    try {
      final support = await getApplicationSupportDirectory();
      final dir = Directory('${support.path}/blobs');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return dir;
    } catch (_) {
      return null;
    }
  }

  static Future<File?> _fileFor(String storagePath) async {
    final dir = await _blobDir();
    if (dir == null) return null;
    return File('${dir.path}/${_idOf(storagePath)}');
  }

  // ---------------------------------------------------------------------------
  // The offline image store. An image attached while the network is down is
  // compressed and encrypted exactly like a bucket object (UTF-8 of the
  // `EncryptionService.encryptBytes` JSON) and written to
  // `<appSupport>/offline_images/<userId>/<id>.enc`. Its path is
  // `offline://img/<userId>/<id>`. [promoteOfflineImage] uploads the same
  // bytes later (no second encryption) and leaves a `<id>.promoted` marker
  // holding the bucket path, so a message that still names the offline path
  // resolves to the uploaded object, also after an app restart.
  // ---------------------------------------------------------------------------

  /// The scheme of an image kept on the device until the network is back.
  static const String offlineScheme = 'offline://img/';

  /// Matches one well-formed offline path inside any text (a JSON list, the
  /// attached-files JSON).
  static final RegExp offlinePathPattern = RegExp(
    r'offline://img/[A-Za-z0-9_-]+/[A-Za-z0-9_-]+',
  );

  static final RegExp _offlineSegment = RegExp(r'^[A-Za-z0-9_-]+$');

  /// Test seam: the path of the root directory of the offline store.
  @visibleForTesting
  static Future<String> Function()? offlineRootOverride;

  /// Test seam: the signed-in user id.
  @visibleForTesting
  static String? Function()? currentUserIdOverride;

  /// Test seam: the bucket upload of already encrypted bytes.
  @visibleForTesting
  static Future<void> Function(String path, Uint8List encryptedBytes)?
  uploadOverride;

  /// Promotions in flight, by offline path. A composer and the outbox may
  /// ask for the same image at the same time; both get one upload.
  static final Map<String, Future<String>> _promotions = {};

  /// Whether [path] names an image in the offline store.
  static bool isOfflinePath(String path) => path.startsWith(offlineScheme);

  /// Whether [storeOfflineImage] can work now: a native platform, a
  /// signed-in user and an encryption key.
  static bool get canStoreOffline =>
      (!_offlineWeb || offlineBlobs.isSupported) &&
      _currentUserId() != null &&
      EncryptionService.hasKey;

  /// Test seam: run the web (IndexedDB) branch of the offline store.
  @visibleForTesting
  static bool? offlineForceWeb;

  /// Test seam: the web store of offline images.
  @visibleForTesting
  static OfflineBlobHandle offlineBlobs = const OfflineBlobHandle();

  static bool get _offlineWeb => offlineForceWeb ?? kIsWeb;

  /// The key of an offline image in the web store.
  static String _offlineKey(String userId, String name) =>
      'offline_images/$userId/$name';

  static String? _currentUserId() {
    final override = currentUserIdOverride;
    if (override != null) return override();
    try {
      return SupabaseService.auth.currentUser?.id;
    } catch (_) {
      return null;
    }
  }

  /// The user id and the file id of an offline path, or null when [path] is
  /// not a well-formed offline path. The check also keeps `..` and `/` out
  /// of the file name.
  static ({String userId, String id})? _parseOffline(String path) {
    if (!isOfflinePath(path)) return null;
    final parts = path.substring(offlineScheme.length).split('/');
    if (parts.length != 2) return null;
    if (!_offlineSegment.hasMatch(parts[0])) return null;
    if (!_offlineSegment.hasMatch(parts[1])) return null;
    return (userId: parts[0], id: parts[1]);
  }

  static Future<Directory?> _offlineRoot() async {
    if (kIsWeb) return null;
    try {
      final override = offlineRootOverride;
      if (override != null) return Directory(await override());
      final support = await getApplicationSupportDirectory();
      return Directory('${support.path}/offline_images');
    } catch (_) {
      return null;
    }
  }

  static Future<_OfflineEntry?> _offlineFile(String path, String ending) async {
    final parsed = _parseOffline(path);
    if (parsed == null) return null;
    if (_offlineWeb) {
      return _BlobEntry(
        offlineBlobs,
        _offlineKey(parsed.userId, '${parsed.id}$ending'),
      );
    }
    final root = await _offlineRoot();
    if (root == null) return null;
    return _FileEntry(File('${root.path}/${parsed.userId}/${parsed.id}$ending'));
  }

  static Future<_OfflineEntry?> _offlineFileFor(String path) =>
      _offlineFile(path, '.enc');

  static Future<_OfflineEntry?> _offlineMarkerFor(String path) =>
      _offlineFile(path, '.promoted');

  /// The bucket path an offline image was promoted to, or null.
  static Future<String?> promotedPathOf(String offlinePath) async {
    final marker = await _offlineMarkerFor(offlinePath);
    if (marker == null || !await marker.exists()) return null;
    final value = (await marker.readString()).trim();
    return value.isEmpty ? null : value;
  }

  /// Compresses and encrypts [imageBytes] and keeps them on this device.
  /// Returns the `offline://img/<userId>/<id>` path.
  ///
  /// Throws [StateError] without a signed-in user or a key, and
  /// [UnsupportedError] on web (no file system). The caller then reports the
  /// failure as before.
  static Future<String> storeOfflineImage(Uint8List imageBytes) async {
    if (_offlineWeb && !offlineBlobs.isSupported) {
      throw UnsupportedError('No offline image store in this browser');
    }
    final userId = _currentUserId();
    if (userId == null || !_offlineSegment.hasMatch(userId)) {
      throw StateError('not signed in');
    }
    if (!EncryptionService.hasKey) {
      throw StateError('no encryption key');
    }
    final compressed = await ImageCompressionService.compressImage(
      imageBytes,
    );
    final encryptedJson = await EncryptionService.encryptBytes(compressed);
    final id = _uuid.v4();
    if (_offlineWeb) {
      await offlineBlobs.put(
        _offlineKey(userId, '$id.enc'),
        Uint8List.fromList(utf8.encode(encryptedJson)),
      );
    } else {
      final root = await _offlineRoot();
      if (root == null) {
        throw StateError('no app support directory');
      }
      final dir = Directory('${root.path}/$userId');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      await File(
        '${dir.path}/$id.enc',
      ).writeAsBytes(utf8.encode(encryptedJson), flush: true);
    }
    final path = '$offlineScheme$userId/$id';
    _imageCache.put(path, compressed);
    if (kDebugMode) {
      debugPrint('[ImageStorage] kept image offline, ${compressed.length} B');
    }
    return path;
  }

  static Future<Uint8List> _readOfflineImage(
    String path, {
    bool bypassCache = false,
  }) async {
    if (!bypassCache) {
      final cached = _imageCache.get(path);
      if (cached != null) return cached;
    }
    final file = await _offlineFileFor(path);
    if (file != null && await file.exists()) {
      if (!EncryptionService.hasKey) {
        throw Exception('Encryption key not available');
      }
      final raw = await file.readBytes();
      final encryptedJson = await compute(_utf8DecodeInBackground, raw);
      final bytes = await EncryptionService.decryptBytes(encryptedJson);
      _imageCache.put(path, bytes);
      return bytes;
    }
    // Already uploaded: read the bucket object instead.
    final promoted = await promotedPathOf(path);
    if (promoted != null) {
      return downloadAndDecryptImage(promoted, bypassCache: bypassCache);
    }
    throw const OfflineImageMissingException();
  }

  /// Uploads an offline image to the bucket and returns its bucket path.
  ///
  /// The stored bytes are already encrypted in the bucket format, so they go
  /// up as they are. Afterwards the local file is deleted, a marker keeps the
  /// mapping, and the cache entry moves to the bucket path. Calling it again
  /// for the same path returns the same bucket path without a new upload.
  ///
  /// Throws [OfflineImageMissingException] when the file is gone,
  /// [StateError] without a session (or for another account's image), and
  /// an [Exception] naming the upload error otherwise.
  static Future<String> promoteOfflineImage(String offlinePath) async {
    final running = _promotions[offlinePath];
    if (running != null) return running;
    final future = _promote(offlinePath);
    _promotions[offlinePath] = future;
    try {
      return await future;
    } finally {
      _promotions.remove(offlinePath);
    }
  }

  static Future<String> _promote(String offlinePath) async {
    final parsed = _parseOffline(offlinePath);
    if (parsed == null) throw const OfflineImageMissingException();
    final already = await promotedPathOf(offlinePath);
    if (already != null) return already;
    final file = await _offlineFileFor(offlinePath);
    if (file == null || !await file.exists()) {
      throw const OfflineImageMissingException();
    }
    final userId = _currentUserId();
    if (userId == null) throw StateError('not signed in');
    if (userId != parsed.userId) {
      throw StateError('image belongs to another account');
    }
    final encryptedBytes = await file.readBytes();
    // Same id as the local file: a retry after a crash between the upload
    // and the marker finds the object already there instead of making a
    // second copy.
    final storagePath = '$userId/${parsed.id}.enc';
    try {
      await _uploadRaw(storagePath, encryptedBytes);
    } catch (e) {
      if (!_isAlreadyExists(e)) {
        throw Exception('Failed to upload encrypted image: $e');
      }
    }
    final marker = await _offlineMarkerFor(offlinePath);
    await marker?.writeString(storagePath);
    final cached = _imageCache.get(offlinePath);
    if (cached != null) {
      _imageCache.remove(offlinePath);
      _imageCache.put(storagePath, cached);
    }
    try {
      await file.delete();
    } catch (_) {}
    if (kDebugMode) {
      debugPrint('[ImageStorage] offline image uploaded');
    }
    return storagePath;
  }

  static bool _isAlreadyExists(Object e) {
    if (e is StorageException) {
      if (e.statusCode == '409') return true;
      final text = '${e.message} ${e.error}'.toLowerCase();
      return text.contains('already exists') || text.contains('duplicate');
    }
    return false;
  }

  /// Deletes an offline image: its file, its marker and its cache entry.
  /// Never touches the bucket object a promotion made.
  static Future<void> deleteOfflineImage(String path) async {
    _imageCache.remove(path);
    for (final file in [
      await _offlineFileFor(path),
      await _offlineMarkerFor(path),
    ]) {
      if (file == null) continue;
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
    if (!_deletedImagesController.isClosed) {
      _deletedImagesController.add(path);
    }
  }

  /// Every offline image of [userId] that still has its file (not uploaded
  /// yet), as offline paths with the time the file was written. For the
  /// startup sweep of images no outbox row names.
  static Future<List<({String path, DateTime modified})>> listOfflineImages(
    String userId,
  ) async {
    if (!_offlineSegment.hasMatch(userId)) return const [];
    final out = <({String path, DateTime modified})>[];
    if (_offlineWeb) {
      try {
        for (final e in await offlineBlobs.list(_offlineKey(userId, ''))) {
          final String name = e.key.split('/').last;
          if (!name.endsWith('.enc')) continue;
          final String id = name.substring(0, name.length - '.enc'.length);
          if (!_offlineSegment.hasMatch(id)) continue;
          out.add((path: '$offlineScheme$userId/$id', modified: e.modified));
        }
      } catch (_) {}
      return out;
    }
    final root = await _offlineRoot();
    if (root == null) return const [];
    final dir = Directory('${root.path}/$userId');
    try {
      if (!await dir.exists()) return const [];
      await for (final entity in dir.list(followLinks: false)) {
        if (entity is! File || !entity.path.endsWith('.enc')) continue;
        final String name = entity.path.split('/').last;
        final String id = name.substring(0, name.length - '.enc'.length);
        if (!_offlineSegment.hasMatch(id)) continue;
        out.add((
          path: '$offlineScheme$userId/$id',
          modified: await entity.lastModified(),
        ));
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[ImageStorage] offline list failed: ${e.runtimeType}');
      }
    }
    return out;
  }

  /// Sign-out: deletes every offline image of [userId] and clears the
  /// decrypted image cache.
  static Future<void> wipeOfflineImages(String userId) async {
    _imageCache.clear();
    _promotions.clear();
    if (!_offlineSegment.hasMatch(userId)) return;
    if (_offlineWeb) {
      try {
        await offlineBlobs.deletePrefix(_offlineKey(userId, ''));
      } catch (_) {}
      return;
    }
    final root = await _offlineRoot();
    if (root == null) return;
    final dir = Directory('${root.path}/$userId');
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (e) {
      if (kDebugMode) {
        debugPrint('[ImageStorage] offline wipe failed: ${e.runtimeType}');
      }
    }
  }
}

/// The file behind an offline image path is gone.
class OfflineImageMissingException implements Exception {
  const OfflineImageMissingException();

  @override
  String toString() => 'image missing (404)';
}

/// One file of the offline image store: a file on native platforms, an
/// IndexedDB entry on web.
abstract class _OfflineEntry {
  Future<bool> exists();
  Future<int> length();
  Future<Uint8List> readBytes();
  Future<String> readString();
  Future<void> writeString(String value);
  Future<void> delete();
}

class _FileEntry implements _OfflineEntry {
  _FileEntry(this.file);
  final File file;

  @override
  Future<bool> exists() => file.exists();
  @override
  Future<int> length() => file.length();
  @override
  Future<Uint8List> readBytes() => file.readAsBytes();
  @override
  Future<String> readString() => file.readAsString();
  @override
  Future<void> writeString(String value) async {
    await file.writeAsString(value, flush: true);
  }

  @override
  Future<void> delete() async {
    await file.delete();
  }
}

class _BlobEntry implements _OfflineEntry {
  _BlobEntry(this.blobs, this.key);
  final OfflineBlobHandle blobs;
  final String key;

  @override
  Future<bool> exists() => blobs.exists(key);
  @override
  Future<int> length() async => (await blobs.get(key))?.length ?? 0;
  @override
  Future<Uint8List> readBytes() async =>
      await blobs.get(key) ?? (throw const OfflineImageMissingException());
  @override
  Future<String> readString() async => utf8.decode(await readBytes());
  @override
  Future<void> writeString(String value) =>
      blobs.put(key, Uint8List.fromList(utf8.encode(value)));
  @override
  Future<void> delete() => blobs.delete(key);
}
