// lib/services/model_capabilities_service.dart

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/services/model_cache_service.dart';

/// Service for determining model capabilities like vision and reasoning.
/// Uses ONLY cached API data (the `supports_*` fields from /v1/models_info).
/// No hardcoded model lists - all capability data comes from the API.
class ModelCapabilitiesService {
  const ModelCapabilitiesService._();

  // In-memory cache for vision support lookups (modelId -> supportsVision)
  static final Map<String, bool> _visionSupportCache = {};

  // In-memory cache for reasoning support lookups (modelId -> supportsReasoning)
  static final Map<String, bool> _reasoningSupportCache = {};

  // In-memory cache for graded-effort support (modelId -> supportsReasoningEffort)
  static final Map<String, bool> _reasoningEffortCache = {};

  static bool _isInitialized = false;

  /// Serializes every load so a self-heal, a startup init and a prefetch
  /// refresh can never interleave. Each load waits for the one before it, so
  /// an older read can never clobber the maps a newer read just wrote.
  static Future<void> _inflight = Future<void>.value();

  /// Bumped every time the in-memory caches are (re)filled. UI can listen to
  /// rebuild the moment capability data becomes available, so a vision model's
  /// attach button enables live on cold start without a second tap.
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// Initialize the in-memory cache from disk cache.
  /// Should be called at app startup after ModelPrefetchService runs.
  /// Reading the on-disk SharedPreferences cache is offline-safe and fast,
  /// and is a no-op when the cache is empty. Idempotent and safe to call
  /// concurrently — a second call while a load is in flight awaits that same
  /// load instead of starting a competing one.
  static Future<void> initialize() {
    if (_isInitialized) return Future<void>.value();
    return _enqueueLoad();
  }

  /// Chain a fresh disk read onto the serialized queue and return it.
  static Future<void> _enqueueLoad() {
    final next = _inflight.then((_) => _loadIntoMaps());
    // Keep the chain alive even if a load throws, so the next caller still
    // runs after it rather than inheriting a failed future.
    _inflight = next.catchError((_) {});
    return next;
  }

  /// Read the disk cache into local maps, then swap them in atomically. The
  /// swap happens with no `await` between build and assign, so a concurrent
  /// reader never sees half-filled maps.
  static Future<void> _loadIntoMaps() async {
    try {
      final cachedModels = await ModelCacheService.loadAvailableModels();
      final vision = <String, bool>{};
      final reasoning = <String, bool>{};
      final effort = <String, bool>{};
      for (final model in cachedModels) {
        final modelId = model['id'];
        if (modelId is! String) continue;
        final supportsVision = model['supports_vision'];
        if (supportsVision is bool) vision[modelId] = supportsVision;
        final supportsReasoning = model['supports_reasoning'];
        if (supportsReasoning is bool) reasoning[modelId] = supportsReasoning;
        final supportsReasoningEffort = model['supports_reasoning_effort'];
        if (supportsReasoningEffort is bool) {
          effort[modelId] = supportsReasoningEffort;
        }
      }
      _visionSupportCache
        ..clear()
        ..addAll(vision);
      _reasoningSupportCache
        ..clear()
        ..addAll(reasoning);
      _reasoningEffortCache
        ..clear()
        ..addAll(effort);
      _isInitialized = true;
      revision.value++;
      if (kDebugMode) {
        debugPrint(
          '✅ [ModelCapabilities] Initialized with ${_visionSupportCache.length} models, ${_visionSupportCache.entries.where((e) => e.value).length} support vision',
        );
      }
    } catch (error) {
      // If the load fails, keep whatever was already there rather than
      // wiping it — a failed refresh must not blank out a good cache.
      if (kDebugMode) {
        debugPrint('⚠️ [ModelCapabilities] Initialization failed: $error');
      }
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
  ///
  /// When the cache is not yet loaded this kicks off a fire-and-forget
  /// [initialize] (self-heal), so the next read/tap succeeds. The [revision]
  /// notifier bumps once that finishes, letting the UI rebuild live.
  static bool supportsImageInputSync(String modelId) {
    if (modelId.isEmpty) return false;
    if (!_isInitialized) {
      // Self-heal: hydrate from the on-disk cache in the background.
      unawaited(initialize());
    }
    return _visionSupportCache[modelId] ?? false;
  }

  /// Whether [modelId] can reason at all. Permissive default: an unknown model
  /// keeps a reasoning control, matching prior behaviour.
  static bool supportsReasoningSync(String modelId) {
    if (modelId.isEmpty) return true;
    return _reasoningSupportCache[modelId] ?? true;
  }

  /// Whether [modelId] accepts a GRADED effort level (low/medium/high).
  /// Permissive default: an unknown model keeps the graded ladder.
  static bool supportsReasoningEffortSync(String modelId) {
    if (modelId.isEmpty) return true;
    return _reasoningEffortCache[modelId] ?? true;
  }

  /// Refresh the in-memory cache from disk.
  /// Call this after model data is refreshed from API. Always re-reads, even
  /// when already initialized, and runs through the same serialized queue so
  /// it can never race an in-flight initialize.
  static Future<void> refresh() => _enqueueLoad();
}
