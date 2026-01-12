import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'package:chuk_chat/services/api_config_service.dart';
import 'package:chuk_chat/services/model_cache_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/services/user_preferences_service.dart';

class ModelPrefetchService {
  const ModelPrefetchService._();

  static bool _isPrefetching = false;

  /// Timeout duration for HTTP requests in the prefetch service.
  /// Short timeout (3s) - we prefer using cached data over waiting for slow network.
  /// If fetch fails, cached models will still work.
  static const Duration _httpTimeout = Duration(seconds: 3);

  /// Prefetch the user's model/provider preferences and cache the available
  /// models early in the app lifecycle so dropdowns can render instantly.
  ///
  /// This is optimized for fast startup:
  /// - Uses short timeout (3s) to avoid blocking
  /// - Skips network fetch if cache is valid (< 24h old)
  /// - Fails silently - cached data will be used as fallback
  static Future<void> prefetch() async {
    if (_isPrefetching) return;
    _isPrefetching = true;

    try {
      // Check if we have valid cached models - skip fetch if so
      final cacheValid = await ModelCacheService.isCacheValid();
      if (cacheValid) {
        debugPrint('📦 [ModelPrefetch] Cache valid, skipping network fetch');
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
      debugPrint('🌐 [ModelPrefetch] Fetching models from network...');
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
          debugPrint('✅ [ModelPrefetch] Cached ${payload.length} models');
        }
      }
    } on TimeoutException {
      // Short timeout is expected on slow networks - use cached data
      debugPrint('⏱️ [ModelPrefetch] Timeout - using cached models');
    } catch (error) {
      // Fail silently - cached models will be used
      debugPrint('⚠️ [ModelPrefetch] Failed, using cache: $error');
    } finally {
      _isPrefetching = false;
    }
  }
}
