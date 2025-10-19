import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class ModelCacheService {
  const ModelCacheService._();

  static const String _kModelsKey = 'cached_models_v1';
  static const String _kSelectedModelKeyPrefix = 'cached_selected_model_';
  static const String _kProviderPrefsKeyPrefix = 'cached_provider_prefs_';

  static Future<void> saveAvailableModels(
    List<Map<String, dynamic>> models,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kModelsKey, jsonEncode(models));
  }

  static Future<List<Map<String, dynamic>>> loadAvailableModels() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kModelsKey);
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
    if (raw == null) return const <String, String>{};
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return const <String, String>{};
      final Map<String, String> result = {};
      decoded.forEach((key, value) {
        if (key is String && value is String) {
          result[key] = value;
        }
      });
      return result;
    } catch (_) {
      return const <String, String>{};
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
