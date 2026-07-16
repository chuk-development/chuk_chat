// lib/services/per_model_system_prompt_service.dart
import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';

/// How a per-model system prompt combines with the base (global + workspace)
/// system prompt at request time.
enum ModelPromptMode {
  /// Per-model prompt is ignored.
  off,

  /// Per-model prompt fully replaces the base system prompt.
  replace,

  /// Per-model prompt is appended after the base prompt with a separator.
  append,

  /// Per-model prompt is prepended before the base prompt with a separator.
  prepend,
}

ModelPromptMode _modeFromString(String? raw) {
  switch (raw) {
    case 'off':
      return ModelPromptMode.off;
    case 'replace':
      return ModelPromptMode.replace;
    case 'prepend':
      return ModelPromptMode.prepend;
    case 'append':
    default:
      return ModelPromptMode.append;
  }
}

String _modeToString(ModelPromptMode mode) {
  switch (mode) {
    case ModelPromptMode.off:
      return 'off';
    case ModelPromptMode.replace:
      return 'replace';
    case ModelPromptMode.prepend:
      return 'prepend';
    case ModelPromptMode.append:
      return 'append';
  }
}

/// Per-model system prompt configuration.
@immutable
class ModelPromptConfig {
  const ModelPromptConfig({
    required this.prompt,
    required this.mode,
  });

  final String prompt;
  final ModelPromptMode mode;

  ModelPromptConfig copyWith({String? prompt, ModelPromptMode? mode}) {
    return ModelPromptConfig(
      prompt: prompt ?? this.prompt,
      mode: mode ?? this.mode,
    );
  }

  /// Effective when the prompt is non-empty and the mode is not "off".
  bool get isActive => mode != ModelPromptMode.off && prompt.trim().isNotEmpty;
}

/// Separator inserted between the base prompt and the per-model prompt
/// for `append` and `prepend` modes.
const String _kModelPromptSeparator = '\n\n---\n\n';

/// Pure helper: merge a per-model prompt into a base system prompt according
/// to [mode]. Empty or whitespace-only [modelPrompt] is treated as "off".
String? mergeModelPrompt({
  required String? base,
  required String? modelPrompt,
  required ModelPromptMode mode,
}) {
  final String trimmedBase = base?.trim() ?? '';
  final String trimmedModel = modelPrompt?.trim() ?? '';

  // No per-model prompt or explicitly disabled — return base unchanged.
  if (mode == ModelPromptMode.off || trimmedModel.isEmpty) {
    return base;
  }

  switch (mode) {
    case ModelPromptMode.replace:
      return trimmedModel;
    case ModelPromptMode.append:
      if (trimmedBase.isEmpty) return trimmedModel;
      return '$trimmedBase$_kModelPromptSeparator$trimmedModel';
    case ModelPromptMode.prepend:
      if (trimmedBase.isEmpty) return trimmedModel;
      return '$trimmedModel$_kModelPromptSeparator$trimmedBase';
    case ModelPromptMode.off:
      return base;
  }
}

/// Manages per-model system prompts.
///
/// Storage:
/// - **Local**: SharedPreferences key `cached_model_system_prompts` —
///   JSON map of `{modelId: {prompt: <encrypted blob>, mode: <string>}}`.
///   Encrypted with the user's chat key (same as the global system prompt).
/// - **Remote**: `user_preferences.preferences` JSONB column under the key
///   `model_system_prompts` (mirrors `developer_options_enabled` pattern).
///   Best-effort sync — falls back to local-only if the column is missing.
class PerModelSystemPromptService {
  const PerModelSystemPromptService._();

  /// SharedPreferences key holding [userId]'s per-model prompt blob.
  ///
  /// Namespaced by user id so a second user in the same install cannot read the
  /// first user's entries. See [_syncCacheToCurrentUser] for why this is keyed
  /// rather than cleared from a sign-out hook.
  static String _localKey(String userId) =>
      'cached_model_system_prompts_$userId';

  /// The pre-namespacing key. Deleted rather than migrated: its contents cannot
  /// be attributed to a user, and a dropped cache re-fetches while a
  /// mis-attributed one leaks.
  static const String _legacyLocalKey = 'cached_model_system_prompts';

  static const String _remotePreferencesColumn = 'preferences';
  static const String _remoteKey = 'model_system_prompts';
  static const String _selectedModelColumn = 'selected_model_id';

  // In-memory cache so callers (chat send path) avoid repeated decrypts.
  // Populated lazily on first load and updated on save/delete.
  static Map<String, ModelPromptConfig>? _decryptedCache;
  static Future<Map<String, ModelPromptConfig>>? _loadInFlight;

  /// The user [_decryptedCache] belongs to.
  ///
  /// Keyed by user id and re-checked on every access, rather than cleared by a
  /// logout hook: this class had a `clearAll()` written to be exactly that hook
  /// and it never had a single caller (it has since been deleted), and
  /// `chat_ui_mobile` signs out through `SupabaseService.signOut()` without
  /// going near `AuthService`. Mirrors `_resetIdentityCacheForUser` in
  /// `notes_tools.dart`.
  static String? _cacheOwnerUserId;

  static void _syncCacheToCurrentUser(String? userId) {
    if (_cacheOwnerUserId == userId) return;
    _cacheOwnerUserId = userId;
    _decryptedCache = null;
    _loadInFlight = null;
  }

  /// The active user id, or null when signed out or before Supabase is up.
  static String? _currentUserId() {
    // Gated on kDebugMode so the override is tree-shaken out of release
    // builds: it is a mutable static that decides ownership, and
    // @visibleForTesting is a lint, not a runtime guard. Tests run in debug.
    if (kDebugMode) {
      final override = debugCurrentUserIdOverride;
      if (override != null) return override();
    }
    try {
      return SupabaseService.auth.currentUser?.id;
    } catch (_) {
      return null;
    }
  }

  /// True while [userId] is *still the live signed-in user*.
  ///
  /// Consults live auth, not just [_cacheOwnerUserId]: the latter only advances
  /// when a public entry point runs [_syncCacheToCurrentUser], so between a
  /// sign-out and the next entry point it still names the previous user and
  /// would wave their data through.
  static bool _stillOwns(String? userId) =>
      userId != null &&
      _cacheOwnerUserId == userId &&
      _currentUserId() == userId;

  static Future<void> _dropLegacyLocalCache(SharedPreferences prefs) async {
    if (prefs.containsKey(_legacyLocalKey)) {
      await prefs.remove(_legacyLocalKey);
    }
  }

  /// Best-effort load of all per-model configs, decrypted.
  ///
  /// Pulls from local SharedPreferences first; in the background tries to
  /// pull remote and update. Returns an empty map when the key is not yet
  /// available or no entries exist.
  static Future<Map<String, ModelPromptConfig>> loadAll() async {
    final userId = _currentUserId();
    _syncCacheToCurrentUser(userId);
    if (userId == null) return <String, ModelPromptConfig>{};

    if (_decryptedCache != null) {
      // Refresh in background so cross-device edits propagate.
      unawaited(_syncFromRemote());
      return Map<String, ModelPromptConfig>.from(_decryptedCache!);
    }
    if (_loadInFlight != null) {
      return _loadInFlight!;
    }

    Future<Map<String, ModelPromptConfig>> run() async {
      final local = await _loadFromLocal(userId);
      // The user changed while the local read was in flight. Return an empty
      // map, never `local`: these are decrypted per-model prompts, and handing
      // them back leaks them to the new user through the return value even
      // with the cache left untouched.
      if (!_stillOwns(userId)) return <String, ModelPromptConfig>{};
      _decryptedCache = local;
      // Trigger remote sync in background — don't block first paint.
      unawaited(_syncFromRemote());
      return Map<String, ModelPromptConfig>.from(local);
    }

    try {
      _loadInFlight = run();
      return await _loadInFlight!;
    } finally {
      _loadInFlight = null;
    }
  }

  /// Get a config for [modelId] (or `null` if none exists). Backed by the
  /// in-memory cache; calls [loadAll] on first access.
  static Future<ModelPromptConfig?> get(String modelId) async {
    _syncCacheToCurrentUser(_currentUserId());
    if (_decryptedCache == null) {
      await loadAll();
    }
    return _decryptedCache?[modelId];
  }

  /// Save (upsert) a per-model config. Re-encrypts before persisting.
  /// Returns true on a successful local write (remote is best-effort).
  static Future<bool> save(String modelId, ModelPromptConfig config) async {
    final userId = _currentUserId();
    _syncCacheToCurrentUser(userId);
    final trimmedId = modelId.trim();
    if (trimmedId.isEmpty) return false;
    // Entries are encrypted with the signed-in user's key; without one there is
    // no correct namespace to write into.
    if (userId == null) return false;

    try {
      _decryptedCache ??= await _loadFromLocal(userId);
      final hadPrevious = _decryptedCache!.containsKey(trimmedId);
      final previous = _decryptedCache![trimmedId];
      _decryptedCache![trimmedId] = config;

      try {
        await _persistAll(userId);
      } catch (_) {
        if (hadPrevious) {
          _decryptedCache![trimmedId] = previous!;
        } else {
          _decryptedCache!.remove(trimmedId);
        }
        rethrow;
      }
      // Best-effort remote upsert — don't block UI.
      unawaited(_saveRemote(userId));
      if (kDebugMode) {
        debugPrint(
          '[PerModelPrompt] saved modelId=$trimmedId '
          'len=${config.prompt.length} mode=${_modeToString(config.mode)}',
        );
      }
      return true;
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[PerModelPrompt] save failed: $error');
      }
      return false;
    }
  }

  /// Remove the per-model config for [modelId].
  static Future<bool> delete(String modelId) async {
    final userId = _currentUserId();
    _syncCacheToCurrentUser(userId);
    final trimmedId = modelId.trim();
    if (trimmedId.isEmpty) return false;
    if (userId == null) return false;
    try {
      _decryptedCache ??= await _loadFromLocal(userId);
      if (!_decryptedCache!.containsKey(trimmedId)) return false;
      _decryptedCache!.remove(trimmedId);
      await _persistAll(userId);
      unawaited(_saveRemote(userId));
      if (kDebugMode) {
        debugPrint('[PerModelPrompt] deleted modelId=$trimmedId');
      }
      return true;
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[PerModelPrompt] delete failed: $error');
      }
      return false;
    }
  }

  // ─── Internal: load from local SharedPreferences ─────────────────────────
  static Future<Map<String, ModelPromptConfig>> _loadFromLocal(
    String userId,
  ) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await _dropLegacyLocalCache(prefs);
      final raw = prefs.getString(_localKey(userId));
      if (raw == null || raw.isEmpty) return <String, ModelPromptConfig>{};

      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, ModelPromptConfig>{};

      return await _decryptMap(decoded);
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[PerModelPrompt] local load failed: $error');
      }
      return <String, ModelPromptConfig>{};
    }
  }

  /// Decrypt a map keyed by model id whose values are
  /// `{ "prompt": <encrypted>, "mode": <string> }`. Entries whose decryption
  /// fails are silently dropped.
  static Future<Map<String, ModelPromptConfig>> _decryptMap(
    Map<dynamic, dynamic> encryptedMap,
  ) async {
    final result = <String, ModelPromptConfig>{};
    for (final entry in encryptedMap.entries) {
      final key = entry.key;
      if (key is! String) continue;
      final value = entry.value;
      if (value is! Map) continue;
      final encryptedPrompt = value['prompt'];
      final rawMode = value['mode'];
      final mode = _modeFromString(rawMode is String ? rawMode : null);
      if (encryptedPrompt is! String || encryptedPrompt.isEmpty) {
        // Allow stored empty entries (mode-only) to round-trip.
        result[key] = ModelPromptConfig(prompt: '', mode: mode);
        continue;
      }
      try {
        final decrypted = await EncryptionService.decrypt(encryptedPrompt);
        result[key] = ModelPromptConfig(prompt: decrypted, mode: mode);
      } catch (error) {
        if (kDebugMode) {
          debugPrint(
            '[PerModelPrompt] decrypt failed for $key (skipped): $error',
          );
        }
      }
    }
    return result;
  }

  /// Encrypt the in-memory map and write it to SharedPreferences.
  static Future<void> _persistAll(String userId) async {
    final cache = _decryptedCache ?? <String, ModelPromptConfig>{};
    final encryptedMap = <String, Map<String, dynamic>>{};
    for (final entry in cache.entries) {
      final modelId = entry.key;
      final cfg = entry.value;
      final encryptedPrompt = cfg.prompt.isEmpty
          ? ''
          : await EncryptionService.encrypt(cfg.prompt);
      encryptedMap[modelId] = {
        'prompt': encryptedPrompt,
        'mode': _modeToString(cfg.mode),
      };
    }
    final prefs = await SharedPreferences.getInstance();
    await _dropLegacyLocalCache(prefs);
    await prefs.setString(_localKey(userId), jsonEncode(encryptedMap));
  }

  // ─── Internal: remote sync (best-effort) ─────────────────────────────────
  static Future<void> _syncFromRemote() async {
    // Safe lookup: this runs unawaited, so a raw `SupabaseService.auth` read
    // would surface as an unhandled async error before Supabase is up.
    final userId = _currentUserId();
    if (userId == null) return;
    _syncCacheToCurrentUser(userId);

    try {
      final row = await SupabaseService.client
          .from('user_preferences')
          .select(_remotePreferencesColumn)
          .eq('user_id', userId)
          .maybeSingle();

      final raw = row?[_remotePreferencesColumn];
      Map<String, dynamic> prefsMap;
      if (raw is Map<String, dynamic>) {
        prefsMap = Map<String, dynamic>.from(raw);
      } else if (raw is Map) {
        prefsMap = raw.map((k, v) => MapEntry(k.toString(), v));
      } else {
        return;
      }

      final remoteEntries = prefsMap[_remoteKey];
      if (remoteEntries is! Map) return;

      final decrypted = await _decryptMap(remoteEntries);

      // Merge remote entries into the existing cache so a concurrent local
      // save isn't clobbered by stale remote data. Local cache wins for any
      // key already present locally (last-writer-wins per key).
      // A background sync must never resurrect the previous user's entries
      // after a sign-out.
      if (!_stillOwns(userId)) return;
      final merged = <String, ModelPromptConfig>{...decrypted};
      final existing = _decryptedCache;
      if (existing != null) {
        merged.addAll(existing);
      }
      _decryptedCache = merged;
      await _persistAll(userId);
      if (kDebugMode) {
        debugPrint(
          '[PerModelPrompt] synced ${decrypted.length} entries from remote',
        );
      }
    } on PostgrestException catch (error) {
      if (_isMissingPreferencesColumn(error)) {
        // Remote schema does not expose `preferences`. Local-only mode is
        // an acceptable fallback — the global system prompt syncs through a
        // dedicated column, while per-model prompts are an additive feature.
        return;
      }
      if (kDebugMode) {
        debugPrint('[PerModelPrompt] remote sync failed: $error');
      }
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[PerModelPrompt] remote sync error: $error');
      }
    }
  }

  /// Re-encrypt [ownerUserId]'s cache and upsert it into the JSONB preferences
  /// column. Best-effort — failures are logged in debug only.
  ///
  /// [ownerUserId] is the user the cache belonged to when the save was started.
  /// It is required, and verified against live auth, because this runs
  /// unawaited: reading the *current* session here instead would upsert the
  /// previous user's decrypted prompts into whichever row is active by the time
  /// it resumes — writing A's data into B's account.
  static Future<void> _saveRemote(String ownerUserId) async {
    if (!_stillOwns(ownerUserId)) return;
    final userId = ownerUserId;
    final cache = _decryptedCache;
    if (cache == null) return;

    try {
      final existingRow = await SupabaseService.client
          .from('user_preferences')
          .select('$_selectedModelColumn,$_remotePreferencesColumn')
          .eq('user_id', userId)
          .maybeSingle();

      final raw = existingRow?[_remotePreferencesColumn];
      final Map<String, dynamic> prefsMap = raw is Map<String, dynamic>
          ? Map<String, dynamic>.from(raw)
          : (raw is Map
              ? raw.map((k, v) => MapEntry(k.toString(), v))
              : <String, dynamic>{});

      final encryptedEntries = <String, Map<String, dynamic>>{};
      for (final entry in cache.entries) {
        final cfg = entry.value;
        final encryptedPrompt = cfg.prompt.isEmpty
            ? ''
            : await EncryptionService.encrypt(cfg.prompt);
        encryptedEntries[entry.key] = {
          'prompt': encryptedPrompt,
          'mode': _modeToString(cfg.mode),
        };
      }
      prefsMap[_remoteKey] = encryptedEntries;

      // Some deployments require `selected_model_id` (NOT NULL) to be set
      // on insert. Skip the remote write entirely when no row exists yet —
      // the row will be created by the regular model-selection flow and a
      // subsequent save will sync the per-model prompts. Preserve any
      // existing selected_model_id on update.
      if (existingRow == null) {
        if (kDebugMode) {
          debugPrint(
            '[PerModelPrompt] skip remote save: no user_preferences row yet',
          );
        }
        return;
      }

      final Map<String, dynamic> upsertData = <String, dynamic>{
        'user_id': userId,
        _remotePreferencesColumn: prefsMap,
      };
      final dynamic existingModelId = existingRow[_selectedModelColumn];
      if (existingModelId is String && existingModelId.trim().isNotEmpty) {
        upsertData[_selectedModelColumn] = existingModelId;
      }

      // Re-check after the select/encrypt awaits: `EncryptionService.encrypt`
      // uses the *live* user's key, so a switch mid-flight would have sealed
      // this user's prompts with the next user's key. Dropping the write costs
      // one best-effort sync; landing it would corrupt the row.
      if (!_stillOwns(ownerUserId)) return;

      await SupabaseService.client
          .from('user_preferences')
          .upsert(upsertData, onConflict: 'user_id');
      if (kDebugMode) {
        debugPrint(
          '[PerModelPrompt] remote save: ${encryptedEntries.length} entries',
        );
      }
    } on PostgrestException catch (error) {
      if (_isMissingPreferencesColumn(error)) {
        return;
      }
      if (kDebugMode) {
        debugPrint('[PerModelPrompt] remote save failed: $error');
      }
    } catch (error) {
      if (kDebugMode) {
        debugPrint('[PerModelPrompt] remote save error: $error');
      }
    }
  }

  static bool _isMissingPreferencesColumn(PostgrestException error) {
    final code = error.code?.toLowerCase() ?? '';
    final message = error.message.toLowerCase();
    return (code == '42703' || message.contains('does not exist')) &&
        message.contains(_remotePreferencesColumn);
  }

  /// Test hook: reset internal state. Visible only to tests.
  @visibleForTesting
  static void debugReset() {
    _decryptedCache = null;
    _loadInFlight = null;
    _cacheOwnerUserId = null;
  }

  // The real entry points read the user id from `SupabaseService.auth`, which
  // needs a live backend; these seams drive the user-change path directly.

  /// Replaces the live auth lookup used by [_currentUserId] and [_stillOwns],
  /// so a test can flip the signed-in user while an async load is suspended.
  @visibleForTesting
  static String? Function()? debugCurrentUserIdOverride;

  @visibleForTesting
  static bool debugStillOwns(String? userId) => _stillOwns(userId);

  @visibleForTesting
  static void debugPrimeCacheForUser(
    String? userId,
    Map<String, ModelPromptConfig>? cache,
  ) {
    _cacheOwnerUserId = userId;
    _decryptedCache = cache;
  }

  @visibleForTesting
  static void debugSyncCacheToUser(String? userId) =>
      _syncCacheToCurrentUser(userId);

  @visibleForTesting
  static Map<String, ModelPromptConfig>? get debugCache => _decryptedCache;

  @visibleForTesting
  static String localCacheKeyForUser(String userId) => _localKey(userId);

  @visibleForTesting
  static const String legacyLocalCacheKey = _legacyLocalKey;
}
