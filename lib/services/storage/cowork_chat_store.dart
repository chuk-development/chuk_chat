/// The CoWork write path into chuk_chat's chat storage.
///
/// chuk_chat keeps a chat in three places: the in-memory map
/// ([ChatStorageState.chatsById]), the plaintext SQLite cache
/// ([LocalChatCacheService]) and the encrypted Supabase row. Its own write
/// path ([ChatStorageCrud.saveChat] / `updateChat`) is built for a chat the
/// device authored: `saveChat` INSERTs and refuses a duplicate, `updateChat`
/// UPDATEs and refuses a missing row, and both refuse to run without a
/// signed-in user and an unlocked encryption key.
///
/// A CoWork thread is different. The host owns the transcript
/// (docs/PRODUCT_PHILOSOPHY.md) and replays it; the app receives a complete
/// or delta copy and must store it — whether or not the cloud is reachable
/// right now, whether or not the row already exists on another device. So
/// this store does a host-authoritative REPLACE:
///
/// 1. memory first, synchronously — the thread paints from it at once;
/// 2. the SQLite cache (survives a restart, no key needed);
/// 3. the encrypted Supabase row, UPSERT on `(user_id, id)`, best-effort.
///
/// ## The outbox (bead cowork-hyg)
///
/// Step 3 can be impossible for a while: no encryption key yet (the key is
/// derived at password login, and a restored session has none until then),
/// no network, or the table not created. A thread that gets no further turn
/// would then never reach Supabase, and a reinstall would lose it. So every
/// thread whose cloud copy is behind its local copy is DIRTY: its key is
/// held in memory and persisted in the same SQLite file (the `kv_cache`
/// table chuk_chat's cache already has, key `cowork.cloud_outbox.<user>`).
/// [flushOutbox] pushes the local copy of every dirty thread to the cloud —
/// on sign-in, every 30 s (the bootstrap's timer, in step with
/// `ChatSyncService`), and after any successful write. A dirty thread is
/// also shielded from the sync: it sits in [ChatStorageState.savingChats]
/// (chuk_chat's own "do not merge over this" set), the facade drops it from
/// the sync's merge batches, and the facade refuses to remove it locally
/// when the sync finds no cloud row for it. Local data is never overwritten
/// by an older cloud picture and never thrown away before it was uploaded.
///
/// Reads go through the verbatim chuk_chat modules unchanged:
/// [ChatStorageService.loadFullChat] is cache-first, and `ChatSyncService`
/// pulls rows written by another device. Both see exactly the rows this
/// store writes, because it uses the same payload shape
/// (`{"v": kChatPayloadVersion, "messages": [...]}`), the same cache row
/// builder and the same table.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:cowork/models/chat_message.dart';
import 'package:cowork/models/content_block.dart';
import 'package:cowork/models/stored_chat.dart';
import 'package:cowork/services/chat_storage_crud.dart' show ChatStorageCrud;
import 'package:cowork/services/chat_storage_mutations.dart'
    show kChatPayloadVersion, saveTitlesToCache;
import 'package:cowork/services/chat_storage_state.dart';
import 'package:cowork/services/encryption_service.dart';
import 'package:cowork/services/local_chat_cache_service.dart';
import 'package:cowork/services/supabase_service.dart';

/// The Supabase table CoWork threads live in. Same columns and RLS as
/// chuk_chat's `encrypted_chats`, but `id` is `text` (a session key is not a
/// UUID) and the primary key is `(user_id, id)`. See docs/SUPABASE_SCHEMA.md.
const String kCoworkChatsTable = 'cowork_chats';

/// Prefix of the per-session replay cursor key in SharedPreferences. Mirrors
/// `kReplayCursorPrefix` in `cowork_replay_loader.dart`; duplicated so this
/// file does not depend on the loader.
const String _kReplayCursorPrefix = 'cowork.replay_cursor.';

/// Prefix of the per-user outbox key in the SQLite `kv_cache` table.
const String kCloudOutboxPrefix = 'cowork.cloud_outbox.';

/// Signature of the cloud upsert. Injectable so the store is testable with no
/// Supabase client. Returns the row as the server stored it (`created_at`,
/// `updated_at`), or null when the write could not be made.
typedef CoworkCloudUpsert =
    Future<Map<String, dynamic>?> Function(
      String userId,
      Map<String, dynamic> row,
    );

class CoworkChatStore {
  CoworkChatStore._();

  /// Session keys this store has written. Used to spot a thread the sync
  /// removed from local state, so its replay cursor can be dropped.
  static final Set<String> _owned = <String>{};

  /// One write chain per session, so a slow cloud write can never be
  /// overtaken by a later, newer one for the same thread.
  static final Map<String, Future<void>> _chains = <String, Future<void>>{};

  /// The outbox: session key → `updated_at` (ISO 8601) of the local copy
  /// that still has to reach the cloud. Loaded per user from SQLite.
  static final Map<String, String> _dirty = <String, String>{};
  static String? _dirtyUser;
  static Future<void>? _outboxLoad;

  /// One chain for the outbox, so a flush never overlaps another flush and a
  /// mark never races a flush's clear.
  static Future<void> _outboxChain = Future<void>.value();

  static StreamSubscription<String?>? _removalWatch;

  /// Test seams.
  @visibleForTesting
  static String? Function()? userIdProvider;
  @visibleForTesting
  static CoworkCloudUpsert? cloudUpsert;
  @visibleForTesting
  static Future<void> Function(String userId, Map<String, dynamic> row)?
  localCacheWriter;
  @visibleForTesting
  static Future<Map<String, dynamic>?> Function(String userId, String id)?
  localCacheReader;
  @visibleForTesting
  static Future<bool> Function()? keyLoader;
  @visibleForTesting
  static Future<String> Function(String plaintext)? encryptor;
  @visibleForTesting
  static Future<String?> Function(String key)? outboxRead;
  @visibleForTesting
  static Future<void> Function(String key, String value)? outboxWrite;
  @visibleForTesting
  static Future<void> Function(String key)? outboxDelete;

  // ---------------------------------------------------------------------------
  // Public API
  // ---------------------------------------------------------------------------

  /// Replaces the whole transcript of [sessionKey] with [rows] — the raw
  /// `List<Map>` row shape the imported chat screen persists.
  ///
  /// Memory is updated before this returns its future (the caller may paint
  /// at once); the SQLite and cloud writes run in the background, in order,
  /// and never throw. Returns the stored chat, or null when [rows] hold no
  /// readable message.
  ///
  /// [createdAt], [updatedAt], [isStarred] and [customName] let a migration
  /// carry a thread over with its own metadata; a live write leaves them
  /// unset and keeps what is known (or "now").
  static Future<StoredChat?> replaceThread(
    String sessionKey,
    List<Map<String, dynamic>> rows, {
    DateTime? createdAt,
    DateTime? updatedAt,
    bool? isStarred,
    String? customName,
  }) async {
    final messages = _decode(rows);
    // Documents have their own host lifetime. A transcript delta/compaction may
    // omit their original file event, but must not erase an already saved copy.
    final retained = _documentSnapshots(
      ChatStorageState.chatsById[sessionKey]?.messages ?? [],
    );
    final incoming = _documentSnapshots(messages);
    for (final entry in retained.entries) {
      final current = incoming[entry.key];
      if (current == null ||
          _documentVersion(current) < _documentVersion(entry.value)) {
        messages.add(ChatMessage.fromJson(_documentRow(entry.value)));
      }
    }
    if (messages.isEmpty) return null;

    final existing = ChatStorageState.chatsById[sessionKey];
    final now = DateTime.now();
    final resolvedName = _normalized(customName ?? existing?.customName);
    final title =
        resolvedName ?? ChatStorageCrud.extractTitleFromMessages(messages);

    final chat = StoredChat(
      id: sessionKey,
      messages: messages,
      createdAt: createdAt ?? existing?.createdAt ?? now,
      updatedAt: updatedAt ?? now,
      isStarred: isStarred ?? existing?.isStarred ?? false,
      title: title.isNotEmpty ? title : null,
      customName: resolvedName,
      assistantId: existing?.assistantId,
    );

    ChatStorageState.chatsById[sessionKey] = chat;
    ChatStorageState.notifyChanges(sessionKey);
    _owned.add(sessionKey);
    _watchRemovals();

    final userId = _currentUserId();
    if (userId == null) {
      // Not signed in (or no Supabase at all, as in a unit test): memory is
      // all there is. Nothing is lost — the host replays on the next open.
      return chat;
    }

    final payloadJson = _payloadJson(messages, resolvedName);

    _enqueue(sessionKey, () async {
      await _writeLocalCache(userId, chat, payloadJson);
      // The local copy is newer than the cloud from this moment on. Mark it
      // before the attempt: a crash mid-write then still flushes later.
      await _markDirty(userId, sessionKey, chat.updatedAt ?? now);
      final ok = await _pushToCloud(
        userId,
        id: sessionKey,
        payloadJson: payloadJson,
        title: title,
        updatedAt: chat.updatedAt ?? now,
      );
      if (ok) await _clearDirty(userId, sessionKey);
    });
    return chat;
  }

  /// Store a full host read without depending on a separate file-event replay.
  /// After the await, use the current transcript so concurrent live turns survive.
  static Future<void> saveDocumentSnapshot(
    String sessionKey,
    Map<String, dynamic> document,
  ) async {
    if (document['session_key'] != sessionKey ||
        (!document.containsKey('rows') && !document.containsKey('text'))) {
      return;
    }
    await loadThread(sessionKey);
    final current = ChatStorageState.chatsById[sessionKey];
    final known = _documentSnapshots(
      current?.messages ?? [],
    )['${document['id']}'];
    if (known != null &&
        _documentVersion(known) >= _documentVersion(document)) {
      return;
    }
    await replaceThread(sessionKey, [
      for (final message in current?.messages ?? <ChatMessage>[])
        message.toJson(),
      _documentRow(document),
    ]);
  }

  static num _documentVersion(Map<String, dynamic> document) =>
      document['version'] as num? ?? 0;

  static Map<String, Map<String, dynamic>> _documentSnapshots(
    List<ChatMessage> messages,
  ) {
    final documents = <String, Map<String, dynamic>>{};
    for (final message in messages) {
      try {
        final blocks = jsonDecode(message.contentBlocks ?? '[]');
        for (final block in (blocks as List).whereType<Map>()) {
          final raw = block['sandboxArtifact']?['document'];
          if (raw is! Map) continue;
          final doc = Map<String, dynamic>.from(raw);
          final id = '${doc['id']}';
          if (!documents.containsKey(id) ||
              _documentVersion(doc) > _documentVersion(documents[id]!)) {
            documents[id] = doc;
          }
        }
      } catch (_) {
        /* Legacy message without structured content. */
      }
    }
    return documents;
  }

  static Map<String, dynamic> _documentRow(Map<String, dynamic> doc) => {
    'sender': 'ai',
    'text': '',
    'contentBlocks': jsonEncode([
      ContentBlock.sandboxArtifact(
        SandboxArtifactPayload(
          storagePath:
              'cowork://document/${Uri.encodeComponent('${doc['id']}')}',
          filename: '${doc['id']}.json',
          mime: 'application/vnd.cowork.document+json',
          sizeBytes: utf8.encode(jsonEncode(doc)).length,
          document: doc,
        ),
      ).toJson(),
    ]),
  };

  /// Reads a thread: memory when it is fully loaded there, else chuk_chat's
  /// cache-first `loadFullChat` (SQLite, then the cloud) when a user is
  /// signed in. With no Supabase session at all (a widget test, a signed-out
  /// app) memory is all there is, so that is what comes back — upstream would
  /// throw before its own memory check.
  static Future<StoredChat?> loadThread(String chatId) async {
    final existing = ChatStorageState.chatsById[chatId];
    if (existing != null && existing.isFullyLoaded) return existing;
    if (_currentUserId() == null) return existing;
    try {
      return await ChatStorageCrud.loadFullChat(chatId) ?? existing;
    } catch (error) {
      if (kDebugMode) debugPrint('[cowork-chat-store] load failed: $error');
      return existing;
    }
  }

  /// True when this device holds a copy of [sessionKey]: fully loaded in
  /// memory, or a SQLite row with a payload. Cheap — no cloud, no full read
  /// of the payload into the model. The replay loader uses it to tell "the
  /// host sent nothing new" from "the host sent nothing new AND I have
  /// nothing": the second case means the cursor lies and a full replay is
  /// due. With no signed-in user memory is all there is.
  static Future<bool> hasThread(String sessionKey) async {
    final inMemory = ChatStorageState.chatsById[sessionKey];
    if (inMemory != null && inMemory.isFullyLoaded) return true;
    final userId = _currentUserId();
    if (userId == null) return false;
    try {
      final read = localCacheReader ?? LocalChatCacheService.loadById;
      final row = await read(userId, sessionKey);
      final payload = row?['payload'];
      return payload is String && payload.isNotEmpty;
    } catch (_) {
      // No SQLite on this platform (a widget test): memory was the only
      // local copy, and it does not hold the thread.
      return false;
    }
  }

  /// True when chuk_chat's cloud-backed entry points can run at all: the
  /// Supabase client exists. They check the user themselves.
  static bool get cloudAvailable =>
      userIdProvider != null || SupabaseService.isInitialized;

  /// True when the local copy of [sessionKey] has not reached the cloud yet.
  static bool isDirty(String sessionKey) => _dirty.containsKey(sessionKey);

  /// The threads waiting for a cloud write, for the facade and for tests.
  static Set<String> get dirtyThreads => Set<String>.unmodifiable(_dirty.keys);

  /// Pushes every dirty thread's local copy to the cloud. Safe to call at any
  /// time and from anywhere: it is serialised, it needs a signed-in user and
  /// a key (otherwise it returns at once and the threads stay dirty), and a
  /// thread whose own write chain is running is left to that chain.
  /// Completes when this flush is done.
  static Future<void> flushOutbox() {
    final userId = _currentUserId();
    if (userId == null) return Future<void>.value();
    return _runOnOutbox(() => _flush(userId));
  }

  /// The write chain for [sessionKey], for a test that wants to await it.
  @visibleForTesting
  static Future<void> pending(String sessionKey) =>
      _chains[sessionKey] ?? Future<void>.value();

  /// Test seam.
  @visibleForTesting
  static Future<void> reset() async {
    for (final chain in _chains.values.toList()) {
      try {
        await chain;
      } catch (_) {}
    }
    try {
      await _outboxChain;
    } catch (_) {}
    _chains.clear();
    _owned.clear();
    for (final id in _dirty.keys) {
      ChatStorageState.savingChats.remove(id);
    }
    _dirty.clear();
    _dirtyUser = null;
    _outboxLoad = null;
    _outboxChain = Future<void>.value();
    await _removalWatch?.cancel();
    _removalWatch = null;
    userIdProvider = null;
    cloudUpsert = null;
    localCacheWriter = null;
    localCacheReader = null;
    keyLoader = null;
    encryptor = null;
    outboxRead = null;
    outboxWrite = null;
    outboxDelete = null;
  }

  // ---------------------------------------------------------------------------
  // Write chains
  // ---------------------------------------------------------------------------

  static void _enqueue(String sessionKey, Future<void> Function() work) {
    final previous = _chains[sessionKey] ?? Future<void>.value();
    late final Future<void> next;
    next = previous
        .then((_) => work())
        .catchError((Object error) {
          if (kDebugMode) debugPrint('[cowork-chat-store] $sessionKey: $error');
        })
        .whenComplete(() {
          if (identical(_chains[sessionKey], next)) _chains.remove(sessionKey);
        });
    _chains[sessionKey] = next;
  }

  static Future<void> _runOnOutbox(Future<void> Function() work) {
    final next = _outboxChain.then((_) => work()).catchError((Object error) {
      if (kDebugMode) debugPrint('[cowork-chat-store] outbox: $error');
    });
    _outboxChain = next;
    return next;
  }

  static Future<void> _writeLocalCache(
    String userId,
    StoredChat chat,
    String payloadJson,
  ) async {
    final row = LocalChatCacheService.buildPlaintextRow(
      id: chat.id,
      payload: payloadJson,
      createdAt: chat.createdAt.toIso8601String(),
      isStarred: chat.isStarred,
      updatedAt: chat.updatedAt?.toIso8601String(),
      title: chat.title,
    );
    try {
      final writer = localCacheWriter ?? LocalChatCacheService.upsert;
      await writer(userId, row);
    } catch (error) {
      // No support directory (a widget test), a locked file: the cache only
      // buys the next launch a warm start. Memory already has the thread.
      if (kDebugMode) {
        debugPrint('[cowork-chat-store] cache write failed: $error');
      }
    }
  }

  /// One encrypted upsert. Returns true when the server took the row. Never
  /// throws; a false leaves the thread dirty for the outbox.
  static Future<bool> _pushToCloud(
    String userId, {
    required String id,
    required String payloadJson,
    required String title,
    required DateTime updatedAt,
  }) async {
    if (!await _ensureKey()) {
      if (kDebugMode) {
        debugPrint('[cowork-chat-store] no encryption key; $id stays local');
      }
      return false;
    }
    try {
      final encrypt = encryptor ?? EncryptionService.encrypt;
      final encryptedPayload = await encrypt(payloadJson);
      final encryptedTitle = title.isNotEmpty ? await encrypt(title) : null;
      final row = <String, dynamic>{
        'id': id,
        'user_id': userId,
        'encrypted_payload': encryptedPayload,
        'encrypted_title': ?encryptedTitle,
        'updated_at': updatedAt.toUtc().toIso8601String(),
      };
      final upsert = cloudUpsert ?? _supabaseUpsert;
      final stored = await upsert(userId, row);
      if (stored == null) return false;
      _adoptServerTimestamps(id, stored);
      // The sidebar title cache is what paints the next launch's list before
      // any network; keep it in step with the row we just made durable.
      unawaited(_saveTitles(userId));
      return true;
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[cowork-chat-store] cloud write failed: $error');
      }
      return false;
    }
  }

  static Future<Map<String, dynamic>?> _supabaseUpsert(
    String userId,
    Map<String, dynamic> row,
  ) async {
    final stored = await SupabaseService.client
        .from(kCoworkChatsTable)
        .upsert(row, onConflict: 'user_id,id')
        .select('id, created_at, updated_at, is_starred')
        .single()
        .timeout(const Duration(seconds: 15));
    return stored;
  }

  /// The server's `created_at` / `updated_at` win over the local guesses, so
  /// the sync's "is the cloud newer?" check compares like with like.
  static void _adoptServerTimestamps(String id, Map<String, dynamic> stored) {
    final current = ChatStorageState.chatsById[id];
    if (current == null) return;
    final createdAt = DateTime.tryParse('${stored['created_at']}');
    final updatedAt = DateTime.tryParse('${stored['updated_at']}');
    if (createdAt == null && updatedAt == null) return;
    ChatStorageState.chatsById[id] = StoredChat(
      id: current.id,
      messages: current.isFullyLoaded ? current.messages : null,
      createdAt: createdAt ?? current.createdAt,
      updatedAt: updatedAt ?? current.updatedAt,
      isStarred: (stored['is_starred'] as bool?) ?? current.isStarred,
      title: current.title,
      customName: current.customName,
      keyVersion: current.keyVersion,
      isLocked: current.isLocked,
      assistantId: current.assistantId,
    );
  }

  static Future<void> _saveTitles(String userId) async {
    try {
      await saveTitlesToCache(
        userId,
        ChatStorageState.chatsById.values.toList(),
      );
    } catch (_) {
      // Title cache is a convenience for the next launch only.
    }
  }

  // ---------------------------------------------------------------------------
  // The outbox
  // ---------------------------------------------------------------------------

  static String _outboxKey(String userId) => '$kCloudOutboxPrefix$userId';

  /// Loads the persisted outbox for [userId] once per user. A thread in it
  /// goes straight into `savingChats` so the sync leaves it alone from the
  /// first tick.
  static Future<void> _loadOutbox(String userId) {
    if (_dirtyUser == userId && _outboxLoad != null) return _outboxLoad!;
    _dirtyUser = userId;
    _dirty.clear();
    return _outboxLoad = () async {
      try {
        final read = outboxRead ?? LocalChatCacheService.kvGet;
        final raw = await read(_outboxKey(userId));
        if (raw == null || raw.isEmpty) return;
        final decoded = jsonDecode(raw);
        if (decoded is! Map) return;
        for (final entry in decoded.entries) {
          final key = entry.key;
          if (key is! String || key.isEmpty) continue;
          _dirty[key] = '${entry.value}';
          ChatStorageState.savingChats.add(key);
        }
      } catch (error) {
        // No SQLite (a widget test): the outbox lives in memory for this
        // process, which still covers "the key arrived after the replay".
        if (kDebugMode) {
          debugPrint('[cowork-chat-store] outbox load failed: $error');
        }
      }
    }();
  }

  static Future<void> _persistOutbox(String userId) async {
    try {
      if (_dirty.isEmpty) {
        final delete = outboxDelete ?? LocalChatCacheService.kvDelete;
        await delete(_outboxKey(userId));
      } else {
        final write = outboxWrite ?? LocalChatCacheService.kvSet;
        await write(_outboxKey(userId), jsonEncode(_dirty));
      }
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[cowork-chat-store] outbox save failed: $error');
      }
    }
  }

  static Future<void> _markDirty(
    String userId,
    String sessionKey,
    DateTime updatedAt,
  ) => _runOnOutbox(() async {
    await _loadOutbox(userId);
    _dirty[sessionKey] = updatedAt.toIso8601String();
    ChatStorageState.savingChats.add(sessionKey);
    await _persistOutbox(userId);
  });

  static Future<void> _clearDirty(String userId, String sessionKey) =>
      _runOnOutbox(() async {
        await _loadOutbox(userId);
        if (_dirty.remove(sessionKey) == null) return;
        ChatStorageState.savingChats.remove(sessionKey);
        await _persistOutbox(userId);
      });

  /// Runs inside the outbox chain.
  static Future<void> _flush(String userId) async {
    await _loadOutbox(userId);
    if (_dirty.isEmpty) return;
    if (!await _ensureKey()) return;

    for (final id in _dirty.keys.toList()) {
      // A running write chain for this thread will push the newest copy and
      // clear the flag itself; pushing here too could only be older.
      if (_chains.containsKey(id)) continue;

      final copy = await _localCopy(userId, id);
      if (copy == null) {
        // Nothing local to upload: the thread is gone on this device. The
        // flag would otherwise shield a ghost forever.
        _dirty.remove(id);
        ChatStorageState.savingChats.remove(id);
        continue;
      }

      final ok = await _pushToCloud(
        userId,
        id: id,
        payloadJson: copy.payloadJson,
        title: copy.title,
        updatedAt: copy.updatedAt,
      );
      if (ok) {
        _dirty.remove(id);
        ChatStorageState.savingChats.remove(id);
      }
    }
    await _persistOutbox(userId);
  }

  /// The newest local copy of a thread: memory when fully loaded there, else
  /// the SQLite row.
  static Future<_LocalCopy?> _localCopy(String userId, String id) async {
    final inMemory = ChatStorageState.chatsById[id];
    if (inMemory != null && inMemory.isFullyLoaded) {
      final customName = _normalized(inMemory.customName);
      final title =
          customName ??
          inMemory.title ??
          ChatStorageCrud.extractTitleFromMessages(inMemory.messages);
      return _LocalCopy(
        payloadJson: _payloadJson(inMemory.messages, customName),
        title: title,
        updatedAt: inMemory.updatedAt ?? inMemory.createdAt,
      );
    }
    try {
      final read = localCacheReader ?? LocalChatCacheService.loadById;
      final row = await read(userId, id);
      final payload = row?['payload'];
      if (payload is! String || payload.isEmpty) return null;
      return _LocalCopy(
        payloadJson: payload,
        title: (row!['title'] as String?) ?? '',
        updatedAt:
            DateTime.tryParse('${row['updated_at']}') ??
            DateTime.tryParse('${row['created_at']}') ??
            DateTime.now(),
      );
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[cowork-chat-store] cache read failed: $error');
      }
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  static String _payloadJson(List<ChatMessage> messages, String? customName) =>
      jsonEncode(<String, dynamic>{
        'v': kChatPayloadVersion,
        'customName': ?customName,
        'messages': messages.map((m) => m.toJson()).toList(),
      });

  static Future<bool> _ensureKey() async {
    if (keyLoader != null) return keyLoader!();
    if (EncryptionService.hasKey) return true;
    try {
      return await EncryptionService.tryLoadKey();
    } catch (_) {
      return false;
    }
  }

  static String? _currentUserId() {
    if (userIdProvider != null) return userIdProvider!();
    if (!SupabaseService.isInitialized) return null;
    try {
      return SupabaseService.auth.currentUser?.id;
    } catch (_) {
      return null;
    }
  }

  /// If the cloud sync removes a thread from local state (the row is gone on
  /// the server), the replay cursor for it must go too: otherwise the next
  /// open asks the host for a delta on top of a transcript the app no longer
  /// holds, and the thread paints only its newest messages. Dropping the
  /// cursor makes the next replay a full one. The host stays the truth.
  static void _watchRemovals() {
    _removalWatch ??= ChatStorageState.changes.listen((String? id) {
      final ids = id == null ? _owned.toList() : <String>[id];
      for (final key in ids) {
        if (!_owned.contains(key)) continue;
        if (ChatStorageState.chatsById.containsKey(key)) continue;
        _owned.remove(key);
        unawaited(_dropCursor(key));
      }
    });
  }

  static Future<void> _dropCursor(String sessionKey) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('$_kReplayCursorPrefix$sessionKey');
      if (kDebugMode) {
        debugPrint('[cowork-chat-store] $sessionKey removed; cursor dropped');
      }
    } catch (_) {
      // No prefs: there was no cursor to drop.
    }
  }

  static List<ChatMessage> _decode(List<Map<String, dynamic>> rows) {
    final out = <ChatMessage>[];
    for (final row in rows) {
      // The imported screen writes `sender`; chuk_chat's payload writes
      // `role`. A row with neither is not a message at all (the model would
      // read it as an empty user turn), so it is dropped; the host can
      // replay the real one.
      if (row['sender'] is! String && row['role'] is! String) continue;
      try {
        out.add(ChatMessage.fromJson(row));
      } catch (_) {
        // A row the model cannot read is dropped; the host can replay it.
      }
    }
    return out;
  }

  static String? _normalized(String? value) {
    final trimmed = value?.trim();
    if (trimmed == null || trimmed.isEmpty) return null;
    return trimmed;
  }
}

class _LocalCopy {
  const _LocalCopy({
    required this.payloadJson,
    required this.title,
    required this.updatedAt,
  });

  final String payloadJson;
  final String title;
  final DateTime updatedAt;
}
