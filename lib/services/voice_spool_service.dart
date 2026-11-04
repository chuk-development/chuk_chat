// lib/services/voice_spool_service.dart
//
// Keeps voice recordings on disk until they are transcribed. A recording is
// written here BEFORE any transcription attempt, so a bad connection, a
// crash or an app restart never loses it. Design: docs/OFFLINE_SEND.md.
//
// Layout: <applicationSupportDir>/voice_spool/<userId or 'anon'>/<uuid>.wav
//
// Web has no file system: every call throws [UnsupportedError] there, and the
// caller falls back to the old in-memory path.
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

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

  /// Whether recordings can be kept on this platform.
  static bool get isSupported => !kIsWeb;

  static String _safeUser(String? userId) {
    if (userId == null || userId.isEmpty) return 'anon';
    // A user id is a UUID; never let it walk out of the spool folder.
    return userId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  }

  static Future<String> _userDir(String? userId) async {
    final base = await baseDir();
    return '$base/$_folder/${_safeUser(userId)}';
  }

  /// Writes [wav] to a new file and returns its absolute path. The write is
  /// flushed to disk before this returns.
  static Future<String> saveWav(Uint8List wav, {String? userId}) async {
    if (!isSupported) {
      throw UnsupportedError('Voice spool is not supported on web');
    }
    final dir = await _userDir(userId);
    await Directory(dir).create(recursive: true);
    final path = '$dir/${_uuid.v4()}.wav';
    await File(path).writeAsBytes(wav, flush: true);
    if (kDebugMode) {
      debugPrint('[VoiceSpool] saved ${wav.length} bytes');
    }
    return path;
  }

  /// Reads a saved recording. Throws when the file is missing.
  static Future<Uint8List> read(String path) async {
    if (!isSupported) {
      throw UnsupportedError('Voice spool is not supported on web');
    }
    return File(path).readAsBytes();
  }

  /// Whether the recording at [path] still exists.
  static Future<bool> exists(String path) async {
    if (!isSupported || path.isEmpty) return false;
    try {
      return await File(path).exists();
    } catch (_) {
      return false;
    }
  }

  /// Deletes a saved recording. A missing file is not an error.
  static Future<void> delete(String path) async {
    if (!isSupported || path.isEmpty) return;
    try {
      final file = File(path);
      if (await file.exists()) await file.delete();
    } catch (e) {
      if (kDebugMode) debugPrint('[VoiceSpool] delete failed: $e');
    }
  }

  /// Sign-out: deletes every recording of [userId].
  static Future<void> wipeUser(String userId) async {
    if (!isSupported) return;
    try {
      final dir = Directory(await _userDir(userId));
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (e) {
      if (kDebugMode) debugPrint('[VoiceSpool] wipe failed: $e');
    }
  }

  @visibleForTesting
  static void reset() {
    baseDir = _defaultBaseDir;
  }
}
