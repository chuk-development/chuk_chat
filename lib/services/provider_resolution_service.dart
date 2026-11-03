// lib/services/provider_resolution_service.dart
//
// The one place that turns a stored provider choice into the slug a send
// carries.
//
// The stored choice can be the "Auto (cheapest)" marker
// [kAutoCheapestProviderSlug]. It is a choice, not a provider: the server
// does not know it, so it must become a real slug before a send leaves the
// app. The old resolver read the provider list from mounted
// `ModelSelectionDropdown` states. That widget is no longer built anywhere,
// so the list was always empty and every send with Auto failed with
// "No provider is configured". This service reads the model catalogue
// (`/v1/models_info`, cached by [ModelCacheService]) instead, which every
// screen keeps current, and fetches it once when the model is missing.

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/services/model_cache_service.dart';
import 'package:chuk_chat/services/model_prefetch_service.dart';
import 'package:chuk_chat/widgets/model_selection_dropdown.dart'
    show kAutoCheapestProviderSlug, ModelProviderSummary;

typedef ModelCatalogueLoader = Future<List<Map<String, dynamic>>> Function();
typedef ModelCatalogueRefresher = Future<void> Function();

class ProviderResolutionService {
  const ProviderResolutionService._();

  /// Reads the cached catalogue. Replaceable in tests.
  @visibleForTesting
  static ModelCatalogueLoader loadCatalogue =
      ModelCacheService.loadAvailableModels;

  /// Fetches the catalogue from the server into the cache, even when the
  /// cache is still valid. Replaceable in tests.
  @visibleForTesting
  static ModelCatalogueRefresher refreshCatalogue = () =>
      ModelPrefetchService.prefetch(force: true);

  /// Puts the production loaders back. For tests.
  @visibleForTesting
  static void resetForTesting() {
    loadCatalogue = ModelCacheService.loadAvailableModels;
    refreshCatalogue = () => ModelPrefetchService.prefetch(force: true);
  }

  /// True when [slug] is the "Auto (cheapest)" marker.
  static bool isAuto(String? slug) => slug?.trim() == kAutoCheapestProviderSlug;

  /// The providers the catalogue lists for [modelId], with their prices.
  static List<ModelProviderSummary> providersIn(
    List<Map<String, dynamic>> catalogue,
    String modelId,
  ) {
    for (final Map<String, dynamic> model in catalogue) {
      if (model['id'] != modelId) continue;
      final Object? providers = model['providers'];
      if (providers is! List) return const <ModelProviderSummary>[];
      final List<ModelProviderSummary> out = <ModelProviderSummary>[];
      for (final Object? entry in providers) {
        if (entry is! Map) continue;
        final Object? slug = entry['slug'];
        if (slug is! String || slug.trim().isEmpty) continue;
        final Object? name = entry['name'];
        final Object? pricing = entry['pricing'];
        out.add(
          ModelProviderSummary(
            slug: slug.trim(),
            name: name is String && name.isNotEmpty ? name : slug,
            promptPrice: _price(pricing is Map ? pricing['prompt'] : null),
            completionPrice: _price(
              pricing is Map ? pricing['completion'] : null,
            ),
          ),
        );
      }
      return out;
    }
    return const <ModelProviderSummary>[];
  }

  /// The cheapest provider by output (completion) price. On a tie the
  /// first listed provider wins. This is the same rule the model screen
  /// uses for its "Auto (cheapest) — currently: X" label, so the provider
  /// the reader sees there is the provider the send uses.
  static ModelProviderSummary? cheapestOf(
    List<ModelProviderSummary> providers,
  ) {
    if (providers.isEmpty) return null;
    ModelProviderSummary best = providers.first;
    for (final ModelProviderSummary p in providers.skip(1)) {
      if (p.completionPrice < best.completionPrice) best = p;
    }
    return best;
  }

  /// The cheapest provider slug for [modelId] in [catalogue], or null.
  static String? cheapestSlugIn(
    List<Map<String, dynamic>> catalogue,
    String modelId,
  ) => cheapestOf(providersIn(catalogue, modelId))?.slug;

  /// The cheapest provider for [modelId] from the cached catalogue. When the
  /// cache does not carry the model (a model added after the last fetch),
  /// the catalogue is fetched once and read again. Null only when the
  /// server itself lists no provider for the model, or is unreachable and
  /// the cache never had it.
  static Future<String?> cheapestSlugFor(String modelId) async {
    if (modelId.trim().isEmpty) return null;
    final String? cached = cheapestSlugIn(await _safeLoad(), modelId);
    if (cached != null) return cached;
    try {
      await refreshCatalogue();
    } catch (error) {
      if (kDebugMode) {
        debugPrint('ProviderResolution: catalogue refresh failed: $error');
      }
    }
    return cheapestSlugIn(await _safeLoad(), modelId);
  }

  /// The slug a send for [modelId] carries, given the stored choice [slug].
  ///
  /// - A concrete slug is returned unchanged.
  /// - The Auto marker becomes the cheapest current provider.
  /// - Null or empty (nothing stored) also becomes the cheapest provider,
  ///   so a model the reader can see in the menu can always be sent to.
  ///
  /// Never returns the Auto marker. Returns null only when no provider is
  /// known for the model at all.
  static Future<String?> resolveForSend(String modelId, String? slug) async {
    final String trimmed = slug?.trim() ?? '';
    if (trimmed.isNotEmpty && !isAuto(trimmed)) return trimmed;
    return cheapestSlugFor(modelId);
  }

  static Future<List<Map<String, dynamic>>> _safeLoad() async {
    try {
      return await loadCatalogue();
    } catch (error) {
      if (kDebugMode) {
        debugPrint('ProviderResolution: catalogue unavailable: $error');
      }
      return const <Map<String, dynamic>>[];
    }
  }

  static double _price(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0.0;
    return 0.0;
  }
}
