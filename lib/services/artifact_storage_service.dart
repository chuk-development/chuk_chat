// lib/services/artifact_storage_service.dart
// MERGE NOTE: the Agents build carried a stub of this file (reads empty, writes
// throw) because the Agents host delivered files as sandbox artifacts into the
// local blob store and had no artifact database. Upstream's Supabase-backed
// artifact store is kept; drop it again deliberately if Agents threads must
// stop writing artifact rows.
//
// Handle and row id. The AI names an artifact with a slug ("todo-app"): the
// handle. Everything outside this service addresses artifacts by it — UI,
// prompt context, tool calls, `<artifact>` tags, pending flushers, chat
// messages. The `artifacts` row is keyed by a random UUID instead
// ([ArtifactDocument.rowId]); handle, title and language travel sealed in
// `encrypted_meta` (see encrypted_meta.dart). A legacy row, written before
// the seal, still has the handle as its id and plaintext metadata; it is
// re-sealed and re-keyed when it is loaded, and by [resealLegacyRows].
//
// Only row ids go into query filters. A handle is resolved to its row id on
// the client (caches, then the handle index), so it never shows up in a
// request URL or a server log.
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import 'package:chuk_chat/models/artifact.dart';
import 'package:chuk_chat/services/artifact_diff_engine.dart';
import 'package:chuk_chat/services/diagnostics_log_service.dart';
import 'package:chuk_chat/services/encrypted_meta.dart';
import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/utils/json_helpers.dart';

/// What the service knows about one `artifacts` row without its content:
/// enough to resolve a handle to the row and to re-seal the row. [stamp] is
/// the row's `updated_at` exactly as read with these values (null when
/// unknown); a re-seal only lands while the row still carries it.
typedef ArtifactRowRef = ({
  String rowId,
  String handle,
  String chatId,
  String title,
  String? language,
  DateTime updatedAt,
  String? stamp,
});

class ArtifactStorageService {
  const ArtifactStorageService._();

  // Pending-flush registry — editors register a "flush" callback keyed by
  // artifactId so the chat-send / system-prompt-build path can force any
  // in-memory edits to be persisted before the AI sees the artifact body.
  // Keeps the data flow simple (no global event bus) and lifecycle-safe:
  // editors call `unregisterPendingFlusher` from their `dispose`.
  static final Map<String, Future<void> Function()> _pendingFlushers =
      <String, Future<void> Function()>{};

  /// Registers a callback that flushes pending in-memory edits for
  /// [artifactId] to storage. The chat-send pipeline calls
  /// [flushPendingEdits] right before assembling the request payload so the
  /// AI sees the latest scene. Safe to call repeatedly — the latest
  /// callback wins.
  static void registerPendingFlusher(
    String artifactId,
    Future<void> Function() flush,
  ) {
    final id = artifactId.trim();
    if (id.isEmpty) return;
    _pendingFlushers[id] = flush;
  }

  /// Removes a previously registered flusher. Editors must call this from
  /// `dispose` so we don't hold dead callbacks across chat switches.
  /// Idempotent — no-op if [artifactId] was never registered or if a newer
  /// flusher has already replaced ours.
  static void unregisterPendingFlusher(
    String artifactId, [
    Future<void> Function()? expected,
  ]) {
    final id = artifactId.trim();
    if (id.isEmpty) return;
    if (expected == null) {
      _pendingFlushers.remove(id);
      return;
    }
    final current = _pendingFlushers[id];
    if (identical(current, expected)) {
      _pendingFlushers.remove(id);
    }
  }

  /// Invokes every registered flusher and awaits them all. Used right
  /// before the chat-send pipeline serializes artifacts into the AI
  /// request payload so live editor scenes (e.g. excalidraw mid-drag) are
  /// committed to the latest snapshot. Per-flusher errors are swallowed
  /// so a stuck editor cannot block the user's send.
  static Future<void> flushPendingEdits() async {
    if (_pendingFlushers.isEmpty) return;
    // Snapshot the values to a list so a flusher that unregisters itself
    // mid-flight doesn't mutate the iterable we're walking.
    final flushers = List<Future<void> Function()>.of(
      _pendingFlushers.values,
    );
    for (final flush in flushers) {
      try {
        // Cap each flusher at 5s — a hung Supabase call (offline, race
        // with a freshly-created artifact, etc.) must never block the
        // outgoing chat request. Worst case the AI sees the previous
        // snapshot instead of the live one; that's recoverable, a
        // frozen chat is not.
        await flush().timeout(
          const Duration(seconds: 5),
          onTimeout: () {
            if (kDebugMode) {
              debugPrint('Pending-flush callback timed out (5s)');
            }
          },
        );
      } catch (error, stack) {
        if (kDebugMode) {
          debugPrint('Pending-flush callback failed: $error\n$stack');
        }
      }
    }
  }

  static const String _artifactsTable = 'artifacts';
  static const String _versionsTable = 'artifact_versions';
  static const String _missingSchemaMessage =
      'Artifact storage is not configured on this server yet. '
      'Please run the database migrations for artifacts.';
  static const int maxContentBytes = 500 * 1024; // 500 KB
  static final RegExp _artifactIdPattern = RegExp(r'^[A-Za-z0-9-]+$');
  static const Uuid _uuid = Uuid();

  /// Columns the handle index and the re-seal sweep read: enough to resolve
  /// a handle and to re-seal a row, never the content.
  static const String _metaColumns =
      'id, chat_id, title, language, encrypted_meta, updated_at';

  /// [_metaColumns] for a server without the `encrypted_meta` column.
  static const String _metaColumnsUnsealed =
      'id, chat_id, title, language, updated_at';

  /// PostgREST returns at most this many rows per request by default.
  static const int _pageSize = 1000;

  /// A handle that misses the index rebuilds it once, unless the index is
  /// younger than this. Covers artifacts created on another device.
  static const Duration _indexMaxAgeOnMiss = Duration(seconds: 5);

  /// A create rebuilds the index for a handle it cannot find at most this
  /// often. This device's own writes keep the index current in between; a
  /// rebuild only catches a handle created on another device meanwhile, and
  /// a rare duplicate is resolved by the newest row anyway.
  static const Duration _indexMaxAgeOnCreate = Duration(minutes: 5);

  /// How long an operation waits for the row lock before it goes ahead
  /// anyway, so one hung request cannot freeze every artifact operation.
  static const Duration _rowLockWait = Duration(seconds: 20);

  /// Selects the rows [resealLegacyRows] must touch: never sealed, or
  /// holding plaintext an old build wrote after the seal. Only the
  /// placeholder goes into the filter, never a handle or a title.
  @visibleForTesting
  static const String resealCandidateFilter =
      'encrypted_meta.is.null,'
      'title.neq.$kEncryptedPlaceholder,'
      'language.not.is.null';

  static final StreamController<void> _changesController =
      StreamController<void>.broadcast();
  static Stream<void> get changes => _changesController.stream;

  static final ValueNotifier<ArtifactDocument?> activeArtifactNotifier =
      ValueNotifier<ArtifactDocument?>(null);

  /// Controls whether the artifact panel is visible in the UI. Decoupled from
  /// activeArtifactNotifier so users can close the panel without losing the
  /// active artifact (inline card in chat can reopen it). Starts closed so
  /// that opening a chat with existing artifacts does not force the panel
  /// open without the user asking — the panel opens on explicit user action
  /// (inline-card tap) or when the AI creates/rewrites an artifact.
  static final ValueNotifier<bool> panelOpenNotifier = ValueNotifier<bool>(false);

  /// Monotonic counter fired each time the user asks to (re-)open the panel,
  /// even when `panelOpenNotifier` is already `true`. Mobile listens on this
  /// so repeated taps on a chip always reopen the modal sheet.
  static final ValueNotifier<int> openRequestNotifier = ValueNotifier<int>(0);

  /// When set, the artifact panel should open on this specific artifact +
  /// version after it loads its version list. The panel only consumes the
  /// request when its currently displayed artifact id matches `artifactId`,
  /// so a click targeting a different artifact cannot be mis-applied to the
  /// panel still showing the previous one.
  static final ValueNotifier<({String artifactId, int? version})?>
  pendingInitialOpen =
      ValueNotifier<({String artifactId, int? version})?>(null);

  /// Request the panel to open (without toggling `panelOpenNotifier`).
  /// Pins to the given version of `artifactId` once that artifact is active.
  static void requestOpen({required String artifactId, int? version}) {
    pendingInitialOpen.value = (artifactId: artifactId, version: version);
    panelOpenNotifier.value = true;
    openRequestNotifier.value = openRequestNotifier.value + 1;
  }

  static String? _activeChatId;

  /// Stable id of the assistant message currently being streamed.
  ///
  /// Set by the send pipeline when it creates the assistant placeholder so
  /// every artifact version produced during that turn (create, rewrite,
  /// inline `<artifact>` tag) is stamped with the same `message_id`. The
  /// regenerate / resend rollback uses this stamp to undo only the
  /// versions belonging to the discarded turn(s).
  ///
  /// `null` between turns. Tests and callers may set it directly when
  /// simulating a turn boundary.
  static String? currentMessageId;
  static String? _cacheUserId;
  static bool _artifactStorageAvailable = true;
  static bool _missingSchemaLogged = false;
  static final Map<String, List<ArtifactDocument>> _cacheByChatId =
      <String, List<ArtifactDocument>>{};

  /// Documents fetched one by one ([loadArtifactById], create, rewrite) for
  /// a chat whose list is not cached, keyed by row id. Kept out of
  /// [_cacheByChatId] so a partial list never stands in for a chat's full
  /// one: the next [loadArtifactsForChat] still fetches every row.
  static final Map<String, ArtifactDocument> _looseDocs =
      <String, ArtifactDocument>{};

  /// Version history, keyed by row id.
  static final Map<String, List<ArtifactVersionSnapshot>> _versionCache =
      <String, List<ArtifactVersionSnapshot>>{};

  /// Every active row of the signed-in user, keyed by row id, without
  /// content. Resolves handles that are not in the document caches. Null
  /// until first needed; kept current by this device's own writes.
  static Map<String, ArtifactRowRef>? _indexByRowId;

  /// When [_indexByRowId] was built. Null marks it stale: the next handle
  /// that misses it rebuilds it.
  static DateTime? _indexBuiltAt;

  /// Row ids this session moved (legacy id → UUID), so a copy that still
  /// carries the old one (e.g. the active document) matches its row.
  static final Map<String, String> _rowIdRemap = <String, String>{};

  /// Rows whose `encrypted_meta` could not be opened (e.g. sealed with an
  /// older key after a password change). Never re-sealed and never given
  /// fresh metadata: that would overwrite the data we cannot read.
  static final Set<String> _unreadableRowIds = <String>{};

  /// Opened envelopes, keyed by the envelope itself. Every seal has a fresh
  /// nonce, so a changed row brings a new key.
  static final Map<({String rowId, String envelope}), Map<String, dynamic>>
  _openedMeta = <({String rowId, String envelope}), Map<String, dynamic>>{};

  /// Row ids queued for, or done with, a re-seal in this session.
  static final Set<String> _resealSeen = <String>{};
  static final List<({String userId, ArtifactRowRef ref})> _resealQueue =
      <({String userId, ArtifactRowRef ref})>[];
  static bool _resealRunning = false;

  /// Set when the server has no `encrypted_meta` column (migration not
  /// applied). Re-sealing stops for the rest of the session.
  static bool _sealColumnMissing = false;

  static final Object _rowLockZoneKey = Object();
  static Future<void> _rowLockTail = Future<void>.value();
  static Object? _rowLockHolder;

  static String? get activeChatId => _activeChatId;

  static Future<void> setActiveChat(
    String? chatId, {
    bool forceRefresh = false,
  }) async {
    _activeChatId = chatId;

    if (chatId == null || chatId.isEmpty) {
      if (activeArtifactNotifier.value != null) {
        activeArtifactNotifier.value = null;
      }
      return;
    }

    final latest = await loadLatestForChat(chatId, forceRefresh: forceRefresh);
    if (_activeChatId == chatId) {
      activeArtifactNotifier.value = latest;
    }
  }

  /// Loads every active artifact owned by the signed-in user, across all
  /// chats. Used by the Media Manager to surface artifacts alongside images.
  /// Does not populate the per-chat cache to avoid cross-chat polluting it.
  static Future<List<ArtifactDocument>> listAllUserArtifacts() async {
    if (!_artifactStorageAvailable) {
      return const <ArtifactDocument>[];
    }

    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      return const <ArtifactDocument>[];
    }
    _ensureCacheForUser(user.id);

    return _withRowLock(() async {
      final List response;
      try {
        response = await SupabaseService.client
            .from(_artifactsTable)
            .select()
            .eq('user_id', user.id)
            .eq('is_active', true)
            .order('updated_at', ascending: false);
      } on PostgrestException catch (error) {
        if (_handleMissingArtifactSchema(
          error,
          operation: 'listAllUserArtifacts',
        )) {
          return const <ArtifactDocument>[];
        }
        rethrow;
      }

      final docs = await _documentsFromRows(response, userId: user.id);
      if (_cacheUserId == user.id) {
        _indexUpsert(docs);
      }
      return docs;
    });
  }

  static Future<List<ArtifactDocument>> loadArtifactsForChat(
    String chatId, {
    bool forceRefresh = false,
  }) async {
    if (!_artifactStorageAvailable) {
      return const <ArtifactDocument>[];
    }

    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      return const <ArtifactDocument>[];
    }

    _ensureCacheForUser(user.id);
    if (!forceRefresh && _cacheByChatId.containsKey(chatId)) {
      return List<ArtifactDocument>.from(_cacheByChatId[chatId]!);
    }

    return _withRowLock(() async {
      final List response;
      try {
        response = await SupabaseService.client
            .from(_artifactsTable)
            .select()
            .eq('chat_id', chatId)
            .eq('user_id', user.id)
            .eq('is_active', true)
            .order('updated_at', ascending: false);
      } on PostgrestException catch (error) {
        if (_handleMissingArtifactSchema(
          error,
          operation: 'loadArtifactsForChat',
        )) {
          return const <ArtifactDocument>[];
        }
        rethrow;
      }

      final docs = await _documentsFromRows(response, userId: user.id);
      if (_cacheUserId != user.id) {
        return docs;
      }
      _cacheByChatId[chatId] = docs;
      _looseDocs.removeWhere((_, doc) => doc.chatId == chatId);
      _indexUpsert(docs);
      return List<ArtifactDocument>.from(docs);
    });
  }

  static Future<ArtifactDocument?> loadLatestForChat(
    String chatId, {
    bool forceRefresh = false,
  }) async {
    final artifacts = await loadArtifactsForChat(
      chatId,
      forceRefresh: forceRefresh,
    );
    if (artifacts.isEmpty) return null;
    return artifacts.first;
  }

  /// Loads an artifact by its handle (what the AI and the UI use) or by its
  /// row id. The handle is resolved on the client — caches first, then the
  /// handle index — and only the row id is sent to the server.
  static Future<ArtifactDocument?> loadArtifactById(String artifactId) async {
    if (!_artifactStorageAvailable) return null;

    final key = artifactId.trim();
    if (key.isEmpty) return null;

    final user = SupabaseService.auth.currentUser;
    if (user == null) return null;
    _ensureCacheForUser(user.id);

    final cached = _findCached(key);
    if (cached != null) return cached;

    return _withRowLock(() async {
      // Another operation may have cached it while this one waited.
      final waitedFor = _findCached(key);
      if (waitedFor != null) return waitedFor;

      final ref = await _findRef(key, user.id);
      if (ref == null) return null;
      final doc = await _fetchRow(ref.rowId, user.id);
      if (doc != null) return doc;

      // The index pointed at a row that is gone, or that another device
      // re-keyed. Look once more with a fresh index.
      final fresh = await _findRef(key, user.id, rebuild: true);
      if (fresh == null || fresh.rowId == ref.rowId) return null;
      return _fetchRow(fresh.rowId, user.id);
    });
  }

  static Future<ArtifactDocument> createArtifact({
    required String chatId,
    required String artifactId,
    required String title,
    required ArtifactType type,
    required String content,
    String? language,
    String? messageId,
    String? attachmentPath,
  }) async {
    if (!_artifactStorageAvailable) {
      throw StateError(_missingSchemaMessage);
    }

    final handle = artifactId.trim();
    final user = _requireUser();
    _validateArtifactId(handle);
    _validateContentSize(content);

    return _withRowLock(() async {
      // The primary key is a random UUID now, so the database no longer
      // keeps handles unique. The check runs here, per user.
      if (await _handleTaken(handle, user.id)) {
        throw StateError(
          'Artifact "$handle" already exists. Use update or rewrite.',
        );
      }

      final rowId = _uuid.v4();
      final encrypted = await _encryptOrThrow(content);
      final now = DateTime.now().toUtc();
      final insertPayload = await _sealOrThrow(
        () => buildInsertPayload(
          rowId: rowId,
          handle: handle,
          chatId: chatId,
          userId: user.id,
          title: title,
          type: type,
          language: language,
          encryptedContent: encrypted,
          messageId: messageId,
          attachmentPath: attachmentPath,
          now: now,
        ),
      );

      final String? stamp;
      try {
        final List inserted = await SupabaseService.client
            .from(_artifactsTable)
            .insert(insertPayload)
            .select('updated_at');
        stamp = _stampOf(inserted);
      } on PostgrestException catch (error) {
        if (_isMissingMetaColumnError(error)) {
          _markSealColumnMissing(error, operation: 'createArtifact');
          throw StateError(_missingSchemaMessage);
        }
        if (_handleMissingArtifactSchema(error, operation: 'createArtifact')) {
          throw StateError(_missingSchemaMessage);
        }
        if (_isDuplicateArtifactError(error)) {
          throw StateError(
            'Artifact "$handle" already exists. Use update or rewrite.',
          );
        }
        rethrow;
      }

      try {
        await _insertVersion(
          rowId: rowId,
          chatId: chatId,
          userId: user.id,
          version: 1,
          encryptedContent: encrypted,
          createdAt: now,
          attachmentPath: attachmentPath,
          messageId: messageId,
        );
      } catch (error) {
        try {
          await SupabaseService.client
              .from(_artifactsTable)
              .delete()
              .eq('id', rowId)
              .eq('user_id', user.id);
        } catch (rollbackError) {
          unawaited(
            DiagnosticsLogService.error(
              'artifact',
              'Artifact rollback delete failed',
              data: {
                'rollbackError': rollbackError.toString(),
                'originalError': error.toString(),
              },
            ),
          );
          if (kDebugMode) {
            debugPrint(
              'Artifact rollback delete failed for row $rowId: '
              '$rollbackError (original: $error)',
            );
          }
        }
        rethrow;
      }

      final doc = ArtifactDocument(
        id: handle,
        rowId: rowId,
        chatId: chatId,
        userId: user.id,
        messageId: messageId,
        title: _titleOrHandle(title, handle),
        type: type,
        language: _cleanLanguage(language),
        content: content,
        version: 1,
        attachmentPath: attachmentPath,
        createdAt: now,
        updatedAt: now,
        updatedAtStamp: stamp,
      );

      _insertIntoCache(doc);
      _indexUpsert([doc]);
      _emitChange(doc.chatId, doc);
      // Opening the panel is reserved for AI-generated artifacts. Create is
      // only reached from the artifact_manager tool / <artifact> tag flow,
      // never from chat load — so popping the panel here is safe.
      panelOpenNotifier.value = true;
      return doc;
    });
  }

  static Future<ArtifactDocument> updateArtifactWithEdits({
    required String artifactId,
    required List<ArtifactEdit> edits,
  }) async {
    final current = await loadArtifactById(artifactId);
    if (current == null) {
      throw StateError('Artifact "$artifactId" not found.');
    }

    final newContent = ArtifactDiffEngine.applyEdits(current.content, edits);
    return rewriteArtifact(
      artifactId: artifactId,
      content: newContent,
      preserveMetadata: true,
    );
  }

  static Future<ArtifactDocument> rewriteArtifact({
    required String artifactId,
    required String content,
    String? title,
    ArtifactType? type,
    String? language,
    String? attachmentPath,
    bool preserveMetadata = false,
    bool clearAttachment = false,
  }) async {
    if (!_artifactStorageAvailable) {
      throw StateError(_missingSchemaMessage);
    }

    return _withRowLock(
      () => _rewriteLocked(
        artifactId: artifactId,
        content: content,
        title: title,
        type: type,
        language: language,
        attachmentPath: attachmentPath,
        preserveMetadata: preserveMetadata,
        clearAttachment: clearAttachment,
        retried: false,
      ),
    );
  }

  static Future<ArtifactDocument> _rewriteLocked({
    required String artifactId,
    required String content,
    required String? title,
    required ArtifactType? type,
    required String? language,
    required String? attachmentPath,
    required bool preserveMetadata,
    required bool clearAttachment,
    required bool retried,
  }) async {
    final current = await loadArtifactById(artifactId);
    if (current == null) {
      throw StateError('Artifact "$artifactId" not found.');
    }

    _validateContentSize(content);

    final nextVersion = current.version + 1;
    final now = DateTime.now().toUtc();
    final encrypted = await _encryptOrThrow(content);
    final previousEncrypted = await _encryptOrThrow(current.content);

    final resolvedTitle = preserveMetadata
        ? current.title
        : (title?.trim().isNotEmpty == true ? title!.trim() : current.title);
    final resolvedType = preserveMetadata
        ? current.type
        : (type ?? current.type);
    final resolvedLanguage = preserveMetadata
        ? current.language
        : (language?.trim().isEmpty == true
              ? null
              : (language?.trim() ?? current.language));
    final resolvedAttachment = clearAttachment
        ? null
        : (attachmentPath ?? current.attachmentPath);

    // Metadata we could not open stays as it is: sealing over it would
    // destroy the handle and title it holds.
    final keepMeta = _unreadableRowIds.contains(current.rowId);
    final storedTitle = keepMeta ? current.title : resolvedTitle;
    final storedLanguage = keepMeta ? current.language : resolvedLanguage;
    // A legacy row gets its random id with this write. Its versions follow
    // through the ON UPDATE CASCADE foreign key.
    final newRowId = !keepMeta && current.rowId == current.id
        ? _uuid.v4()
        : null;
    final targetRowId = newRowId ?? current.rowId;
    final sealed = keepMeta
        ? null
        : await _sealOrThrow(
            // Sealed for the id the row carries after this very update.
            () => sealedMetaColumns(
              rowId: targetRowId,
              handle: current.id,
              title: resolvedTitle,
              language: resolvedLanguage,
            ),
          );

    final List updateRows;
    try {
      updateRows = await SupabaseService.client
          .from(_artifactsTable)
          .update({
            'id': ?newRowId,
            'type': resolvedType.value,
            'content': encrypted,
            'version': nextVersion,
            'attachment_path': resolvedAttachment,
            'updated_at': now.toIso8601String(),
            ...?sealed,
          })
          .eq('id', current.rowId)
          .eq('user_id', current.userId)
          .select('id, updated_at');
    } on PostgrestException catch (error) {
      if (_isMissingMetaColumnError(error)) {
        _markSealColumnMissing(error, operation: 'rewriteArtifact');
        throw StateError(_missingSchemaMessage);
      }
      if (_handleMissingArtifactSchema(error, operation: 'rewriteArtifact')) {
        throw StateError(_missingSchemaMessage);
      }
      rethrow;
    }

    if (updateRows.isEmpty) {
      // The cached row id may be stale (the row was re-keyed on another
      // device). Look the handle up once more before giving up.
      if (!retried &&
          await _reloadAfterMiss(current.rowId, current.id, current.userId) !=
              null) {
        return _rewriteLocked(
          artifactId: current.id,
          content: content,
          title: title,
          type: type,
          language: language,
          attachmentPath: attachmentPath,
          preserveMetadata: preserveMetadata,
          clearAttachment: clearAttachment,
          retried: true,
        );
      }
      throw StateError(
        'Artifact "${current.id}" was not found or is no longer editable.',
      );
    }
    if (newRowId != null) {
      _applyRekey(current.rowId, newRowId);
    }

    try {
      await _insertVersion(
        rowId: targetRowId,
        chatId: current.chatId,
        userId: current.userId,
        version: nextVersion,
        encryptedContent: encrypted,
        createdAt: now,
        attachmentPath: resolvedAttachment,
      );
    } catch (error) {
      try {
        final restoredMeta = keepMeta
            ? null
            : await sealedMetaColumns(
                rowId: targetRowId,
                handle: current.id,
                title: current.title,
                language: current.language,
              );
        await SupabaseService.client
            .from(_artifactsTable)
            .update({
              'type': current.type.value,
              'content': previousEncrypted,
              'version': current.version,
              'attachment_path': current.attachmentPath,
              'updated_at': current.updatedAt.toIso8601String(),
              ...?restoredMeta,
            })
            .eq('id', targetRowId)
            .eq('user_id', current.userId);
      } catch (rollbackError) {
        unawaited(
          DiagnosticsLogService.error(
            'artifact',
            'Artifact rollback update failed',
            data: {
              'rollbackError': rollbackError.toString(),
              'originalError': error.toString(),
            },
          ),
        );
        if (kDebugMode) {
          debugPrint(
            'Artifact rollback update failed for row $targetRowId: '
            '$rollbackError (original: $error)',
          );
        }
      }
      rethrow;
    }

    final updated = ArtifactDocument(
      id: current.id,
      rowId: targetRowId,
      chatId: current.chatId,
      userId: current.userId,
      messageId: current.messageId,
      title: storedTitle,
      type: resolvedType,
      language: storedLanguage,
      content: content,
      version: nextVersion,
      attachmentPath: resolvedAttachment,
      createdAt: current.createdAt,
      updatedAt: now,
      // The trigger stamped the row; the stamp is the server's, not `now`.
      updatedAtStamp: _stampOf(updateRows),
    );

    _insertIntoCache(updated);
    _indexUpsert([updated]);
    _versionCache.remove(targetRowId);
    _emitChange(updated.chatId, updated);
    // Same reasoning as createArtifact: rewrite only runs from AI flows
    // (artifact_manager update/rewrite, <artifact> tag). Panel should pop
    // so the user sees the new version.
    panelOpenNotifier.value = true;
    return updated;
  }

  /// In-place update of the current artifact row WITHOUT bumping `version`
  /// or inserting a new `artifact_versions` snapshot. The snapshot row for
  /// the current version is replaced (or inserted, if missing) so version
  /// history stays consistent.
  ///
  /// Use this for live user edits (drag, resize, color change) where each
  /// micro-movement creating a new version would be noise. AI-driven
  /// rewrites still go through [rewriteArtifact] so the version increments
  /// and is auditable.
  ///
  /// Does NOT touch [panelOpenNotifier] — the panel is already open during
  /// edits and popping it up mid-drag would be jarring.
  static Future<ArtifactDocument> overwriteCurrentArtifact({
    required String artifactId,
    required String content,
  }) async {
    if (!_artifactStorageAvailable) {
      throw StateError(_missingSchemaMessage);
    }

    return _withRowLock(
      () => _overwriteLocked(
        artifactId: artifactId,
        content: content,
        retried: false,
      ),
    );
  }

  static Future<ArtifactDocument> _overwriteLocked({
    required String artifactId,
    required String content,
    required bool retried,
  }) async {
    final current = await loadArtifactById(artifactId);
    if (current == null) {
      throw StateError('Artifact "$artifactId" not found.');
    }

    _validateContentSize(content);

    final now = DateTime.now().toUtc();
    final encrypted = await _encryptOrThrow(content);

    final List updateRows;
    try {
      updateRows = await SupabaseService.client
          .from(_artifactsTable)
          .update({
            'content': encrypted,
            'updated_at': now.toIso8601String(),
          })
          .eq('id', current.rowId)
          .eq('user_id', current.userId)
          .eq('version', current.version)
          .select('id, updated_at');
    } on PostgrestException catch (error) {
      if (_handleMissingArtifactSchema(
        error,
        operation: 'overwriteCurrentArtifact',
      )) {
        throw StateError(_missingSchemaMessage);
      }
      rethrow;
    }

    if (updateRows.isEmpty) {
      // Either the artifact disappeared, or its version advanced (an AI
      // rewrite landed mid-edit), or its row id moved on another device.
      // Only the last case is safe to retry; otherwise the caller's
      // in-memory copy is stale — surface a clear error and let them reload.
      if (!retried) {
        final fresh = await _reloadAfterMiss(
          current.rowId,
          current.id,
          current.userId,
        );
        if (fresh != null && fresh.version == current.version) {
          return _overwriteLocked(
            artifactId: fresh.id,
            content: content,
            retried: true,
          );
        }
      }
      throw StateError(
        'Artifact "${current.id}" was updated elsewhere; reload before saving.',
      );
    }

    // Keep the per-version snapshot in sync. Try update first; if no row
    // exists for this version (older artifacts pre-dating version
    // snapshotting), fall back to insert.
    try {
      final List versionUpdateRows = await SupabaseService.client
          .from(_versionsTable)
          .update({
            'content': encrypted,
            'attachment_path': current.attachmentPath,
            'created_at': now.toIso8601String(),
          })
          .eq('artifact_id', current.rowId)
          .eq('user_id', current.userId)
          .eq('version', current.version)
          .select('id');

      if (versionUpdateRows.isEmpty) {
        await _insertVersion(
          rowId: current.rowId,
          chatId: current.chatId,
          userId: current.userId,
          version: current.version,
          encryptedContent: encrypted,
          createdAt: now,
          attachmentPath: current.attachmentPath,
        );
      }
    } on PostgrestException catch (error) {
      if (_handleMissingArtifactSchema(
        error,
        operation: 'overwriteCurrentArtifact(version sync)',
      )) {
        throw StateError(_missingSchemaMessage);
      }
      rethrow;
    }

    final updated = _stamped(
      current.copyWith(content: content, updatedAt: now),
      _stampOf(updateRows),
    );

    _insertIntoCache(updated);
    _indexUpsert([updated]);
    // Drop cached version history for this artifact — the snapshot row we
    // just rewrote in-place is stale in the cache.
    _versionCache.remove(updated.rowId);
    _emitChange(updated.chatId, updated);
    // Intentionally NOT touching panelOpenNotifier — see method doc.
    return updated;
  }

  static Future<List<ArtifactVersionSnapshot>> loadVersionHistory(
    String artifactId, {
    bool forceRefresh = false,
  }) async {
    if (!_artifactStorageAvailable) {
      return const <ArtifactVersionSnapshot>[];
    }

    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      return const <ArtifactVersionSnapshot>[];
    }
    _ensureCacheForUser(user.id);

    final cachedDoc = _findCached(artifactId.trim());
    if (!forceRefresh &&
        cachedDoc != null &&
        _versionCache.containsKey(cachedDoc.rowId)) {
      return List<ArtifactVersionSnapshot>.from(
        _versionCache[cachedDoc.rowId]!,
      );
    }

    return _withRowLock(() async {
      // Versions are keyed by row id; resolve the handle first. An id that
      // names no row of this user has no history.
      final doc = await loadArtifactById(artifactId);
      if (doc == null) {
        return const <ArtifactVersionSnapshot>[];
      }
      if (!forceRefresh && _versionCache.containsKey(doc.rowId)) {
        return List<ArtifactVersionSnapshot>.from(_versionCache[doc.rowId]!);
      }

      final List response;
      try {
        response = await SupabaseService.client
            .from(_versionsTable)
            .select()
            .eq('artifact_id', doc.rowId)
            .eq('user_id', user.id)
            .order('version', ascending: false);
      } on PostgrestException catch (error) {
        if (_handleMissingArtifactSchema(
          error,
          operation: 'loadVersionHistory',
        )) {
          return const <ArtifactVersionSnapshot>[];
        }
        rethrow;
      }

      final rows = response
          .map((row) => Map<String, dynamic>.from(row as Map))
          .toList(growable: false);

      final versions = <ArtifactVersionSnapshot>[];
      for (final row in rows) {
        final raw = row['content'] as String? ?? '';
        final content = await _decryptMaybe(raw);
        versions.add(
          ArtifactVersionSnapshot.fromMap(
            row,
            decryptedContent: content,
            artifactId: doc.id,
          ),
        );
      }

      _versionCache[doc.rowId] = versions;
      return List<ArtifactVersionSnapshot>.from(versions);
    });
  }

  /// Rebuilds [artifact_versions] from the current [artifacts] row when the
  /// snapshot chain is missing or incomplete. Idempotent — only inserts
  /// snapshots for versions not already present. Use to repair legacy
  /// artifacts that pre-date the version-snapshot feature.
  ///
  /// Behaviour:
  ///   * Loads the current artifact row.
  ///   * Reads which `version` rows already exist in `artifact_versions`.
  ///   * Inserts a snapshot for `current.version` if missing (using the
  ///     live encrypted content + attachment path).
  ///   * If NO snapshots exist at all and `current.version > 1`, also
  ///     inserts a v1 snapshot mirroring the current content. This is a
  ///     lossy approximation — the genuinely-original v1 body is
  ///     unrecoverable — and a warning is logged.
  ///
  /// Returns the number of snapshot rows inserted (0 when the chain is
  /// already healthy or the artifact doesn't exist).
  static Future<int> repairVersionChain(String artifactId) async {
    if (!_artifactStorageAvailable) return 0;
    final normalizedId = artifactId.trim();
    if (normalizedId.isEmpty) return 0;

    return _withRowLock(() => _repairVersionChainLocked(normalizedId));
  }

  static Future<int> _repairVersionChainLocked(String artifactId) async {
    final current = await loadArtifactById(artifactId);
    if (current == null) return 0;

    final user = SupabaseService.auth.currentUser;
    if (user == null) return 0;

    final List existingRows;
    try {
      existingRows = await SupabaseService.client
          .from(_versionsTable)
          .select('version')
          .eq('artifact_id', current.rowId)
          .eq('user_id', user.id);
    } on PostgrestException catch (error) {
      if (_handleMissingArtifactSchema(
        error,
        operation: 'repairVersionChain(select)',
      )) {
        return 0;
      }
      rethrow;
    }

    final existingVersions = existingRows
        .map((row) => (row as Map)['version'])
        .map((v) => v is num ? v.toInt() : null)
        .whereType<int>()
        .toSet();

    final missingVersions = <int>{};
    if (!existingVersions.contains(current.version)) {
      missingVersions.add(current.version);
    }
    // If nothing at all exists and version > 1, also seed a v1 from the
    // current content. The genuine v1 body is gone — log so the user knows
    // older versions are a lossy approximation.
    final seedV1 = existingVersions.isEmpty && current.version > 1;
    if (seedV1) {
      missingVersions.add(1);
      unawaited(
        DiagnosticsLogService.warning(
          'artifact',
          'repairVersionChain: seeding v1 from current content (lossy)',
          data: {
            'currentVersion': current.version,
          },
        ),
      );
      if (kDebugMode) {
        debugPrint(
          '[repairVersionChain] row ${current.rowId}: no snapshots exist, '
          'seeding v1 from current v${current.version} (older versions '
          'are unrecoverable).',
        );
      }
    }

    if (missingVersions.isEmpty) return 0;

    // Encrypt once and reuse for every insert — the same content is being
    // mirrored into each missing snapshot row.
    final encrypted = await _encryptOrThrow(current.content);

    int inserted = 0;
    for (final version in missingVersions) {
      try {
        await _insertVersion(
          rowId: current.rowId,
          chatId: current.chatId,
          userId: current.userId,
          version: version,
          encryptedContent: encrypted,
          createdAt: current.updatedAt,
          attachmentPath: current.attachmentPath,
          messageId: current.messageId,
        );
        inserted++;
      } catch (error, stack) {
        // Don't abort the whole repair on a single failed insert — log
        // and continue so a partially-broken chain still gets partial
        // repair. The caller surfaces the count back to the user.
        unawaited(
          DiagnosticsLogService.error(
            'artifact',
            'repairVersionChain insert failed',
            data: {
              'version': version,
              'error': error.toString(),
            },
          ),
        );
        if (kDebugMode) {
          debugPrint(
            '[repairVersionChain] insert v$version for row '
            '${current.rowId} failed: $error\n$stack',
          );
        }
      }
    }

    if (inserted > 0) {
      _versionCache.remove(current.rowId);
      _changesController.add(null);
    }
    return inserted;
  }

  static Future<void> _insertVersion({
    required String rowId,
    required String chatId,
    required String userId,
    required int version,
    required String encryptedContent,
    required DateTime createdAt,
    String? attachmentPath,
    String? messageId,
  }) async {
    // Pull from the current-turn stamp when the caller didn't pass one
    // explicitly. Empty strings collapse to null so the column stays NULL
    // for orphan snapshots (e.g. background backfills) and the rollback
    // ignores them.
    final stamp = (messageId?.trim().isNotEmpty == true)
        ? messageId!.trim()
        : currentMessageId;
    final normalizedStamp =
        (stamp != null && stamp.trim().isNotEmpty) ? stamp.trim() : null;
    try {
      await SupabaseService.client.from(_versionsTable).insert({
        'artifact_id': rowId,
        'chat_id': chatId,
        'user_id': userId,
        'version': version,
        'content': encryptedContent,
        'attachment_path': attachmentPath,
        'created_at': createdAt.toIso8601String(),
        'message_id': normalizedStamp,
      });
    } on PostgrestException catch (error) {
      if (_handleMissingArtifactSchema(error, operation: '_insertVersion')) {
        throw StateError(_missingSchemaMessage);
      }
      rethrow;
    }
  }

  /// Roll back any artifact versions whose `message_id` is in [messageIds].
  ///
  /// For each affected artifact:
  ///   * Snapshot rows belonging to a discarded message are deleted.
  ///   * If a prior snapshot remains, `artifacts.content`, `version`, and
  ///     `attachment_path` are reset to the latest remaining snapshot.
  ///   * If no snapshot remains (the discarded message originally created
  ///     the artifact), the artifact row is deleted entirely.
  ///
  /// Used by the regenerate / resend flow before the new AI request goes
  /// out so the next pass writes a fresh version on top of clean state.
  ///
  /// Idempotent: empty input or message ids with no artifacts is a no-op.
  /// Best-effort: per-artifact failures are logged but do not abort the
  /// whole batch — the caller (resend) cannot block on artifact cleanup.
  ///
  /// ## Timestamp-bracket fallback
  ///
  /// Snapshots created BEFORE the `artifact_versions.message_id` column
  /// shipped (or from any build path that wrote the row without a stamp)
  /// have `message_id = NULL`. The `message_id IN (...)` query above
  /// silently skips them, so a resend would leave orphan v3/v4 in place
  /// and the next AI run would stack v5 on top.
  ///
  /// When the direct lookup returns zero rows, the rollback falls back
  /// to a TIMESTAMP-BASED match. It uses [_artifactsTable]`.message_id`
  /// (stamped on every create from day one of the message-id feature) to
  /// translate each discarded message id into a `(chat_id, created_at)`
  /// pair, then for each pair brackets a window from that timestamp up to
  /// the next stamped event in the same chat (or `now` if nothing
  /// stamped follows). Any `artifact_versions` row in that window
  /// belonging to the same chat AND with `message_id IS NULL` is treated
  /// as an orphan of the discarded message.
  ///
  /// Safety: the fallback ONLY matches rows where `message_id IS NULL`.
  /// It never touches a row stamped to a different (live) message, even
  /// if that row happens to fall in the window.
  static Future<void> rollbackArtifactsForMessages(
    Iterable<String> messageIds,
  ) async {
    if (!_artifactStorageAvailable) return;
    final ids = messageIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (ids.isEmpty) return;

    final user = SupabaseService.auth.currentUser;
    if (user == null) return;
    _ensureCacheForUser(user.id);

    await _withRowLock(() => _rollbackForMessagesLocked(ids, user.id));
  }

  static Future<void> _rollbackForMessagesLocked(
    List<String> ids,
    String userId,
  ) async {
    // 1. Find the snapshot rows that belong to the discarded messages.
    //    `artifact_id` there is the row id, never the handle.
    final List discardedRows;
    try {
      discardedRows = await SupabaseService.client
          .from(_versionsTable)
          .select('id, artifact_id, version, chat_id')
          .inFilter('message_id', ids)
          .eq('user_id', userId);
    } on PostgrestException catch (error) {
      if (_handleMissingArtifactSchema(
        error,
        operation: 'rollbackArtifactsForMessages(select)',
      )) {
        return;
      }
      if (kDebugMode) {
        debugPrint('[rollbackArtifactsForMessages] select failed: $error');
      }
      return;
    }

    // 2. Group discarded snapshots by row id.
    final discardedByArtifact = <String, List<Map<String, dynamic>>>{};
    for (final row in discardedRows) {
      final map = Map<String, dynamic>.from(row as Map);
      final rowId = (map['artifact_id'] as String?)?.trim();
      if (rowId == null || rowId.isEmpty) continue;
      discardedByArtifact.putIfAbsent(rowId, () => []).add(map);
    }

    // 2a. If nothing matched by `message_id`, try the timestamp fallback
    //     for legacy / un-stamped snapshots. The fallback only touches
    //     rows whose `message_id IS NULL`, so it cannot harm legitimately
    //     stamped versions from interleaved chats.
    if (discardedByArtifact.isEmpty) {
      final fallbackMatches = await _findOrphanSnapshotsForMessages(
        messageIds: ids,
        userId: userId,
      );
      if (fallbackMatches.isEmpty) return;
      if (kDebugMode) {
        debugPrint(
          '[rollbackArtifactsForMessages] timestamp fallback matched '
          '${fallbackMatches.values.fold<int>(0, (sum, list) => sum + list.length)} '
          'legacy snapshot(s) for messages ${ids.join(",")}',
        );
      }
      discardedByArtifact.addAll(fallbackMatches);
    }

    if (discardedByArtifact.isEmpty) return;

    // 3. For each affected artifact, delete the discarded snapshot rows
    //    and then either roll back to the latest remaining snapshot or
    //    delete the artifact entirely. Per-artifact failures are logged
    //    but do not abort the whole batch.
    final affectedChats = <String>{};
    final fullyDeleted = <String>{};
    for (final entry in discardedByArtifact.entries) {
      // A row re-keyed since the select above is found under its new id.
      final rowId = _canonicalRowId(entry.key);
      final discardedSnapshots = entry.value;
      try {
        final outcome = await _rollbackOneArtifact(
          rowId: rowId,
          discardedSnapshots: discardedSnapshots,
          userId: userId,
        );
        if (outcome.affectedChatId != null) {
          affectedChats.add(outcome.affectedChatId!);
        }
        if (outcome.deleted) {
          fullyDeleted.add(rowId);
        }
      } catch (error) {
        if (kDebugMode) {
          debugPrint(
            '[rollbackArtifactsForMessages] row $rowId failed: $error',
          );
        }
        unawaited(
          DiagnosticsLogService.error(
            'artifact',
            'Artifact rollback failed for one artifact',
            data: {
              'error': error.toString(),
            },
          ),
        );
      }
    }

    // 4. Drop the cached version history for every touched artifact.
    for (final id in discardedByArtifact.keys) {
      _versionCache.remove(_canonicalRowId(id));
    }

    // 5. Fire a single change event so listeners (panel, sidebar) refresh.
    if (affectedChats.isNotEmpty || fullyDeleted.isNotEmpty) {
      _changesController.add(null);
    }
  }

  /// Internal helper: roll back a single artifact based on its discarded
  /// snapshot rows. Returns `({deleted, affectedChatId})`.
  ///
  /// Steps:
  ///   1. Delete the discarded snapshot rows.
  ///   2. Query the new latest remaining snapshot.
  ///   3. If a snapshot remains → update `artifacts` row to that snapshot.
  ///   4. Otherwise → delete the artifact row.
  /// Cache + active-notifier updates happen here so the caller only has to
  /// emit one change event after the batch. Runs under the row lock.
  static Future<({bool deleted, String? affectedChatId})> _rollbackOneArtifact({
    required String rowId,
    required List<Map<String, dynamic>> discardedSnapshots,
    required String userId,
  }) async {
    // Load the current artifact so we know which chat it belongs to and
    // whether the active notifier is pointing at it.
    final current = _findCachedByRowId(rowId) ?? await _fetchRow(rowId, userId);
    final chatId = current?.chatId ??
        ((discardedSnapshots.first['chat_id'] as String?)?.trim());

    // Delete the snapshot rows for the discarded versions.
    final discardedVersions = discardedSnapshots
        .map((row) => (row['version'] as num?)?.toInt())
        .whereType<int>()
        .toList(growable: false);
    if (discardedVersions.isNotEmpty) {
      try {
        await SupabaseService.client
            .from(_versionsTable)
            .delete()
            .eq('artifact_id', rowId)
            .eq('user_id', userId)
            .inFilter('version', discardedVersions);
      } on PostgrestException catch (error) {
        if (_handleMissingArtifactSchema(
          error,
          operation: 'rollbackArtifactsForMessages(deleteVersions)',
        )) {
          return (deleted: false, affectedChatId: chatId);
        }
        rethrow;
      }
    }

    // Look up the latest remaining snapshot.
    final latestRemaining = await _loadLatestRemainingSnapshot(
      rowId: rowId,
      userId: userId,
    );

    if (latestRemaining == null) {
      // No prior snapshot — discarded message created this artifact.
      // Delete the row entirely.
      try {
        await SupabaseService.client
            .from(_artifactsTable)
            .delete()
            .eq('id', rowId)
            .eq('user_id', userId);
      } on PostgrestException catch (error) {
        if (_handleMissingArtifactSchema(
          error,
          operation: 'rollbackArtifactsForMessages(deleteArtifact)',
        )) {
          return (deleted: false, affectedChatId: chatId);
        }
        rethrow;
      }

      _removeArtifactFromCache(rowId);
      final active = activeArtifactNotifier.value;
      if (active != null && _isSameRow(active, rowId)) {
        activeArtifactNotifier.value = null;
        panelOpenNotifier.value = false;
      }
      return (deleted: true, affectedChatId: chatId);
    }

    // A prior snapshot remains — reset the artifact row to it. Use the
    // raw encrypted content from the snapshot row to avoid a redundant
    // encrypt round-trip. Title and language are not touched here.
    final raw = latestRemaining['content'] as String? ?? '';
    final attachmentPath =
        (latestRemaining['attachment_path'] as String?)?.trim().isEmpty == true
            ? null
            : latestRemaining['attachment_path'] as String?;
    final restoredVersion = (latestRemaining['version'] as num?)?.toInt() ?? 1;
    final restoredCreatedAt = DateTime.tryParse(
          latestRemaining['created_at'] as String? ?? '',
        ) ??
        DateTime.now().toUtc();

    final List resetRows;
    try {
      resetRows = await SupabaseService.client
          .from(_artifactsTable)
          .update({
            'content': raw,
            'version': restoredVersion,
            'attachment_path': attachmentPath,
            'updated_at': restoredCreatedAt.toIso8601String(),
          })
          .eq('id', rowId)
          .eq('user_id', userId)
          .select('updated_at');
    } on PostgrestException catch (error) {
      if (_handleMissingArtifactSchema(
        error,
        operation: 'rollbackArtifactsForMessages(resetArtifact)',
      )) {
        return (deleted: false, affectedChatId: chatId);
      }
      rethrow;
    }

    // Decrypt the restored content for the in-memory cache + notifier.
    final decryptedContent = await _decryptMaybe(raw);
    final known = _indexByRowId?[rowId];
    final restored = _stamped(
      (current ??
              ArtifactDocument(
              id: known?.handle ?? rowId,
              rowId: rowId,
              chatId: chatId ?? '',
              userId: userId,
              title: known?.title ?? known?.handle ?? rowId,
              language: known?.language,
              type: ArtifactType.markdown,
              content: decryptedContent,
              version: restoredVersion,
              createdAt: restoredCreatedAt,
              updatedAt: restoredCreatedAt,
            ))
          .copyWith(
        content: decryptedContent,
        version: restoredVersion,
        attachmentPath: attachmentPath,
        updatedAt: restoredCreatedAt,
      ),
      _stampOf(resetRows),
    );

    _insertIntoCache(restored);
    _indexUpsert([restored]);
    final active = activeArtifactNotifier.value;
    if (active != null && _isSameRow(active, rowId)) {
      activeArtifactNotifier.value = restored;
    } else if (_activeChatId == restored.chatId) {
      // Keep `_emitChange` semantics in sync — the active chat saw an
      // artifact mutation even if the active notifier was pointed at a
      // sibling artifact.
    }
    return (deleted: false, affectedChatId: restored.chatId);
  }

  /// Returns the latest remaining snapshot row for [rowId] (after the
  /// rollback delete), or `null` if no snapshot survived. Encrypted content
  /// is returned raw so the caller can avoid a redundant decrypt cycle when
  /// it only needs to forward the value to the `artifacts` table.
  static Future<Map<String, dynamic>?> _loadLatestRemainingSnapshot({
    required String rowId,
    required String userId,
  }) async {
    try {
      final row = await SupabaseService.client
          .from(_versionsTable)
          .select()
          .eq('artifact_id', rowId)
          .eq('user_id', userId)
          .order('version', ascending: false)
          .limit(1)
          .maybeSingle();
      if (row == null) return null;
      return Map<String, dynamic>.from(row as Map);
    } on PostgrestException catch (error) {
      if (_handleMissingArtifactSchema(
        error,
        operation: 'rollbackArtifactsForMessages(loadLatest)',
      )) {
        return null;
      }
      rethrow;
    }
  }

  /// Pure helper extracted for testing. Given a sorted-by-version snapshot
  /// list and the set of versions to discard, returns the latest version
  /// number that survives the rollback (or `null` if nothing remains).
  ///
  /// `snapshots` may be in any order — the helper picks the highest
  /// non-discarded version. Exposed for unit tests so the rollback's
  /// "find the latest remaining version" decision stays covered without
  /// requiring a live Supabase backend.
  @visibleForTesting
  static int? latestRemainingVersion({
    required List<int> snapshotVersions,
    required Set<int> discardedVersions,
  }) {
    int? best;
    for (final v in snapshotVersions) {
      if (discardedVersions.contains(v)) continue;
      if (best == null || v > best) best = v;
    }
    return best;
  }

  /// Pure helper: given a set of stamped artifact rows (each `{chat_id,
  /// created_at}`) belonging to discarded messages, compute a list of
  /// `(chatId, start, end?)` bracket windows by pairing each discarded
  /// stamp with the next chronologically-later stamped event in the same
  /// chat (drawn from [nextStampedEvents]). When no later event exists,
  /// the bracket is open-ended (`end == null`, treated as "now" by the
  /// caller).
  ///
  /// Inputs may be in any order. Output windows are de-duplicated by
  /// `(chatId, start)` so calling with overlapping discarded stamps does
  /// not produce double work. Exposed for unit tests.
  ///
  /// Both [discardedStamps] and [nextStampedEvents] entries must contain
  /// `chat_id` (String) and `created_at` (ISO-8601 String). Entries with
  /// missing / malformed fields are skipped.
  @visibleForTesting
  static List<({String chatId, DateTime start, DateTime? end})>
      computeOrphanBrackets({
    required List<Map<String, dynamic>> discardedStamps,
    required List<Map<String, dynamic>> nextStampedEvents,
  }) {
    // Group next-events by chat for fast "first event strictly after X" lookup.
    final eventsByChat = <String, List<DateTime>>{};
    for (final row in nextStampedEvents) {
      final chatId = (row['chat_id'] as String?)?.trim();
      final createdAtRaw = row['created_at'] as String?;
      if (chatId == null || chatId.isEmpty) continue;
      if (createdAtRaw == null) continue;
      final createdAt = DateTime.tryParse(createdAtRaw);
      if (createdAt == null) continue;
      eventsByChat.putIfAbsent(chatId, () => []).add(createdAt.toUtc());
    }
    for (final list in eventsByChat.values) {
      list.sort();
    }

    final brackets = <({String chatId, DateTime start, DateTime? end})>[];
    final seen = <String>{}; // dedupe key: "chatId|start.iso"
    for (final row in discardedStamps) {
      final chatId = (row['chat_id'] as String?)?.trim();
      final createdAtRaw = row['created_at'] as String?;
      if (chatId == null || chatId.isEmpty) continue;
      if (createdAtRaw == null) continue;
      final start = DateTime.tryParse(createdAtRaw)?.toUtc();
      if (start == null) continue;

      final dedupeKey = '$chatId|${start.toIso8601String()}';
      if (!seen.add(dedupeKey)) continue;

      // Find the first stamped event in the same chat that is strictly
      // AFTER `start`. Linear scan — the per-chat lists are small.
      DateTime? end;
      final chatEvents = eventsByChat[chatId];
      if (chatEvents != null) {
        for (final ts in chatEvents) {
          if (ts.isAfter(start)) {
            end = ts;
            break;
          }
        }
      }

      brackets.add((chatId: chatId, start: start, end: end));
    }
    return brackets;
  }

  /// Pure helper: filters [candidateSnapshots] (each `{message_id,
  /// chat_id, created_at}`) down to ONLY rows whose `message_id IS NULL`
  /// AND that fall inside one of the [brackets] for the matching chat.
  /// A snapshot at `t` is in-window when `bracket.start <= t < bracket.end`
  /// (or `bracket.start <= t` when `bracket.end == null` — open-ended).
  ///
  /// The `message_id IS NULL` guard is the load-bearing safety check:
  /// the fallback must NEVER roll back a row stamped to a different
  /// (live) message just because it shares the chat / timestamp range.
  @visibleForTesting
  static List<Map<String, dynamic>> filterOrphanSnapshotsInBrackets({
    required List<Map<String, dynamic>> candidateSnapshots,
    required List<({String chatId, DateTime start, DateTime? end})> brackets,
  }) {
    if (candidateSnapshots.isEmpty || brackets.isEmpty) {
      return const <Map<String, dynamic>>[];
    }

    // Index brackets by chat_id.
    final bracketsByChat =
        <String, List<({DateTime start, DateTime? end})>>{};
    for (final b in brackets) {
      bracketsByChat
          .putIfAbsent(b.chatId, () => [])
          .add((start: b.start, end: b.end));
    }

    final matched = <Map<String, dynamic>>[];
    for (final row in candidateSnapshots) {
      // Safety guard: only un-stamped rows are eligible. A stamped row
      // belongs to a live message — never roll it back via this path.
      final stamp = row['message_id'];
      if (stamp != null && stamp.toString().trim().isNotEmpty) continue;

      final chatId = (row['chat_id'] as String?)?.trim();
      final createdAtRaw = row['created_at'] as String?;
      if (chatId == null || chatId.isEmpty) continue;
      if (createdAtRaw == null) continue;
      final ts = DateTime.tryParse(createdAtRaw)?.toUtc();
      if (ts == null) continue;

      final chatBrackets = bracketsByChat[chatId];
      if (chatBrackets == null) continue;

      bool inWindow = false;
      for (final b in chatBrackets) {
        final start = b.start;
        final end = b.end;
        final atOrAfterStart = !ts.isBefore(start); // ts >= start
        if (!atOrAfterStart) continue;
        if (end == null || ts.isBefore(end)) {
          inWindow = true;
          break;
        }
      }
      if (inWindow) matched.add(row);
    }
    return matched;
  }

  /// Looks up legacy / un-stamped `artifact_versions` rows that belong to
  /// the discarded messages by translating each [messageIds] into a
  /// `(chat_id, created_at)` bracket via the `artifacts` table (which
  /// stamps `message_id` on create from day one of the feature), then
  /// scanning for `message_id IS NULL` snapshot rows in those windows.
  ///
  /// Returns a map `artifact_id -> [snapshot rows]` shaped exactly like
  /// the primary `message_id IN (...)` lookup so the rest of the
  /// rollback pipeline doesn't have to branch.
  ///
  /// Best-effort: any PostgREST failure short-circuits to an empty map
  /// rather than aborting the resend flow.
  static Future<Map<String, List<Map<String, dynamic>>>>
      _findOrphanSnapshotsForMessages({
    required List<String> messageIds,
    required String userId,
  }) async {
    if (messageIds.isEmpty) return const {};

    // Step 1: look up which artifacts were created by the discarded
    // messages. `artifacts.message_id` has been populated from day one
    // of the message-id feature, so even if `artifact_versions.message_id`
    // is NULL for old snapshots, we can usually still find the parent
    // artifact's chat + creation time.
    final List discardedArtifactRows;
    try {
      discardedArtifactRows = await SupabaseService.client
          .from(_artifactsTable)
          .select('id, chat_id, created_at, message_id')
          .inFilter('message_id', messageIds)
          .eq('user_id', userId);
    } on PostgrestException catch (error) {
      if (_handleMissingArtifactSchema(
        error,
        operation: 'rollbackArtifactsForMessages(fallback artifacts)',
      )) {
        return const {};
      }
      if (kDebugMode) {
        debugPrint(
          '[rollbackArtifactsForMessages] fallback artifacts query failed: '
          '$error',
        );
      }
      return const {};
    }

    final discardedStamps = discardedArtifactRows
        .map((row) => Map<String, dynamic>.from(row as Map))
        .toList(growable: false);
    if (discardedStamps.isEmpty) return const {};

    final chatIds = discardedStamps
        .map((row) => (row['chat_id'] as String?)?.trim())
        .whereType<String>()
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (chatIds.isEmpty) return const {};

    // Step 2: pull the upper bracket bounds — any stamped event in the
    // same chats whose message_id is OUTSIDE the discarded set. The
    // earliest such event AFTER a discarded stamp is the bracket end.
    // We deliberately also pull versions (not just artifact creates) so
    // a later rewrite by a different message closes the window early.
    final List stampedEventRows;
    try {
      stampedEventRows = await SupabaseService.client
          .from(_versionsTable)
          .select('chat_id, created_at, message_id')
          .inFilter('chat_id', chatIds)
          .eq('user_id', userId)
          .not('message_id', 'is', null);
    } on PostgrestException catch (error) {
      if (_handleMissingArtifactSchema(
        error,
        operation: 'rollbackArtifactsForMessages(fallback events)',
      )) {
        return const {};
      }
      if (kDebugMode) {
        debugPrint(
          '[rollbackArtifactsForMessages] fallback events query failed: '
          '$error',
        );
      }
      return const {};
    }

    final discardedSet = messageIds.toSet();
    final nextStampedEvents = stampedEventRows
        .map((row) => Map<String, dynamic>.from(row as Map))
        .where((row) {
      final stamp = (row['message_id'] as String?)?.trim();
      return stamp != null && stamp.isNotEmpty && !discardedSet.contains(stamp);
    }).toList(growable: false);

    final brackets = computeOrphanBrackets(
      discardedStamps: discardedStamps,
      nextStampedEvents: nextStampedEvents,
    );
    if (brackets.isEmpty) return const {};

    // Step 3: pull every NULL-stamp snapshot in the affected chats and
    // filter to those inside a bracket window.
    final List candidateRows;
    try {
      candidateRows = await SupabaseService.client
          .from(_versionsTable)
          .select('id, artifact_id, version, chat_id, created_at, message_id')
          .inFilter('chat_id', chatIds)
          .eq('user_id', userId)
          .filter('message_id', 'is', null);
    } on PostgrestException catch (error) {
      if (_handleMissingArtifactSchema(
        error,
        operation: 'rollbackArtifactsForMessages(fallback candidates)',
      )) {
        return const {};
      }
      if (kDebugMode) {
        debugPrint(
          '[rollbackArtifactsForMessages] fallback candidates query failed: '
          '$error',
        );
      }
      return const {};
    }

    final candidateSnapshots = candidateRows
        .map((row) => Map<String, dynamic>.from(row as Map))
        .toList(growable: false);

    final orphanMatches = filterOrphanSnapshotsInBrackets(
      candidateSnapshots: candidateSnapshots,
      brackets: brackets,
    );
    if (orphanMatches.isEmpty) return const {};

    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final row in orphanMatches) {
      final artifactId = (row['artifact_id'] as String?)?.trim();
      if (artifactId == null || artifactId.isEmpty) continue;
      grouped.putIfAbsent(artifactId, () => []).add(row);
    }
    return grouped;
  }

  /// Drops every cached copy of [rowId]: chat lists, loose documents,
  /// version history and its index entry. Returns the chats whose cached
  /// list contained it.
  static Set<String> _removeArtifactFromCache(String rowId) {
    final chats = <String>{};
    for (final entry in _cacheByChatId.entries) {
      final before = entry.value.length;
      entry.value.removeWhere((doc) => doc.rowId == rowId);
      if (entry.value.length != before) chats.add(entry.key);
    }
    _looseDocs.remove(rowId);
    _versionCache.remove(rowId);
    _indexByRowId?.remove(rowId);
    return chats;
  }

  /// Hard-deletes the given artifacts (handles or row ids) and their version
  /// history for the current user. Used on resend: removed AI messages must
  /// not leave orphan artifact cards pinned to the chat.
  ///
  /// Silent for ids that don't exist or fail to delete — the caller (resend
  /// flow) should not block on artifact cleanup. Cached entries are pruned
  /// and a change event is emitted so the panel refreshes.
  static Future<void> deleteArtifactsByIds(Iterable<String> artifactIds) async {
    if (!_artifactStorageAvailable) return;
    final ids = artifactIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (ids.isEmpty) return;

    final user = SupabaseService.auth.currentUser;
    if (user == null) return;
    _ensureCacheForUser(user.id);

    await _withRowLock(() async {
      // Handles are resolved here; only row ids go to the server.
      final rowIds = await _rowIdsForKeys(ids, user.id);
      if (rowIds.isEmpty) return;

      final deleted = await _deleteRows(rowIds, user.id);
      if (deleted == null) return;

      // A row id that deleted nothing is stale (re-keyed or removed on
      // another device). Resolve the handles once more against fresh data.
      final missed = rowIds.difference(deleted);
      if (missed.isNotEmpty) {
        for (final rowId in missed) {
          _forgetRow(rowId);
        }
        final again = (await _rowIdsForKeys(ids, user.id, rebuild: true))
            .difference(deleted)
            .difference(missed);
        if (again.isNotEmpty) {
          deleted.addAll(await _deleteRows(again, user.id) ?? const <String>{});
        }
      }

      final affectedChats = <String>{};
      for (final rowId in deleted) {
        affectedChats.addAll(_removeArtifactFromCache(rowId));
      }
      final active = activeArtifactNotifier.value;
      if (active != null) {
        final activeRow = _canonicalRowId(active.rowId);
        if (deleted.contains(activeRow) || missed.contains(activeRow)) {
          activeArtifactNotifier.value = null;
        }
      }
      if (affectedChats.isNotEmpty || deleted.isNotEmpty) {
        _changesController.add(null);
      }
    });
  }

  /// Deletes the given rows and their versions. Returns the row ids that
  /// were deleted, or null when the delete failed.
  static Future<Set<String>?> _deleteRows(
    Set<String> rowIds,
    String userId,
  ) async {
    final ids = rowIds.toList(growable: false);
    try {
      await SupabaseService.client
          .from(_versionsTable)
          .delete()
          .inFilter('artifact_id', ids)
          .eq('user_id', userId);
    } on PostgrestException catch (error) {
      if (!_handleMissingArtifactSchema(
        error,
        operation: 'deleteArtifactsByIds(versions)',
      )) {
        if (kDebugMode) {
          debugPrint('[deleteArtifactsByIds] version cleanup failed: $error');
        }
      }
    }

    try {
      final List rows = await SupabaseService.client
          .from(_artifactsTable)
          .delete()
          .inFilter('id', ids)
          .eq('user_id', userId)
          .select('id');
      return rows
          .map((row) => (row as Map)['id'])
          .whereType<String>()
          .toSet();
    } on PostgrestException catch (error) {
      if (_handleMissingArtifactSchema(
        error,
        operation: 'deleteArtifactsByIds',
      )) {
        return null;
      }
      unawaited(
        DiagnosticsLogService.error(
          'artifact',
          'Artifact delete failed',
          data: {'count': ids.length, 'code': error.code},
        ),
      );
      if (kDebugMode) {
        debugPrint('[deleteArtifactsByIds] artifact delete failed: $error');
      }
      return null;
    }
  }

  /// Sets [attachmentPath] on an existing artifact row **without** bumping
  /// the version. Used to backfill a compiled PDF for artifacts that were
  /// created before attachment persistence was available.
  static Future<void> setAttachmentPath({
    required String artifactId,
    required String attachmentPath,
  }) async {
    if (!_artifactStorageAvailable) {
      if (kDebugMode) {
        debugPrint('📄 [setAttachmentPath] Storage unavailable — skipping');
      }
      return;
    }

    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      if (kDebugMode) {
        debugPrint('📄 [setAttachmentPath] No user — skipping');
      }
      return;
    }
    _ensureCacheForUser(user.id);

    await _withRowLock(() async {
      final doc = await loadArtifactById(artifactId);
      if (doc == null) {
        if (kDebugMode) {
          debugPrint('📄 [setAttachmentPath] Artifact not found — skipping');
        }
        return;
      }

      if (kDebugMode) {
        debugPrint('📄 [setAttachmentPath] Updating row ${doc.rowId}');
      }
      final List updatedRows;
      try {
        updatedRows = await SupabaseService.client
            .from(_artifactsTable)
            .update({'attachment_path': attachmentPath})
            .eq('id', doc.rowId)
            .eq('user_id', user.id)
            .select('updated_at');
        if (kDebugMode) {
          debugPrint('📄 [setAttachmentPath] ✅ DB updated');
        }
      } on PostgrestException catch (error) {
        if (kDebugMode) {
          debugPrint('📄 [setAttachmentPath] ❌ PostgREST error: '
              '${error.code} ${error.message}');
        }
        if (_handleMissingArtifactSchema(
          error,
          operation: 'setAttachmentPath',
        )) {
          return;
        }
        rethrow;
      }

      // Update the in-memory cache so the current session sees the path.
      final cached = _findCachedByRowId(doc.rowId);
      if (cached == null) return;
      final updated = _stamped(
        cached.copyWith(attachmentPath: attachmentPath),
        _stampOf(updatedRows),
      );
      _insertIntoCache(updated);
      _indexUpsert([updated]);
      _emitChange(updated.chatId, updated);
      if (kDebugMode) {
        debugPrint('📄 [setAttachmentPath] ✅ Cache updated for row '
            '${doc.rowId}');
      }
    });
  }

  static void _emitChange(String chatId, ArtifactDocument updated) {
    if (_activeChatId == chatId) {
      activeArtifactNotifier.value = updated;
    }
    _changesController.add(null);
  }

  /// Puts [doc] into its chat's cached list, replacing the copy with the
  /// same row id. When that list is not loaded, the document is kept on its
  /// own ([_looseDocs]) so it never stands in for the whole chat.
  static void _insertIntoCache(ArtifactDocument doc) {
    final chatDocs = _cacheByChatId[doc.chatId];
    if (chatDocs == null) {
      _looseDocs[doc.rowId] = doc;
      return;
    }
    _looseDocs.remove(doc.rowId);
    final existing = List<ArtifactDocument>.from(chatDocs);
    existing.removeWhere((item) => item.rowId == doc.rowId);
    existing.insert(0, doc);
    existing.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    _cacheByChatId[doc.chatId] = existing;
  }

  static Iterable<ArtifactDocument> _cachedDocs() sync* {
    for (final docs in _cacheByChatId.values) {
      yield* docs;
    }
    yield* _looseDocs.values;
  }

  /// A cached document for [key]: the newest one with that handle, else the
  /// one with that row id.
  static ArtifactDocument? _findCached(String key) {
    if (key.isEmpty) return null;
    final rowId = _canonicalRowId(key);
    ArtifactDocument? byHandle;
    ArtifactDocument? byRowId;
    for (final doc in _cachedDocs()) {
      if (doc.id == key) {
        if (byHandle == null || doc.updatedAt.isAfter(byHandle.updatedAt)) {
          byHandle = doc;
        }
      } else if (doc.rowId == rowId) {
        byRowId ??= doc;
      }
    }
    return byHandle ?? byRowId;
  }

  static ArtifactDocument? _findCachedByRowId(String rowId) {
    final canonical = _canonicalRowId(rowId);
    for (final doc in _cachedDocs()) {
      if (doc.rowId == canonical) return doc;
    }
    return null;
  }

  /// Fetches one active row by its row id and caches it.
  static Future<ArtifactDocument?> _fetchRow(String rowId, String userId) async {
    final Map<String, dynamic>? row;
    try {
      row = await SupabaseService.client
          .from(_artifactsTable)
          .select()
          .eq('id', rowId)
          .eq('user_id', userId)
          .eq('is_active', true)
          .maybeSingle();
    } on PostgrestException catch (error) {
      if (_handleMissingArtifactSchema(error, operation: 'loadArtifactById')) {
        return null;
      }
      rethrow;
    }

    if (row == null) return null;
    final docs = await _documentsFromRows([row], userId: userId);
    final doc = docs.single;
    if (_cacheUserId == userId) {
      _insertIntoCache(doc);
      _indexUpsert(docs);
    }
    return doc;
  }

  /// Opens and decrypts fetched `artifacts` rows and queues every row that
  /// still carries plaintext metadata for a re-seal. The re-seal worker
  /// takes the row lock itself, so it starts only after the caller's load.
  static Future<List<ArtifactDocument>> _documentsFromRows(
    List<dynamic> response, {
    required String userId,
  }) async {
    final docs = <ArtifactDocument>[];
    final reseal = <ArtifactRowRef>[];
    for (final raw in response) {
      final row = Map<String, dynamic>.from(raw as Map);
      final opened = await _openMeta(row);
      final content = await _decryptMaybe(row['content'] as String? ?? '');
      final doc = documentFromRow(
        row,
        decryptedContent: content,
        meta: opened.meta,
        metaUnreadable: opened.unreadable,
      );
      docs.add(doc);
      if (needsReseal(
        row,
        meta: opened.meta,
        metaUnreadable: opened.unreadable,
      )) {
        reseal.add(_refOf(doc));
      }
    }
    _queueReseal(userId, reseal);
    return docs;
  }

  /// Opens a row's `encrypted_meta`, remembering the result. A row that
  /// cannot be opened is marked so it is never re-sealed.
  static Future<({Map<String, dynamic>? meta, bool unreadable})> _openMeta(
    Map<String, dynamic> row,
  ) async {
    final envelope = row['encrypted_meta'];
    final rowId = row['id'] as String? ?? '';
    // Keyed by row too: an envelope opened for one row must not be taken
    // as valid when the server serves it on another.
    if (envelope is String) {
      final known = _openedMeta[(rowId: rowId, envelope: envelope)];
      if (known != null) {
        _unreadableRowIds.remove(rowId);
        return (meta: known, unreadable: false);
      }
    }

    final opened = await decodeRowMeta(envelope, rowId: rowId);
    if (opened.unreadable) {
      if (_unreadableRowIds.add(rowId)) {
        unawaited(
          DiagnosticsLogService.warning(
            'artifact',
            'Artifact metadata could not be opened; row left sealed',
          ),
        );
      }
      return opened;
    }

    _unreadableRowIds.remove(rowId);
    final meta = opened.meta;
    if (envelope is String && meta != null) {
      _openedMeta[(rowId: rowId, envelope: envelope)] = meta;
    }
    return opened;
  }

  // ---------------------------------------------------------------------
  // Handle index
  // ---------------------------------------------------------------------

  static ArtifactRowRef _refOf(ArtifactDocument doc) => (
    rowId: doc.rowId,
    handle: doc.id,
    chatId: doc.chatId,
    title: doc.title,
    language: doc.language,
    updatedAt: doc.updatedAt,
    stamp: doc.updatedAtStamp,
  );

  /// The raw `updated_at` of the first row a write returned, exactly as the
  /// server sent it. Null when the write returned no row.
  static String? _stampOf(List<dynamic> rows) {
    if (rows.isEmpty) return null;
    final first = rows.first;
    final stamp = first is Map ? first['updated_at'] : null;
    return stamp is String ? stamp : null;
  }

  /// [doc] with [stamp] as its stamp, also when [stamp] is null: a stamp
  /// must never outlive the snapshot it came with.
  static ArtifactDocument _stamped(ArtifactDocument doc, String? stamp) {
    return ArtifactDocument(
      id: doc.id,
      rowId: doc.rowId,
      chatId: doc.chatId,
      userId: doc.userId,
      messageId: doc.messageId,
      title: doc.title,
      type: doc.type,
      language: doc.language,
      content: doc.content,
      version: doc.version,
      attachmentPath: doc.attachmentPath,
      createdAt: doc.createdAt,
      updatedAt: doc.updatedAt,
      updatedAtStamp: stamp,
    );
  }

  /// Writes fresh documents into the index, when it exists. A missing index
  /// is built from the server when first needed.
  static void _indexUpsert(Iterable<ArtifactDocument> docs) {
    final index = _indexByRowId;
    if (index == null) return;
    for (final doc in docs) {
      index[doc.rowId] = _refOf(doc);
    }
  }

  static bool _indexOlderThan(Duration age) {
    final builtAt = _indexBuiltAt;
    return builtAt == null || DateTime.now().difference(builtAt) > age;
  }

  /// The index for [userId]; built on first use, or when [rebuild] is set.
  static Future<Map<String, ArtifactRowRef>> _ensureIndex(
    String userId, {
    bool rebuild = false,
  }) {
    return _withRowLock(() async {
      final index = _indexByRowId;
      if (index != null && !rebuild) return index;
      return _buildIndex(userId);
    });
  }

  /// Resolves a handle or row id through the index. A miss rebuilds the
  /// index once (an artifact made on another device), unless it is fresh.
  static Future<ArtifactRowRef?> _findRef(
    String key,
    String userId, {
    bool rebuild = false,
  }) async {
    final index = await _ensureIndex(userId, rebuild: rebuild);
    final ref = resolveRowRef(index.values, key);
    if (ref != null || rebuild || !_indexOlderThan(_indexMaxAgeOnMiss)) {
      return ref;
    }
    final fresh = await _ensureIndex(userId, rebuild: true);
    return resolveRowRef(fresh.values, key);
  }

  /// Every row the given handles or row ids name: per key the document
  /// [loadArtifactById] would return for it.
  static Future<Set<String>> _rowIdsForKeys(
    List<String> keys,
    String userId, {
    bool rebuild = false,
  }) async {
    final rowIds = <String>{};
    final unresolved = <String>[];
    Map<String, ArtifactRowRef>? index;
    for (final key in keys) {
      final cached = rebuild ? null : _findCached(key);
      if (cached != null) {
        rowIds.add(cached.rowId);
        continue;
      }
      index ??= await _ensureIndex(userId, rebuild: rebuild);
      final ref = resolveRowRef(index.values, key);
      if (ref != null) {
        rowIds.add(ref.rowId);
      } else {
        unresolved.add(key);
      }
    }
    if (unresolved.isNotEmpty &&
        !rebuild &&
        _indexOlderThan(_indexMaxAgeOnMiss)) {
      final fresh = await _ensureIndex(userId, rebuild: true);
      for (final key in unresolved) {
        final ref = resolveRowRef(fresh.values, key);
        if (ref != null) rowIds.add(ref.rowId);
      }
    }
    return rowIds;
  }

  /// True when this user already has an active artifact with [handle].
  static Future<bool> _handleTaken(String handle, String userId) async {
    if (_cachedDocs().any((doc) => doc.id == handle)) return true;
    final index = await _ensureIndex(userId);
    if (index.values.any((ref) => ref.handle == handle)) return true;
    if (!_indexOlderThan(_indexMaxAgeOnCreate)) return false;
    final fresh = await _ensureIndex(userId, rebuild: true);
    return fresh.values.any((ref) => ref.handle == handle);
  }

  /// Reads every active row of [userId] without content (paged), opens the
  /// metadata and installs the result as the index. Queues the rows that
  /// still need a re-seal. Runs under the row lock.
  static Future<Map<String, ArtifactRowRef>> _buildIndex(String userId) async {
    final rows = <Map<String, dynamic>>[];
    try {
      for (var from = 0; ; from += _pageSize) {
        final List page = await _selectIndexPage(userId, from);
        rows.addAll(page.map((row) => Map<String, dynamic>.from(row as Map)));
        if (page.length < _pageSize) break;
      }
    } on PostgrestException catch (error) {
      if (_handleMissingArtifactSchema(error, operation: 'handleIndex')) {
        return <String, ArtifactRowRef>{};
      }
      rethrow;
    }

    final refs = <String, ArtifactRowRef>{};
    final reseal = <ArtifactRowRef>[];
    for (final row in rows) {
      final opened = await _openMeta(row);
      final ref = rowRefFromRow(
        row,
        meta: opened.meta,
        metaUnreadable: opened.unreadable,
      );
      refs[ref.rowId] = ref;
      if (needsReseal(
        row,
        meta: opened.meta,
        metaUnreadable: opened.unreadable,
      )) {
        reseal.add(ref);
      }
    }

    if (_cacheUserId != userId) return refs;
    _indexByRowId = refs;
    _indexBuiltAt = DateTime.now();
    _queueReseal(userId, reseal);
    return refs;
  }

  static Future<List<dynamic>> _selectIndexPage(String userId, int from) async {
    Future<List<dynamic>> select(String columns) => SupabaseService.client
        .from(_artifactsTable)
        .select(columns)
        .eq('user_id', userId)
        .eq('is_active', true)
        .order('id')
        .range(from, from + _pageSize - 1);

    if (_sealColumnMissing) return select(_metaColumnsUnsealed);
    try {
      return await select(_metaColumns);
    } on PostgrestException catch (error) {
      if (!_isMissingMetaColumnError(error)) rethrow;
      _markSealColumnMissing(error, operation: 'handleIndex');
      return select(_metaColumnsUnsealed);
    }
  }

  /// After a write by row id matched nothing: drops the stale copy and
  /// looks the handle up again against fresh data. Returns the document
  /// when the row still exists under another row id, else null.
  static Future<ArtifactDocument?> _reloadAfterMiss(
    String staleRowId,
    String handle,
    String userId,
  ) async {
    _forgetRow(staleRowId);
    final ref = await _findRef(handle, userId, rebuild: true);
    if (ref == null || ref.rowId == staleRowId) return null;
    return _fetchRow(ref.rowId, userId);
  }

  /// Drops a row this device holds stale data about and marks the index
  /// stale, so the next miss rebuilds it. Returns the chats whose cached
  /// list held the row.
  static Set<String> _forgetRow(String rowId) {
    final chats = _removeArtifactFromCache(rowId);
    _indexBuiltAt = null;
    return chats;
  }

  // ---------------------------------------------------------------------
  // Re-seal: legacy rows get a random id and sealed metadata
  // ---------------------------------------------------------------------

  /// Seals every row of the signed-in user that still carries plaintext
  /// metadata: legacy rows (handle as id, plaintext title and language) and
  /// rows an old app build wrote plaintext into after the seal. Soft-deleted
  /// rows too, since they hold titles as well. Legacy rows get a random id;
  /// their versions follow through the ON UPDATE CASCADE foreign key.
  ///
  /// Meant for every app start, in the background: it reads only the rows
  /// that need work (no content), so it costs one small query once nothing
  /// is left. Same rules as the re-seal on load: each row at most once per
  /// session, rows whose metadata cannot be opened are left alone, and a
  /// missing `encrypted_meta` column stops it quietly for the session.
  /// Needs the encryption key: without it, it returns 0 and touches nothing.
  /// A row that fails without a server verdict (no key, cipher or network
  /// error) can be tried again by a later call. Never throws. Returns how
  /// many rows it sealed.
  static Future<int> resealLegacyRows() async {
    if (!_artifactStorageAvailable ||
        _sealColumnMissing ||
        !EncryptionService.hasKey) {
      return 0;
    }
    final user = SupabaseService.auth.currentUser;
    if (user == null) return 0;
    _ensureCacheForUser(user.id);

    var sealed = 0;
    // One page per round. A sealed row drops out of the filter, so every
    // round reads from the top again; a round that seals nothing ends the
    // sweep (what is left cannot be opened or keeps failing).
    while (true) {
      final List response;
      try {
        response = await SupabaseService.client
            .from(_artifactsTable)
            .select(_metaColumns)
            .eq('user_id', user.id)
            .or(resealCandidateFilter)
            .limit(_pageSize);
      } on PostgrestException catch (error) {
        if (_isMissingMetaColumnError(error)) {
          _markSealColumnMissing(error, operation: 'resealLegacyRows');
          return sealed;
        }
        if (_handleMissingArtifactSchema(
          error,
          operation: 'resealLegacyRows',
        )) {
          return sealed;
        }
        _logResealFailure('resealLegacyRows', error.code ?? 'postgrest');
        return sealed;
      } catch (error) {
        _logResealFailure('resealLegacyRows', error.runtimeType.toString());
        return sealed;
      }

      var sealedThisRound = 0;
      for (final raw in response) {
        if (_sealColumnMissing || _cacheUserId != user.id) return sealed;
        final row = Map<String, dynamic>.from(raw as Map);
        final opened = await _openMeta(row);
        if (!needsReseal(
          row,
          meta: opened.meta,
          metaUnreadable: opened.unreadable,
        )) {
          continue;
        }
        final ref = rowRefFromRow(
          row,
          meta: opened.meta,
          metaUnreadable: opened.unreadable,
        );
        if (!_resealSeen.add(ref.rowId)) continue;
        if (await _withRowLock(() => _resealOne(user.id, ref))) {
          sealed++;
          sealedThisRound++;
        }
      }
      if (response.length < _pageSize || sealedThisRound == 0) {
        return sealed;
      }
    }
  }

  /// Queues rows for a background re-seal, each at most once per session.
  static void _queueReseal(String userId, Iterable<ArtifactRowRef> refs) {
    // Without the key nothing can be sealed. Queueing now would mark the
    // rows as seen and keep the sweep, which runs once the key is there,
    // from sealing them.
    if (_sealColumnMissing || !EncryptionService.hasKey) return;
    for (final ref in refs) {
      if (_unreadableRowIds.contains(ref.rowId)) continue;
      if (!_resealSeen.add(ref.rowId)) continue;
      _resealQueue.add((userId: userId, ref: ref));
    }
    if (_resealQueue.isEmpty || _resealRunning) return;
    _resealRunning = true;
    // Started outside the caller's lock section: the worker takes the lock
    // per row, so it runs after the load that queued it, one row at a time.
    runZoned(
      () => unawaited(_drainResealQueue()),
      zoneValues: {_rowLockZoneKey: null},
    );
  }

  static Future<void> _drainResealQueue() async {
    try {
      while (_resealQueue.isNotEmpty && !_sealColumnMissing) {
        final job = _resealQueue.removeAt(0);
        await _withRowLock(() => _resealOne(job.userId, job.ref));
      }
    } catch (error) {
      _logResealFailure('drain', error.runtimeType.toString());
    } finally {
      if (_sealColumnMissing) _resealQueue.clear();
      _resealRunning = false;
    }
  }

  /// Seals one row. Uses the freshest copy of its metadata this device
  /// holds; a legacy row also gets a random id. Returns true when the row
  /// was sealed. Never throws. Runs under the row lock.
  static Future<bool> _resealOne(String userId, ArtifactRowRef queued) async {
    if (_sealColumnMissing || !_artifactStorageAvailable) return false;
    if (_cacheUserId != userId ||
        SupabaseService.auth.currentUser?.id != userId) {
      return false;
    }
    // Re-keyed meanwhile (e.g. by a rewrite): already sealed.
    if (_canonicalRowId(queued.rowId) != queued.rowId) return false;
    if (_unreadableRowIds.contains(queued.rowId)) return false;
    if (!EncryptionService.hasKey) {
      _releaseReseal(queued.rowId);
      return false;
    }

    // Values and stamp always come from one snapshot: the freshest copy of
    // the row this device holds.
    final cached = _findCachedByRowId(queued.rowId);
    final ref = freshestRef([
      if (cached != null) _refOf(cached),
      ?_indexByRowId?[queued.rowId],
      queued,
    ]);
    final filters = ref == null
        ? null
        : resealFilters(ref, userId: userId);
    // Without a stamp the write cannot be guarded against a newer edit;
    // leave the row to a later load or sweep.
    if (ref == null || filters == null) {
      _releaseReseal(queued.rowId);
      return false;
    }

    try {
      final update = await buildResealUpdate(ref);
      final newRowId = update['id'] as String?;
      var query = SupabaseService.client
          .from(_artifactsTable)
          .update(update);
      for (final filter in filters.entries) {
        query = query.eq(filter.key, filter.value);
      }
      final List rows = await query.select('id');
      if (rows.isEmpty) {
        // Skipped, not failed: the row is gone, was re-keyed on another
        // device first, or was edited after our copy was read (the stamp
        // moved). Our copy is stale either way. Drop it and let the
        // affected chats load their lists again.
        final chats = _forgetRow(ref.rowId);
        for (final chatId in chats) {
          _cacheByChatId.remove(chatId);
        }
        if (chats.isNotEmpty) _changesController.add(null);
        return false;
      }
      if (newRowId != null) {
        _applyRekey(ref.rowId, newRowId);
      }
      return true;
    } on PostgrestException catch (error) {
      if (_isMissingMetaColumnError(error)) {
        _markSealColumnMissing(error, operation: 'reseal');
        return false;
      }
      if (_handleMissingArtifactSchema(error, operation: 'reseal')) {
        return false;
      }
      _logResealFailure('reseal', error.code ?? 'postgrest');
      return false;
    } catch (error) {
      // No verdict from the server (no key, a cipher error, the network):
      // the row may be tried again later in this session.
      _releaseReseal(ref.rowId);
      _logResealFailure('reseal', error.runtimeType.toString());
      return false;
    }
  }

  /// Lets a later load or the sweep try [rowId] again in this session.
  /// Only for failures the server has not ruled on: a PostgREST error or a
  /// 0-row answer keeps the row marked as done.
  static void _releaseReseal(String rowId) {
    _resealSeen.remove(rowId);
  }

  /// Moves every cached copy of a row to its new id.
  static void _applyRekey(String oldRowId, String newRowId) {
    _rowIdRemap[oldRowId] = newRowId;
    _resealSeen.add(newRowId);
    for (final docs in _cacheByChatId.values) {
      for (var i = 0; i < docs.length; i++) {
        if (docs[i].rowId == oldRowId) {
          docs[i] = docs[i].copyWith(rowId: newRowId);
        }
      }
    }
    final loose = _looseDocs.remove(oldRowId);
    if (loose != null) {
      _looseDocs[newRowId] = loose.copyWith(rowId: newRowId);
    }
    final versions = _versionCache.remove(oldRowId);
    if (versions != null) {
      _versionCache[newRowId] = versions;
    }
    final index = _indexByRowId;
    final ref = index?.remove(oldRowId);
    if (index != null && ref != null) {
      index[newRowId] = (
        rowId: newRowId,
        handle: ref.handle,
        chatId: ref.chatId,
        title: ref.title,
        language: ref.language,
        updatedAt: ref.updatedAt,
        // A re-seal keeps the row's stamp (see the migration's trigger).
        stamp: ref.stamp,
      );
    }
  }

  /// Follows the re-keys of this session, so a stale row id finds its row.
  static String _canonicalRowId(String rowId) {
    var current = rowId;
    for (var hops = 0; hops < 4; hops++) {
      final next = _rowIdRemap[current];
      if (next == null) break;
      current = next;
    }
    return current;
  }

  static bool _isSameRow(ArtifactDocument doc, String rowId) =>
      _canonicalRowId(doc.rowId) == _canonicalRowId(rowId);

  static void _markSealColumnMissing(
    PostgrestException error, {
    required String operation,
  }) {
    if (_sealColumnMissing) return;
    _sealColumnMissing = true;
    _resealQueue.clear();
    unawaited(
      DiagnosticsLogService.warning(
        'artifact',
        'encrypted_meta column missing; artifact re-seal paused for this '
            'session',
        data: {'operation': operation, 'code': error.code},
      ),
    );
    if (kDebugMode) {
      debugPrint(
        'Artifact encrypted_meta column missing (operation: $operation); '
        're-seal paused for this session.',
      );
    }
  }

  static void _logResealFailure(String operation, String reason) {
    unawaited(
      DiagnosticsLogService.warning(
        'artifact',
        'Artifact re-seal failed',
        data: {'operation': operation, 'reason': reason},
      ),
    );
    if (kDebugMode) {
      debugPrint('Artifact re-seal failed ($operation): $reason');
    }
  }

  // ---------------------------------------------------------------------
  // Row lock
  // ---------------------------------------------------------------------

  /// Runs [body] while no other artifact row operation of this device runs.
  ///
  /// Re-sealing a legacy row changes its primary key. Every path that
  /// resolves a row id and then reads or writes by it — loads that fill the
  /// caches, writes, the re-seal worker — runs under this lock, so none of
  /// them acts on a row id another one just moved. Re-entrant: a call made
  /// from inside the section it belongs to runs straight away. A waiter
  /// gives up waiting after [_rowLockWait] and goes ahead.
  static Future<T> _withRowLock<T>(Future<T> Function() body) {
    final holder = _rowLockHolder;
    if (holder != null && identical(Zone.current[_rowLockZoneKey], holder)) {
      return body();
    }
    final previous = _rowLockTail;
    final release = Completer<void>();
    _rowLockTail = release.future;
    final token = Object();
    return previous
        .timeout(_rowLockWait, onTimeout: _onRowLockTimeout)
        .then((_) {
          _rowLockHolder = token;
          return runZoned(body, zoneValues: {_rowLockZoneKey: token});
        })
        .whenComplete(() {
          if (identical(_rowLockHolder, token)) _rowLockHolder = null;
          release.complete();
        });
  }

  static void _onRowLockTimeout() {
    unawaited(
      DiagnosticsLogService.warning(
        'artifact',
        'Artifact row lock wait timed out; continuing',
        data: {'waitMs': _rowLockWait.inMilliseconds},
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Pure helpers (unit-tested)
  // ---------------------------------------------------------------------

  /// Opens the `encrypted_meta` value of the `artifacts` row [rowId] (the
  /// id of the row it was read from). `meta` is null for a legacy row (no
  /// envelope). `unreadable` is true when the envelope cannot be opened or
  /// was sealed for another row — the server moved it — and such a row is
  /// treated like one sealed with another key.
  @visibleForTesting
  static Future<({Map<String, dynamic>? meta, bool unreadable})>
  decodeRowMeta(Object? envelope, {required String rowId}) async {
    if (envelope is! String) return (meta: null, unreadable: false);
    try {
      final meta = await EncryptedMeta.decode(
        envelope,
        table: _artifactsTable,
        rowId: rowId,
      );
      return (meta: meta, unreadable: false);
    } catch (_) {
      return (meta: null, unreadable: true);
    }
  }

  /// Resolves an `artifacts` row and its opened metadata ([meta] null for a
  /// legacy row). The handle is the sealed one, else the row id (a legacy
  /// row). Title and language follow [EncryptedMeta.pick]: real plaintext —
  /// a legacy row, or an old build that wrote after the seal — wins over
  /// the sealed value. A row whose metadata cannot be opened
  /// ([metaUnreadable]) shows its row id as handle and the placeholder as
  /// title.
  @visibleForTesting
  static ArtifactRowRef rowRefFromRow(
    Map<String, dynamic> row, {
    required Map<String, dynamic>? meta,
    bool metaUnreadable = false,
  }) {
    final rowId = row['id'] as String;
    final sealed = metaUnreadable ? null : meta;
    final sealedHandle = sealed?['handle'];
    final handle = sealedHandle is String && sealedHandle.trim().isNotEmpty
        ? sealedHandle.trim()
        : rowId;
    final title =
        EncryptedMeta.pick(row['title'], sealed, 'title') ??
        (metaUnreadable ? kEncryptedPlaceholder : handle);
    return (
      rowId: rowId,
      handle: handle,
      chatId: row['chat_id'] as String? ?? '',
      title: title,
      language: EncryptedMeta.pick(row['language'], sealed, 'language'),
      updatedAt: _parseTimestamp(row['updated_at']),
      stamp: row['updated_at'] is String ? row['updated_at'] as String : null,
    );
  }

  /// The document for an `artifacts` row: [ArtifactDocument.id] is the
  /// handle, [ArtifactDocument.rowId] the primary key. See [rowRefFromRow].
  @visibleForTesting
  static ArtifactDocument documentFromRow(
    Map<String, dynamic> row, {
    required String decryptedContent,
    required Map<String, dynamic>? meta,
    bool metaUnreadable = false,
  }) {
    final ref = rowRefFromRow(
      row,
      meta: meta,
      metaUnreadable: metaUnreadable,
    );
    final attachment = row['attachment_path'] as String?;
    return ArtifactDocument(
      id: ref.handle,
      rowId: ref.rowId,
      chatId: row['chat_id'] as String,
      userId: row['user_id'] as String,
      messageId: row['message_id'] as String?,
      title: ref.title,
      type: ArtifactTypeX.fromValue(row['type'] as String? ?? 'markdown'),
      language: ref.language,
      content: decryptedContent,
      version: (row['version'] as num?)?.toInt() ?? 1,
      attachmentPath: attachment?.trim().isEmpty == true ? null : attachment,
      createdAt: _parseTimestamp(row['created_at']),
      updatedAt: ref.updatedAt,
      updatedAtStamp: ref.stamp,
    );
  }

  /// Whether a row still needs a re-seal: never sealed, plaintext in
  /// `title` / `language` (an old build wrote after the seal), or a sealed
  /// row whose id still is its handle. Mirrors [resealCandidateFilter].
  /// Never true for a row whose metadata cannot be opened.
  @visibleForTesting
  static bool needsReseal(
    Map<String, dynamic> row, {
    required Map<String, dynamic>? meta,
    bool metaUnreadable = false,
  }) {
    if (metaUnreadable) return false;
    final envelope = row['encrypted_meta'];
    if (envelope is! String || envelope.trim().isEmpty) return true;
    if (row['title'] != kEncryptedPlaceholder) return true;
    if (row['language'] != null) return true;
    return meta?['handle'] == row['id'];
  }

  /// The row a handle or row id names: the newest row with that handle
  /// (an old build can leave two), else the row with that id.
  @visibleForTesting
  static ArtifactRowRef? resolveRowRef(
    Iterable<ArtifactRowRef> refs,
    String key,
  ) {
    ArtifactRowRef? newest;
    ArtifactRowRef? byRowId;
    for (final ref in refs) {
      if (ref.handle == key) {
        if (newest == null || ref.updatedAt.isAfter(newest.updatedAt)) {
          newest = ref;
        }
      } else if (ref.rowId == key) {
        byRowId = ref;
      }
    }
    return newest ?? byRowId;
  }

  /// The snapshot a re-seal works from: of the copies this device holds of
  /// one row, the one with the newest stamp. Stamps are compared, not
  /// [ArtifactRowRef.updatedAt], because only the stamp is always the
  /// server's clock. Values and stamp stay together. On a tie the earlier
  /// copy wins. Null when no copy has a stamp.
  @visibleForTesting
  static ArtifactRowRef? freshestRef(Iterable<ArtifactRowRef> copies) {
    ArtifactRowRef? best;
    DateTime? bestAt;
    for (final copy in copies) {
      final stamp = copy.stamp;
      if (stamp == null || stamp.isEmpty) continue;
      final at = DateTime.tryParse(stamp);
      if (best == null ||
          (at != null && (bestAt == null || at.isAfter(bestAt)))) {
        best = copy;
        bestAt = at;
      }
    }
    return best;
  }

  /// The filters of a re-seal update: the row, its owner, and the raw
  /// `updated_at` read together with the values being sealed. Any newer
  /// edit (another device, an old build) moves the stamp, so the update
  /// then matches nothing and that edit survives. A re-seal itself keeps
  /// the stamp. Null without a stamp. Never a handle, title or envelope.
  @visibleForTesting
  static Map<String, String>? resealFilters(
    ArtifactRowRef ref, {
    required String userId,
  }) {
    final stamp = ref.stamp;
    if (stamp == null || stamp.isEmpty) return null;
    return <String, String>{
      'id': ref.rowId,
      'user_id': userId,
      'updated_at': stamp,
    };
  }

  /// The metadata columns of a sealed row: the placeholder in `title`,
  /// null in `language`, and one envelope with handle, title and language,
  /// bound to [rowId]. [rowId] is the id the row has once the write that
  /// carries these columns has run (the new id on a re-key).
  @visibleForTesting
  static Future<Map<String, dynamic>> sealedMetaColumns({
    required String rowId,
    required String handle,
    required String title,
    String? language,
  }) async {
    return <String, dynamic>{
      'title': kEncryptedPlaceholder,
      'language': null,
      'encrypted_meta': await EncryptedMeta.encode(
        <String, Object?>{
          'handle': handle,
          'title': title,
          'language': language,
        },
        table: _artifactsTable,
        rowId: rowId,
      ),
    };
  }

  /// The insert for a new artifact: a random row id, the handle only inside
  /// the envelope. An empty title falls back to the handle.
  @visibleForTesting
  static Future<Map<String, dynamic>> buildInsertPayload({
    required String rowId,
    required String handle,
    required String chatId,
    required String userId,
    required String title,
    required ArtifactType type,
    required String encryptedContent,
    required DateTime now,
    String? language,
    String? messageId,
    String? attachmentPath,
  }) async {
    final timestamp = now.toUtc().toIso8601String();
    return <String, dynamic>{
      'id': rowId,
      'chat_id': chatId,
      'user_id': userId,
      'message_id': messageId,
      'type': type.value,
      'content': encryptedContent,
      'version': 1,
      'is_active': true,
      'attachment_path': attachmentPath,
      'created_at': timestamp,
      'updated_at': timestamp,
      ...await sealedMetaColumns(
        rowId: rowId,
        handle: handle,
        title: _titleOrHandle(title, handle),
        language: _cleanLanguage(language),
      ),
    };
  }

  /// The update that re-seals [ref]'s row. A row whose id still is its
  /// handle (legacy) also gets a random id from [newRowId], and the envelope
  /// is sealed for that new id in the same update; its versions follow
  /// through the ON UPDATE CASCADE foreign key.
  @visibleForTesting
  static Future<Map<String, dynamic>> buildResealUpdate(
    ArtifactRowRef ref, {
    String Function()? newRowId,
  }) async {
    final rekeyedTo = ref.rowId == ref.handle
        ? (newRowId ?? _uuid.v4)()
        : null;
    return <String, dynamic>{
      'id': ?rekeyedTo,
      ...await sealedMetaColumns(
        rowId: rekeyedTo ?? ref.rowId,
        handle: ref.handle,
        title: ref.title,
        language: ref.language,
      ),
    };
  }

  /// Whether [id] is a valid handle (the AI-facing artifact id).
  @visibleForTesting
  static bool isValidHandle(String id) =>
      _artifactIdPattern.hasMatch(id.trim());

  static String _titleOrHandle(String title, String handle) =>
      title.trim().isEmpty ? handle : title.trim();

  static String? _cleanLanguage(String? language) {
    final trimmed = language?.trim();
    return trimmed == null || trimmed.isEmpty ? null : trimmed;
  }

  static DateTime _parseTimestamp(Object? raw) =>
      DateTime.tryParse(raw is String ? raw : '') ?? DateTime.now().toUtc();

  static User _requireUser() {
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      throw StateError('No authenticated user.');
    }
    _ensureCacheForUser(user.id);
    return user;
  }

  static void _ensureCacheForUser(String userId) {
    if (_cacheUserId == userId) {
      return;
    }
    _cacheUserId = userId;
    _cacheByChatId.clear();
    _looseDocs.clear();
    _versionCache.clear();
    _indexByRowId = null;
    _indexBuiltAt = null;
    _rowIdRemap.clear();
    _unreadableRowIds.clear();
    _openedMeta.clear();
    _resealSeen.clear();
    _resealQueue.clear();
    if (activeArtifactNotifier.value?.userId != userId) {
      activeArtifactNotifier.value = null;
    }
  }

  static void _validateArtifactId(String id) {
    final trimmed = id.trim();
    if (trimmed.isEmpty) {
      throw StateError('artifact_id is required.');
    }
    if (!_artifactIdPattern.hasMatch(trimmed)) {
      throw StateError(
        'Invalid artifact_id. Use only letters, numbers, and hyphens.',
      );
    }
  }

  static void _validateContentSize(String content) {
    final bytes = utf8.encode(content).length;
    if (bytes > maxContentBytes) {
      throw StateError(
        'Artifact content exceeds 500KB limit (${(bytes / 1024).toStringAsFixed(1)}KB).',
      );
    }
  }

  static bool _isDuplicateArtifactError(PostgrestException error) {
    final code = error.code?.toLowerCase() ?? '';
    final message = error.message.toLowerCase();
    return code == '23505' || message.contains('duplicate key');
  }

  static bool _handleMissingArtifactSchema(
    PostgrestException error, {
    required String operation,
  }) {
    if (!_isMissingArtifactSchemaError(error)) return false;

    _artifactStorageAvailable = false;
    _cacheByChatId.clear();
    _looseDocs.clear();
    _versionCache.clear();
    _indexByRowId = null;
    _indexBuiltAt = null;
    if (activeArtifactNotifier.value != null) {
      activeArtifactNotifier.value = null;
    }

    unawaited(
      DiagnosticsLogService.warning(
        'artifact',
        'Artifact schema missing; disabling artifact features',
        data: {
          'operation': operation,
          'code': error.code,
          'message': error.message,
          'hint': error.hint,
        },
      ),
    );

    if (kDebugMode && !_missingSchemaLogged) {
      _missingSchemaLogged = true;
      debugPrint(
        'Artifact schema missing (operation: $operation). '
        'Artifacts are now disabled for this app session.',
      );
    }

    return true;
  }

  static bool _isMissingArtifactSchemaError(PostgrestException error) {
    final code = (error.code ?? '').toUpperCase();
    final message = error.message.toLowerCase();
    final details = (error.details ?? '').toString().toLowerCase();
    final hint = (error.hint ?? '').toString().toLowerCase();

    if (code == 'PGRST205') return true;
    // A missing `encrypted_meta` column is not a missing table: reads keep
    // working, only sealing stops (see _markSealColumnMissing).
    if (_isMissingMetaColumnError(error)) return false;
    final mentionsArtifacts =
        message.contains('artifacts') ||
        message.contains('artifact_versions') ||
        details.contains('artifacts') ||
        details.contains('artifact_versions') ||
        hint.contains('artifacts') ||
        hint.contains('artifact_versions');

    if (!mentionsArtifacts) return false;
    return message.contains('schema cache') ||
        message.contains('could not find the table');
  }

  /// PostgREST names the column when it is missing (42703, or PGRST204
  /// "Could not find the 'encrypted_meta' column ... in the schema cache").
  static bool _isMissingMetaColumnError(PostgrestException error) =>
      EncryptedMeta.isMissingColumnError(error);

  static Future<String> _encryptOrThrow(String content) async {
    try {
      return await EncryptionService.encrypt(content);
    } catch (error) {
      throw StateError('Failed to encrypt artifact content: $error');
    }
  }

  /// Runs a sealing step; turns a cipher failure into the same kind of
  /// error [_encryptOrThrow] raises.
  static Future<T> _sealOrThrow<T>(Future<T> Function() seal) async {
    try {
      return await seal();
    } catch (error) {
      throw StateError('Failed to encrypt artifact metadata: $error');
    }
  }

  static Future<String> _decryptMaybe(String value) async {
    if (value.isEmpty) return '';

    if (!looksLikeEncryptedPayload(value)) {
      return value;
    }

    try {
      return await EncryptionService.decrypt(value);
    } catch (error) {
      unawaited(
        DiagnosticsLogService.warning(
          'artifact',
          'Artifact decrypt failed; returning placeholder',
          data: {'error': error.toString()},
        ),
      );
      if (kDebugMode) {
        debugPrint('Artifact decrypt failed: $error');
      }
      return '[Encrypted artifact content unavailable]';
    }
  }

}
