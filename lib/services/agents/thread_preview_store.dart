/// What a thread last said, so the roster can show it.
///
/// The roster line used to read "No activity yet" under every coworker, or a
/// thread title, because the list has no messages: `StoredChat.forSidebar`
/// carries titles only, and decrypting every thread to draw a list would cost a
/// disk read and a decrypt per row on every frame.
///
/// So the preview is written when the rows are already in hand — the moment the
/// replay loader commits a thread — and kept in a small map that is persisted
/// as plain preferences. It holds one short line per thread, nothing else: the
/// last line of text, who said it, and when.
///
/// The stored line is chat content, so it is truncated hard and never leaves
/// the device.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/agents/media_index.dart';

/// One thread's last line.
@immutable
class ThreadPreview {
  const ThreadPreview({required this.text, required this.fromUser, this.at});

  /// The text as it should appear in the roster, already trimmed and cut.
  final String text;

  /// True when the user wrote it. The roster prefixes those with "You: ".
  final bool fromUser;

  final DateTime? at;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'text': text,
    'user': fromUser,
    if (at != null) 'at': at!.toIso8601String(),
  };

  static ThreadPreview? fromJson(Object? value) {
    if (value is! Map) return null;
    final Object? text = value['text'];
    if (text is! String || text.isEmpty) return null;
    return ThreadPreview(
      text: text,
      fromUser: value['user'] == true,
      at: DateTime.tryParse('${value['at']}'),
    );
  }
}

/// The content blocks of a stored row.
///
/// Two shapes reach this code and both are legitimate: the chat's own rows hold
/// a list, the agents replay rows hold the SAME list as a JSON string (it goes
/// through a column that takes text). Reading only one of them is why the media
/// index and the roster preview came back empty for relayed files.
List<Object?> contentBlocksOf(Map<String, dynamic> row) {
  final Object? raw = row['contentBlocks'];
  if (raw is List) return raw;
  if (raw is String && raw.trim().isNotEmpty) {
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is List) return decoded;
    } catch (_) {
      // A row whose blocks cannot be read carries none.
    }
  }
  return const <Object?>[];
}

class ThreadPreviewStore extends ChangeNotifier {
  ThreadPreviewStore();

  static final ThreadPreviewStore instance = ThreadPreviewStore();

  static const String _prefsKey = 'agents_thread_previews_v2';

  /// The longest preview kept. A roster line shows far less; this is only the
  /// ceiling for what is written to disk.
  static const int _maxChars = 160;

  final Map<String, ThreadPreview> _previews = <String, ThreadPreview>{};
  bool _loaded = false;

  bool get loaded => _loaded;

  ThreadPreview? of(String threadKey) => _previews[threadKey];

  /// The newest preview among [threadKeys], or null when none is known.
  ThreadPreview? newestOf(Iterable<String> threadKeys) {
    ThreadPreview? best;
    for (final String key in threadKeys) {
      final ThreadPreview? candidate = _previews[key];
      if (candidate == null) continue;
      if (best == null) {
        best = candidate;
        continue;
      }
      final DateTime? a = candidate.at;
      final DateTime? b = best.at;
      if (a == null) continue;
      if (b == null || a.isAfter(b)) best = candidate;
    }
    return best;
  }

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString(_prefsKey);
      if (raw == null || raw.isEmpty) return;
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map) return;
      decoded.forEach((Object? key, Object? value) {
        final ThreadPreview? preview = ThreadPreview.fromJson(value);
        if (key is String && preview != null) _previews[key] = preview;
      });
      notifyListeners();
    } catch (_) {
      // A preview is a convenience. An unreadable cache is dropped, not fixed.
    }
  }

  /// Fill in previews for threads this store has never seen, by reading what
  /// is already on disk.
  ///
  /// The live path ([noteRows]) only fires when a thread is committed, so after
  /// a restart the roster would sit blank until each coworker says something.
  /// This reads the stored thread once per key and then never again: the answer
  /// is kept in the map and persisted.
  Future<void> ensureFor(Iterable<String> threadKeys) async {
    for (final String key in threadKeys) {
      if (key.isEmpty || _previews.containsKey(key) || _pending.contains(key)) {
        continue;
      }
      _pending.add(key);
      try {
        final StoredChat? chat = await ChatStorageService.loadFullChat(key);
        final List<ChatMessage>? messages = chat?.messagesOrNull;
        if (messages == null || messages.isEmpty) continue;
        final List<Map<String, dynamic>> rows = messages
            .map((ChatMessage m) => m.toJson())
            .toList();
        noteRows(key, rows);
        // The same read fills the media index, so the Media tab works after a
        // restart without a second pass over every thread.
        MediaIndex.instance.noteRows(key, rows);
      } catch (_) {
        // A thread that cannot be read leaves its line empty.
      }
    }
  }

  /// Keys already looked up, so a roster rebuild does not read the same thread
  /// again on every frame.
  final Set<String> _pending = <String>{};

  /// Take the last readable line out of [rows] and remember it for [threadKey].
  ///
  /// [rows] are the stored chat rows (`role`/`text`, or the agents shape
  /// `sender`/`text`). A row with no text of its own — a file, an image — is
  /// described instead of skipped, because "sent you a file" is exactly what
  /// the roster should say.
  void noteRows(String threadKey, List<Map<String, dynamic>> rows) {
    for (int i = rows.length - 1; i >= 0; i--) {
      final Map<String, dynamic> row = rows[i];
      final bool fromUser =
          row['role'] == 'user' ||
          row['sender'] == 'user' ||
          row['isUser'] == true;
      final String text = _lineOf(row);
      if (text.isEmpty) continue;
      final ThreadPreview preview = ThreadPreview(
        text: text.length > _maxChars ? text.substring(0, _maxChars) : text,
        fromUser: fromUser,
        at: DateTime.tryParse('${row['timestamp'] ?? row['at'] ?? ''}'),
      );
      final ThreadPreview? current = _previews[threadKey];
      if (current != null &&
          current.text == preview.text &&
          current.fromUser == preview.fromUser) {
        return;
      }
      _previews[threadKey] = preview;
      notifyListeners();
      unawaited(_persist());
      return;
    }
  }

  /// One row as one line, or empty when the row says nothing a reader wants.
  static String _lineOf(Map<String, dynamic> row) {
    final Object? text = row['text'] ?? row['content'];
    if (text is String && text.trim().isNotEmpty) {
      return _flatten(text);
    }
    final List<Object?> blocks = contentBlocksOf(row);
    if (blocks.isNotEmpty) {
      for (final Object? block in blocks.reversed) {
        if (block is! Map) continue;
        final Object? blockText = block['text'];
        if (blockText is String && blockText.trim().isNotEmpty) {
          return _flatten(blockText);
        }
        final Object? artifact = block['sandboxArtifact'];
        if (artifact is Map && artifact['filename'] is String) {
          return '${artifact['filename']}';
        }
      }
    }
    final Object? attachments = row['attachments'];
    if (attachments is List && attachments.isNotEmpty) {
      return '${attachments.first}';
    }
    return '';
  }

  /// A chat line is markdown over several lines; a roster line is one line of
  /// plain text. The markers are removed, not rendered: `**Endstand**` in a
  /// list row reads as a typo, not as emphasis.
  static String _flatten(String text) {
    String line = text;
    line = line.replaceAll(RegExp(r'```[\s\S]*?```'), ' ');
    line = line.replaceAllMapped(
      RegExp(r'`([^`]*)`'),
      (Match m) => m.group(1) ?? '',
    );
    line = line.replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), ' ');
    line = line.replaceAllMapped(
      RegExp(r'\[([^\]]+)\]\([^)]*\)'),
      (Match m) => m.group(1) ?? '',
    );
    line = line.replaceAll(RegExp(r'^\s{0,3}#{1,6}\s*', multiLine: true), '');
    line = line.replaceAll(RegExp(r'^\s{0,3}>\s?', multiLine: true), '');
    line = line.replaceAll(
      RegExp(r'^\s{0,3}([-*+]|\d+\.)\s+', multiLine: true),
      '',
    );
    line = line.replaceAll(RegExp(r'\*\*|__|~~'), '');
    line = line.replaceAll(RegExp(r'(?<!\w)[*_](?!\s)'), '');
    return line.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  Future<void> _persist() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _prefsKey,
        jsonEncode(<String, dynamic>{
          for (final MapEntry<String, ThreadPreview> entry in _previews.entries)
            entry.key: entry.value.toJson(),
        }),
      );
    } catch (_) {
      // Losing the cache costs one empty roster line after a restart.
    }
  }
}
