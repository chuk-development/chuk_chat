// lib/services/artifact_storage_service.dart
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chuk_chat/models/artifact.dart';
import 'package:chuk_chat/services/artifact_diff_engine.dart';
import 'package:chuk_chat/services/diagnostics_log_service.dart';
import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';

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
  static final Map<String, List<ArtifactVersionSnapshot>> _versionCache =
      <String, List<ArtifactVersionSnapshot>>{};

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

    final rows = response
        .map((row) => Map<String, dynamic>.from(row as Map))
        .toList(growable: false);

    final docs = <ArtifactDocument>[];
    for (final row in rows) {
      final raw = row['content'] as String? ?? '';
      final content = await _decryptMaybe(raw);
      docs.add(ArtifactDocument.fromMap(row, decryptedContent: content));
    }
    return docs;
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

    final rows = response
        .map((row) => Map<String, dynamic>.from(row as Map))
        .toList(growable: false);

    final docs = <ArtifactDocument>[];
    for (final row in rows) {
      final raw = row['content'] as String? ?? '';
      final content = await _decryptMaybe(raw);
      docs.add(ArtifactDocument.fromMap(row, decryptedContent: content));
    }

    _cacheByChatId[chatId] = docs;
    return List<ArtifactDocument>.from(docs);
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

  static Future<ArtifactDocument?> loadArtifactById(String artifactId) async {
    if (!_artifactStorageAvailable) return null;

    final normalizedArtifactId = artifactId.trim();
    if (normalizedArtifactId.isEmpty) return null;

    final user = SupabaseService.auth.currentUser;
    if (user == null) return null;
    _ensureCacheForUser(user.id);

    for (final artifacts in _cacheByChatId.values) {
      for (final artifact in artifacts) {
        if (artifact.id == normalizedArtifactId) {
          return artifact;
        }
      }
    }

    final row = await (() async {
      try {
        return await SupabaseService.client
            .from(_artifactsTable)
            .select()
            .eq('id', normalizedArtifactId)
            .eq('user_id', user.id)
            .eq('is_active', true)
            .maybeSingle();
      } on PostgrestException catch (error) {
        if (_handleMissingArtifactSchema(
          error,
          operation: 'loadArtifactById',
        )) {
          return null;
        }
        rethrow;
      }
    })();

    if (row == null) return null;
    final map = Map<String, dynamic>.from(row as Map);
    final content = await _decryptMaybe(map['content'] as String? ?? '');
    final doc = ArtifactDocument.fromMap(map, decryptedContent: content);
    _insertIntoCache(doc);
    return doc;
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

    final normalizedArtifactId = artifactId.trim();
    final user = _requireUser();
    _validateArtifactId(normalizedArtifactId);
    _validateContentSize(content);

    final encrypted = await _encryptOrThrow(content);
    final now = DateTime.now().toUtc();

    final insertPayload = {
      'id': normalizedArtifactId,
      'chat_id': chatId,
      'user_id': user.id,
      'message_id': messageId,
      'title': title.trim().isEmpty ? normalizedArtifactId : title.trim(),
      'type': type.value,
      'language': language?.trim().isEmpty == true ? null : language?.trim(),
      'content': encrypted,
      'version': 1,
      'is_active': true,
      'attachment_path': attachmentPath,
      'created_at': now.toIso8601String(),
      'updated_at': now.toIso8601String(),
    };

    try {
      await SupabaseService.client.from(_artifactsTable).insert(insertPayload);
    } on PostgrestException catch (error) {
      if (_handleMissingArtifactSchema(error, operation: 'createArtifact')) {
        throw StateError(_missingSchemaMessage);
      }
      if (_isDuplicateArtifactError(error)) {
        throw StateError(
          'Artifact "$normalizedArtifactId" already exists. Use update or rewrite.',
        );
      }
      rethrow;
    }

    try {
      await _insertVersion(
        artifactId: normalizedArtifactId,
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
            .eq('id', normalizedArtifactId)
            .eq('user_id', user.id);
      } catch (rollbackError) {
        unawaited(
          DiagnosticsLogService.error(
            'artifact',
            'Artifact rollback delete failed',
            data: {
              'artifactId': normalizedArtifactId,
              'rollbackError': rollbackError.toString(),
              'originalError': error.toString(),
            },
          ),
        );
        if (kDebugMode) {
          debugPrint(
            'Artifact rollback delete failed for $normalizedArtifactId: '
            '$rollbackError (original: $error)',
          );
        }
      }
      rethrow;
    }

    final doc = ArtifactDocument(
      id: normalizedArtifactId,
      chatId: chatId,
      userId: user.id,
      messageId: messageId,
      title: title.trim().isEmpty ? normalizedArtifactId : title.trim(),
      type: type,
      language: language?.trim().isEmpty == true ? null : language?.trim(),
      content: content,
      version: 1,
      attachmentPath: attachmentPath,
      createdAt: now,
      updatedAt: now,
    );

    _insertIntoCache(doc);
    _emitChange(doc.chatId, doc);
    // Opening the panel is reserved for AI-generated artifacts. Create is
    // only reached from the artifact_manager tool / <artifact> tag flow,
    // never from chat load — so popping the panel here is safe.
    panelOpenNotifier.value = true;
    return doc;
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

    final List updateRows;
    try {
      updateRows = await SupabaseService.client
          .from(_artifactsTable)
          .update({
            'title': resolvedTitle,
            'type': resolvedType.value,
            'language': resolvedLanguage,
            'content': encrypted,
            'version': nextVersion,
            'attachment_path': resolvedAttachment,
            'updated_at': now.toIso8601String(),
          })
          .eq('id', current.id)
          .eq('user_id', current.userId)
          .select('id');
    } on PostgrestException catch (error) {
      if (_handleMissingArtifactSchema(error, operation: 'rewriteArtifact')) {
        throw StateError(_missingSchemaMessage);
      }
      rethrow;
    }

    if (updateRows.isEmpty) {
      throw StateError(
        'Artifact "${current.id}" was not found or is no longer editable.',
      );
    }

    try {
      await _insertVersion(
        artifactId: current.id,
        chatId: current.chatId,
        userId: current.userId,
        version: nextVersion,
        encryptedContent: encrypted,
        createdAt: now,
        attachmentPath: resolvedAttachment,
      );
    } catch (error) {
      try {
        await SupabaseService.client
            .from(_artifactsTable)
            .update({
              'title': current.title,
              'type': current.type.value,
              'language': current.language,
              'content': previousEncrypted,
              'version': current.version,
              'attachment_path': current.attachmentPath,
              'updated_at': current.updatedAt.toIso8601String(),
            })
            .eq('id', current.id)
            .eq('user_id', current.userId);
      } catch (rollbackError) {
        unawaited(
          DiagnosticsLogService.error(
            'artifact',
            'Artifact rollback update failed',
            data: {
              'artifactId': current.id,
              'rollbackError': rollbackError.toString(),
              'originalError': error.toString(),
            },
          ),
        );
        if (kDebugMode) {
          debugPrint(
            'Artifact rollback update failed for ${current.id}: '
            '$rollbackError (original: $error)',
          );
        }
      }
      rethrow;
    }

    final updated = ArtifactDocument(
      id: current.id,
      chatId: current.chatId,
      userId: current.userId,
      messageId: current.messageId,
      title: resolvedTitle,
      type: resolvedType,
      language: resolvedLanguage,
      content: content,
      version: nextVersion,
      attachmentPath: resolvedAttachment,
      createdAt: current.createdAt,
      updatedAt: now,
    );

    _insertIntoCache(updated);
    _versionCache.remove(updated.id);
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
          .eq('id', current.id)
          .eq('user_id', current.userId)
          .eq('version', current.version)
          .select('id');
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
      // rewrite landed mid-edit). Either way, the caller's in-memory copy
      // is stale — surface a clear error and let them reload.
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
          .eq('artifact_id', current.id)
          .eq('user_id', current.userId)
          .eq('version', current.version)
          .select('id');

      if (versionUpdateRows.isEmpty) {
        await _insertVersion(
          artifactId: current.id,
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

    final updated = ArtifactDocument(
      id: current.id,
      chatId: current.chatId,
      userId: current.userId,
      messageId: current.messageId,
      title: current.title,
      type: current.type,
      language: current.language,
      content: content,
      version: current.version,
      attachmentPath: current.attachmentPath,
      createdAt: current.createdAt,
      updatedAt: now,
    );

    _insertIntoCache(updated);
    // Drop cached version history for this artifact — the snapshot row we
    // just rewrote in-place is stale in the cache.
    _versionCache.remove(updated.id);
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

    if (!forceRefresh && _versionCache.containsKey(artifactId)) {
      return List<ArtifactVersionSnapshot>.from(_versionCache[artifactId]!);
    }

    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      return const <ArtifactVersionSnapshot>[];
    }
    _ensureCacheForUser(user.id);

    final List response;
    try {
      response = await SupabaseService.client
          .from(_versionsTable)
          .select()
          .eq('artifact_id', artifactId)
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
        ArtifactVersionSnapshot.fromMap(row, decryptedContent: content),
      );
    }

    _versionCache[artifactId] = versions;
    return List<ArtifactVersionSnapshot>.from(versions);
  }

  static Future<void> _insertVersion({
    required String artifactId,
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
        'artifact_id': artifactId,
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

    // 1. Find the snapshot rows that belong to the discarded messages.
    final List discardedRows;
    try {
      discardedRows = await SupabaseService.client
          .from(_versionsTable)
          .select('id, artifact_id, version, chat_id')
          .inFilter('message_id', ids)
          .eq('user_id', user.id);
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

    if (discardedRows.isEmpty) return;

    // 2. Group discarded snapshots by artifact_id.
    final discardedByArtifact = <String, List<Map<String, dynamic>>>{};
    for (final row in discardedRows) {
      final map = Map<String, dynamic>.from(row as Map);
      final artifactId = (map['artifact_id'] as String?)?.trim();
      if (artifactId == null || artifactId.isEmpty) continue;
      discardedByArtifact.putIfAbsent(artifactId, () => []).add(map);
    }
    if (discardedByArtifact.isEmpty) return;

    // 3. For each affected artifact, delete the discarded snapshot rows
    //    and then either roll back to the latest remaining snapshot or
    //    delete the artifact entirely. Per-artifact failures are logged
    //    but do not abort the whole batch.
    final affectedChats = <String>{};
    final fullyDeleted = <String>{};
    for (final entry in discardedByArtifact.entries) {
      final artifactId = entry.key;
      final discardedSnapshots = entry.value;
      try {
        final outcome = await _rollbackOneArtifact(
          artifactId: artifactId,
          discardedSnapshots: discardedSnapshots,
          userId: user.id,
        );
        if (outcome.affectedChatId != null) {
          affectedChats.add(outcome.affectedChatId!);
        }
        if (outcome.deleted) {
          fullyDeleted.add(artifactId);
        }
      } catch (error) {
        if (kDebugMode) {
          debugPrint(
            '[rollbackArtifactsForMessages] artifact $artifactId failed: '
            '$error',
          );
        }
        unawaited(
          DiagnosticsLogService.error(
            'artifact',
            'Artifact rollback failed for one artifact',
            data: {
              'artifactId': artifactId,
              'error': error.toString(),
            },
          ),
        );
      }
    }

    // 4. Drop the cached version history for every touched artifact.
    for (final id in discardedByArtifact.keys) {
      _versionCache.remove(id);
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
  /// emit one change event after the batch.
  static Future<({bool deleted, String? affectedChatId})> _rollbackOneArtifact({
    required String artifactId,
    required List<Map<String, dynamic>> discardedSnapshots,
    required String userId,
  }) async {
    // Load the current artifact so we know which chat it belongs to and
    // whether the active notifier is pointing at it.
    final current = await loadArtifactById(artifactId);
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
            .eq('artifact_id', artifactId)
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
      artifactId: artifactId,
      userId: userId,
    );

    if (latestRemaining == null) {
      // No prior snapshot — discarded message created this artifact.
      // Delete the row entirely.
      try {
        await SupabaseService.client
            .from(_artifactsTable)
            .delete()
            .eq('id', artifactId)
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

      _removeArtifactFromCache(artifactId);
      final active = activeArtifactNotifier.value;
      if (active != null && active.id == artifactId) {
        activeArtifactNotifier.value = null;
        panelOpenNotifier.value = false;
      }
      return (deleted: true, affectedChatId: chatId);
    }

    // A prior snapshot remains — reset the artifact row to it. Use the
    // raw encrypted content from the snapshot row to avoid a redundant
    // encrypt round-trip.
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

    try {
      await SupabaseService.client
          .from(_artifactsTable)
          .update({
            'content': raw,
            'version': restoredVersion,
            'attachment_path': attachmentPath,
            'updated_at': restoredCreatedAt.toIso8601String(),
          })
          .eq('id', artifactId)
          .eq('user_id', userId);
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
    final restored = (current ??
            ArtifactDocument(
              id: artifactId,
              chatId: chatId ?? '',
              userId: userId,
              title: artifactId,
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
    );

    _insertIntoCache(restored);
    final active = activeArtifactNotifier.value;
    if (active != null && active.id == artifactId) {
      activeArtifactNotifier.value = restored;
    } else if (_activeChatId == restored.chatId) {
      // Keep `_emitChange` semantics in sync — the active chat saw an
      // artifact mutation even if the active notifier was pointed at a
      // sibling artifact.
    }
    return (deleted: false, affectedChatId: restored.chatId);
  }

  /// Returns the latest remaining snapshot row for [artifactId] (after the
  /// rollback delete), or `null` if no snapshot survived. Encrypted content
  /// is returned raw so the caller can avoid a redundant decrypt cycle when
  /// it only needs to forward the value to the `artifacts` table.
  static Future<Map<String, dynamic>?> _loadLatestRemainingSnapshot({
    required String artifactId,
    required String userId,
  }) async {
    try {
      final row = await SupabaseService.client
          .from(_versionsTable)
          .select()
          .eq('artifact_id', artifactId)
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

  static void _removeArtifactFromCache(String artifactId) {
    for (final entry in _cacheByChatId.entries) {
      entry.value.removeWhere((doc) => doc.id == artifactId);
    }
    _versionCache.remove(artifactId);
  }

  /// Hard-deletes the given artifact ids (and their version history) for the
  /// current user. Used on resend: removed AI messages must not leave orphan
  /// artifact cards pinned to the chat.
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

    try {
      await SupabaseService.client
          .from(_versionsTable)
          .delete()
          .inFilter('artifact_id', ids)
          .eq('user_id', user.id);
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
      await SupabaseService.client
          .from(_artifactsTable)
          .delete()
          .inFilter('id', ids)
          .eq('user_id', user.id);
    } on PostgrestException catch (error) {
      if (_handleMissingArtifactSchema(
        error,
        operation: 'deleteArtifactsByIds',
      )) {
        return;
      }
      if (kDebugMode) {
        debugPrint('[deleteArtifactsByIds] artifact delete failed: $error');
      }
      return;
    }

    final affectedChats = <String>{};
    for (final entry in _cacheByChatId.entries) {
      final before = entry.value.length;
      entry.value.removeWhere((doc) => ids.contains(doc.id));
      if (entry.value.length != before) {
        affectedChats.add(entry.key);
      }
    }
    for (final id in ids) {
      _versionCache.remove(id);
    }
    final active = activeArtifactNotifier.value;
    if (active != null && ids.contains(active.id)) {
      activeArtifactNotifier.value = null;
    }
    if (affectedChats.isNotEmpty) {
      _changesController.add(null);
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

    if (kDebugMode) {
      debugPrint('📄 [setAttachmentPath] Updating $artifactId → '
          '$attachmentPath');
    }
    try {
      await SupabaseService.client
          .from(_artifactsTable)
          .update({'attachment_path': attachmentPath})
          .eq('id', artifactId)
          .eq('user_id', user.id);
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
    for (final entry in _cacheByChatId.entries) {
      final idx = entry.value.indexWhere((a) => a.id == artifactId);
      if (idx == -1) continue;
      final old = entry.value[idx];
      final updated = old.copyWith(attachmentPath: attachmentPath);
      entry.value[idx] = updated;
      _emitChange(entry.key, updated);
      if (kDebugMode) {
        debugPrint('📄 [setAttachmentPath] ✅ Cache updated for '
            '$artifactId');
      }
      break;
    }
  }

  static void _emitChange(String chatId, ArtifactDocument updated) {
    if (_activeChatId == chatId) {
      activeArtifactNotifier.value = updated;
    }
    _changesController.add(null);
  }

  static void _insertIntoCache(ArtifactDocument doc) {
    final existing = List<ArtifactDocument>.from(
      _cacheByChatId[doc.chatId] ?? [],
    );
    existing.removeWhere((item) => item.id == doc.id);
    existing.insert(0, doc);
    existing.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    _cacheByChatId[doc.chatId] = existing;
  }

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
    _versionCache.clear();
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
    _versionCache.clear();
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

  static Future<String> _encryptOrThrow(String content) async {
    try {
      return await EncryptionService.encrypt(content);
    } catch (error) {
      throw StateError('Failed to encrypt artifact content: $error');
    }
  }

  static Future<String> _decryptMaybe(String value) async {
    if (value.isEmpty) return '';

    if (!_looksLikeEncryptedPayload(value)) {
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

  static bool _looksLikeEncryptedPayload(String value) {
    try {
      final decoded = jsonDecode(value);
      if (decoded is! Map<String, dynamic>) return false;
      return decoded['v'] != null &&
          decoded['nonce'] != null &&
          decoded['ciphertext'] != null &&
          decoded['mac'] != null;
    } catch (_) {
      return false;
    }
  }
}
