// lib/services/model_capabilities_service.dart

import 'package:chuk_chat/services/model_cache_service.dart';

/// Service for determining model capabilities like vision support.
/// Uses ONLY cached API data (supports_vision field from /v1/models_info).
/// No hardcoded model lists - all capability data comes from the API.
class ModelCapabilitiesService {
  const ModelCapabilitiesService._();

  // In-memory cache for vision support lookups (modelId -> supportsVision)
  static final Map<String, bool> _visionSupportCache = {};
  static bool _isInitialized = false;

  /// Initialize the in-memory cache from disk cache.
  /// Should be called at app startup after ModelPrefetchService runs.
  static Future<void> initialize() async {
    if (_isInitialized) return;

    try {
      final cachedModels = await ModelCacheService.loadAvailableModels();
      _visionSupportCache.clear();
      for (final model in cachedModels) {
        final modelId = model['id'];
        final supportsVision = model['supports_vision'];
        if (modelId is String && supportsVision is bool) {
          _visionSupportCache[modelId] = supportsVision;
        }
      }
      _isInitialized = true;
    } catch (_) {
      // If initialization fails, cache stays empty (all models = no vision)
      _isInitialized = false;
    }
  }

  /// Returns `true` if the provided model id supports image input.
  /// Uses cached API data exclusively - no hardcoded fallbacks.
  static Future<bool> supportsImageInput(String modelId) async {
    if (modelId.isEmpty) return false;

    // Ensure cache is loaded
    if (!_isInitialized) {
      await initialize();
    }

    return _visionSupportCache[modelId] ?? false;
  }

  /// Synchronous version for UI - uses in-memory cache.
  /// Returns false if model not found or cache not yet initialized.
  static bool supportsImageInputSync(String modelId) {
    if (modelId.isEmpty) return false;
    return _visionSupportCache[modelId] ?? false;
  }

  /// Refresh the in-memory cache from disk.
  /// Call this after model data is refreshed from API.
  static Future<void> refresh() async {
    _isInitialized = false;
    await initialize();
  }
}
