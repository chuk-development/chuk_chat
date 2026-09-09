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

  // In-memory cache for mandatory reasoning (modelId -> reasoningMandatory).
  // A model flagged here forbids disabling reasoning; the server rejects a
  // "reasoning off" request with a hard 400, so the UI must not offer it.
  static final Map<String, bool> _reasoningMandatoryCache = {};

  // In-memory cache of the server's `supported_efforts` list per model — THE
  // picker list the client must render verbatim (see the reasoning-effort
  // contract). "none"/off is first when disabling is allowed, absent when
  // reasoning is mandatory. The list is already fully resolved by the server;
  // the client never invents or reorders it.
  static final Map<String, List<String>> _supportedEffortsCache = {};

  // In-memory cache of the server's `reasoning_default_effort` per model — the
  // level the model reasons at by default, used as a clamp target for an
  // unknown/stale stored selection.
  static final Map<String, String> _reasoningDefaultEffortCache = {};

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
      final mandatory = <String, bool>{};
      final supportedEfforts = <String, List<String>>{};
      final defaultEffort = <String, String>{};
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
        final reasoningMandatory = model['reasoning_mandatory'];
        if (reasoningMandatory is bool) {
          mandatory[modelId] = reasoningMandatory;
        }
        final efforts = model['supported_efforts'];
        if (efforts is List) {
          final tokens = efforts.whereType<String>().toList();
          if (tokens.isNotEmpty) supportedEfforts[modelId] = tokens;
        }
        final defEffort = model['reasoning_default_effort'];
        if (defEffort is String && defEffort.isNotEmpty) {
          defaultEffort[modelId] = defEffort;
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
      _reasoningMandatoryCache
        ..clear()
        ..addAll(mandatory);
      _supportedEffortsCache
        ..clear()
        ..addAll(supportedEfforts);
      _reasoningDefaultEffortCache
        ..clear()
        ..addAll(defaultEffort);
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

  /// Whether [modelId] FORCES reasoning on (cannot be turned off). When true,
  /// the UI must hide the "off" option and never send a reasoning-disabled
  /// request — the server rejects it with a hard 400. Conservative default:
  /// an unknown model is treated as NOT mandatory (keeps the off option); the
  /// server-side safety net still recovers if such a model rejects a disable.
  static bool isReasoningMandatorySync(String modelId) {
    if (modelId.isEmpty) return false;
    return _reasoningMandatoryCache[modelId] ?? false;
  }

  /// The server's `supported_efforts` list for [modelId] — the picker options,
  /// rendered verbatim (see the reasoning-effort contract). Returns an empty
  /// list when the catalog cache has no entry yet (cold start) or the model is
  /// unknown, so the caller falls back to the derived list. The returned list
  /// is a copy, so a caller can never mutate the cache.
  static List<String> supportedEffortsSync(String modelId) {
    if (modelId.isEmpty) return const <String>[];
    final cached = _supportedEffortsCache[modelId];
    return cached == null ? const <String>[] : List<String>.of(cached);
  }

  /// The server's `reasoning_default_effort` for [modelId], or null when the
  /// model advertises none / is unknown. Used as a clamp target for a stale
  /// stored selection that is no longer in the model's list.
  static String? reasoningDefaultEffortSync(String modelId) {
    if (modelId.isEmpty) return null;
    return _reasoningDefaultEffortCache[modelId];
  }

  /// Refresh the in-memory cache from disk.
  /// Call this after model data is refreshed from API. Always re-reads, even
  /// when already initialized, and runs through the same serialized queue so
  /// it can never race an in-flight initialize.
  static Future<void> refresh() => _enqueueLoad();
}
