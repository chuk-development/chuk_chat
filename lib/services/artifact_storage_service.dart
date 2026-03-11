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
  static const int maxContentBytes = 500 * 1024; // 500 KB
  static final RegExp _artifactIdPattern = RegExp(r'^[A-Za-z0-9-]+$');

  static final StreamController<void> _changesController =
      StreamController<void>.broadcast();
  static Stream<void> get changes => _changesController.stream;

  static final ValueNotifier<ArtifactDocument?> activeArtifactNotifier =
      ValueNotifier<ArtifactDocument?>(null);

  static String? _activeChatId;
  static String? _cacheUserId;
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
    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      return const <ArtifactDocument>[];
    }

    _ensureCacheForUser(user.id);
    if (!forceRefresh && _cacheByChatId.containsKey(chatId)) {
      return List<ArtifactDocument>.from(_cacheByChatId[chatId]!);
    }

    final response = await SupabaseService.client
        .from(_artifactsTable)
        .select()
        .eq('chat_id', chatId)
        .eq('user_id', user.id)
        .eq('is_active', true)
        .order('updated_at', ascending: false);

    final rows = (response as List)
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

    final row = await SupabaseService.client
        .from(_artifactsTable)
        .select()
        .eq('id', normalizedArtifactId)
        .eq('user_id', user.id)
        .eq('is_active', true)
        .maybeSingle();

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
  }) async {
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
      'created_at': now.toIso8601String(),
      'updated_at': now.toIso8601String(),
    };

    try {
      await SupabaseService.client.from(_artifactsTable).insert(insertPayload);
    } on PostgrestException catch (error) {
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
    bool preserveMetadata = false,
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

    final updateRows = await SupabaseService.client
        .from(_artifactsTable)
        .update({
          'title': resolvedTitle,
          'type': resolvedType.value,
          'language': resolvedLanguage,
          'content': encrypted,
          'version': nextVersion,
          'updated_at': now.toIso8601String(),
        })
        .eq('id', current.id)
        .eq('user_id', current.userId)
        .select('id');

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

    final updated = current.copyWith(
      title: resolvedTitle,
      type: resolvedType,
      language: resolvedLanguage,
      content: content,
      version: nextVersion,
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
    if (!forceRefresh && _versionCache.containsKey(artifactId)) {
      return List<ArtifactVersionSnapshot>.from(_versionCache[artifactId]!);
    }

    final user = SupabaseService.auth.currentUser;
    if (user == null) {
      return const <ArtifactVersionSnapshot>[];
    }
    _ensureCacheForUser(user.id);

    final response = await SupabaseService.client
        .from(_versionsTable)
        .select()
        .eq('artifact_id', artifactId)
        .eq('user_id', user.id)
        .order('version', ascending: false);

    final rows = (response as List)
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
  }) async {
    await SupabaseService.client.from(_versionsTable).insert({
      'artifact_id': artifactId,
      'chat_id': chatId,
      'user_id': userId,
      'version': version,
      'content': encryptedContent,
      'created_at': createdAt.toIso8601String(),
    });
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
