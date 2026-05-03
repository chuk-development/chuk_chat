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

  static const String _localKey = 'cached_model_system_prompts';
  static const String _remotePreferencesColumn = 'preferences';
  static const String _remoteKey = 'model_system_prompts';
  static const String _selectedModelColumn = 'selected_model_id';

  // In-memory cache so callers (chat send path) avoid repeated decrypts.
  // Populated lazily on first load and updated on save/delete.
  static Map<String, ModelPromptConfig>? _decryptedCache;
  static Future<Map<String, ModelPromptConfig>>? _loadInFlight;

  /// Best-effort load of all per-model configs, decrypted.
  ///
  /// Pulls from local SharedPreferences first; in the background tries to
  /// pull remote and update. Returns an empty map when the key is not yet
  /// available or no entries exist.
  static Future<Map<String, ModelPromptConfig>> loadAll() async {
    if (_decryptedCache != null) {
      // Refresh in background so cross-device edits propagate.
      unawaited(_syncFromRemote());
      return Map<String, ModelPromptConfig>.from(_decryptedCache!);
    }
    if (_loadInFlight != null) {
      return _loadInFlight!;
    }

    Future<Map<String, ModelPromptConfig>> run() async {
      final local = await _loadFromLocal();
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
    if (_decryptedCache == null) {
      await loadAll();
    }
    return _decryptedCache?[modelId];
  }

  /// Save (upsert) a per-model config. Re-encrypts before persisting.
  /// Returns true on a successful local write (remote is best-effort).
  static Future<bool> save(String modelId, ModelPromptConfig config) async {
    final trimmedId = modelId.trim();
    if (trimmedId.isEmpty) return false;

    try {
      _decryptedCache ??= await _loadFromLocal();
      final hadPrevious = _decryptedCache!.containsKey(trimmedId);
      final previous = _decryptedCache![trimmedId];
      _decryptedCache![trimmedId] = config;

      try {
        await _persistAll();
      } catch (_) {
        if (hadPrevious) {
          _decryptedCache![trimmedId] = previous!;
        } else {
          _decryptedCache!.remove(trimmedId);
        }
        rethrow;
      }
      // Best-effort remote upsert — don't block UI.
      unawaited(_saveRemote());
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
    final trimmedId = modelId.trim();
    if (trimmedId.isEmpty) return false;
    try {
      _decryptedCache ??= await _loadFromLocal();
      if (!_decryptedCache!.containsKey(trimmedId)) return false;
      _decryptedCache!.remove(trimmedId);
      await _persistAll();
      unawaited(_saveRemote());
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

  /// Clear all per-model configs (used on sign-out / password change).
  static Future<void> clearAll() async {
    _decryptedCache = null;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(_localKey);
    } catch (_) {}
  }

  // ─── Internal: load from local SharedPreferences ─────────────────────────
  static Future<Map<String, ModelPromptConfig>> _loadFromLocal() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_localKey);
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
  static Future<void> _persistAll() async {
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
    await prefs.setString(_localKey, jsonEncode(encryptedMap));
  }

  // ─── Internal: remote sync (best-effort) ─────────────────────────────────
  static Future<void> _syncFromRemote() async {
    final session = SupabaseService.auth.currentSession;
    if (session == null) return;
    final userId = session.user.id;

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
      final merged = <String, ModelPromptConfig>{...decrypted};
      final existing = _decryptedCache;
      if (existing != null) {
        merged.addAll(existing);
      }
      _decryptedCache = merged;
      await _persistAll();
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

  /// Re-encrypt the current cache and upsert into the JSONB preferences
  /// column. Best-effort — failures are logged in debug only.
  static Future<void> _saveRemote() async {
    final session = SupabaseService.auth.currentSession;
    if (session == null) return;
    final userId = session.user.id;
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
  }
}
