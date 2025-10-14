import 'package:flutter/foundation.dart';
import 'package:chuk_chat/services/supabase_service.dart';

class UserPreferencesService {
  const UserPreferencesService._();

  /// Save the user's selected model to Supabase
  static Future<bool> saveSelectedModel(String modelId) async {
    try {
      final session = SupabaseService.auth.currentSession;
      if (session == null) {
        debugPrint('No authenticated session found');
        return false;
      }

      final userId = session.user.id;

      // Upsert the user's model preference
      final response = await SupabaseService.client
          .from('user_preferences')
          .upsert({
            'user_id': userId,
            'selected_model_id': modelId,
          }, onConflict: 'user_id')
          .select();

      if (response.isNotEmpty) {
        debugPrint('Successfully saved model preference: $modelId');
        return true;
      } else {
        debugPrint('Failed to save model preference: empty response');
        return false;
      }
    } catch (e) {
      debugPrint('Error saving model preference: $e');
      return false;
    }
  }

  /// Load the user's selected model from Supabase
  static Future<String?> loadSelectedModel() async {
    try {
      final session = SupabaseService.auth.currentSession;
      if (session == null) {
        debugPrint('No authenticated session found');
        return null;
      }

      final userId = session.user.id;

      final response = await SupabaseService.client
          .from('user_preferences')
          .select('selected_model_id')
          .eq('user_id', userId)
          .maybeSingle();

      if (response != null && response['selected_model_id'] != null) {
        final modelId = response['selected_model_id'] as String;
        debugPrint('Loaded model preference: $modelId');
        return modelId;
      } else {
        debugPrint('No model preference found for user');
        return null;
      }
    } catch (e) {
      debugPrint('Error loading model preference: $e');
      return null;
    }
  }

  /// Clear the user's model preference
  static Future<bool> clearSelectedModel() async {
    try {
      final session = SupabaseService.auth.currentSession;
      if (session == null) {
        debugPrint('No authenticated session found');
        return false;
      }

      final userId = session.user.id;

      final List<dynamic> response = await SupabaseService.client
          .from('user_preferences')
          .delete()
          .eq('user_id', userId)
          .select();

      final int deletedCount = response.length;
      if (deletedCount > 0) {
        debugPrint('Cleared $deletedCount model preference(s) for user');
        return true;
      }
      debugPrint('No model preferences found to clear for user');
      return false;
    } catch (e) {
      debugPrint('Error clearing model preference: $e');
      return false;
    }
  }

  /// Save the user's selected provider for a specific model
  static Future<bool> saveSelectedProvider(
    String modelId,
    String providerSlug,
  ) async {
    try {
      final session = SupabaseService.auth.currentSession;
      if (session == null) {
        debugPrint('No authenticated session found');
        return false;
      }

      final userId = session.user.id;

      // Upsert the user's provider preference for the model
      final response = await SupabaseService.client
          .from('user_model_providers')
          .upsert({
            'user_id': userId,
            'model_id': modelId,
            'provider_slug': providerSlug,
          }, onConflict: 'user_id,model_id')
          .select();

      if (response.isNotEmpty) {
        debugPrint(
          'Successfully saved provider preference: $modelId -> $providerSlug',
        );
        return true;
      } else {
        debugPrint('Failed to save provider preference: empty response');
        return false;
      }
    } catch (e) {
      debugPrint('Error saving provider preference: $e');
      return false;
    }
  }

  /// Load the user's selected provider for a specific model
  static Future<String?> loadSelectedProvider(String modelId) async {
    try {
      final session = SupabaseService.auth.currentSession;
      if (session == null) {
        debugPrint('No authenticated session found');
        return null;
      }

      final userId = session.user.id;

      final response = await SupabaseService.client
          .from('user_model_providers')
          .select('provider_slug')
          .eq('user_id', userId)
          .eq('model_id', modelId)
          .maybeSingle();

      if (response != null && response['provider_slug'] != null) {
        final providerSlug = response['provider_slug'] as String;
        debugPrint('Loaded provider preference: $modelId -> $providerSlug');
        return providerSlug;
      } else {
        debugPrint('No provider preference found for model: $modelId');
        return null;
      }
    } catch (e) {
      debugPrint('Error loading provider preference: $e');
      return null;
    }
  }

  /// Load all user's provider preferences
  static Future<Map<String, String>> loadAllProviderPreferences() async {
    try {
      final session = SupabaseService.auth.currentSession;
      if (session == null) {
        debugPrint('No authenticated session found');
        return {};
      }

      final userId = session.user.id;

      final response = await SupabaseService.client
          .from('user_model_providers')
          .select('model_id, provider_slug')
          .eq('user_id', userId);

      final Map<String, String> preferences = {};
      for (final row in response) {
        preferences[row['model_id'] as String] = row['provider_slug'] as String;
      }

      debugPrint('Loaded ${preferences.length} provider preferences');
      return preferences;
    } catch (e) {
      debugPrint('Error loading all provider preferences: $e');
      return {};
    }
  }

  /// Clear all provider preferences for a user
  static Future<bool> clearAllProviderPreferences() async {
    try {
      final session = SupabaseService.auth.currentSession;
      if (session == null) {
        debugPrint('No authenticated session found');
        return false;
      }

      final userId = session.user.id;

      final List<dynamic> response = await SupabaseService.client
          .from('user_model_providers')
          .delete()
          .eq('user_id', userId)
          .select();

      final int deletedCount = response.length;
      if (deletedCount > 0) {
        debugPrint('Cleared $deletedCount provider preference(s) for user');
        return true;
      }
      debugPrint('No provider preferences found to clear for user');
      return false;
    } catch (e) {
      debugPrint('Error clearing provider preferences: $e');
      return false;
    }
  }
}
