/// The Agents write path into chuk_chat's chat storage.
///
/// chuk_chat keeps a chat in three places: the in-memory map
/// ([ChatStorageState.chatsById]), the plaintext SQLite cache
/// ([LocalChatCacheService]) and the encrypted Supabase row. Its own write
/// path ([ChatStorageCrud.saveChat] / `updateChat`) is built for a chat the
/// device authored: `saveChat` INSERTs and refuses a duplicate, `updateChat`
/// UPDATEs and refuses a missing row, and both refuse to run without a
/// signed-in user and an unlocked encryption key.
///
/// A Agents thread is different. The host owns the transcript
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
/// Only Agents threads come here ([ChatOrigin.isAgentsThread]); a chuk_chat
/// chat keeps upstream's INSERT/UPDATE of `encrypted_chats`.
///
/// ## Reads (the cloud half)
///
/// chuk_chat's sync, sidebar and preload read `encrypted_chats` only, so they
/// never see a row this store writes to [kAgentsChatsTable]. This store reads
/// its own table, as the standalone Agents app did:
///
/// * [loadThread] is memory, then the SQLite row, then the `cowork_chats` row
///   (decrypted, then cached). A new device paints a thread from the cloud
///   without waiting for a host replay.
/// * [pullFromCloud] is the Agents half of chuk_chat's 30 s poll: it compares
///   `updated_at` per thread and brings every newer cloud copy into SQLite
///   (and into memory when the thread is there). A dirty thread, a thread
///   with a write in flight and a thread just deleted are never overwritten.
///
/// The payload shape is chuk_chat's (`{"v": kChatPayloadVersion,
/// "messages": [...]}`) and the cache row builder is chuk_chat's.
///
/// ## Delete and password change
///
/// [deleteThread] removes the `cowork_chats` row (not `encrypted_chats`), the
/// SQLite row and the outbox entry. [snapshotCloudThreads] and
/// [reencryptCloudThreads] let a password change re-seal every
/// `cowork_chats` row with the new key, beside chuk_chat's `reencryptChats`.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/models/chat_message.dart';
import 'package:chuk_chat/services/agents/agents_queued_marks.dart';
import 'package:chuk_chat/models/content_block.dart';
import 'package:chuk_chat/models/stored_chat.dart';
import 'package:chuk_chat/services/chat_storage_crud.dart' show ChatStorageCrud;
import 'package:chuk_chat/services/chat_storage_sync.dart'
    show deserializePayloadIsolate;
import 'package:chuk_chat/services/chat_storage_mutations.dart'
    show kChatPayloadVersion, saveTitlesToCache;
import 'package:chuk_chat/services/chat_storage_state.dart';
import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/local_chat_cache_service.dart';
import 'package:chuk_chat/services/storage/chat_origin.dart';
import 'package:chuk_chat/services/supabase_service.dart';

/// The Supabase table Agents threads live in. Same columns and RLS as
/// chuk_chat's `encrypted_chats`, but `id` is `text` (a session key is not a
/// UUID) and the primary key is `(user_id, id)`. See docs/SUPABASE_SCHEMA.md.
const String kAgentsChatsTable = 'cowork_chats';

/// Prefix of the per-session replay cursor key in SharedPreferences. Mirrors
/// `kReplayCursorPrefix` in `agents_replay_loader.dart`; duplicated so this
/// file does not depend on the loader.
const String _kReplayCursorPrefix = 'cowork.replay_cursor.';

/// Prefix of the per-user outbox key in the SQLite `kv_cache` table.
const String kCloudOutboxPrefix = 'cowork.cloud_outbox.';

/// Where the last signed-in user id is remembered, so the local cache can be
/// READ before Supabase has its session back (bead cowork-91pn). It is only a
/// read key: nothing is written to the cloud under it, and it is replaced the
/// moment a real session names a user.
const String kLastCacheUserKey = 'cowork.last_user_id';

/// Signature of the cloud upsert. Injectable so the store is testable with no
/// Supabase client. Returns the row as the server stored it (`created_at`,
/// `updated_at`), or null when the write could not be made.
typedef AgentsCloudUpsert = Future<Map<String, dynamic>?> Function(
  String userId,
  Map<String, dynamic> row,
);

/// Signature of a cloud read of [kAgentsChatsTable]. [ids] null reads every
/// row of the user. [columns] is the Supabase select list. [from] and [to]
/// (both inclusive, set together) ask for one page of the rows ordered by id,
/// like Supabase's `.range(from, to)`.
typedef AgentsCloudSelect = Future<List<Map<String, dynamic>>> Function(
  String userId, {
  List<String>? ids,
  required String columns,
  int? from,
  int? to,
});

/// The columns of a full `cowork_chats` row.
const String _kFullColumns =
    'id, encrypted_payload, encrypted_title, created_at, is_starred, updated_at';

/// One Agents thread of the cloud, decrypted: what a password change re-seals.
@immutable
class AgentsCloudThread {
  const AgentsCloudThread({
    required this.id,
    required this.payloadJson,
    this.title,
  });

  final String id;
  final String payloadJson;
  final String? title;
}

class AgentsChatStore {
  AgentsChatStore._();

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
  static AgentsCloudUpsert? cloudUpsert;
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
  @visibleForTesting
  static AgentsCloudSelect? cloudSelect;

  /// Rows per page of the id list. Supabase caps one response at its
  /// `max-rows` setting (1000 by default), so the list is read in pages.
  @visibleForTesting
  static int idPageSize = 1000;
  @visibleForTesting
  static Future<void> Function(
    String userId,
    String id,
    Map<String, dynamic> values,
  )?
  cloudUpdate;
  @visibleForTesting
  static Future<void> Function(String userId, String id)? cloudDelete;
  @visibleForTesting
  static Future<String> Function(String ciphertext)? decryptor;
  @visibleForTesting
  static Future<List<Map<String, dynamic>>> Function(String userId)?
  localMetaReader;
  @visibleForTesting
  static Future<void> Function(String userId, String id)? localCacheDeleter;

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
    ChatOrigin.claimAgentsThread(sessionKey);
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
    // The queue mark has the same problem as a document, for a different
    // reason: the imported chat screen persists ITS OWN list of messages, and
    // that list never carried a `queueId`. A prompt that is waiting in the
    // outbox would lose its mark — and with it the Retry button — the next
    // time the screen saved anything. So a mark the store already holds is
    // carried across a write that does not mention it. It is taken off
    // explicitly by [AgentsQueuedMarks.clearMark] once the prompt goes out.
    _retainQueueMarks(
      ChatStorageState.chatsById[sessionKey]?.messagesOrNull ?? const [],
      messages,
    );
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

  /// Copies a still-open queue mark from [stored] onto the matching row of
  /// [incoming], in place. Matched on the prompt text, because that is the only
  /// thing the imported screen and the store agree on for a user row.
  static void _retainQueueMarks(
    List<ChatMessage> stored,
    List<ChatMessage> incoming,
  ) {
    final marks = AgentsQueuedMarks.marksIn(stored);
    if (marks.isEmpty) return;
    for (int i = 0; i < incoming.length; i++) {
      final message = incoming[i];
      if (!AgentsQueuedMarks.isUserRole(message.role)) continue;
      if (message.queueId != null && message.queueId!.isNotEmpty) continue;
      final mark = marks[message.text];
      if (mark == null) continue;
      incoming[i] = ChatMessage.fromJson({
        ...message.toJson(),
        'status': mark['status'],
        'queueId': mark['queueId'],
      });
    }
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

  /// Whose rows the local cache is read under.
  ///
  /// THE one answer. [loadThread], [hasThread] and — through [loadThread] —
  /// `AgentsReplayLoader._cachedRows` all go through this, and all three fail
  /// the same way when it is null. That is not tidiness, it is the safety
  /// property: if `hasThread` said yes on one id while the row read used
  /// another, the replay's cursor guard would splice a delta onto the wrong
  /// base, `saveChat` REPLACES, and the history would be gone for good — the
  /// host never re-sends below the cursor.
  ///
  /// A live Supabase session wins and is remembered. When there is none yet —
  /// a cold start paints long before gotrue has its session back off disk —
  /// the id the last session left behind is used, so the thread the user was
  /// in paints from SQLite with no network at all.
  static Future<String?> resolveCacheUserId() async {
    final live = _currentUserId();
    if (live != null) {
      if (_rememberedUserId != live) unawaited(rememberUser(live));
      return live;
    }
    if (_rememberedUserId != null) return _rememberedUserId;
    if (_rememberedLoaded) return null;
    await _loadRememberedUser();
    return _rememberedUserId;
  }

  /// Writes the read key for the next cold start. Called when a session signs
  /// in (`AgentsChatStorageBootstrap._signedIn`).
  static Future<void> rememberUser(String userId) async {
    if (userId.isEmpty) return;
    _rememberedUserId = userId;
    _rememberedLoaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(kLastCacheUserKey, userId);
    } catch (_) {
      // No preferences: this launch still reads the id from memory.
    }
  }

  static String? _rememberedUserId;
  static bool _rememberedLoaded = false;

  static Future<void> _loadRememberedUser() async {
    if (_rememberedLoaded) return;
    _rememberedLoaded = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(kLastCacheUserKey);
      if (stored != null && stored.isNotEmpty) _rememberedUserId = stored;
    } catch (_) {
      // No preferences (a widget test): there is no remembered id.
    }
  }

  /// Reads a thread: memory when it is fully loaded there, else the SQLite
  /// row, else — with a live session — the `cowork_chats` row. The SQLite row
  /// alone is read when the session is not back yet but this device
  /// remembers whose rows these are. With no id at all (a widget test, a
  /// never-signed-in app) memory is all there is, so that is what comes back
  /// — upstream would throw before its own memory check.
  ///
  /// The cloud step reads [kAgentsChatsTable], never `encrypted_chats`:
  /// chuk_chat's `loadFullChat` would look for the thread in the wrong table
  /// and a new device would only get it back through a host replay.
  static Future<StoredChat?> loadThread(String chatId) async {
    final existing = ChatStorageState.chatsById[chatId];
    if (existing != null && existing.isFullyLoaded) return existing;
    final userId = await resolveCacheUserId();
    if (userId == null) return existing;
    final cached = await _loadFromLocalCache(userId, chatId, existing);
    if (cached != null) return cached;
    if (_currentUserId() != userId) return existing;
    return await _loadFromCloud(userId, chatId, existing) ?? existing;
  }

  /// The cloud half of [loadThread]: one `cowork_chats` row, decrypted, put
  /// in memory and in the SQLite cache. Null when there is no readable row.
  static Future<StoredChat?> _loadFromCloud(
    String userId,
    String chatId,
    StoredChat? existing,
  ) async {
    if (!cloudAvailable) return null;
    if (ChatStorageState.wasRecentlyDeleted(chatId)) return null;
    try {
      if (!await _ensureKey()) return null;
      final rows = await _select(
        userId,
        ids: <String>[chatId],
        columns: _kFullColumns,
      );
      if (rows.isEmpty) return null;
      final decoded = await _decodeCloudRow(rows.first);
      if (decoded == null) return null;
      // A replay may have written the thread while the row was in flight.
      // That copy is the newer one; keep it.
      final current = ChatStorageState.chatsById[chatId];
      if (current != null && current.isFullyLoaded) return current;
      if (isDirty(chatId) || _chains.containsKey(chatId)) return current;
      // Deleted while the row was in flight: do not bring it back.
      if (ChatStorageState.wasRecentlyDeleted(chatId)) return null;
      final chat = decoded.chat(existing);
      ChatStorageState.chatsById[chatId] = chat;
      ChatStorageState.notifyChanges(chatId);
      _owned.add(chatId);
      _watchRemovals();
      await _writeLocalCache(userId, chat, decoded.payloadJson);
      return chat;
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[agents-chat-store] cloud load failed: $error');
      }
      return null;
    }
  }

  /// Brings every Agents thread whose `cowork_chats` row is newer than this
  /// device's copy into the SQLite cache — and into memory when the thread is
  /// there already, so an open thread repaints. The Agents half of
  /// chuk_chat's 30 s poll, which reads `encrypted_chats` only.
  ///
  /// Never overwrites local data that is newer: a dirty thread (its local
  /// copy has not reached the cloud), a thread with a write in flight and a
  /// thread deleted a moment ago are skipped. Needs a signed-in user and the
  /// key; without them it returns at once. Never throws. Returns the ids it
  /// brought in.
  static Future<List<String>> pullFromCloud() async {
    if (!ChatOrigin.agentsEnabled) return const <String>[];
    final userId = _currentUserId();
    if (userId == null || !cloudAvailable) return const <String>[];
    try {
      if (!await _ensureKey()) return const <String>[];
      await _loadOutbox(userId);
      final listed = await _selectIdList(userId);
      if (listed.isEmpty) return const <String>[];

      final local = await _localTimestamps(userId);
      final wanted = <String>[];
      for (final row in listed) {
        final id = row['id'];
        if (id is! String || id.isEmpty) continue;
        if (_skipPull(id)) continue;
        final cloudAt = DateTime.tryParse('${row['updated_at']}');
        final localAt = local[id];
        if (localAt == null || (cloudAt != null && cloudAt.isAfter(localAt))) {
          wanted.add(id);
        }
      }
      if (wanted.isEmpty) return const <String>[];

      final pulled = <String>[];
      for (final row in await _selectBatched(userId, wanted)) {
        final decoded = await _decodeCloudRow(row);
        if (decoded == null) continue;
        final id = decoded.id;
        // Checked again: a replay may have written the thread meanwhile.
        if (_skipPull(id)) continue;
        final existing = ChatStorageState.chatsById[id];
        final chat = decoded.chat(existing);
        if (existing != null) {
          ChatStorageState.chatsById[id] = chat;
          ChatStorageState.notifyChanges(id);
          _owned.add(id);
          _watchRemovals();
        }
        await _writeLocalCache(userId, chat, decoded.payloadJson);
        pulled.add(id);
      }
      return pulled;
    } catch (error) {
      if (kDebugMode) debugPrint('[agents-chat-store] pull failed: $error');
      return const <String>[];
    }
  }

  static bool _skipPull(String id) =>
      !ChatOrigin.isAgentsThread(id) ||
      isDirty(id) ||
      _chains.containsKey(id) ||
      ChatStorageState.wasRecentlyDeleted(id);

  /// The newest `updated_at` this device holds per thread: the SQLite row,
  /// or memory when that is newer.
  static Future<Map<String, DateTime>> _localTimestamps(String userId) async {
    final out = <String, DateTime>{};
    try {
      final read = localMetaReader ?? LocalChatCacheService.loadMeta;
      for (final row in await read(userId)) {
        final id = row['id'];
        if (id is! String) continue;
        final at =
            DateTime.tryParse('${row['updated_at']}') ??
            DateTime.tryParse('${row['created_at']}');
        if (at != null) out[id] = at;
      }
    } catch (_) {
      // No SQLite (a widget test): memory is all this device holds.
    }
    for (final chat in ChatStorageState.chatsById.values) {
      if (!chat.isFullyLoaded) continue;
      final at = chat.updatedAt ?? chat.createdAt;
      final known = out[chat.id];
      if (known == null || at.isAfter(known)) out[chat.id] = at;
    }
    return out;
  }

  /// Decrypts one full `cowork_chats` row. Null when it cannot be read.
  static Future<_CloudRow?> _decodeCloudRow(Map<String, dynamic> row) async {
    final id = row['id'];
    final cipher = row['encrypted_payload'];
    if (id is! String || cipher is! String || cipher.isEmpty) return null;
    try {
      final decrypt = decryptor ?? EncryptionService.decryptInBackground;
      final payloadJson = await decrypt(cipher);
      final decoded = deserializePayloadIsolate(payloadJson);
      final messages = <ChatMessage>[
        for (final m in decoded.messages) ChatMessage.fromJson(m),
      ];
      if (messages.isEmpty) return null;
      return _CloudRow(
        id: id,
        row: row,
        payloadJson: payloadJson,
        messages: messages,
        customName: _normalized(decoded.customName),
      );
    } catch (error) {
      if (kDebugMode) {
        // The type only: a parse error quotes the decrypted input.
        debugPrint(
          '[agents-chat-store] cannot read cloud row $id: '
          '${error.runtimeType}',
        );
      }
      return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Delete
  // ---------------------------------------------------------------------------

  /// Deletes an Agents thread: its `cowork_chats` row, its SQLite row, its
  /// outbox entry and its memory copy. The chuk_chat counterpart
  /// (`ChatStorageCrud.deleteChat`) deletes from `encrypted_chats`, which
  /// never holds the thread, and left the cloud row behind.
  ///
  /// As upstream: the cloud row goes first, and a failed cloud delete throws
  /// before anything local is touched. With no signed-in user (or no Supabase
  /// at all) there is no cloud row to delete, and memory is all there is.
  static Future<void> deleteThread(String sessionKey) async {
    final userId = _currentUserId();
    if (userId != null && cloudAvailable) {
      // A write in flight would upsert the row again after the delete.
      await pending(sessionKey);
      final delete = cloudDelete ?? _supabaseDelete;
      // On the outbox chain: a flush that already read this thread's local
      // copy would otherwise upsert the row again after the delete. The
      // error still reaches the caller, so a failed delete keeps the thread.
      final done = Completer<void>();
      unawaited(
        _runOnOutbox(() async {
          try {
            await delete(userId, sessionKey);
            done.complete();
          } catch (error, stack) {
            done.completeError(error, stack);
          }
        }),
      );
      await done.future;
    }

    ChatStorageState.markDeleted(sessionKey);
    ChatStorageState.chatsById.remove(sessionKey);
    ChatStorageState.savingChats.remove(sessionKey);
    ChatStorageState.pendingSaves.remove(sessionKey);
    if (ChatStorageState.selectedChatId == sessionKey) {
      ChatStorageState.selectedChatId = null;
    }
    ChatStorageState.notifyChanges(sessionKey);

    if (userId == null) {
      _dirty.remove(sessionKey);
      return;
    }
    await _runOnOutbox(() async {
      await _loadOutbox(userId);
      if (_dirty.remove(sessionKey) != null) await _persistOutbox(userId);
    });
    try {
      final deleteLocal = localCacheDeleter ?? LocalChatCacheService.delete;
      await deleteLocal(userId, sessionKey);
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[agents-chat-store] cache delete failed: $error');
      }
    }
    unawaited(_saveTitles(userId));
  }

  static Future<void> _supabaseDelete(String userId, String id) async {
    await SupabaseService.client
        .from(kAgentsChatsTable)
        .delete()
        .eq('user_id', userId)
        .eq('id', id)
        .timeout(const Duration(seconds: 10));
  }

  // ---------------------------------------------------------------------------
  // Password change
  // ---------------------------------------------------------------------------

  /// Every `cowork_chats` row of the signed-in user, decrypted with the key
  /// that is loaded NOW. Taken before a password change rotates the key; the
  /// rotation then re-seals it with [reencryptCloudThreads]. A row the
  /// current key cannot open is left out: it cannot be re-sealed either.
  ///
  /// Throws when the table cannot be read: a password change that went on
  /// would leave every Agents cloud copy sealed with a key nobody has.
  static Future<List<AgentsCloudThread>> snapshotCloudThreads() async {
    final userId = _currentUserId();
    if (userId == null || !cloudAvailable) return const <AgentsCloudThread>[];
    // The ids first (small), then the full rows in batches: one request for
    // every payload can outgrow the timeout and block the password change.
    final listed = await _selectIdList(userId);
    final ids = <String>[
      for (final row in listed)
        if (row['id'] is String) row['id'] as String,
    ];
    final rows = await _selectBatched(userId, ids, strict: true);
    final decrypt = decryptor ?? EncryptionService.decryptInBackground;
    final out = <AgentsCloudThread>[];
    for (final row in rows) {
      final id = row['id'];
      final cipher = row['encrypted_payload'];
      if (id is! String || cipher is! String || cipher.isEmpty) continue;
      try {
        final payloadJson = await decrypt(cipher);
        String? title;
        final titleCipher = row['encrypted_title'];
        if (titleCipher is String && titleCipher.isNotEmpty) {
          try {
            title = await decrypt(titleCipher);
          } catch (_) {
            title = null;
          }
        }
        out.add(
          AgentsCloudThread(id: id, payloadJson: payloadJson, title: title),
        );
      } catch (error) {
        if (kDebugMode) {
          debugPrint('[agents-chat-store] snapshot skips $id: $error');
        }
      }
    }
    return out;
  }

  /// Seals every thread of [snapshot] with the key that is loaded NOW and
  /// writes it back to `cowork_chats`. Called by the password change inside
  /// the key rotation (with the new key), and on rollback (with the old
  /// one). Throws on the first failed write, so the rotation rolls back.
  static Future<void> reencryptCloudThreads(
    List<AgentsCloudThread> snapshot,
  ) async {
    if (snapshot.isEmpty) return;
    final userId = _currentUserId();
    if (userId == null) return;
    final encrypt = encryptor ?? EncryptionService.encrypt;
    final update = cloudUpdate ?? _supabaseUpdate;
    for (final thread in snapshot) {
      final values = <String, dynamic>{
        'encrypted_payload': await encrypt(thread.payloadJson),
      };
      final title = thread.title;
      if (title != null && title.isNotEmpty) {
        values['encrypted_title'] = await encrypt(title);
      }
      await update(userId, thread.id, values);
    }
  }

  static Future<void> _supabaseUpdate(
    String userId,
    String id,
    Map<String, dynamic> values,
  ) async {
    await SupabaseService.client
        .from(kAgentsChatsTable)
        .update(values)
        .eq('user_id', userId)
        .eq('id', id)
        .timeout(const Duration(seconds: 15));
  }

  /// How many full rows one cloud read asks for.
  static const int _kFetchBatch = 50;

  /// Full rows for [ids], [_kFetchBatch] at a time, so one large request
  /// can neither outgrow the URL nor the timeout. A failed batch is skipped
  /// (the next pull asks again); with [strict] it throws instead.
  static Future<List<Map<String, dynamic>>> _selectBatched(
    String userId,
    List<String> ids, {
    bool strict = false,
  }) async {
    final out = <Map<String, dynamic>>[];
    for (var i = 0; i < ids.length; i += _kFetchBatch) {
      final end = i + _kFetchBatch > ids.length ? ids.length : i + _kFetchBatch;
      try {
        // The server may cap a response below the batch size. Ask again for
        // the ids that did not come back until none come back: those rows are
        // gone (deleted meanwhile), not merely cut off.
        var remaining = ids.sublist(i, end);
        while (remaining.isNotEmpty) {
          final page = await _select(
            userId,
            ids: remaining,
            columns: _kFullColumns,
          );
          if (page.isEmpty) break;
          out.addAll(page);
          final got = <Object?>{for (final row in page) row['id']};
          remaining = [
            for (final id in remaining)
              if (!got.contains(id)) id,
          ];
        }
      } catch (error) {
        if (strict) rethrow;
        if (kDebugMode) {
          debugPrint('[agents-chat-store] fetch batch failed: $error');
        }
      }
    }
    return out;
  }

  // ---------------------------------------------------------------------------
  // Pausing cloud writes (password change)
  // ---------------------------------------------------------------------------

  static bool _cloudWritesPaused = false;

  /// Stops every cloud write until [resumeCloudWrites]. A thread written
  /// meanwhile stays dirty in the outbox. Waits for the writes in flight, so
  /// nothing lands between a password change's snapshot and its re-encrypt:
  /// no newer row is overwritten by the older snapshot, and no row is sealed
  /// with the old key after the re-encrypt.
  static Future<void> pauseCloudWrites() async {
    _cloudWritesPaused = true;
    for (final chain in _chains.values.toList()) {
      try {
        await chain;
      } catch (_) {}
    }
    try {
      await _outboxChain;
    } catch (_) {}
  }

  /// Lets cloud writes run again and flushes what waited, sealed with the key
  /// that is loaded now.
  static Future<void> resumeCloudWrites() async {
    _cloudWritesPaused = false;
    await flushOutbox();
  }

  /// `id` and `updated_at` of every row of the user, read in pages of
  /// [idPageSize] until a short page. One plain read would stop at the
  /// server's row limit and leave the rest out without a word.
  static Future<List<Map<String, dynamic>>> _selectIdList(
    String userId,
  ) async {
    final out = <Map<String, dynamic>>[];
    final size = idPageSize;
    // The server may cap a page below the size asked for, so a short page is
    // not the end: advance by the rows that came back, and stop only on an
    // empty page.
    for (var from = 0; ;) {
      final page = await _select(
        userId,
        columns: 'id, updated_at',
        from: from,
        to: from + size - 1,
      );
      if (page.isEmpty) return out;
      out.addAll(page);
      from += page.length;
    }
  }

  static Future<List<Map<String, dynamic>>> _select(
    String userId, {
    List<String>? ids,
    required String columns,
    int? from,
    int? to,
  }) async {
    final hook = cloudSelect;
    if (hook != null) {
      return hook(userId, ids: ids, columns: columns, from: from, to: to);
    }
    var query = SupabaseService.client
        .from(kAgentsChatsTable)
        .select(columns)
        .eq('user_id', userId);
    if (ids != null) query = query.inFilter('id', ids);
    final rows = (from != null && to != null)
        ? await query
              .order('id', ascending: true)
              .range(from, to)
              .timeout(const Duration(seconds: 30))
        : await query.timeout(const Duration(seconds: 30));
    return rows.cast<Map<String, dynamic>>();
  }

  /// The offline half of [loadThread]: the plaintext SQLite row, decoded into
  /// the same [StoredChat] shape chuk_chat's cache path produces, and put in
  /// memory so the screen paints it. Null when there is no readable row.
  static Future<StoredChat?> _loadFromLocalCache(
    String userId,
    String chatId,
    StoredChat? existing,
  ) async {
    try {
      final read = localCacheReader ?? LocalChatCacheService.loadById;
      final row = await read(userId, chatId);
      final payload = row?['payload'];
      if (payload is! String || payload.isEmpty) return null;
      // The payload is parsed HERE, not in an isolate: this is the cold-start
      // paint path, and spawning an isolate to read one thread costs more than
      // the parse it saves. `deserializePayloadIsolate` is a pure function —
      // `deserializePayloadAsync` is only that same function behind `compute`.
      final decoded = deserializePayloadIsolate(payload);
      final messages = <ChatMessage>[
        for (final row in decoded.messages) ChatMessage.fromJson(row),
      ];
      if (messages.isEmpty) return null;
      final customName = _normalized(decoded.customName);
      final title =
          customName ??
          existing?.title ??
          ChatStorageCrud.extractTitleFromMessages(messages);
      final chat = StoredChat.fromRow(
        row!,
        messages,
        customName: customName,
        title: title.isNotEmpty ? title : null,
      );
      ChatStorageState.chatsById[chatId] = chat;
      ChatStorageState.notifyChanges(chatId);
      return chat;
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[agents-chat-store] offline load failed: $error');
      }
      return null;
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
    // The SAME id [loadThread] reads under — see [resolveCacheUserId].
    final userId = await resolveCacheUserId();
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
    _cloudWritesPaused = false;
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
    cloudSelect = null;
    idPageSize = 1000;
    cloudUpdate = null;
    cloudDelete = null;
    decryptor = null;
    localMetaReader = null;
    localCacheDeleter = null;
    _rememberedUserId = null;
    _rememberedLoaded = false;
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
          if (kDebugMode) debugPrint('[agents-chat-store] $sessionKey: $error');
        })
        .whenComplete(() {
          if (identical(_chains[sessionKey], next)) _chains.remove(sessionKey);
        });
    _chains[sessionKey] = next;
  }

  static Future<void> _runOnOutbox(Future<void> Function() work) {
    final next = _outboxChain.then((_) => work()).catchError((Object error) {
      if (kDebugMode) debugPrint('[agents-chat-store] outbox: $error');
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
        debugPrint('[agents-chat-store] cache write failed: $error');
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
    // A password change is rotating the key: stay dirty, flushed on resume.
    if (_cloudWritesPaused) return false;
    if (!await _ensureKey()) {
      if (kDebugMode) {
        debugPrint('[agents-chat-store] no encryption key; $id stays local');
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
        debugPrint('[agents-chat-store] cloud write failed: $error');
      }
      return false;
    }
  }

  static Future<Map<String, dynamic>?> _supabaseUpsert(
    String userId,
    Map<String, dynamic> row,
  ) async {
    final stored = await SupabaseService.client
        .from(kAgentsChatsTable)
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
          debugPrint('[agents-chat-store] outbox load failed: $error');
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
        debugPrint('[agents-chat-store] outbox save failed: $error');
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

      final copy = ChatStorageState.wasRecentlyDeleted(id)
          ? null
          : await _localCopy(userId, id);
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
        debugPrint('[agents-chat-store] cache read failed: $error');
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
        debugPrint('[agents-chat-store] $sessionKey removed; cursor dropped');
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

/// One decrypted `cowork_chats` row.
class _CloudRow {
  const _CloudRow({
    required this.id,
    required this.row,
    required this.payloadJson,
    required this.messages,
    required this.customName,
  });

  final String id;
  final Map<String, dynamic> row;
  final String payloadJson;
  final List<ChatMessage> messages;
  final String? customName;

  StoredChat chat(StoredChat? existing) {
    final title =
        customName ??
        existing?.title ??
        ChatStorageCrud.extractTitleFromMessages(messages);
    return StoredChat.fromRow(
      row,
      messages,
      customName: customName,
      title: title.isNotEmpty ? title : null,
      assistantId: existing?.assistantId,
    );
  }
}
