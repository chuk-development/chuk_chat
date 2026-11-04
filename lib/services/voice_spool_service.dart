// lib/services/voice_spool_service.dart
//
// Keeps voice recordings on disk until they are transcribed. A recording is
// written here BEFORE any transcription attempt, so a bad connection, a
// crash or an app restart never loses it. Design: docs/OFFLINE_SEND.md.
//
// Layout: <applicationSupportDir>/voice_spool/<userId or 'anon'>/<uuid>.wav.enc
//
// A recording is the user's message, so it is sealed at rest with the chat
// key (`EncryptionService.encryptBytes`, as the offline images). When no key
// can be loaded, the recording is NOT written in plaintext: it is kept in
// memory under its final path and written, sealed, as soon as a key is
// there ([sealPending], also at every outbox flush). If the app dies before
// that, the recording is lost and its row fails with "recording missing".
//
// Web has no file system: there the recordings live in IndexedDB
// ([OfflineBlobStore]) under the same layout, and a path is
// `idb:voice_spool/<user>/<uuid>.wav`. A browser without IndexedDB throws
// [UnsupportedError], and the caller falls back to the old in-memory path.
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/offline_blob_handle.dart';
import 'package:chuk_chat/utils/io_helper.dart' show Directory, File;
import 'package:chuk_chat/utils/path_provider_stub.dart'
    if (dart.library.io) 'package:path_provider/path_provider.dart';

abstract final class VoiceSpoolService {
  static const String _folder = 'voice_spool';
  static const Uuid _uuid = Uuid();

  /// Test seam: the base directory (the app support directory by default).
  @visibleForTesting
  static Future<String> Function() baseDir = _defaultBaseDir;

  static Future<String> _defaultBaseDir() async =>
      (await getApplicationSupportDirectory()).path;

  /// The path prefix of a recording kept in the web store.
  static const String webScheme = 'idb:';

  /// Test seam: run the web (IndexedDB) branch on any platform.
  @visibleForTesting
  static bool? forceWeb;

  static bool get _web => forceWeb ?? kIsWeb;

  /// Test seam: the web store.
  @visibleForTesting
  static OfflineBlobHandle blobs = const OfflineBlobHandle();

  /// Whether recordings can be kept on this platform.
  static bool get isSupported => !_web || blobs.isSupported;

  static String _safeUser(String? userId) {
    if (userId == null || userId.isEmpty) return 'anon';
    // A user id is a UUID; never let it walk out of the spool folder.
    return userId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  }

  static Future<String> _userDir(String? userId) async {
    final base = await baseDir();
    return '$base/$_folder/${_safeUser(userId)}';
  }

  /// The suffix of a sealed recording.
  static const String sealedSuffix = '.wav.enc';

  /// Test seam: seals the bytes of a recording, or null when no key can be
  /// loaded.
  @visibleForTesting
  static Future<Uint8List?> Function(Uint8List wav) seal = _defaultSeal;

  /// Test seam: opens bytes written by [seal].
  @visibleForTesting
  static Future<Uint8List> Function(Uint8List sealed) open = _defaultOpen;

  static Future<Uint8List?> _defaultSeal(Uint8List wav) async {
    if (!EncryptionService.hasKey && !await EncryptionService.tryLoadKey()) {
      return null;
    }
    return Uint8List.fromList(
      utf8.encode(await EncryptionService.encryptBytes(wav)),
    );
  }

  static Future<Uint8List> _defaultOpen(Uint8List sealed) =>
      EncryptionService.decryptBytes(utf8.decode(sealed));

  /// Recordings saved while no key could be loaded, by their final path.
  /// They never touch the disk in plaintext.
  static final Map<String, Uint8List> _pending = <String, Uint8List>{};

  /// Whether a recording waits in memory for the key.
  @visibleForTesting
  static bool isPending(String path) => _pending.containsKey(path);

  /// Saves [wav] as a new recording and returns its path. With a key the
  /// sealed bytes are on disk (flushed) before this returns; without one
  /// they wait in memory until [sealPending] can write them.
  static Future<String> saveWav(Uint8List wav, {String? userId}) async {
    if (!isSupported) {
      throw UnsupportedError('Voice spool is not supported on web');
    }
    final String name = '${_uuid.v4()}$sealedSuffix';
    final String path;
    if (_web) {
      path = '$webScheme$_folder/${_safeUser(userId)}/$name';
    } else {
      path = '${await _userDir(userId)}/$name';
    }
    final Uint8List? sealed = await seal(wav);
    if (sealed == null) {
      _pending[path] = wav;
      if (kDebugMode) debugPrint('[VoiceSpool] kept in memory until the key');
      return path;
    }
    await _write(path, sealed);
    if (kDebugMode) {
      debugPrint('[VoiceSpool] saved ${wav.length} bytes (sealed)');
    }
    // A key is there now: earlier recordings that waited for it go too.
    if (_pending.isNotEmpty) await sealPending();
    return path;
  }

  static Future<void> _write(String path, Uint8List bytes) async {
    if (_web) {
      await blobs.put(_webKey(path), bytes);
      return;
    }
    final int cut = path.lastIndexOf('/');
    if (cut > 0) {
      await Directory(path.substring(0, cut)).create(recursive: true);
    }
    await File(path).writeAsBytes(bytes, flush: true);
  }

  /// Writes the recordings that waited for the key, sealed. Returns how
  /// many were written. No-op while no key can be loaded.
  static Future<int> sealPending() async {
    if (_pending.isEmpty) return 0;
    var n = 0;
    for (final String path in _pending.keys.toList()) {
      final Uint8List? wav = _pending[path];
      if (wav == null) continue;
      final Uint8List? sealed = await seal(wav);
      if (sealed == null) break;
      try {
        await _write(path, sealed);
        // Only now: a failed write keeps it in memory for the next try.
        _pending.remove(path);
        n++;
      } catch (e) {
        if (kDebugMode) debugPrint('[VoiceSpool] seal write failed: $e');
      }
    }
    return n;
  }

  /// Reads a saved recording (opened when sealed). Throws when it is
  /// missing.
  static Future<Uint8List> read(String path) async {
    if (!isSupported) {
      throw UnsupportedError('Voice spool is not supported on web');
    }
    final Uint8List? held = _pending[path];
    if (held != null) return held;
    final Uint8List raw;
    if (_web) {
      final bytes = await blobs.get(_webKey(path));
      if (bytes == null) throw StateError('recording is missing');
      raw = bytes;
    } else {
      raw = await File(path).readAsBytes();
    }
    return path.endsWith(sealedSuffix) ? open(raw) : raw;
  }

  static String _webKey(String path) =>
      path.startsWith(webScheme) ? path.substring(webScheme.length) : path;

  /// Whether the recording at [path] still exists.
  static Future<bool> exists(String path) async {
    if (!isSupported || path.isEmpty) return false;
    if (_pending.containsKey(path)) return true;
    if (_web) {
      try {
        return await blobs.exists(_webKey(path));
      } catch (_) {
        return false;
      }
    }
    try {
      return await File(path).exists();
    } catch (_) {
      return false;
    }
  }

  /// Deletes a saved recording. A missing file is not an error.
  static Future<void> delete(String path) async {
    if (!isSupported || path.isEmpty) return;
    _pending.remove(path);
    try {
      if (_web) {
        await blobs.delete(_webKey(path));
        return;
      }
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (e) {
      if (kDebugMode) debugPrint('[VoiceSpool] delete failed: $e');
    }
  }

  /// Every saved recording of [userId] (and of the `anon` folder, which a
  /// recording made before the session was known lands in), with the time
  /// it was last written. For the startup sweep of files no row names.
  static Future<List<({String path, DateTime modified})>> listFiles(
    String userId,
  ) async {
    if (!isSupported) return const [];
    final out = <({String path, DateTime modified})>[];
    if (_web) {
      for (final String folder in <String>{_safeUser(userId), 'anon'}) {
        try {
          for (final e in await blobs.list('$_folder/$folder/')) {
            if (!_isRecording(e.key)) continue;
            out.add((path: '$webScheme${e.key}', modified: e.modified));
          }
        } catch (_) {}
      }
      return out;
    }
    for (final String folder in <String>{_safeUser(userId), 'anon'}) {
      final dir = Directory('${await baseDir()}/$_folder/$folder');
      try {
        if (!await dir.exists()) continue;
        await for (final entity in dir.list(followLinks: false)) {
          if (entity is! File || !_isRecording(entity.path)) continue;
          out.add((path: entity.path, modified: await entity.lastModified()));
        }
      } catch (e) {
        if (kDebugMode) debugPrint('[VoiceSpool] list failed: $e');
      }
    }
    return out;
  }

  /// A recording file: sealed, or a plaintext `.wav` of an older build.
  static bool _isRecording(String path) =>
      path.endsWith(sealedSuffix) || path.endsWith('.wav');

  /// Sign-out: deletes every recording of [userId], also one that still
  /// waits in memory for the key.
  static Future<void> wipeUser(String userId) async {
    if (!isSupported) return;
    final String folder = '/$_folder/${_safeUser(userId)}/';
    _pending.removeWhere(
      (String path, _) => path.contains(folder) ||
          path.startsWith('$webScheme${folder.substring(1)}'),
    );
    try {
      if (_web) {
        await blobs.deletePrefix('$_folder/${_safeUser(userId)}/');
        return;
      }
      final dir = Directory(await _userDir(userId));
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (e) {
      if (kDebugMode) debugPrint('[VoiceSpool] wipe failed: $e');
    }
  }

  /// Test seam: a stand-in cipher (no real key). [withKey] false acts as
  /// "no key can be loaded".
  @visibleForTesting
  static void useFakeCipher({bool withKey = true}) {
    seal = (Uint8List wav) async => withKey
        ? Uint8List.fromList(<int>[0x53, for (final b in wav) b ^ 0x5a])
        : null;
    open = (Uint8List sealed) async {
      if (sealed.isEmpty || sealed.first != 0x53) {
        throw StateError('not sealed');
      }
      return Uint8List.fromList(<int>[
        for (final b in sealed.skip(1)) b ^ 0x5a,
      ]);
    };
  }

  @visibleForTesting
  static void reset() {
    baseDir = _defaultBaseDir;
    forceWeb = null;
    blobs = const OfflineBlobHandle();
    seal = _defaultSeal;
    open = _defaultOpen;
    _pending.clear();
  }
}
