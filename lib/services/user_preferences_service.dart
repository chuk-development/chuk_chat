import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/services/encryption_service.dart';
import 'package:chuk_chat/services/model_cache_service.dart';
import 'package:chuk_chat/services/supabase_service.dart';
import 'package:chuk_chat/core/model_selection_events.dart';

class UserPreferencesService {
  const UserPreferencesService._();
  static Map<String, String>? _cachedProviderPreferences;
  static DateTime? _providerPrefsFetchedAt;
  static Future<Map<String, String>>? _providerPrefsInFlight;
  static const Duration _kProviderPreferencesTtl = Duration(minutes: 1);

  // Cache for selected model to avoid redundant Supabase calls
  static String? _cachedSelectedModel;
  static DateTime? _selectedModelFetchedAt;
  static Future<String?>? _selectedModelInFlight;
  static const Duration _kSelectedModelTtl = Duration(minutes: 1);

  /// The user every static cache in this class currently belongs to.
  ///
  /// **Cache invalidation is keyed by user id, not hooked off sign-out.** The
  /// obvious design would be a `resetCache()` called from a logout hook — this
  /// class had exactly that, and it never ran: its only caller,
  /// `AppInitializationService.resetServices()`, was itself dead code. A hook
  /// also cannot be a guarantee here, because `chat_ui_mobile` signs out via
  /// `SupabaseService.signOut()` and never touches `AuthService` at all.
  /// Comparing the user id on every access cannot be bypassed by a sign-out
  /// path that forgets to call it. Same pattern as `_resetIdentityCacheForUser`
  /// in `notes_tools.dart` and `_syncCacheToCurrentUser` in
  /// `services/skills/user_skills_service.dart`.
  static String? _cacheOwnerUserId;

  /// Drops every per-user cache in this class when the active user changed.
  /// Called at the top of each public entry point — see [_cacheOwnerUserId].
  static void _syncCacheToCurrentUser(String? userId) {
    if (_cacheOwnerUserId == userId) return;
    _cacheOwnerUserId = userId;
    _cachedProviderPreferences = null;
    _providerPrefsFetchedAt = null;
    _providerPrefsInFlight = null;
    _cachedSelectedModel = null;
    _selectedModelFetchedAt = null;
    _selectedModelInFlight = null;
    // Back to "not loaded" — never `''`, which means "loaded, no prompt set".
    _systemPromptMemCache = null;
  }

  /// The active user id, or null when signed out or Supabase is not up yet
  /// (`SupabaseService.auth` throws before initialization).
  static String? _currentUserId() {
    // Gated on kDebugMode so the override is tree-shaken out of release
    // builds: it is a mutable static that decides ownership, and
    // @visibleForTesting is a lint, not a runtime guard. Tests run in debug.
    if (kDebugMode) {
      final override = debugCurrentUserIdOverride;
      if (override != null) return override();
    }
    try {
      return SupabaseService.auth.currentUser?.id;
    } catch (_) {
      return null;
    }
  }

  /// True while [userId] is *still the live signed-in user*, so an async
  /// continuation that started as [userId] may keep its result.
  ///
  /// This deliberately consults live auth and not just [_cacheOwnerUserId].
  /// [_cacheOwnerUserId] only advances when a public entry point calls
  /// [_syncCacheToCurrentUser], so between a sign-out and the next entry point
  /// it still names the *previous* user — comparing against it alone would
  /// answer "yes, A still owns this" while B is already signed in, which is the
  /// exact leak this class exists to prevent. Checking [_currentUserId] closes
  /// that window without depending on anything having been called first.
  static bool _stillOwns(String? userId) =>
      userId != null &&
      _cacheOwnerUserId == userId &&
      _currentUserId() == userId;

  /// Save the user's selected model to Supabase
  static Future<bool> saveSelectedModel(String modelId) async {
    _syncCacheToCurrentUser(_currentUserId());
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
        // The save succeeded for `userId`, but if they signed out during the
        // round-trip their choice must not populate the new user's cache or be
        // announced to the new user's UI on the event bus.
        if (!_stillOwns(userId)) return true;
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
      final userId = _currentUserId();
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
    _syncCacheToCurrentUser(_currentUserId());
    final DateTime now = DateTime.now();

    // Return in-flight request if one exists
    if (_selectedModelInFlight != null) {
      return await _selectedModelInFlight!;
    }

    // Return in-memory cache if valid
    if (_cachedSelectedModel != null &&
        _selectedModelFetchedAt != null &&
        now.difference(_selectedModelFetchedAt!) < _kSelectedModelTtl) {
      final String? userId = _currentUserId();
      if (userId != null) {
        // Keep UI fast with in-memory cache while still checking for
        // remote preference changes in the background.
        unawaited(_syncModelFromNetwork(userId));
      }
      if (kDebugMode) {
        debugPrint('Using cached model preference: $_cachedSelectedModel');
      }
      return _cachedSelectedModel;
    }

    Future<String?> performFetch() async {
      final userId = _currentUserId();
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
        // The user changed while the local read was in flight — abort rather
        // than return, or the previous user's model selection reaches the new
        // user's UI through the return value.
        if (!_stillOwns(userId)) return null;
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

  /// Force-load the selected model directly from Supabase, bypassing cache.
  /// Used when no cached model exists and we need the Supabase trigger default.
  static Future<String?> forceLoadSelectedModel() async {
    final userId = _currentUserId();
    _syncCacheToCurrentUser(userId);
    if (userId == null) return null;
    return _fetchModelFromNetwork(userId);
  }

  /// Fetch model preference from network (blocking)
  static Future<String?> _fetchModelFromNetwork(String userId) async {
    try {
      final session =
          await SupabaseService.refreshSession() ??
          SupabaseService.auth.currentSession;
      if (session == null || session.user.id != userId) {
        return null;
      }

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
        // Never hand another user's model to whoever is signed in now, and
        // never write it into their cache.
        if (!_stillOwns(userId)) return null;
        _cachedSelectedModel = modelId;
        _selectedModelFetchedAt = DateTime.now();
        return modelId;
      } else {
        await ModelCacheService.saveSelectedModel(userId, '');
        if (!_stillOwns(userId)) return null;
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
      final session =
          await SupabaseService.refreshSession() ??
          SupabaseService.auth.currentSession;
      if (session == null || session.user.id != userId) {
        return;
      }

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
          // A background sync must never resurrect the previous user's model
          // after a sign-out, nor announce it on the event bus.
          if (!_stillOwns(userId)) return;
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
    _syncCacheToCurrentUser(_currentUserId());
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
    _syncCacheToCurrentUser(_currentUserId());
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
      final userId = _currentUserId();
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
    _syncCacheToCurrentUser(_currentUserId());
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
      final userId = _currentUserId();
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
    _syncCacheToCurrentUser(_currentUserId());
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
        // Abort if the user switched during the fetch — do not hand the
        // previous user's provider choice to the current one.
        if (!_stillOwns(userId)) return null;
        return providerSlug;
      } else {
        if (kDebugMode) {
          debugPrint('No provider preference found for model: $modelId');
        }
        return null;
      }
    } catch (e) {
      final userId = _currentUserId();
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
    _syncCacheToCurrentUser(_currentUserId());
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
        // The user changed while the request was in flight — abort rather than
        // return the previous user's preferences.
        if (!_stillOwns(userId)) return <String, String>{};
        _cachedProviderPreferences = preferences;
        _providerPrefsFetchedAt = DateTime.now();
        return Map<String, String>.from(preferences);
      } catch (e) {
        final userId = _currentUserId();
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
            if (!_stillOwns(userId)) return <String, String>{};
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

  /// Drop the in-memory provider-preferences cache so the next
  /// [loadAllProviderPreferences] hits Supabase. Called by realtime listeners
  /// when another device mutates `user_model_providers`.
  static void invalidateProviderPreferencesCache() {
    _cachedProviderPreferences = null;
    _providerPrefsFetchedAt = null;
  }

  /// Drop the in-memory selected-model cache so the next [loadSelectedModel]
  /// hits Supabase. Called by realtime listeners when another device updates
  /// `user_preferences.selected_model_id`.
  static void invalidateSelectedModelCache() {
    _cachedSelectedModel = null;
    _selectedModelFetchedAt = null;
  }

  /// Clear all provider preferences for a user
  static Future<bool> clearAllProviderPreferences() async {
    _syncCacheToCurrentUser(_currentUserId());
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

  /// SharedPreferences key holding [userId]'s cached system-prompt ciphertext.
  ///
  /// Namespaced by user id so a second user in the same install reads their own
  /// row instead of the previous user's. Before this, the key was a bare
  /// `cached_system_prompt` shared by every account, and the only thing keeping
  /// it from leaking was `EncryptionService._ensureKey()` happening to throw
  /// into a `catch (_) { return null; }` — a decryption failure, not an access
  /// check.
  static String _systemPromptCacheKey(String userId) =>
      'cached_system_prompt_$userId';

  /// The pre-namespacing key. Its value cannot be attributed to a user, so it
  /// is deleted rather than migrated onto whoever happens to be signed in now:
  /// re-fetching this cache costs one request, while mis-attributing it is
  /// exactly the cross-user leak the namespacing exists to prevent.
  static const String _legacySystemPromptCacheKey = 'cached_system_prompt';

  static Future<void> _dropLegacySystemPromptCache(
    SharedPreferences prefs,
  ) async {
    if (prefs.containsKey(_legacySystemPromptCacheKey)) {
      await prefs.remove(_legacySystemPromptCacheKey);
    }
  }

  /// In-memory decrypted system prompt. Populated by [loadSystemPrompt] /
  /// [saveSystemPrompt] and read by [loadSystemPromptFast] so the send path
  /// never blocks on a Supabase round-trip for a value that changes only
  /// when the user edits it. `''` is a valid cached value (no prompt set);
  /// null means "not loaded yet this session".
  ///
  /// Dropped by [_syncCacheToCurrentUser] when the active user changes.
  static String? _systemPromptMemCache;

  /// Fast system-prompt read for the send path: in-memory → local
  /// (SharedPreferences, decrypt, no network) → network as a last resort.
  /// Avoids the per-send Supabase select that [loadSystemPrompt] performs.
  /// Edits go through [saveSystemPrompt]/[clearSystemPrompt], which keep all
  /// three layers in sync, so cache-first is correct for the same device.
  static Future<String?> loadSystemPromptFast() async {
    final userId = _currentUserId();
    _syncCacheToCurrentUser(userId);
    if (userId == null) return null;
    if (_systemPromptMemCache != null) return _systemPromptMemCache;

    final local = await _loadSystemPromptLocalForUser(userId);
    // The user may have switched while the local read was in flight. Aborting
    // (rather than returning `local`) matters: this is the send path, and
    // handing back the previous user's plaintext leaks it into the new user's
    // message even though the cache itself stayed clean. Returning null means
    // "no custom prompt for this send" — fail-safe, and the next send reloads
    // correctly for whoever is now signed in.
    if (!_stillOwns(userId)) return null;
    if (local != null) {
      _systemPromptMemCache = local;
      return local;
    }
    return loadSystemPrompt();
  }

  /// Load the system prompt from local SharedPreferences only (no network).
  /// The cached value is stored encrypted; returns `null` if nothing is cached,
  /// if no user is signed in, or if decryption fails (e.g. encryption key not
  /// yet loaded).
  static Future<String?> loadSystemPromptLocal() async {
    final userId = _currentUserId();
    _syncCacheToCurrentUser(userId);
    if (userId == null) return null;
    return _loadSystemPromptLocalForUser(userId);
  }

  static Future<String?> _loadSystemPromptLocalForUser(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await _dropLegacySystemPromptCache(prefs);
      final encrypted = prefs.getString(_systemPromptCacheKey(userId));
      if (encrypted == null || encrypted.isEmpty) return null;
      final decrypted = await EncryptionService.decrypt(encrypted);
      // Decryption is async; the user can change during it. Never hand back
      // the previous user's plaintext to whoever is signed in now.
      if (!_stillOwns(userId)) return null;
      return decrypted;
    } catch (_) {
      return null;
    }
  }

  /// Save the user's system prompt (encrypted)
  static Future<bool> saveSystemPrompt(String systemPrompt) async {
    _syncCacheToCurrentUser(_currentUserId());
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

      final Map<String, dynamic> upsertData = {
        'user_id': userId,
        'system_prompt': encryptedPrompt,
      };
      if (selectedModelId != null) {
        upsertData['selected_model_id'] = selectedModelId;
      }

      // Upsert the encrypted system prompt
      final response = await SupabaseService.client
          .from('user_preferences')
          .upsert(upsertData, onConflict: 'user_id')
          .select();

      if (response.isNotEmpty) {
        // Cache locally only after successful server save.
        try {
          final prefs = await SharedPreferences.getInstance();
          await _dropLegacySystemPromptCache(prefs);
          await prefs.setString(_systemPromptCacheKey(userId), encryptedPrompt);
        } catch (_) {
          // Non-critical — caching is best-effort.
        }
        if (_stillOwns(userId)) _systemPromptMemCache = systemPrompt;
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
    _syncCacheToCurrentUser(_currentUserId());
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

        // Abort if the user switched during the fetch/decrypt: returning this
        // plaintext would leak it to the new user through the return value,
        // even with the memory cache left untouched.
        if (!_stillOwns(userId)) return null;

        // Cache the encrypted value locally for instant page loads.
        try {
          final prefs = await SharedPreferences.getInstance();
          await _dropLegacySystemPromptCache(prefs);
          await prefs.setString(_systemPromptCacheKey(userId), encryptedPrompt);
        } catch (_) {
          // Non-critical — caching is best-effort.
        }
        _systemPromptMemCache = decryptedPrompt;

        if (kDebugMode) {
          debugPrint(
            'Loaded and decrypted system prompt: ${decryptedPrompt.length} characters',
          );
        }
        return decryptedPrompt;
      } else {
        // No prompt set — cache the empty result so the fast path doesn't
        // re-hit the network on every send for users without a custom prompt.
        // `''` (loaded, none set) is deliberately distinct from null (not
        // loaded); only write it while this user still owns the cache.
        if (_stillOwns(userId)) _systemPromptMemCache = '';
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
    _syncCacheToCurrentUser(_currentUserId());
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
        // Clear local cache after successful server clear.
        try {
          final prefs = await SharedPreferences.getInstance();
          await _dropLegacySystemPromptCache(prefs);
          await prefs.remove(_systemPromptCacheKey(userId));
        } catch (_) {}
        if (_stillOwns(userId)) _systemPromptMemCache = '';
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

  // ─── Test seams ──────────────────────────────────────────────────────────
  // The real entry points read the active user id from `SupabaseService.auth`,
  // which needs a live backend. These drive the user-change path directly so
  // the invalidation and key namespacing stay unit-testable. They are seams,
  // not a sign-out hook — correctness comes from [_syncCacheToCurrentUser]
  // running on every access.

  /// Replaces the live auth lookup used by [_currentUserId] and [_stillOwns].
  ///
  /// Lets a test flip the signed-in user *while an async operation is
  /// suspended*, which is the only way to reproduce the sign-out-mid-flight
  /// race without a live backend. Null (the default) outside tests.
  @visibleForTesting
  static String? Function()? debugCurrentUserIdOverride;

  @visibleForTesting
  static bool debugStillOwns(String? userId) => _stillOwns(userId);

  @visibleForTesting
  static void debugPrimeCachesForUser(
    String? userId, {
    String? systemPrompt,
    String? selectedModel,
    Map<String, String>? providerPreferences,
  }) {
    _cacheOwnerUserId = userId;
    _systemPromptMemCache = systemPrompt;
    _cachedSelectedModel = selectedModel;
    _selectedModelFetchedAt = selectedModel == null ? null : DateTime.now();
    _cachedProviderPreferences = providerPreferences;
    _providerPrefsFetchedAt = providerPreferences == null
        ? null
        : DateTime.now();
  }

  @visibleForTesting
  static void debugSyncCacheToUser(String? userId) =>
      _syncCacheToCurrentUser(userId);

  @visibleForTesting
  static String systemPromptCacheKeyForUser(String userId) =>
      _systemPromptCacheKey(userId);

  @visibleForTesting
  static const String legacySystemPromptCacheKey = _legacySystemPromptCacheKey;

  @visibleForTesting
  static Future<String?> debugLoadSystemPromptLocalForUser(String userId) =>
      _loadSystemPromptLocalForUser(userId);

  @visibleForTesting
  static String? get debugSystemPromptMemCache => _systemPromptMemCache;

  @visibleForTesting
  static String? get debugSelectedModelCache => _cachedSelectedModel;

  @visibleForTesting
  static Map<String, String>? get debugProviderPreferencesCache =>
      _cachedProviderPreferences;

  @visibleForTesting
  static String? get debugCacheOwnerUserId => _cacheOwnerUserId;
}
