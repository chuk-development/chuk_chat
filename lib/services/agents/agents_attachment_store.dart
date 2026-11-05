/// The files a user attaches to an Agents task, kept on this device until
/// they are uploaded to the host (docs/WIRE_CONTRACT.md, "Attachments to
/// Agents"; docs/OFFLINE_SEND.md, "Agents").
///
/// A picture goes the chat's own way: compressed and encrypted, kept offline
/// (`offline://img/…`) or in the encrypted bucket. Every other file is sealed
/// here with the user's chat key and named by a ref,
/// `agents-att://<user>/<id>`. Nothing is written in plaintext; a file that
/// cannot be sealed (no key, web) is refused and the composer says so.
///
/// It also keeps two small indexes that hold no content: the name a picture
/// had when it was attached (its storage path loses it), and which local copy
/// an uploaded `blob_id` came from, so a replayed bubble can still draw a
/// thumbnail from this device.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/utils/io_helper.dart' show Directory, File;
import 'package:chuk_chat/utils/path_provider_stub.dart'
    if (dart.library.io) 'package:path_provider/path_provider.dart';

/// What the store knows about one sealed file.
@immutable
class AgentsAttachmentMeta {
  const AgentsAttachmentMeta({
    required this.name,
    required this.mime,
    required this.size,
  });

  final String name;
  final String mime;
  final int size;

  Map<String, Object> toJson() => <String, Object>{
    'name': name,
    'mime': mime,
    'size': size,
  };

  static AgentsAttachmentMeta? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final Object? name = raw['name'];
    final Object? mime = raw['mime'];
    final Object? size = raw['size'];
    if (name is! String || size is! int) return null;
    return AgentsAttachmentMeta(
      name: name,
      mime: mime is String && mime.isNotEmpty
          ? mime
          : 'application/octet-stream',
      size: size,
    );
  }
}

/// One file read back from the store.
@immutable
class AgentsStoredAttachment {
  const AgentsStoredAttachment({required this.meta, required this.bytes});

  final AgentsAttachmentMeta meta;
  final Uint8List bytes;
}

class AgentsAttachmentStore {
  AgentsAttachmentStore._();

  static const String scheme = 'agents-att://';
  static final RegExp _segment = RegExp(r'^[A-Za-z0-9_-]+$');
  static const Uuid _uuid = Uuid();

  /// Test seams.
  @visibleForTesting
  static Future<String> Function()? rootOverride;
  @visibleForTesting
  static String? Function()? userOverride;
  @visibleForTesting
  static Future<String> Function(Uint8List bytes)? sealOverride;
  @visibleForTesting
  static Future<Uint8List> Function(String sealed)? openOverride;

  static final Map<String, AgentsAttachmentMeta> _meta =
      <String, AgentsAttachmentMeta>{};

  /// True for a ref this store made.
  static bool isRef(String? value) =>
      value != null && value.startsWith(scheme) && _parse(value) != null;

  /// True when this device can keep a sealed file (a file system, a user
  /// and a key).
  static bool get canStore =>
      !kIsWeb &&
      _user() != null &&
      (sealOverride != null || EncryptionService.hasKey);

  static String? _user() {
    final String? Function()? override = userOverride;
    if (override != null) return override();
    try {
      return SupabaseService.isInitialized
          ? SupabaseService.auth.currentUser?.id
          : null;
    } catch (_) {
      return null;
    }
  }

  static ({String user, String id})? _parse(String ref) {
    if (!ref.startsWith(scheme)) return null;
    final List<String> parts = ref.substring(scheme.length).split('/');
    if (parts.length != 2) return null;
    if (!_segment.hasMatch(parts[0]) || !_segment.hasMatch(parts[1])) {
      return null;
    }
    return (user: parts[0], id: parts[1]);
  }

  static Future<Directory?> _root() async {
    if (kIsWeb) return null;
    try {
      final Future<String> Function()? override = rootOverride;
      if (override != null) return Directory(await override());
      final support = await getApplicationSupportDirectory();
      return Directory('${support.path}/agents_attachments');
    } catch (_) {
      return null;
    }
  }

  static Future<String> _seal(Uint8List bytes) =>
      (sealOverride ?? EncryptionService.encryptBytes)(bytes);

  static Future<Uint8List> _open(String sealed) =>
      (openOverride ?? EncryptionService.decryptBytes)(sealed);

  /// Seals [bytes] with the user's key and returns the ref. Throws
  /// [StateError] when the file cannot be kept sealed (no user, no key, no
  /// file system).
  static Future<String> put(
    Uint8List bytes, {
    required String name,
    String? mime,
  }) async {
    final String? user = _user();
    if (user == null || !_segment.hasMatch(user)) {
      throw StateError('not signed in');
    }
    if (sealOverride == null && !EncryptionService.hasKey) {
      throw StateError('no encryption key');
    }
    final Directory? root = await _root();
    if (root == null) throw StateError('no app support directory');
    final Directory dir = Directory('${root.path}/$user');
    if (!await dir.exists()) await dir.create(recursive: true);
    final String id = _uuid.v4().replaceAll('-', '');
    final AgentsAttachmentMeta meta = AgentsAttachmentMeta(
      name: name,
      mime: mime ?? agentsMimeForName(name),
      size: bytes.length,
    );
    final String sealedBody = await _seal(bytes);
    final String sealedMeta = await _seal(
      Uint8List.fromList(utf8.encode(jsonEncode(meta.toJson()))),
    );
    await File('${dir.path}/$id.enc').writeAsString(sealedBody, flush: true);
    await File('${dir.path}/$id.meta').writeAsString(sealedMeta, flush: true);
    final String ref = '$scheme$user/$id';
    _meta[ref] = meta;
    return ref;
  }

  /// The name, type and size of [ref], from memory or the sealed sidecar.
  static Future<AgentsAttachmentMeta?> meta(String ref) async {
    final AgentsAttachmentMeta? cached = _meta[ref];
    if (cached != null) return cached;
    final ({String user, String id})? parsed = _parse(ref);
    if (parsed == null) return null;
    try {
      final Directory? root = await _root();
      if (root == null) return null;
      final File file = File('${root.path}/${parsed.user}/${parsed.id}.meta');
      if (!await file.exists()) return null;
      final Uint8List raw = await _open(await file.readAsString());
      final AgentsAttachmentMeta? meta = AgentsAttachmentMeta.fromJson(
        jsonDecode(utf8.decode(raw)),
      );
      if (meta != null) _meta[ref] = meta;
      return meta;
    } catch (_) {
      return null;
    }
  }

  /// The meta of [ref] when it is already in memory.
  static AgentsAttachmentMeta? peekMeta(String ref) => _meta[ref];

  /// Reads [ref] back. Null when the file is gone or does not open.
  static Future<AgentsStoredAttachment?> read(String ref) async {
    final ({String user, String id})? parsed = _parse(ref);
    if (parsed == null) return null;
    final AgentsAttachmentMeta? info = await meta(ref);
    if (info == null) return null;
    try {
      final Directory? root = await _root();
      if (root == null) return null;
      final File file = File('${root.path}/${parsed.user}/${parsed.id}.enc');
      if (!await file.exists()) return null;
      final Uint8List bytes = await _open(await file.readAsString());
      return AgentsStoredAttachment(meta: info, bytes: bytes);
    } catch (_) {
      return null;
    }
  }

  /// Deletes [ref]. Never throws.
  static Future<void> delete(String ref) async {
    final ({String user, String id})? parsed = _parse(ref);
    _meta.remove(ref);
    if (parsed == null) return;
    try {
      final Directory? root = await _root();
      if (root == null) return;
      for (final String ending in const <String>['.enc', '.meta']) {
        final File file = File(
          '${root.path}/${parsed.user}/${parsed.id}$ending',
        );
        if (await file.exists()) await file.delete();
      }
    } catch (_) {}
  }

  /// Sign-out: every sealed file of [userId] and its indexes go.
  static Future<void> wipeUser(String userId) async {
    _meta.removeWhere((String ref, _) => ref.startsWith('$scheme$userId/'));
    _names.clear();
    _blobs.clear();
    _blobsLoaded = false;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.remove(_blobKey(userId));
    } catch (_) {}
    if (!_segment.hasMatch(userId)) return;
    try {
      final Directory? root = await _root();
      if (root == null) return;
      final Directory dir = Directory('${root.path}/$userId');
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (error) {
      if (kDebugMode) debugPrint('[agents-attach] wipe failed: $error');
    }
  }

  // ── the name of a picture, by its storage path (memory only) ──────────────

  static final Map<String, String> _names = <String, String>{};

  /// Remembers the name [path] had when it was attached.
  static void rememberName(String path, String name) {
    if (path.isEmpty || name.trim().isEmpty) return;
    _names[path] = name.trim();
    if (_names.length > 200) _names.remove(_names.keys.first);
  }

  static String? nameOf(String path) => _names[path];

  // ── blob id → local copy ───────────────────────────────────────────────────

  static const int _maxBlobs = 300;
  static final Map<String, String> _blobs = <String, String>{};
  static bool _blobsLoaded = false;

  static String _blobKey(String? user) =>
      'agents_attachment_blobs:${user ?? 'anon'}';

  /// Records that [blobId] was uploaded from [localPath] (a ref or an image
  /// path). Only ids and paths are kept, never content.
  static Future<void> rememberBlob(String blobId, String localPath) async {
    await _loadBlobs();
    _blobs.remove(blobId);
    _blobs[blobId] = localPath;
    while (_blobs.length > _maxBlobs) {
      _blobs.remove(_blobs.keys.first);
    }
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(_blobKey(_user()), jsonEncode(_blobs));
    } catch (_) {}
  }

  /// The local copy [blobId] was uploaded from, when this device knows it.
  static String? localPathOfBlob(String blobId) => _blobs[blobId];

  /// Loads the blob index once. Safe to call often.
  static Future<void> _loadBlobs() async {
    if (_blobsLoaded) return;
    _blobsLoaded = true;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString(_blobKey(_user()));
      if (raw == null) return;
      final Object? decoded = jsonDecode(raw);
      if (decoded is Map) {
        for (final MapEntry<Object?, Object?> e in decoded.entries) {
          if (e.key is String && e.value is String) {
            _blobs['${e.key}'] = '${e.value}';
          }
        }
      }
    } catch (_) {}
  }

  /// Warms the blob index so [localPathOfBlob] answers synchronously.
  static Future<void> warm() => _loadBlobs();

  @visibleForTesting
  static void resetForTest() {
    rootOverride = null;
    userOverride = null;
    sealOverride = null;
    openOverride = null;
    _meta.clear();
    _names.clear();
    _blobs.clear();
    _blobsLoaded = false;
  }
}

/// A mime type for a file name, from its extension. Unknown is
/// `application/octet-stream`.
String agentsMimeForName(String name) {
  final int dot = name.lastIndexOf('.');
  final String ext = dot < 0 ? '' : name.substring(dot + 1).toLowerCase();
  return switch (ext) {
    'png' => 'image/png',
    'jpg' || 'jpeg' => 'image/jpeg',
    'webp' => 'image/webp',
    'gif' => 'image/gif',
    'heic' => 'image/heic',
    'pdf' => 'application/pdf',
    'txt' || 'log' => 'text/plain',
    'md' => 'text/markdown',
    'csv' => 'text/csv',
    'json' => 'application/json',
    'html' || 'htm' => 'text/html',
    'xml' => 'application/xml',
    'zip' => 'application/zip',
    'doc' => 'application/msword',
    'docx' =>
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'xls' => 'application/vnd.ms-excel',
    'xlsx' =>
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
    'pptx' =>
      'application/vnd.openxmlformats-officedocument.presentationml.presentation',
    'mp3' => 'audio/mpeg',
    'wav' => 'audio/wav',
    'mp4' => 'video/mp4',
    _ => 'application/octet-stream',
  };
}

/// The mime type of picture bytes, from their magic bytes. Null when they
/// are not one of PNG, JPEG, WebP or GIF.
String? agentsSniffImageMime(Uint8List bytes) {
  if (bytes.length >= 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    return 'image/png';
  }
  if (bytes.length >= 3 &&
      bytes[0] == 0xFF &&
      bytes[1] == 0xD8 &&
      bytes[2] == 0xFF) {
    return 'image/jpeg';
  }
  if (bytes.length >= 12 &&
      bytes[0] == 0x52 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x46 &&
      bytes[8] == 0x57 &&
      bytes[9] == 0x45 &&
      bytes[10] == 0x42 &&
      bytes[11] == 0x50) {
    return 'image/webp';
  }
  if (bytes.length >= 4 &&
      bytes[0] == 0x47 &&
      bytes[1] == 0x49 &&
      bytes[2] == 0x46 &&
      bytes[3] == 0x38) {
    return 'image/gif';
  }
  return null;
}
