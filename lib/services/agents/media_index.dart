/// Everything the agents have handed over, in one place.
///
/// A thread holds its own files and pictures, and until now that was the only
/// way to find them: open the conversation, scroll back, hope. The Media tab
/// asks a different question — "what do I have" — and no store could answer it,
/// because chuk's media services are stubs here (Agents keeps blobs local and
/// sandbox files in the encrypted bucket, neither of which is a list).
///
/// So this index is built from the rows themselves, in the one place they are
/// already decrypted: when a thread is committed. It is a small, persisted list
/// of references — never the bytes.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/services/chat_storage_service.dart';

/// What kind of thing an entry points at.
///
/// A [page] is a document the agent keeps and rewrites (`chat_document`,
/// docs/PAGES.md). It is one entry per agent and page id, whatever the number
/// of versions the agent sent: the newest version wins.
enum MediaKind { image, file, page }

/// The mime type the host stamps on a document delivery.
const String kDocumentMime = 'application/vnd.cowork.document+json';

/// One thing an agent handed over.
@immutable
class MediaEntry {
  const MediaEntry({
    required this.kind,
    required this.reference,
    required this.name,
    required this.threadKey,
    this.mime = '',
    this.sizeBytes,
    this.at,
    this.pageId,
    this.pageKind,
    this.version,
  });

  /// The index key of a page: one per thread (= agent) and page id.
  static String pageReference(String threadKey, String pageId) =>
      'page:$threadKey/$pageId';

  final MediaKind kind;

  /// For a page: its id in the agent's store, its document kind (`markdown`,
  /// `html`, `table`, `bar_chart`, `text`) and the newest version seen.
  final String? pageId;
  final String? pageKind;
  final int? version;

  /// Where the bytes are: a `cowork://blob/<id>` URL for a picture, the storage
  /// path of the encrypted object for a sandbox file.
  final String reference;

  final String name;
  final String threadKey;
  final String mime;
  final int? sizeBytes;
  final DateTime? at;

  Map<String, dynamic> toJson() => <String, dynamic>{
    'kind': kind.name,
    'ref': reference,
    'name': name,
    'thread': threadKey,
    if (mime.isNotEmpty) 'mime': mime,
    if (sizeBytes != null) 'size': sizeBytes,
    if (at != null) 'at': at!.toIso8601String(),
    if (pageId != null) 'page': pageId,
    if (pageKind != null) 'pkind': pageKind,
    if (version != null) 'v': version,
  };

  static MediaEntry? fromJson(Object? value) {
    if (value is! Map) return null;
    final String reference = '${value['ref'] ?? ''}';
    if (reference.isEmpty) return null;
    final MediaKind kind = switch ('${value['kind']}') {
      'image' => MediaKind.image,
      'page' => MediaKind.page,
      _ => MediaKind.file,
    };
    // A document delivery indexed as a file before pages existed. It is not a
    // file the user can open as one; the next scan of its thread adds it back
    // as a page.
    if (kind == MediaKind.file && '${value['mime']}' == kDocumentMime) {
      return null;
    }
    return MediaEntry(
      kind: kind,
      reference: reference,
      name: '${value['name'] ?? ''}',
      threadKey: '${value['thread'] ?? ''}',
      mime: '${value['mime'] ?? ''}',
      sizeBytes: value['size'] is int ? value['size'] as int : null,
      at: DateTime.tryParse('${value['at'] ?? ''}'),
      pageId: value['page'] is String ? value['page'] as String : null,
      pageKind: value['pkind'] is String ? value['pkind'] as String : null,
      version: value['v'] is int ? value['v'] as int : null,
    );
  }
}

/// The newest snapshot of the page [pageId] in [rows], or null.
///
/// Every version the agent writes arrives as one more file block carrying the
/// whole document, so the page is the block with the highest version.
Map<String, dynamic>? latestPageIn(
  List<Map<String, dynamic>> rows,
  String pageId,
) {
  Map<String, dynamic>? best;
  for (final Map<String, dynamic> row in rows) {
    for (final Object? block in contentBlocksOf(row)) {
      if (block is! Map) continue;
      final Object? artifact = block['sandboxArtifact'];
      if (artifact is! Map) continue;
      final Object? raw = artifact['document'];
      if (raw is! Map || '${raw['id']}' != pageId) continue;
      final Map<String, dynamic> doc = Map<String, dynamic>.from(raw);
      final Object? rawVersion = doc['version'];
      final num version = rawVersion is num ? rawVersion : 0;
      final Object? rawBest = best?['version'];
      final num bestVersion = rawBest is num ? rawBest : -1;
      if (version >= bestVersion) best = doc;
    }
  }
  return best;
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

class MediaIndex extends ChangeNotifier {
  MediaIndex();

  static final MediaIndex instance = MediaIndex();

  static const String _prefsKey = 'cowork_media_index_v1';

  /// Keyed by reference, so the same file indexed twice is one entry.
  final Map<String, MediaEntry> _entries = <String, MediaEntry>{};
  bool _loaded = false;

  bool get loaded => _loaded;

  /// Newest first. [kind] null returns everything.
  List<MediaEntry> entries({MediaKind? kind}) {
    final List<MediaEntry> list = _entries.values
        .where((MediaEntry entry) => kind == null || entry.kind == kind)
        .toList();
    list.sort((MediaEntry a, MediaEntry b) {
      final DateTime? left = a.at;
      final DateTime? right = b.at;
      if (left == null && right == null) return 0;
      if (left == null) return 1;
      if (right == null) return -1;
      return right.compareTo(left);
    });
    return list;
  }

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? raw = prefs.getString(_prefsKey);
      if (raw == null || raw.isEmpty) return;
      final Object? decoded = jsonDecode(raw);
      if (decoded is! List) return;
      for (final Object? item in decoded) {
        final MediaEntry? entry = MediaEntry.fromJson(item);
        if (entry != null) _entries[entry.reference] = entry;
      }
      notifyListeners();
    } catch (_) {
      // An unreadable index is rebuilt from the next commit, not repaired.
    }
  }

  /// Read the threads this device already holds, once per thread.
  ///
  /// The live path only fires when a thread is committed, so everything that
  /// arrived before this index existed would be invisible. Its own pending set,
  /// deliberately: hanging the backfill off the preview store's meant a thread
  /// that already had a preview line was never read for its files.
  Future<void> ensureFor(Iterable<String> threadKeys) async {
    for (final String key in threadKeys) {
      if (key.isEmpty || _scanned.contains(key)) continue;
      _scanned.add(key);
      try {
        final StoredChat? chat = await ChatStorageService.loadFullChat(key);
        final List<ChatMessage>? messages = chat?.messagesOrNull;
        if (messages == null || messages.isEmpty) continue;
        noteRows(key, messages.map((ChatMessage m) => m.toJson()).toList());
      } catch (_) {
        // A thread that cannot be read contributes nothing.
      }
    }
  }

  /// Threads already read, so a rebuild does not read them again.
  final Set<String> _scanned = <String>{};

  /// Take every picture and every file out of [rows] and remember where they
  /// are. Rows are the stored chat rows of [threadKey].
  void noteRows(String threadKey, List<Map<String, dynamic>> rows) {
    var added = 0;
    for (final Map<String, dynamic> row in rows) {
      final DateTime? at = DateTime.tryParse('${row['timestamp'] ?? ''}');
      for (final Object? image
          in (row['images'] as List? ?? const <Object?>[])) {
        final String reference = '$image';
        if (!reference.startsWith('cowork://blob/')) continue;
        if (_entries.containsKey(reference)) continue;
        _entries[reference] = MediaEntry(
          kind: MediaKind.image,
          reference: reference,
          name: reference.split('/').last,
          threadKey: threadKey,
          mime: 'image/*',
          at: at,
        );
        added++;
      }
      for (final Object? block in contentBlocksOf(row)) {
        if (block is! Map) continue;
        final Object? artifact = block['sandboxArtifact'];
        if (artifact is! Map) continue;
        final Object? document = artifact['document'];
        if (document is Map) {
          if (_notePage(threadKey, document, at)) added++;
          continue;
        }
        if ('${artifact['mime']}' == kDocumentMime) continue;
        final String reference = '${artifact['storagePath'] ?? ''}';
        if (reference.isEmpty || _entries.containsKey(reference)) continue;
        final String mime = '${artifact['mime'] ?? ''}';
        _entries[reference] = MediaEntry(
          kind: mime.startsWith('image/') ? MediaKind.image : MediaKind.file,
          reference: reference,
          name: '${artifact['filename'] ?? reference.split('/').last}',
          threadKey: threadKey,
          mime: mime,
          sizeBytes: artifact['sizeBytes'] is int
              ? artifact['sizeBytes'] as int
              : null,
          at: at,
        );
        added++;
      }
    }
    if (added == 0) return;
    notifyListeners();
    unawaited(_persist());
  }

  /// Index one page snapshot. True when the index changed: a page seen for
  /// the first time, or a newer version of one already known.
  bool _notePage(
    String threadKey,
    Map<Object?, Object?> document,
    DateTime? at,
  ) {
    final String id = '${document['id'] ?? ''}';
    if (id.isEmpty) return false;
    final String reference = MediaEntry.pageReference(threadKey, id);
    final Object? rawVersion = document['version'];
    final int version = rawVersion is num ? rawVersion.toInt() : 0;
    final MediaEntry? known = _entries[reference];
    if (known != null && (known.version ?? 0) >= version) return false;
    final String title = '${document['title'] ?? ''}'.trim();
    final Object? rawStamp = document['updated_at'];
    // Seconds since the epoch, in DateTime's range; anything else (a
    // millisecond stamp, NaN) counts as no stamp instead of throwing.
    final double? stamp =
        rawStamp is num && rawStamp.isFinite && rawStamp > 0 && rawStamp < 8.64e12
        ? rawStamp.toDouble()
        : null;
    _entries[reference] = MediaEntry(
      kind: MediaKind.page,
      reference: reference,
      name: title.isEmpty ? id : title,
      threadKey: threadKey,
      mime: kDocumentMime,
      at: stamp != null
          ? DateTime.fromMillisecondsSinceEpoch((stamp * 1000).round())
          : at ?? known?.at,
      pageId: id,
      pageKind: '${document['kind'] ?? 'markdown'}',
      version: version,
    );
    return true;
  }

  /// The page behind [entry], read from its thread on this device.
  ///
  /// The index holds references, never bodies; the body is in the thread's
  /// stored rows, which every device that holds the thread has.
  static Future<Map<String, dynamic>?> loadPage(MediaEntry entry) async {
    final String? id = entry.pageId;
    if (id == null) return null;
    final StoredChat? chat = await ChatStorageService.loadFullChat(
      entry.threadKey,
    );
    final List<ChatMessage>? messages = chat?.messagesOrNull;
    if (messages == null || messages.isEmpty) return null;
    return latestPageIn(
      messages.map((ChatMessage m) => m.toJson()).toList(),
      id,
    );
  }

  Future<void> _persist() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _prefsKey,
        jsonEncode(<Map<String, dynamic>>[
          for (final MediaEntry entry in _entries.values) entry.toJson(),
        ]),
      );
    } catch (_) {
      // Losing the index costs a rebuild, nothing else.
    }
  }

  @visibleForTesting
  void clearForTest() {
    _entries.clear();
    _scanned.clear();
    _loaded = false;
  }
}
