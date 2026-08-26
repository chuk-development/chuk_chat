/// Storage for the user's Agent Skills.
///
/// **Local SQLite is the source of truth** (the `skills` table, via
/// [LocalChatCacheService]), holding each skill's SKILL.md source in plaintext —
/// the same convention as `chat_cache`: the encryption key lives on the device,
/// so a second at-rest layer is theatre. Supabase is the cross-device mirror and
/// keeps the body E2E-encrypted.
///
/// **Catalog bookkeeping travels inside the encrypted blob.** A stored skill can
/// carry `catalogName` (which catalog entry it tracks) and `baselineHash` (the
/// catalog body hash it was seeded from). Rather than add plaintext columns to
/// Supabase, [encrypted_source] holds a small JSON envelope
/// `{v, source, catalog_name, baseline_hash}`; a legacy row that is raw SKILL.md
/// is still read correctly (see [_decodeEnvelope]). Locally these are real
/// columns so a device can reconcile without decrypting.
///
/// **Cache invalidation is keyed by user id, on purpose.** The obvious pattern —
/// a `resetCache()` on a logout hook — was dead code here; `notes_tools.dart`
/// compares the cached user id on every access instead, and that is the pattern
/// copied here. It needs no hook to be wired up.
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/models/skill.dart';
import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/local_chat_cache_service.dart';
import 'package:chuk_chat/services/skills/skill_frontmatter_parser.dart';
import 'package:chuk_chat/services/skills/skill_registry.dart';
import 'package:chuk_chat/services/supabase_service.dart';

/// Thrown for storage-level failures. Spec violations surface as
/// [SkillParseException] from the shared parser instead.
class UserSkillException implements Exception {
  const UserSkillException(this.message);

  final String message;

  @override
  String toString() => 'UserSkillException: $message';
}

class UserSkillsService {
  const UserSkillsService._();

  static const String _kTable = 'user_skills';

  /// Ceiling on stored skills. Every one costs a catalog entry (name +
  /// description) in every prompt, so this bounds Level-1 prompt weight. Higher
  /// than before because the catalog can seed many skills, not just the
  /// handful a user hand-writes.
  static const int kMaxUserSkills = 200;

  static String? _cachedUserId;
  static List<Skill>? _memCache;

  /// Drops the cache when the active user changed. Called at the top of every
  /// public entry point — see the library doc for why this is not a logout hook.
  static void _syncCacheToCurrentUser(String? userId) {
    if (_cachedUserId == userId) return;
    _cachedUserId = userId;
    _memCache = null;
  }

  static String? _currentUserId() {
    try {
      return SupabaseService.auth.currentUser?.id;
    } catch (_) {
      return null;
    }
  }

  static String _nowIso() => DateTime.now().toUtc().toIso8601String();

  // ─── Envelope ──────────────────────────────────────────────────────────

  /// Wraps a skill's source and catalog bookkeeping into the JSON that gets
  /// encrypted into `encrypted_source`.
  static String _encodeEnvelope(
    String source, {
    String? catalogName,
    String? baselineHash,
  }) {
    return jsonEncode({
      'v': 1,
      'source': source,
      'catalog_name': ?catalogName,
      'baseline_hash': ?baselineHash,
    });
  }

  /// Reads a decrypted `encrypted_source`. A v1 JSON envelope yields the source
  /// plus catalog fields; anything else is a legacy raw SKILL.md with no catalog
  /// bookkeeping.
  static ({String source, String? catalogName, String? baselineHash})
  _decodeEnvelope(String plaintext) {
    try {
      final decoded = jsonDecode(plaintext);
      if (decoded is Map && decoded['source'] is String) {
        return (
          source: decoded['source'] as String,
          catalogName: decoded['catalog_name'] as String?,
          baselineHash: decoded['baseline_hash'] as String?,
        );
      }
    } catch (_) {
      // Not JSON: a legacy raw-markdown row. Fall through.
    }
    return (source: plaintext, catalogName: null, baselineHash: null);
  }

  // ─── Load ──────────────────────────────────────────────────────────────

  /// Every stored skill, newest first. Local-first: memory, then the SQLite
  /// store, then a background Supabase refresh that rewrites the local store.
  ///
  /// Returns an empty list when signed out — a user with no skills and a user
  /// we cannot resolve both mean "no user skills in the prompt".
  static Future<List<Skill>> load({bool forceRefresh = false}) async {
    final userId = _currentUserId();
    _syncCacheToCurrentUser(userId);
    if (userId == null) return const [];

    if (!forceRefresh && _memCache != null) return _memCache!;

    if (!forceRefresh) {
      final local = await _loadLocal(userId);
      if (local.isNotEmpty) {
        _memCache = local;
        unawaited(_refreshFromServer(userId));
        return local;
      }
    }

    return _refreshFromServer(userId);
  }

  /// Reads the SQLite store and parses each row. A row that fails to parse is
  /// skipped, not fatal — one corrupt skill must not take the catalog down.
  static Future<List<Skill>> _loadLocal(String userId) async {
    try {
      final rows = await LocalChatCacheService.skillRows(userId);
      final skills = <Skill>[];
      for (final row in rows) {
        final skill = _rowToSkill(row);
        if (skill != null) skills.add(skill);
      }
      return List.unmodifiable(skills);
    } catch (error) {
      if (kDebugMode) debugPrint('[UserSkills] local load failed: $error');
      return const [];
    }
  }

  static Skill? _rowToSkill(Map<String, dynamic> row) {
    final id = row['id']?.toString();
    final source = row['source'] as String?;
    if (id == null || source == null || source.isEmpty) return null;
    try {
      return parseSkillMarkdown(source, skillSource: SkillSource.user).copyWith(
        id: id,
        catalogName: row['catalog_name'] as String?,
        baselineHash: row['baseline_hash'] as String?,
      );
    } on SkillParseException catch (error) {
      if (kDebugMode) {
        debugPrint('[UserSkills] skipping unparseable local skill: '
            '${error.message}');
      }
      return null;
    }
  }

  static Future<List<Skill>> _refreshFromServer(String userId) async {
    try {
      final rows = await SupabaseService.client
          .from(_kTable)
          .select('id, encrypted_source')
          .eq('user_id', userId)
          .order('updated_at', ascending: false);

      final decoded = await _decodeRows(rows);
      _memCache = decoded.skills;
      await LocalChatCacheService.replaceSkills(userId, decoded.localRows);
      return decoded.skills;
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[UserSkills] server refresh failed: $error');
      }
      // Offline or transient: keep whatever is cached rather than blanking the
      // user's skills out of the prompt.
      return _memCache ?? const [];
    }
  }

  /// Decrypts and parses server rows into both [Skill]s (for the prompt) and
  /// local SQLite rows (plaintext, for the store). A row that fails either step
  /// is skipped.
  static Future<({List<Skill> skills, List<Map<String, dynamic>> localRows})>
  _decodeRows(List<dynamic> rows) async {
    final ciphertexts = <String>[];
    final ids = <String>[];
    final userIds = <String>[];
    for (final row in rows) {
      final map = Map<String, dynamic>.from(row as Map);
      final source = map['encrypted_source'] as String?;
      final id = map['id']?.toString();
      final userId = map['user_id']?.toString() ?? _cachedUserId;
      if (source == null || source.isEmpty || id == null || userId == null) {
        continue;
      }
      ciphertexts.add(source);
      ids.add(id);
      userIds.add(userId);
    }
    if (ciphertexts.isEmpty) {
      return (skills: const <Skill>[], localRows: const <Map<String, dynamic>>[]);
    }

    final List<String?> plaintexts;
    try {
      plaintexts = await EncryptionService.decryptBatchInBackground(ciphertexts);
    } catch (error) {
      if (kDebugMode) debugPrint('[UserSkills] batch decrypt failed: $error');
      return (skills: const <Skill>[], localRows: const <Map<String, dynamic>>[]);
    }

    final skills = <Skill>[];
    final localRows = <Map<String, dynamic>>[];
    for (var i = 0; i < plaintexts.length; i++) {
      final plaintext = plaintexts[i];
      if (plaintext == null) continue;
      final env = _decodeEnvelope(plaintext);
      try {
        skills.add(
          parseSkillMarkdown(env.source, skillSource: SkillSource.user).copyWith(
            id: ids[i],
            catalogName: env.catalogName,
            baselineHash: env.baselineHash,
          ),
        );
        localRows.add({
          'id': ids[i],
          'user_id': userIds[i],
          'source': env.source,
          'catalog_name': env.catalogName,
          'baseline_hash': env.baselineHash,
          'updated_at': _nowIso(),
        });
      } on SkillParseException catch (error) {
        if (kDebugMode) {
          debugPrint('[UserSkills] skipping unparseable skill: ${error.message}');
        }
      }
    }
    return (skills: List<Skill>.unmodifiable(skills), localRows: localRows);
  }

  // ─── Mutations ─────────────────────────────────────────────────────────

  /// Validates, stores and returns a skill.
  ///
  /// Pass [id] to replace an existing skill, omit it to create one.
  /// [catalogName] and [baselineHash] carry catalog bookkeeping for a
  /// reconciliation write; a hand-authored skill leaves them null.
  ///
  /// Throws [SkillParseException] when [source] violates the spec, and
  /// [UserSkillException] for storage problems (signed out, duplicate name,
  /// over the cap, network).
  static Future<Skill> save(
    String source, {
    String? id,
    String? catalogName,
    String? baselineHash,
  }) async {
    final userId = _currentUserId();
    _syncCacheToCurrentUser(userId);
    if (userId == null) {
      throw const UserSkillException('You must be signed in to save a skill.');
    }

    // Parse first: never store something we cannot read back. expectedName is
    // null — a user skill has no directory to match.
    final parsed = parseSkillMarkdown(source, skillSource: SkillSource.user);

    // A user skill must never shadow a built-in: the prompt builder gates a
    // built-in's protocol block out on the strength of that name being present,
    // so a shadow would remove e.g. the weather schema and substitute arbitrary
    // text for it.
    if (SkillRegistry.builtinNames.contains(parsed.name)) {
      throw UserSkillException(
        '"${parsed.name}" is a built-in skill name. Pick a different name.',
      );
    }

    final existing = await load();
    final clash = existing.any((s) => s.name == parsed.name && s.id != id);
    if (clash) {
      throw UserSkillException(
        'You already have a skill named "${parsed.name}". Names must be '
        'unique — the model picks a skill by name.',
      );
    }
    if (id == null && existing.length >= kMaxUserSkills) {
      throw const UserSkillException(
        'You have reached the limit of $kMaxUserSkills skills. Every skill '
        'costs prompt space in every message — delete one first.',
      );
    }

    final String encrypted;
    try {
      encrypted = await EncryptionService.encrypt(
        _encodeEnvelope(
          source,
          catalogName: catalogName,
          baselineHash: baselineHash,
        ),
      );
    } catch (error) {
      throw UserSkillException('Could not encrypt the skill: $error');
    }

    try {
      final now = _nowIso();
      final String rowId;
      if (id == null) {
        final inserted = await SupabaseService.client
            .from(_kTable)
            .insert({'user_id': userId, 'encrypted_source': encrypted})
            .select('id')
            .single();
        rowId = inserted['id'].toString();
      } else {
        await SupabaseService.client
            .from(_kTable)
            .update({'encrypted_source': encrypted})
            .eq('id', id)
            .eq('user_id', userId);
        rowId = id;
      }

      // Write the local store too, so the next read is instant and offline-safe
      // without waiting for a server round-trip.
      await LocalChatCacheService.upsertSkill({
        'id': rowId,
        'user_id': userId,
        'source': source,
        'catalog_name': catalogName,
        'baseline_hash': baselineHash,
        'updated_at': now,
      });

      final stored = parsed.copyWith(
        id: rowId,
        catalogName: catalogName,
        baselineHash: baselineHash,
      );
      // Refresh the in-memory cache from the local store rather than the server:
      // the server refresh is a slower background concern.
      _memCache = await _loadLocal(userId);
      return stored;
    } catch (error) {
      if (error is UserSkillException) rethrow;
      throw UserSkillException('Could not save the skill: $error');
    }
  }

  /// Deletes the skill with [id]. Throws [UserSkillException] on failure —
  /// never fails silently, or the row reappears on the next sync with no
  /// explanation.
  static Future<void> delete(String id) async {
    final userId = _currentUserId();
    _syncCacheToCurrentUser(userId);
    if (userId == null) {
      throw const UserSkillException(
        'You must be signed in to delete a skill.',
      );
    }

    try {
      await SupabaseService.client
          .from(_kTable)
          .delete()
          .eq('id', id)
          .eq('user_id', userId);
      await LocalChatCacheService.deleteSkill(userId, id);
      _memCache = await _loadLocal(userId);
    } catch (error) {
      throw UserSkillException('Could not delete the skill: $error');
    }
  }

  /// Test seam: drops the in-memory cache state.
  @visibleForTesting
  static void resetForTest() {
    _cachedUserId = null;
    _memCache = null;
  }
}
