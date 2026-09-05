/// Carries the P2b JSON-file cache over to the SQLite cache, and drops replay
/// cursors that point past a transcript this device no longer holds.
///
/// Why this exists (bead cowork-izh, "yesterday's chat history is gone"):
/// P2b kept one `<session key>.json` per thread under `<app support>/chats`
/// and a replay cursor per thread in SharedPreferences. The SQLite storage
/// (bead cowork-sha) replaced the file cache but did not read those files,
/// so a thread that had been fully replayed before the switch had NO local
/// copy any more — while its cursor still said "I hold everything up to
/// mid N". The next open asked the host for a delta above N (nothing), and
/// the thread painted empty. The host still had every message; the copy on
/// this device was simply not looked at.
///
/// Two repairs, both run once per sign-in from the bootstrap:
///
/// 1. [migrateJsonCache]: every JSON file that has no SQLite row yet becomes
///    one (through [CoworkChatStore.replaceThread], so it also reaches the
///    cloud). The file is renamed to `.migrated`, never deleted.
/// 2. [dropOrphanCursors]: a cursor whose thread has no local copy anywhere
///    is removed, so the next open is a full replay from the host. The host
///    is the truth; a full replay is always safe, an empty delta is not.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cowork/models/stored_chat.dart';
import 'package:cowork/services/storage/cowork_chat_store.dart';
import 'package:cowork/utils/io_helper.dart';
import 'package:cowork/utils/path_provider_stub.dart'
    if (dart.library.io) 'package:path_provider/path_provider.dart';

/// Prefix of the per-session replay cursor key in SharedPreferences (the
/// loader's `kReplayCursorPrefix`).
const String kReplayCursorPrefsPrefix = 'cowork.replay_cursor.';

/// Suffix a migrated JSON file gets. It stays on disk as a backup.
const String kMigratedSuffix = '.migrated';

typedef CoworkThreadWriter =
    Future<StoredChat?> Function(
      String sessionKey,
      List<Map<String, dynamic>> rows, {
      DateTime? createdAt,
      DateTime? updatedAt,
      bool? isStarred,
      String? customName,
    });

class CoworkChatCacheMigration {
  CoworkChatCacheMigration._();

  /// Test seams.
  @visibleForTesting
  static Future<Directory?> Function()? chatDirProvider;
  @visibleForTesting
  static Future<bool> Function(String userId, String sessionKey)? hasLocalCopy;
  @visibleForTesting
  static CoworkThreadWriter? writer;

  @visibleForTesting
  static void reset() {
    chatDirProvider = null;
    hasLocalCopy = null;
    writer = null;
  }

  /// Moves every un-migrated P2b JSON thread file into the SQLite cache.
  /// Returns the number of threads migrated. Never throws.
  static Future<int> migrateJsonCache(String userId) async {
    final dir = await _chatDir();
    if (dir == null) return 0;
    var migrated = 0;
    try {
      for (final file in await _jsonFiles(dir)) {
        try {
          final decoded = jsonDecode(await file.readAsString());
          if (decoded is! Map<String, dynamic>) continue;
          final id = decoded['id'];
          if (id is! String || id.isEmpty) continue;
          final rawMessages = decoded['messages'];
          final rows = <Map<String, dynamic>>[
            if (rawMessages is List)
              for (final row in rawMessages)
                if (row is Map) Map<String, dynamic>.from(row),
          ];
          if (rows.isEmpty) {
            await _markMigrated(file);
            continue;
          }
          if (await _hasLocalCopy(userId, id)) {
            // SQLite already knows this thread (a live turn or a replay
            // wrote it after the switch). The file is older; keep the row.
            await _markMigrated(file);
            continue;
          }
          final write = writer ?? CoworkChatStore.replaceThread;
          final stored = await write(
            id,
            rows,
            createdAt: DateTime.tryParse('${decoded['createdAt']}'),
            updatedAt: DateTime.tryParse('${decoded['updatedAt']}'),
            isStarred: decoded['isStarred'] == true,
            customName: decoded['customName'] as String?,
          );
          if (stored == null) continue;
          // Memory holds the thread now; the SQLite and cloud writes are
          // queued behind it. Not awaited: a slow cloud (15 s timeout) must
          // not hold sign-in, and if the app dies before the row lands the
          // cursor repair below makes the next open a full host replay.
          await _markMigrated(file);
          migrated++;
          if (kDebugMode) {
            debugPrint(
              '[cowork-chat-migration] $id: ${rows.length} rows from '
              '${file.path} into SQLite',
            );
          }
        } catch (error) {
          // One unreadable file must not stop the others. It stays as it is
          // and is looked at again next sign-in.
          if (kDebugMode) {
            debugPrint('[cowork-chat-migration] ${file.path}: $error');
          }
        }
      }
    } catch (error) {
      if (kDebugMode) debugPrint('[cowork-chat-migration] $error');
    }
    return migrated;
  }

  /// Removes every replay cursor whose thread has no local copy. Returns the
  /// number of cursors dropped. Never throws.
  static Future<int> dropOrphanCursors(String userId) async {
    var dropped = 0;
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final key in prefs.getKeys().toList()) {
        if (!key.startsWith(kReplayCursorPrefsPrefix)) continue;
        final sessionKey = key.substring(kReplayCursorPrefsPrefix.length);
        if (sessionKey.isEmpty) continue;
        if (await _hasLocalCopy(userId, sessionKey)) continue;
        await prefs.remove(key);
        dropped++;
        if (kDebugMode) {
          debugPrint(
            '[cowork-chat-migration] $sessionKey: no local copy, cursor '
            'dropped; the next open replays the whole thread',
          );
        }
      }
    } catch (error) {
      if (kDebugMode) debugPrint('[cowork-chat-migration] cursors: $error');
    }
    return dropped;
  }

  // ---------------------------------------------------------------------------

  static Future<bool> _hasLocalCopy(String userId, String sessionKey) async {
    final probe = hasLocalCopy;
    if (probe != null) return probe(userId, sessionKey);
    return CoworkChatStore.hasThread(sessionKey);
  }

  static Future<Directory?> _chatDir() async {
    final provider = chatDirProvider;
    if (provider != null) return provider();
    try {
      final support = await getApplicationSupportDirectory();
      final dir = Directory('${support.path}/chats');
      if (!await dir.exists()) return null;
      return dir;
    } catch (_) {
      return null;
    }
  }

  /// The P2b files. P2b kept `index.json` (a JSON list of ids) precisely
  /// because the web `Directory` stub cannot list a directory, so the index
  /// is the way in here too; each id maps to its file the way P2b named it.
  static Future<List<File>> _jsonFiles(Directory dir) async {
    final out = <File>[];
    try {
      final index = File('${dir.path}/index.json');
      if (!await index.exists()) return out;
      final decoded = jsonDecode(await index.readAsString());
      if (decoded is! List) return out;
      for (final id in decoded) {
        if (id is! String || id.isEmpty) continue;
        final file = File('${dir.path}/${_fileNameOf(id)}');
        if (await file.exists()) out.add(file);
      }
    } catch (_) {
      // An index that cannot be read has nothing to migrate.
    }
    return out;
  }

  /// P2b's file name for a session key (`chat_storage_service.dart` stub,
  /// now gone): every character outside `[A-Za-z0-9._-]` became `_`.
  static String _fileNameOf(String chatId) =>
      '${chatId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_')}.json';

  /// A rename in two steps, because the web `File` stub has no rename: the
  /// backup copy is written first, the original deleted only after that.
  static Future<void> _markMigrated(File file) async {
    try {
      final content = await file.readAsString();
      await File(
        '${file.path}$kMigratedSuffix',
      ).writeAsString(content, flush: true);
      await file.delete();
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[cowork-chat-migration] rename failed: $error');
      }
    }
  }
}
