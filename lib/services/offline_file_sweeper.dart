// lib/services/offline_file_sweeper.dart
//
// Deletes outbox files that no outbox row names any more
// (docs/OFFLINE_SEND.md, "Files a crash left behind").
//
// A voice recording is written before its row exists, and an offline image
// before its message is sent. A crash between the two, or an image attached
// and never sent, leaves a file with no row. Once per app run, when a user
// and the key are there, this looks at the user's voice recordings and
// offline images:
//  * a file that a row names is kept, whatever its age;
//  * a file no row names is deleted once it is older than [grace]. A newer
//    one may belong to a recording or a composer that is still open.
// When any row of the user cannot be opened (wrong key), nothing is deleted:
// the files that row names are not known.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/models/queued_message.dart';
import 'package:chuk_chat/services/agents/agents_task_outbox.dart';
import 'package:chuk_chat/services/image_storage_service.dart';
import 'package:chuk_chat/services/offline_outbox_cipher.dart';
import 'package:chuk_chat/services/offline_queue_service.dart';
import 'package:chuk_chat/services/voice_spool_service.dart';

typedef SweptFile = ({String path, DateTime modified});

class OfflineFileSweeper {
  OfflineFileSweeper._();

  static final OfflineFileSweeper instance = OfflineFileSweeper._();

  /// A file younger than this is never swept.
  static Duration grace = const Duration(hours: 6);

  // ── Test seams ──────────────────────────────────────────────────────
  @visibleForTesting
  static String? Function() currentUser = _defaultUser;
  @visibleForTesting
  static bool Function() canOpen = _defaultCanOpen;
  @visibleForTesting
  static Future<List<QueuedMessage>> Function() rows = _defaultRows;
  @visibleForTesting
  static Future<List<SweptFile>> Function(String userId) voiceFiles =
      VoiceSpoolService.listFiles;
  @visibleForTesting
  static Future<List<SweptFile>> Function(String userId) imageFiles =
      ImageStorageService.listOfflineImages;
  @visibleForTesting
  static Future<void> Function(String path) deleteVoice =
      VoiceSpoolService.delete;
  @visibleForTesting
  static Future<void> Function(String path) deleteImage =
      ImageStorageService.deleteOfflineImage;
  @visibleForTesting
  static DateTime Function() now = DateTime.now;

  /// The local attachment paths the queued Agents prompts still name (null:
  /// a row cannot be opened, so nothing is deleted).
  static Future<Set<String>?> Function() agentsPaths =
      AgentsTaskOutbox.attachmentPaths;

  static String? _defaultUser() => OutboxCipher.currentUserId();
  static bool _defaultCanOpen() => OutboxCipher.canOpen();

  static Future<List<QueuedMessage>> _defaultRows() =>
      OfflineQueueService.instance.listAll();

  @visibleForTesting
  static void resetSeams() {
    currentUser = _defaultUser;
    canOpen = _defaultCanOpen;
    rows = _defaultRows;
    voiceFiles = VoiceSpoolService.listFiles;
    imageFiles = ImageStorageService.listOfflineImages;
    deleteVoice = VoiceSpoolService.delete;
    deleteImage = ImageStorageService.deleteOfflineImage;
    now = DateTime.now;
    agentsPaths = AgentsTaskOutbox.attachmentPaths;
    grace = const Duration(hours: 6);
    instance._swept.clear();
    instance._running = null;
  }

  /// [path] in one form for comparing: a saved path joins with `/`, while
  /// a directory listing on Windows joins with a backslash. Without this a
  /// named recording would look orphaned there and be deleted.
  @visibleForTesting
  static String pathKey(String path) {
    final String slashed = path.replaceAll('\\', '/');
    final String collapsed = slashed.replaceAll(RegExp('/{2,}'), '/');
    return collapsed.replaceAll('/./', '/');
  }

  /// Users swept in this app run.
  final Set<String> _swept = <String>{};
  Future<int>? _running;

  /// Sweeps once per app run and user. Safe to call on every trigger.
  void sweepOnce() {
    final String? user = currentUser();
    if (user == null || _swept.contains(user) || _running != null) return;
    if (!canOpen()) return;
    _running = sweep(user).whenComplete(() => _running = null);
  }

  /// Sweeps [userId]'s files now. Returns how many were deleted.
  Future<int> sweep(String userId) async {
    var deleted = 0;
    try {
      final List<QueuedMessage> all = await rows();
      final List<QueuedMessage> mine = <QueuedMessage>[
        for (final r in all)
          if (r.userId == userId || r.userId == null) r,
      ];
      if (mine.any((r) => r.locked)) return 0;
      // A queued Agents prompt keeps its pictures offline until they are
      // uploaded to the host.
      final Set<String>? agents = await agentsPaths();
      if (agents == null) return 0;

      final Set<String> voice = <String>{};
      final Set<String> images = <String>{
        for (final String p in agents)
          if (ImageStorageService.isOfflinePath(p)) p,
      };
      for (final r in mine) {
        final Object? path = r.sendPayload['voicePath'];
        if (path is String && path.isNotEmpty) voice.add(pathKey(path));
        final String text = jsonEncode(r.sendPayload);
        for (final m in ImageStorageService.offlinePathPattern.allMatches(
          text,
        )) {
          images.add(m.group(0)!);
        }
      }

      final DateTime cutoff = now().subtract(grace);
      for (final f in await voiceFiles(userId)) {
        if (voice.contains(pathKey(f.path)) || f.modified.isAfter(cutoff)) {
          continue;
        }
        await deleteVoice(f.path);
        deleted++;
      }
      for (final f in await imageFiles(userId)) {
        if (images.contains(f.path) || f.modified.isAfter(cutoff)) continue;
        await deleteImage(f.path);
        deleted++;
      }
      _swept.add(userId);
      if (kDebugMode && deleted > 0) {
        debugPrint('[OfflineFileSweeper] deleted $deleted orphan file(s)');
      }
    } catch (e) {
      if (kDebugMode) debugPrint('[OfflineFileSweeper] sweep failed: $e');
    }
    return deleted;
  }
}
