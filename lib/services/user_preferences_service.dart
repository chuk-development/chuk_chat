import 'package:flutter/foundation.dart';
import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/model_cache_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/core/model_selection_events.dart';

class UserPreferencesService {
  const UserPreferencesService._();
  static const String _kFallbackModelId = 'deepseek/deepseek-chat-v3.1';
  static Map<String, String>? _cachedProviderPreferences;
  static DateTime? _providerPrefsFetchedAt;
  static Future<Map<String, String>>? _providerPrefsInFlight;
  static const Duration _kProviderPreferencesTtl = Duration(minutes: 1);

  // Cache for selected model to avoid redundant Supabase calls
  static String? _cachedSelectedModel;
  static DateTime? _selectedModelFetchedAt;
  static Future<String?>? _selectedModelInFlight;
  static const Duration _kSelectedModelTtl = Duration(minutes: 1);

  /// Save the user's selected model to Supabase
  static Future<bool> saveSelectedModel(String modelId) async {
    try {
      final session = SupabaseService.auth.currentSession;
      if (session == null) {
        if (kDebugMode) {
          debugPrint('No authenticated session found');
        }
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
        if (kDebugMode) {
          debugPrint('Successfully saved model preference: $modelId');
        }
        await ModelCacheService.saveSelectedModel(userId, modelId);
        // Update in-memory cache immediately
        _cachedSelectedModel = modelId;
        _selectedModelFetchedAt = DateTime.now();
        // Notify via event bus instead of direct widget reference
        ModelSelectionEventBus().notifyModelSelected(modelId);
        return true;
      } else {
        if (kDebugMode) {
          debugPrint('Failed to save model preference: empty response');
        }
        return false;
      }
    } catch (e) {
      final userId = SupabaseService.auth.currentUser?.id;
      if (userId != null) {
        await ModelCacheService.saveSelectedModel(userId, modelId);
      }
      if (kDebugMode) {
        debugPrint('Error saving model preference: $e');
      }
      return false;
    }
  }

  /// Force all active model dropdowns to re-query preferences and models.
  static Future<void> refreshModelSelections() async {
    // Notify via event bus instead of direct widget reference
    ModelSelectionEventBus().notifyRefresh();
  }

  /// Load the user's selected model - cache first, then sync from network
  static Future<String?> loadSelectedModel() async {
    final DateTime now = DateTime.now();

    // Return in-flight request if one exists
    if (_selectedModelInFlight != null) {
      return await _selectedModelInFlight!;
    }

    // Return in-memory cache if valid
    if (_cachedSelectedModel != null &&
        _selectedModelFetchedAt != null &&
        now.difference(_selectedModelFetchedAt!) < _kSelectedModelTtl) {
      if (kDebugMode) {
        debugPrint('Using cached model preference: $_cachedSelectedModel');
      }
      return _cachedSelectedModel;
    }

    Future<String?> performFetch() async {
      final userId = SupabaseService.auth.currentUser?.id;
      if (userId == null) {
        if (kDebugMode) {
          debugPrint('No authenticated user found');
        }
        return null;
      }

      // STEP 1: Load from local cache FIRST (instant)
      final cachedModel = await ModelCacheService.loadSelectedModel(userId);
      if (cachedModel != null && cachedModel.isNotEmpty) {
        if (kDebugMode) {
          debugPrint('Loaded model preference from cache: $cachedModel');
        }
        _cachedSelectedModel = cachedModel;
        _selectedModelFetchedAt = DateTime.now();

        // STEP 2: Sync from network in background (don't block)
        _syncModelFromNetwork(userId);

        return cachedModel;
      }

      // No cache - must fetch from network
      return await _fetchModelFromNetwork(userId);
    }

    try {
      _selectedModelInFlight = performFetch();
      return await _selectedModelInFlight!;
    } finally {
      _selectedModelInFlight = null;
    }
  }

  /// Fetch model preference from network (blocking)
  static Future<String?> _fetchModelFromNetwork(String userId) async {
    try {
      final response = await SupabaseService.client
          .from('user_preferences')
          .select('selected_model_id')
          .eq('user_id', userId)
          .maybeSingle();

      if (response != null && response['selected_model_id'] != null) {
        final modelId = response['selected_model_id'] as String;
        if (kDebugMode) {
          debugPrint('Loaded model preference from network: $modelId');
        }
        await ModelCacheService.saveSelectedModel(userId, modelId);
        _cachedSelectedModel = modelId;
        _selectedModelFetchedAt = DateTime.now();
        return modelId;
      } else {
        await ModelCacheService.saveSelectedModel(userId, '');
        _cachedSelectedModel = null;
        _selectedModelFetchedAt = DateTime.now();
        if (kDebugMode) {
          debugPrint('No model preference found for user');
        }
        return null;
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error fetching model preference: $e');
      }
      return null;
    }
  }

  /// Sync model preference from network in background
  static Future<void> _syncModelFromNetwork(String userId) async {
    try {
      final response = await SupabaseService.client
          .from('user_preferences')
          .select('selected_model_id')
          .eq('user_id', userId)
          .maybeSingle();

      if (response != null && response['selected_model_id'] != null) {
        final modelId = response['selected_model_id'] as String;
        if (modelId != _cachedSelectedModel) {
          if (kDebugMode) {
            debugPrint('Model preference updated from network: $modelId');
          }
          await ModelCacheService.saveSelectedModel(userId, modelId);
          _cachedSelectedModel = modelId;
          _selectedModelFetchedAt = DateTime.now();
          // Notify via event bus
          ModelSelectionEventBus().notifyModelSelected(modelId);
        }
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Background model sync failed: $e');
      }
    }
  }

  /// Clear the user's model preference
  static Future<bool> clearSelectedModel() async {
    try {
      final session = SupabaseService.auth.currentSession;
      if (session == null) {
        if (kDebugMode) {
          debugPrint('No authenticated session found');
        }
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
        if (kDebugMode) {
          debugPrint('Cleared $deletedCount model preference(s) for user');
        }
        await ModelCacheService.saveSelectedModel(userId, '');
        // Clear in-memory cache
        _cachedSelectedModel = null;
        _selectedModelFetchedAt = null;
        return true;
      }
      if (kDebugMode) {
        debugPrint('No model preferences found to clear for user');
      }
      return false;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error clearing model preference: $e');
      }
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
        if (kDebugMode) {
          debugPrint('No authenticated session found');
        }
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
        if (kDebugMode) {
          debugPrint(
            'Successfully saved provider preference: $modelId -> $providerSlug',
          );
        }
        await ModelCacheService.updateProviderPreference(
          userId,
          modelId,
          providerSlug,
        );
        // Update in-memory cache immediately to avoid stale data
        if (_cachedProviderPreferences != null) {
          _cachedProviderPreferences![modelId] = providerSlug;
        }
        return true;
      } else {
        if (kDebugMode) {
          debugPrint('Failed to save provider preference: empty response');
        }
        return false;
      }
    } catch (e) {
      final userId =
          SupabaseService.auth.currentSession?.user.id ??
          SupabaseService.auth.currentUser?.id;
      if (userId != null) {
        await ModelCacheService.updateProviderPreference(
          userId,
          modelId,
          providerSlug,
        );
      }
      if (kDebugMode) {
        debugPrint('Error saving provider preference: $e');
      }
      return false;
    }
  }

  /// Remove the saved provider preference for a specific model
  static Future<bool> clearSelectedProvider(String modelId) async {
    try {
      final session = SupabaseService.auth.currentSession;
      if (session == null) {
        if (kDebugMode) {
          debugPrint('No authenticated session found');
        }
        return false;
      }

      final userId = session.user.id;

      final List<dynamic> response = await SupabaseService.client
          .from('user_model_providers')
          .delete()
          .eq('user_id', userId)
          .eq('model_id', modelId)
          .select();

      final int deletedCount = response.length;
      if (deletedCount > 0) {
        if (kDebugMode) {
          debugPrint('Cleared provider preference for model: $modelId');
        }
        await ModelCacheService.clearProviderPreference(userId, modelId);
        // Remove from in-memory cache immediately to avoid stale data
        if (_cachedProviderPreferences != null) {
          _cachedProviderPreferences!.remove(modelId);
        }
        return true;
      }

      if (kDebugMode) {
        debugPrint('No provider preference found to clear for model: $modelId');
      }
      return false;
    } catch (e) {
      final userId = SupabaseService.auth.currentUser?.id;
      if (userId != null) {
        await ModelCacheService.clearProviderPreference(userId, modelId);
      }
      if (kDebugMode) {
        debugPrint('Error clearing provider preference for $modelId: $e');
      }
      return false;
    }
  }

  /// Load the user's selected provider for a specific model
  static Future<String?> loadSelectedProvider(String modelId) async {
    try {
      final session = SupabaseService.auth.currentSession;
      if (session == null) {
        if (kDebugMode) {
          debugPrint('No authenticated session found');
        }
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
        if (kDebugMode) {
          debugPrint('Loaded provider preference: $modelId -> $providerSlug');
        }
        await ModelCacheService.updateProviderPreference(
          userId,
          modelId,
          providerSlug,
        );
        return providerSlug;
      } else {
        if (kDebugMode) {
          debugPrint('No provider preference found for model: $modelId');
        }
        return null;
      }
    } catch (e) {
      final userId = SupabaseService.auth.currentUser?.id;
      if (userId != null) {
        final cached = await ModelCacheService.loadProviderPreferences(userId);
        if (cached.containsKey(modelId)) {
          final providerSlug = cached[modelId]!;
          if (kDebugMode) {
            debugPrint(
              'Loaded cached provider preference: $modelId -> $providerSlug',
            );
          }
          return providerSlug;
        }
      }
      if (kDebugMode) {
        debugPrint('Error loading provider preference: $e');
      }
      return null;
    }
  }

  /// Load all user's provider preferences
  static Future<Map<String, String>> loadAllProviderPreferences() async {
    final DateTime now = DateTime.now();
    if (_providerPrefsInFlight != null) {
      return await _providerPrefsInFlight!;
    }
    if (_cachedProviderPreferences != null &&
        _providerPrefsFetchedAt != null &&
        now.difference(_providerPrefsFetchedAt!) < _kProviderPreferencesTtl) {
      return Map<String, String>.from(_cachedProviderPreferences!);
    }

    Future<Map<String, String>> performFetch() async {
      try {
        final session = SupabaseService.auth.currentSession;
        if (session == null) {
          if (kDebugMode) {
            debugPrint('No authenticated session found');
          }
          return {};
        }

        final userId = session.user.id;

        final response = await SupabaseService.client
            .from('user_model_providers')
            .select('model_id, provider_slug')
            .eq('user_id', userId);

        final Map<String, String> preferences = {};
        for (final row in response) {
          preferences[row['model_id'] as String] =
              row['provider_slug'] as String;
        }

        if (kDebugMode) {
          debugPrint('Loaded ${preferences.length} provider preferences');
        }
        await ModelCacheService.saveProviderPreferences(userId, preferences);
        _cachedProviderPreferences = preferences;
        _providerPrefsFetchedAt = DateTime.now();
        return Map<String, String>.from(preferences);
      } catch (e) {
        final userId = SupabaseService.auth.currentUser?.id;
        if (userId != null) {
          final cached = await ModelCacheService.loadProviderPreferences(
            userId,
          );
          if (cached.isNotEmpty) {
            if (kDebugMode) {
              debugPrint(
                'Loaded ${cached.length} cached provider preferences for offline use',
              );
            }
            _cachedProviderPreferences = cached;
            _providerPrefsFetchedAt = DateTime.now();
            return Map<String, String>.from(cached);
          }
        }
        if (kDebugMode) {
          debugPrint('Error loading all provider preferences: $e');
        }
        return {};
      }
    }

    try {
      _providerPrefsInFlight = performFetch();
      return await _providerPrefsInFlight!;
    } finally {
      _providerPrefsInFlight = null;
    }
  }

  /// Clear all provider preferences for a user
  static Future<bool> clearAllProviderPreferences() async {
    try {
      final session = SupabaseService.auth.currentSession;
      if (session == null) {
        if (kDebugMode) {
          debugPrint('No authenticated session found');
        }
        return false;
      }

      final userId = session.user.id;

      final List<dynamic> response = await SupabaseService.client
          .from('user_model_providers')
          .delete()
          .eq('user_id', userId)
          .select();

      final int deletedCount = response.length;

      // Clear in-memory and persistent cache to prevent stale data
      _cachedProviderPreferences = null;
      _providerPrefsFetchedAt = null;
      await ModelCacheService.saveProviderPreferences(userId, {});

      if (deletedCount > 0) {
        if (kDebugMode) {
          debugPrint('Cleared $deletedCount provider preference(s) for user');
        }
        return true;
      }
      if (kDebugMode) {
        debugPrint('No provider preferences found to clear for user');
      }
      return false;
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error clearing provider preferences: $e');
      }
      return false;
    }
  }

  /// Save the user's system prompt (encrypted)
  static Future<bool> saveSystemPrompt(String systemPrompt) async {
    try {
      final session = SupabaseService.auth.currentSession;
      if (session == null) {
        if (kDebugMode) {
          debugPrint('No authenticated session found');
        }
        return false;
      }

      final userId = session.user.id;

      // Encrypt the system prompt using the same encryption as chat data
      final encryptedPrompt = await EncryptionService.encrypt(systemPrompt);

      String? selectedModelId;
      try {
        final response = await SupabaseService.client
            .from('user_preferences')
            .select('selected_model_id')
            .eq('user_id', userId)
            .maybeSingle();
        selectedModelId = (response?['selected_model_id'] as String?)?.trim();
      } catch (error) {
        if (kDebugMode) {
          debugPrint('Unable to load existing model preference: $error');
        }
      }

      selectedModelId ??= await ModelCacheService.loadSelectedModel(userId);
      if (selectedModelId != null && selectedModelId.trim().isEmpty) {
        selectedModelId = null;
      }
      selectedModelId ??= _kFallbackModelId;

      final Map<String, dynamic> upsertData = {
        'user_id': userId,
        'selected_model_id': selectedModelId,
        'system_prompt': encryptedPrompt,
      };

      // Upsert the encrypted system prompt
      final response = await SupabaseService.client
          .from('user_preferences')
          .upsert(upsertData, onConflict: 'user_id')
          .select();

      if (response.isNotEmpty) {
        if (kDebugMode) {
          debugPrint('Successfully saved encrypted system prompt');
        }
        return true;
      } else {
        if (kDebugMode) {
          debugPrint('Failed to save system prompt: empty response');
        }
        return false;
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error saving system prompt: $e');
      }
      return false;
    }
  }

  /// Load the user's system prompt (decrypted)
  static Future<String?> loadSystemPrompt() async {
    try {
      final session = SupabaseService.auth.currentSession;
      if (session == null) {
        if (kDebugMode) {
          debugPrint('No authenticated session found');
        }
        return null;
      }

      final userId = session.user.id;

      final response = await SupabaseService.client
          .from('user_preferences')
          .select('system_prompt')
          .eq('user_id', userId)
          .maybeSingle();

      if (response != null && response['system_prompt'] != null) {
        final encryptedPrompt = response['system_prompt'] as String;

        // Decrypt the system prompt
        final decryptedPrompt = await EncryptionService.decrypt(
          encryptedPrompt,
        );

        if (kDebugMode) {
          debugPrint(
            'Loaded and decrypted system prompt: ${decryptedPrompt.length} characters',
          );
        }
        return decryptedPrompt;
      } else {
        if (kDebugMode) {
          debugPrint('No system prompt found for user');
        }
        return null;
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error loading system prompt: $e');
      }
      return null;
    }
  }

  /// Clear the user's system prompt
  static Future<bool> clearSystemPrompt() async {
    try {
      final session = SupabaseService.auth.currentSession;
      if (session == null) {
        if (kDebugMode) {
          debugPrint('No authenticated session found');
        }
        return false;
      }

      final userId = session.user.id;

      // Update the system_prompt field to null
      final response = await SupabaseService.client
          .from('user_preferences')
          .update({'system_prompt': null})
          .eq('user_id', userId)
          .select();

      if (response.isNotEmpty) {
        if (kDebugMode) {
          debugPrint('Successfully cleared system prompt');
        }
        return true;
      } else {
        if (kDebugMode) {
          debugPrint('No system prompt found to clear');
        }
        return false;
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Error clearing system prompt: $e');
      }
      return false;
    }
  }
}
