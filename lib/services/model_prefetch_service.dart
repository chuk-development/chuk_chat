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

  /// Prefetch the user's model/provider preferences and cache the available
  /// models early in the app lifecycle so dropdowns can render instantly.
  static Future<void> prefetch() async {
    if (_isPrefetching) return;

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

    _isPrefetching = true;
    try {
      final String userId = session.user.id;

      // Load and cache provider preferences.
      final Map<String, String> providerPrefs =
          await UserPreferencesService.loadAllProviderPreferences();
      if (providerPrefs.isNotEmpty) {
        await ModelCacheService.saveProviderPreferences(userId, providerPrefs);
      }

      // Fetch models list and cache for quick reuse.
      final response = await http.get(
        Uri.parse('${ApiConfigService.apiBaseUrl}/models_info'),
        headers: {'Authorization': 'Bearer $accessToken'},
      );

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
    } catch (error, stackTrace) {
      debugPrint('Model prefetch failed: $error');
      debugPrint('$stackTrace');
    } finally {
      _isPrefetching = false;
    }
  }
}
