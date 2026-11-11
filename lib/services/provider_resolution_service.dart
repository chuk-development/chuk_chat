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
import 'package:chuk_chat/services/provider_cache_affinity.dart';
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
        final Object? speed = entry['speed'];
        out.add(
          ModelProviderSummary(
            slug: slug.trim(),
            name: name is String && name.isNotEmpty ? name : slug,
            promptPrice: _price(pricing is Map ? pricing['prompt'] : null),
            completionPrice: _price(
              pricing is Map ? pricing['completion'] : null,
            ),
            cacheReadPrice: _optional(
              pricing is Map ? pricing['cache_read'] : null,
            ),
            throughput: _optional(speed is Map ? speed['throughput'] : null),
            latencyP95Ms: _optional(
              speed is Map ? speed['latency_ms_p95'] : null,
            ),
          ),
        );
      }
      return out;
    }
    return const <ModelProviderSummary>[];
  }

  /// Prompt and output size [cheapestOf] prices a turn at when the chat has
  /// no served request to go by. Chats carry a system prompt, tool
  /// definitions and history, so the prompt side dominates the bill.
  static const int defaultPromptTokens = 6000;
  static const int defaultCompletionTokens = 600;

  /// Share of the last prompt a warm cache is expected to serve. Measured on
  /// Fireworks within 5 min: ~0.9 (`usage_logs`, 2026-11-11).
  static const double warmCacheShare = 0.9;

  /// Providers slower than this (tokens/s) or with a p95 latency above
  /// [maxLatencyP95Ms] are only picked when nothing else is left. "Flex"
  /// tiers are cheap because they queue; Auto must not trade a few cents
  /// for a minute of "Prompt processing".
  static const double minThroughput = 40;
  static const double maxLatencyP95Ms = 10000;

  /// The estimated cost of one turn on [p]. [warm] is the chat's last served
  /// request while its provider's cache is still alive; it supplies the
  /// prompt and output size, and makes the cached share of the prompt cost
  /// the cache-read price on that same provider.
  static double estimatedCost(
    ModelProviderSummary p, {
    ProviderAffinity? warm,
  }) {
    final int prompt = warm == null
        ? defaultPromptTokens
        : warm.promptTokens + 500; // the next turn adds the new message
    final int completion = warm == null || warm.completionTokens <= 0
        ? defaultCompletionTokens
        : warm.completionTokens;
    double cached = 0;
    final double? cacheRead = p.cacheReadPrice;
    if (warm != null &&
        warm.providerSlug == p.slug &&
        cacheRead != null &&
        cacheRead < p.promptPrice) {
      cached = warm.promptTokens * warmCacheShare;
    }
    return cached * (cacheRead ?? p.promptPrice) +
        (prompt - cached) * p.promptPrice +
        completion * p.completionPrice;
  }

  static bool _fastEnough(ModelProviderSummary p) {
    final double? tps = p.throughput;
    final double? p95 = p.latencyP95Ms;
    if (tps != null && tps > 0 && tps < minThroughput) return false;
    if (p95 != null && p95 > maxLatencyP95Ms) return false;
    return true;
  }

  /// The provider Auto sends to: the lowest [estimatedCost], among the
  /// providers that are [_fastEnough] (all of them when none is). On a tie
  /// the first listed provider wins. With [warm], the provider that still
  /// holds the chat's prompt in cache is priced at its cache-read rate, so
  /// Auto stays there unless another provider is cheaper even uncached.
  /// The model screen's "Auto — currently: X" label uses the same rule
  /// (without [warm]).
  static ModelProviderSummary? cheapestOf(
    List<ModelProviderSummary> providers, {
    ProviderAffinity? warm,
  }) {
    if (providers.isEmpty) return null;
    final List<ModelProviderSummary> fast = providers
        .where(_fastEnough)
        .toList();
    final List<ModelProviderSummary> pool = fast.isEmpty ? providers : fast;
    ModelProviderSummary best = pool.first;
    double bestCost = estimatedCost(best, warm: warm);
    for (final ModelProviderSummary p in pool.skip(1)) {
      final double cost = estimatedCost(p, warm: warm);
      if (cost < bestCost) {
        best = p;
        bestCost = cost;
      }
    }
    return best;
  }

  /// The cheapest provider slug for [modelId] in [catalogue], or null.
  static String? cheapestSlugIn(
    List<Map<String, dynamic>> catalogue,
    String modelId, {
    ProviderAffinity? warm,
  }) => cheapestOf(providersIn(catalogue, modelId), warm: warm)?.slug;

  /// The cheapest provider for [modelId] from the cached catalogue. When the
  /// cache does not carry the model (a model added after the last fetch),
  /// the catalogue is fetched once and read again. Null only when the
  /// server itself lists no provider for the model, or is unreachable and
  /// the cache never had it. [chatId] lets a warm provider cache of that
  /// chat count ([ProviderCacheAffinity]).
  static Future<String?> cheapestSlugFor(
    String modelId, {
    String? chatId,
  }) async {
    if (modelId.trim().isEmpty) return null;
    final ProviderAffinity? warm = ProviderCacheAffinity.instance.warmFor(
      chatId,
      modelId,
    );
    final String? cached = cheapestSlugIn(
      await _safeLoad(),
      modelId,
      warm: warm,
    );
    if (cached != null) return cached;
    try {
      await refreshCatalogue();
    } catch (error) {
      if (kDebugMode) {
        debugPrint('ProviderResolution: catalogue refresh failed: $error');
      }
    }
    return cheapestSlugIn(await _safeLoad(), modelId, warm: warm);
  }

  /// The slug a send for [modelId] carries, given the stored choice [slug].
  ///
  /// - A concrete slug is returned unchanged.
  /// - The Auto marker becomes the cheapest current provider for this turn
  ///   of [chatId] (see [cheapestOf]).
  /// - Null or empty (nothing stored) also becomes the cheapest provider,
  ///   so a model the reader can see in the menu can always be sent to.
  ///
  /// Never returns the Auto marker. Returns null only when no provider is
  /// known for the model at all.
  static Future<String?> resolveForSend(
    String modelId,
    String? slug, {
    String? chatId,
  }) async {
    final String trimmed = slug?.trim() ?? '';
    if (trimmed.isNotEmpty && !isAuto(trimmed)) return trimmed;
    return cheapestSlugFor(modelId, chatId: chatId);
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

  static double? _optional(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value);
    return null;
  }

  static double _price(Object? value) {
    if (value is num) return value.toDouble();
    if (value is String) return double.tryParse(value) ?? 0.0;
    return 0.0;
  }
}
