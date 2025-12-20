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
  /// This prevents the prefetch operation from hanging indefinitely.
  /// Set to 15 seconds to allow for slower network conditions.
  static const Duration _httpTimeout = Duration(seconds: 15);

  /// Prefetch the user's model/provider preferences and cache the available
  /// models early in the app lifecycle so dropdowns can render instantly.
  static Future<void> prefetch() async {
    if (_isPrefetching) return;
    _isPrefetching = true;

    try {
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
        }
      }
    } on TimeoutException catch (error, stackTrace) {
      debugPrint(
        'Model prefetch timed out after ${_httpTimeout.inSeconds} seconds: $error',
      );
      debugPrint('$stackTrace');
      // TimeoutException is handled gracefully - no retry needed as this is a prefetch operation
    } catch (error, stackTrace) {
      debugPrint('Model prefetch failed: $error');
      debugPrint('$stackTrace');
    } finally {
      _isPrefetching = false;
    }
  }
}
