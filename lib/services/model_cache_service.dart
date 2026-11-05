import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/services/local_chat_cache_service.dart';

class ModelCacheService {
  const ModelCacheService._();

  static const String _kModelsKey = 'cached_models_v2';
  static const String _kModelsTimestampKey = 'cached_models_timestamp_v2';
  static const String _kSelectedModelKeyPrefix = 'cached_selected_model_';
  static const String _kProviderPrefsKeyPrefix = 'cached_provider_prefs_';

  /// How long a stored catalogue counts as fresh. Older than this it is
  /// still served at once (stale-while-revalidate), and a read starts one
  /// background refresh. Was 24 h, so a model added on the server stayed
  /// missing for up to a day.
  static const Duration cacheFreshDuration = Duration(minutes: 10);

  /// Least time between two background refresh attempts, so a failing
  /// network is not asked again on every read.
  static const Duration _minRevalidateGap = Duration(seconds: 30);

  /// Fetches the catalogue and calls [saveAvailableModels]. Set by
  /// `ModelPrefetchService`; null in tests unless a test sets it.
  static Future<void> Function()? _revalidator;
  static Future<void>? _revalidating;
  static DateTime? _lastRevalidateStart;

  /// When the stored catalogue was written (ms since epoch), once read.
  static int? _savedAtMs;
  static bool _savedAtLoaded = false;

  /// Registers the background refresh used when a read finds the catalogue
  /// stale. Concurrent stale reads share one refresh.
  static void registerRevalidator(Future<void> Function() revalidate) {
    _revalidator = revalidate;
  }

  @visibleForTesting
  static void debugResetRevalidation() {
    _revalidator = null;
    _revalidating = null;
    _lastRevalidateStart = null;
    _savedAtMs = null;
    _savedAtLoaded = false;
  }

  /// The refresh started by the last stale read, or null when none runs.
  @visibleForTesting
  static Future<void>? get debugRevalidating => _revalidating;

  static Future<int?> _savedAt() async {
    if (_savedAtLoaded) return _savedAtMs;
    final raw = await LocalChatCacheService.kvGet(_kModelsTimestampKey);
    _savedAtMs = raw == null ? null : int.tryParse(raw);
    _savedAtLoaded = true;
    return _savedAtMs;
  }

  static bool _isFresh(int? savedAtMs, DateTime now) {
    if (savedAtMs == null) return false;
    final age = now.difference(DateTime.fromMillisecondsSinceEpoch(savedAtMs));
    return age >= Duration.zero && age < cacheFreshDuration;
  }

  /// Starts one background refresh when the catalogue is stale. Never waits
  /// for it and never throws.
  static Future<void> _revalidateIfStale() async {
    final revalidate = _revalidator;
    if (revalidate == null || _revalidating != null) return;
    final now = DateTime.now();
    final last = _lastRevalidateStart;
    if (last != null && now.difference(last) < _minRevalidateGap) return;
    int? savedAt;
    try {
      savedAt = await _savedAt();
    } catch (_) {
      return;
    }
    if (_isFresh(savedAt, now) || _revalidating != null) return;
    _lastRevalidateStart = now;
    final Future<void> run = Future<void>.sync(revalidate).catchError((
      Object e,
    ) {
      if (kDebugMode) debugPrint('ModelCacheService: refresh failed: $e');
    });
    _revalidating = run;
    unawaited(
      run.whenComplete(() {
        if (identical(_revalidating, run)) _revalidating = null;
      }),
    );
  }

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

  /// The decoded catalogue, kept after the first read.
  ///
  /// The catalogue is about 200 KB of JSON. Every mount of the chat screen
  /// reads it several times (model name, picked models, capabilities), and in
  /// the Agents build every agent switch mounts the screen again, so each
  /// switch paid for several full `jsonDecode` calls on the UI isolate. The
  /// catalogue changes only through [saveAvailableModels], which drops this
  /// copy, so the memo can never be older than the stored value.
  static List<Map<String, dynamic>>? _decodedModels;

  /// Moves on every [saveAvailableModels], so a read that started before a
  /// write does not store the old list as the memo.
  static int _modelsGeneration = 0;

  /// Drops the in-memory copy of the catalogue. Tests that swap the storage
  /// under this class call it; the app itself never needs to.
  @visibleForTesting
  static void debugClearMemo() => _decodedModels = null;

  static Future<void> saveAvailableModels(
    List<Map<String, dynamic>> models,
  ) async {
    _modelsGeneration++;
    _decodedModels = null;
    await LocalChatCacheService.kvSet(_kModelsKey, jsonEncode(models));
    // Again after the write: a read that began while it was in flight may
    // have seen the old value.
    _modelsGeneration++;
    _decodedModels = null;
    final int now = DateTime.now().millisecondsSinceEpoch;
    await LocalChatCacheService.kvSet(_kModelsTimestampKey, now.toString());
    _savedAtMs = now;
    _savedAtLoaded = true;
  }

  /// Whether the stored catalogue is fresh (younger than
  /// [cacheFreshDuration]). A stale one is still served by
  /// [loadAvailableModels]; this only says whether to fetch again.
  static Future<bool> isCacheValid() async {
    await _migrateFromPrefs();
    final raw = await LocalChatCacheService.kvGet(_kModelsTimestampKey);
    final timestamp = raw == null ? null : int.tryParse(raw);
    _savedAtMs = timestamp;
    _savedAtLoaded = true;
    return _isFresh(timestamp, DateTime.now());
  }

  /// The stored catalogue, served at once. When it is older than
  /// [cacheFreshDuration], one background refresh starts (see
  /// [registerRevalidator]); its result reaches the next read.
  static Future<List<Map<String, dynamic>>> loadAvailableModels() async {
    unawaited(_revalidateIfStale());
    final memo = _decodedModels;
    if (memo != null) return _copyOf(memo);
    final generation = _modelsGeneration;
    await _migrateFromPrefs();
    final raw = await LocalChatCacheService.kvGet(_kModelsKey);
    if (raw == null) return const <Map<String, dynamic>>[];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const <Map<String, dynamic>>[];
      final models = decoded
          .whereType<Map<String, dynamic>>()
          .toList(growable: false);
      if (generation == _modelsGeneration) _decodedModels = models;
      return _copyOf(models);
    } catch (_) {
      return const <Map<String, dynamic>>[];
    }
  }

  /// A fresh list of fresh maps, as every read handed out before the memo:
  /// a caller that edits an entry must not edit the memo.
  static List<Map<String, dynamic>> _copyOf(
    List<Map<String, dynamic>> models,
  ) => models
      .map((entry) => Map<String, dynamic>.from(entry))
      .toList(growable: false);

  /// Human name of a model, e.g. `DeepSeek: DeepSeek V4 Flash` for
  /// `deepseek/deepseek-v4-flash`.
  ///
  /// Returns null when the list has not been cached yet or the id is not
  /// in it — callers then show the id, which is ugly but never wrong.
  static Future<String?> displayNameFor(String modelId) async {
    if (modelId.isEmpty) return null;
    // The name is cosmetic and callers fire this unawaited from the chat
    // screens, so a cache that cannot be opened (no support directory, a
    // locked DB) means "no name", not an uncaught async error.
    final List<Map<String, dynamic>> models;
    try {
      models = await loadAvailableModels();
    } catch (e) {
      if (kDebugMode) {
        debugPrint('ModelCacheService.displayNameFor: cache unavailable: $e');
      }
      return null;
    }
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
    // Every chat mount re-reads the provider from the cloud and lands here
    // with the value that is already stored. On desktop Linux each preference
    // write rewrites the whole preferences file on the UI isolate, so an
    // unchanged value is not written again.
    if (current[modelId] == providerSlug) return;
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
