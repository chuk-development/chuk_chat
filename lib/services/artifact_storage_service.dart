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
  /// active artifact (inline card in chat can reopen it).
  static final ValueNotifier<bool> panelOpenNotifier = ValueNotifier<bool>(true);

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
  }) async {
    try {
      await SupabaseService.client.from(_versionsTable).insert({
        'artifact_id': artifactId,
        'chat_id': chatId,
        'user_id': userId,
        'version': version,
        'content': encryptedContent,
        'attachment_path': attachmentPath,
        'created_at': createdAt.toIso8601String(),
      });
    } on PostgrestException catch (error) {
      if (_handleMissingArtifactSchema(error, operation: '_insertVersion')) {
        throw StateError(_missingSchemaMessage);
      }
      rethrow;
    }
  }

  /// Sets [attachmentPath] on an existing artifact row **without** bumping
  /// the version. Used to backfill a compiled PDF for artifacts that were
  /// created before attachment persistence was available.
  static Future<void> setAttachmentPath({
    required String artifactId,
    required String attachmentPath,
  }) async {
    if (!_artifactStorageAvailable) return;

    final user = SupabaseService.auth.currentUser;
    if (user == null) return;
    _ensureCacheForUser(user.id);

    try {
      await SupabaseService.client
          .from(_artifactsTable)
          .update({'attachment_path': attachmentPath})
          .eq('id', artifactId)
          .eq('user_id', user.id);
    } on PostgrestException catch (error) {
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
