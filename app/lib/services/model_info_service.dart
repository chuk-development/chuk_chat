import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'package:cowork/services/api_config_service.dart';
import 'package:cowork/services/model_cache_service.dart';
import 'package:cowork/services/model_capabilities_service.dart';

/// Fetches the live model list from `/v1/models_info` and caches it, so the
/// composer's mode selector can show real model names and capabilities.
///
/// This is the same source and id format chuk_chat uses. Each entry carries
/// `id`, `name`, `supports_reasoning`, `supports_reasoning_effort` and a
/// `providers` list of `{slug, pricing}`. The cached list feeds
/// [ModelCacheService] and [ModelCapabilitiesService] exactly as in chuk_chat.
class ModelInfoService {
  const ModelInfoService._();

  static bool _isLoading = false;

  /// Short timeout: the cache is the fallback, so a slow network never blocks
  /// the composer.
  static const Duration _httpTimeout = Duration(seconds: 5);

  /// Load the model list, preferring a valid disk cache. When the cache is
  /// stale (or empty) and [accessToken] is non-empty, fetch from the API,
  /// persist the result and refresh the capability caches. Returns the models
  /// as a list of raw maps (possibly from cache) — never throws.
  static Future<List<Map<String, dynamic>>> loadModels({
    required String accessToken,
    bool forceRefresh = false,
  }) async {
    if (!forceRefresh) {
      final cacheValid = await ModelCacheService.isCacheValid();
      if (cacheValid) {
        await ModelCapabilitiesService.initialize();
        return ModelCacheService.loadAvailableModels();
      }
    }

    if (accessToken.isEmpty || _isLoading) {
      await ModelCapabilitiesService.initialize();
      return ModelCacheService.loadAvailableModels();
    }

    _isLoading = true;
    try {
      final response = await http
          .get(
            Uri.parse('${ApiConfigService.apiBaseUrl}/v1/models_info'),
            headers: {'Authorization': 'Bearer $accessToken'},
          )
          .timeout(_httpTimeout);

      if (response.statusCode == 200 && response.body.isNotEmpty) {
        final dynamic decoded = jsonDecode(response.body);
        if (decoded is List) {
          final payload = decoded
              .whereType<Map<String, dynamic>>()
              .map((entry) => Map<String, dynamic>.from(entry))
              .toList(growable: false);
          await ModelCacheService.saveAvailableModels(payload);
          await ModelCapabilitiesService.refresh();
          return payload;
        }
      }
    } on TimeoutException {
      if (kDebugMode) {
        debugPrint('⏱️ [ModelInfo] Timeout — using cached models');
      }
    } catch (error) {
      if (kDebugMode) {
        debugPrint('⚠️ [ModelInfo] Fetch failed, using cache: $error');
      }
    } finally {
      _isLoading = false;
    }

    // Any failure path falls back to whatever is cached.
    await ModelCapabilitiesService.initialize();
    return ModelCacheService.loadAvailableModels();
  }

  /// The provider slug a model is pinned to by default: the first provider in
  /// its `providers` list. Returns an empty string when unknown, which
  /// [sendTask] treats as "no provider — let the host choose".
  static String defaultProviderSlug(Map<String, dynamic> model) {
    final providers = model['providers'];
    if (providers is List) {
      for (final entry in providers) {
        if (entry is Map && entry['slug'] is String) {
          final slug = (entry['slug'] as String).trim();
          if (slug.isNotEmpty) return slug;
        }
      }
    }
    return '';
  }
}
