import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/services/local_chat_cache_service.dart';

class ModelCacheService {
  const ModelCacheService._();

  static const String _kModelsKey = 'cached_models_v2';
  static const String _kModelsTimestampKey = 'cached_models_timestamp_v2';
  static const String _kSelectedModelKeyPrefix = 'cached_selected_model_';
  static const String _kProviderPrefsKeyPrefix = 'cached_provider_prefs_';

  /// Cache validity duration - models don't change often
  static const Duration _cacheValidDuration = Duration(hours: 24);

  // The model catalogue (~200 KB) used to live in SharedPreferences. That
  // bloated the prefs file, which the legacy plugin re-parses on every
  // getInstance() (startup critical path) and rewrites whole on every
  // setString(). It now lives in the SQLite kv_cache; this moves any existing
  // prefs copy over once, then deletes the prefs keys so the file shrinks.
  //
  // Memoised as a shared Future so concurrent isCacheValid() / loadAvailable
  // Models() callers all await the SAME migration and none reads kv_cache
  // before the copy finished (a cold-start "no models" race otherwise).
  static Future<void>? _migration;
  static Future<void> _migrateFromPrefs() => _migration ??= _runMigration();

  static Future<void> _runMigration() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!prefs.containsKey(_kModelsKey)) return;
      // Only adopt the prefs copy when kv has none, so a fresh kv write is
      // never clobbered by a stale prefs value.
      if (await LocalChatCacheService.kvGet(_kModelsKey) == null) {
        final oldRaw = prefs.getString(_kModelsKey);
        if (oldRaw != null) {
          await LocalChatCacheService.kvSet(_kModelsKey, oldRaw);
        }
        final ts = prefs.getInt(_kModelsTimestampKey);
        if (ts != null) {
          await LocalChatCacheService.kvSet(
            _kModelsTimestampKey,
            ts.toString(),
          );
        }
      }
      await prefs.remove(_kModelsKey);
      await prefs.remove(_kModelsTimestampKey);
    } catch (_) {
      // Best-effort; a failure just leaves the prefs copy in place.
    }
  }

  static Future<void> saveAvailableModels(
    List<Map<String, dynamic>> models,
  ) async {
    await LocalChatCacheService.kvSet(_kModelsKey, jsonEncode(models));
    await LocalChatCacheService.kvSet(
      _kModelsTimestampKey,
      DateTime.now().millisecondsSinceEpoch.toString(),
    );
  }

  /// Check if cached models are still valid (less than 24h old)
  static Future<bool> isCacheValid() async {
    await _migrateFromPrefs();
    final raw = await LocalChatCacheService.kvGet(_kModelsTimestampKey);
    final timestamp = raw == null ? null : int.tryParse(raw);
    if (timestamp == null) return false;

    final cachedAt = DateTime.fromMillisecondsSinceEpoch(timestamp);
    final age = DateTime.now().difference(cachedAt);
    return age < _cacheValidDuration;
  }

  static Future<List<Map<String, dynamic>>> loadAvailableModels() async {
    await _migrateFromPrefs();
    final raw = await LocalChatCacheService.kvGet(_kModelsKey);
    if (raw == null) return const <Map<String, dynamic>>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <Map<String, dynamic>>[];
      return decoded
          .whereType<Map<String, dynamic>>()
          .map((entry) => Map<String, dynamic>.from(entry))
          .toList(growable: false);
    } catch (_) {
      return const <Map<String, dynamic>>[];
    }
  }

  /// Human name of a model, e.g. `DeepSeek: DeepSeek V4 Flash` for
  /// `deepseek/deepseek-v4-flash`.
  ///
  /// Returns null when the list has not been cached yet or the id is not
  /// in it — callers then show the id, which is ugly but never wrong.
  static Future<String?> displayNameFor(String modelId) async {
    if (modelId.isEmpty) return null;
    final models = await loadAvailableModels();
    for (final model in models) {
      if (model['id'] == modelId) {
        final name = model['name'];
        if (name is String && name.trim().isNotEmpty) return name.trim();
        return null;
      }
    }
    return null;
  }

  static Future<void> saveSelectedModel(String userId, String modelId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_selectedModelKey(userId), modelId);
  }

  static Future<String?> loadSelectedModel(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_selectedModelKey(userId));
  }

  static Future<void> saveProviderPreferences(
    String userId,
    Map<String, String> providers,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_providerPrefsKey(userId), jsonEncode(providers));
  }

  static Future<Map<String, String>> loadProviderPreferences(
    String userId,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_providerPrefsKey(userId));
    if (raw == null) return <String, String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return <String, String>{};
      final Map<String, String> result = {};
      decoded.forEach((key, value) {
        if (key is String && value is String) {
          result[key] = value;
        }
      });
      return result;
    } catch (_) {
      return <String, String>{};
    }
  }

  static Future<void> updateProviderPreference(
    String userId,
    String modelId,
    String providerSlug,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final Map<String, String> current = await loadProviderPreferences(userId);
    current[modelId] = providerSlug;
    await prefs.setString(_providerPrefsKey(userId), jsonEncode(current));
  }

  static Future<void> clearProviderPreference(
    String userId,
    String modelId,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final Map<String, String> current = await loadProviderPreferences(userId);
    if (current.remove(modelId) == null) return;
    await prefs.setString(_providerPrefsKey(userId), jsonEncode(current));
  }

  static Future<void> clearAllForUser(String userId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_selectedModelKey(userId));
    await prefs.remove(_providerPrefsKey(userId));
  }

  static String _selectedModelKey(String userId) =>
      '$_kSelectedModelKeyPrefix$userId';

  static String _providerPrefsKey(String userId) =>
      '$_kProviderPrefsKeyPrefix$userId';
}
