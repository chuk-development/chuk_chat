import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'package:chuk_chat/services/api_config_service.dart';
import 'package:chuk_chat/services/model_cache_service.dart';
import 'package:chuk_chat/services/model_capabilities_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/services/user_preferences_service.dart';

class ModelPrefetchService {
  const ModelPrefetchService._();

  /// The fetch in flight. A second caller waits for it instead of returning
  /// at once with nothing fetched (the old `_isPrefetching` flag did that,
  /// so a send that needed the catalogue got an empty answer).
  static Future<void>? _inFlight;

  /// Timeout duration for HTTP requests in the prefetch service.
  /// Short timeout (3s) - we prefer using cached data over waiting for slow network.
  /// If fetch fails, cached models will still work.
  static const Duration _httpTimeout = Duration(seconds: 3);

  /// Prefetch the user's model/provider preferences and cache the available
  /// models early in the app lifecycle so dropdowns can render instantly.
  ///
  /// This is optimized for fast startup:
  /// - Uses short timeout (3s) to avoid blocking
  /// - Skips network fetch if cache is fresh (< 10 min old)
  /// - Fails silently - cached data will be used as fallback
  ///
  /// [force] fetches even when the cache is still valid: a model added on the
  /// server after the last fetch is otherwise missing until the cache turns stale.
  static Future<void> prefetch({bool force = false}) {
    // A stale catalogue read (older than 10 min) refreshes through here, in
    // the background; the in-flight future below dedupes it.
    ModelCacheService.registerRevalidator(prefetch);
    final Future<void>? running = _inFlight;
    if (running != null && !force) return running;
    final Future<void> next = (running ?? Future<void>.value())
        .catchError((Object _) {})
        .then((_) => _prefetch(force: force));
    _inFlight = next;
    return next.whenComplete(() {
      if (identical(_inFlight, next)) _inFlight = null;
    });
  }

  static Future<void> _prefetch({required bool force}) async {
    try {
      // Check if we have valid cached models - skip fetch if so
      final cacheValid = !force && await ModelCacheService.isCacheValid();
      if (cacheValid) {
        if (kDebugMode) {
          debugPrint('📦 [ModelPrefetch] Cache valid, skipping network fetch');
        }
        // Initialize capabilities service with cached data
        await ModelCapabilitiesService.initialize();
        return;
      }

      final session =
          await SupabaseService.refreshSession() ??
          SupabaseService.auth.currentSession;
      if (session == null) {
        return;
      }

      final String accessToken = session.accessToken;
      if (accessToken.isEmpty) {
        return;
      }

      final String userId = session.user.id;

      // Load and cache provider preferences.
      final Map<String, String> providerPrefs =
          await UserPreferencesService.loadAllProviderPreferences();
      if (providerPrefs.isNotEmpty) {
        await ModelCacheService.saveProviderPreferences(userId, providerPrefs);
      }

      // Fetch models list and cache for quick reuse.
      if (kDebugMode) {
        debugPrint('🌐 [ModelPrefetch] Fetching models from network...');
      }
      final response = await http
          .get(
            Uri.parse('${ApiConfigService.apiBaseUrl}/v1/models_info'),
            headers: {'Authorization': 'Bearer $accessToken'},
          )
          .timeout(_httpTimeout);

      if (response.statusCode == 200 && response.body.isNotEmpty) {
        final dynamic decoded = jsonDecode(response.body);
        if (decoded is List) {
          final List<Map<String, dynamic>> payload = decoded
              .whereType<Map<String, dynamic>>()
              .map((entry) => Map<String, dynamic>.from(entry))
              .toList(growable: false);
          await ModelCacheService.saveAvailableModels(payload);
          if (kDebugMode) {
            debugPrint('✅ [ModelPrefetch] Cached ${payload.length} models');
          }
          // Initialize capabilities service with fresh data
          await ModelCapabilitiesService.refresh();
        }
      }
    } on TimeoutException {
      // Short timeout is expected on slow networks - use cached data
      if (kDebugMode) {
        debugPrint('⏱️ [ModelPrefetch] Timeout - using cached models');
      }
      // Hydrate capabilities from any existing disk cache so vision/reasoning
      // controls still work offline.
      await ModelCapabilitiesService.initialize();
    } catch (error) {
      // Fail silently - cached models will be used
      if (kDebugMode) {
        debugPrint('⚠️ [ModelPrefetch] Failed, using cache: $error');
      }
      // Hydrate capabilities from any existing disk cache on failure too.
      await ModelCapabilitiesService.initialize();
    }
  }
}
