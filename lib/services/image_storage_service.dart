// COWORK STUB. Upstream: chuk_chat/lib/services/image_storage_service.dart @ d31526a229fdde27c82adf3661d5d3a149db8340.
// Reason: replaced by cowork service — upstream stores encrypted blobs in a
// Supabase bucket. CoWork keeps them LOCAL: one file per blob under the app
// support directory, addressed as `cowork://blob/<id>`. This is where relayed
// files from the host land.
// Keep the public API signature-compatible with upstream so the imported chat UI compiles unchanged. Do not "improve" this file.

import 'dart:async';
import 'dart:typed_data';

import 'package:cowork/utils/io_helper.dart';
import 'package:cowork/utils/path_provider_stub.dart'
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

/// The CoWork blob store: local files, no network, no encryption at rest
/// beyond what the filesystem already gives.
class ImageStorageService {
  const ImageStorageService._();

  /// Kept for signature compatibility. Nothing is uploaded anywhere.
  static const String bucketName = 'images';

  /// The scheme every path this service hands out uses.
  static const String scheme = 'cowork://blob/';

  static const Uuid _uuid = Uuid();

  static final StreamController<String> _deletedImagesController =
      StreamController<String>.broadcast();

  /// Stream of deleted image storage paths.
  static Stream<String> get onImageDeleted => _deletedImagesController.stream;

  static final Map<String, Uint8List> _memoryCache = <String, Uint8List>{};

  static void clearFromCache(String storagePath) {
    _memoryCache.remove(storagePath);
  }

  static void clearCache() {
    _memoryCache.clear();
  }

  static Uint8List? getCached(String storagePath) => _memoryCache[storagePath];

  /// Writes [imageBytes] to the local blob store and returns its
  /// `cowork://blob/<id>` path.
  static Future<String> uploadEncryptedImage(Uint8List imageBytes) async {
    final id = _uuid.v4();
    final storagePath = '$scheme$id';
    final dir = await _blobDir();
    if (dir != null) {
      await File('${dir.path}/$id').writeAsBytes(imageBytes, flush: true);
    }
    _memoryCache[storagePath] = imageBytes;
    return storagePath;
  }

  static Future<Uint8List> downloadAndDecryptImage(
    String storagePath, {
    bool bypassCache = false,
  }) async {
    if (!bypassCache) {
      final cached = _memoryCache[storagePath];
      if (cached != null) return cached;
    }
    final file = await _fileFor(storagePath);
    if (file == null || !await file.exists()) {
      throw Exception('Blob not found: $storagePath');
    }
    final bytes = await file.readAsBytes();
    _memoryCache[storagePath] = bytes;
    return bytes;
  }

  static Future<void> deleteEncryptedImage(String storagePath) async {
    _memoryCache.remove(storagePath);
    final file = await _fileFor(storagePath);
    if (file != null && await file.exists()) {
      await file.delete();
    }
    if (!_deletedImagesController.isClosed) {
      _deletedImagesController.add(storagePath);
    }
  }

  static Future<int> getImageSize(String storagePath) async {
    final cached = _memoryCache[storagePath];
    if (cached != null) return cached.length;
    final file = await _fileFor(storagePath);
    if (file == null || !await file.exists()) return 0;
    return file.length();
  }

  /// The local store is not enumerated: the server transcript is the index.
  static Future<List<StoredImage>> listUserImages() async => <StoredImage>[];

  /// No cross-chat index locally.
  static Future<List<ChatUsingImage>> findChatsUsingImage(
    String storagePath,
  ) async => <ChatUsingImage>[];

  static Future<bool> imageExists(String storagePath) async {
    if (_memoryCache.containsKey(storagePath)) return true;
    final file = await _fileFor(storagePath);
    if (file == null) return false;
    return file.exists();
  }

  // --------------------------------------------------------------------------
  // Local helpers (not upstream API).
  // --------------------------------------------------------------------------

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
}
