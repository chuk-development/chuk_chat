// lib/services/provider_cache_affinity.dart
//
// Which provider served a chat last, when, and with how big a prompt.
//
// "Auto" picks a provider per send. A provider that served the previous
// turn of the same chat still holds that prompt in its prefix cache for a
// few minutes, and a cache read costs a fraction of a fresh prompt token
// (DeepSeek V4.1 Flash: ~0.006 $/M read vs 0.04-0.45 $/M fresh). So the
// cheapest provider for the next turn is often the last one, not the one
// with the lowest list price. [ProviderResolutionService] reads this record
// to price that in.
//
// Memory only: the caches it describes live for minutes, so losing the
// record on an app restart costs at most one cache miss.

import 'package:flutter/foundation.dart';

import 'package:chuk_chat/models/chat_stream_event.dart';

/// The last served request of one chat.
@immutable
class ProviderAffinity {
  const ProviderAffinity({
    required this.modelId,
    required this.providerSlug,
    required this.servedAt,
    required this.promptTokens,
    required this.completionTokens,
  });

  final String modelId;
  final String providerSlug;
  final DateTime servedAt;
  final int promptTokens;
  final int completionTokens;
}

/// Notifies when the provider a model runs on changes, so the "Auto · X"
/// labels update the moment the server names the provider.
class ProviderCacheAffinity extends ChangeNotifier {
  ProviderCacheAffinity._();

  static final ProviderCacheAffinity instance = ProviderCacheAffinity._();

  /// Clock. Replaceable in tests.
  @visibleForTesting
  DateTime Function() now = DateTime.now;

  final Map<String, ProviderAffinity> _byChat = <String, ProviderAffinity>{};

  /// The provider each model was last sent to, and when. Set from the
  /// stream's `meta` frame, before the first token, so the UI can show the
  /// provider while the answer is still coming.
  final Map<String, (String, DateTime)> _servingByModel =
      <String, (String, DateTime)>{};

  /// The provider Auto ran [modelId] on last, while that provider's cache
  /// is still warm. Null when the model has not run lately.
  String? currentProviderFor(String modelId) {
    final (String, DateTime)? serving = _servingByModel[modelId];
    if (serving == null) return null;
    final (String slug, DateTime at) = serving;
    if (now().difference(at) > cacheTtlFor(slug)) return null;
    return slug;
  }

  void _noteServing(String modelId, String slug) {
    final (String, DateTime)? previous = _servingByModel[modelId];
    _servingByModel[modelId] = (slug, now());
    if (previous?.$1 != slug) notifyListeners();
  }

  /// How long a provider keeps a prompt prefix cached, by provider family
  /// (the slug before the first `/`). Measured on our own `usage_logs`
  /// (45 days, consecutive requests of one user, model and provider,
  /// 2026-11-11): Fireworks hits 94 % at 1-5 min, 38 % at 5-15 min, 0 %
  /// after 15 min; DeepInfra still hits ~50 % after 15 min. The rest come
  /// from the providers' docs, taken at the safe end: Together "about an
  /// hour", Groq 2 h, DeepSeek "a few hours to a few days", Cerebras and
  /// Moonshot 5 min. Families without data get [defaultCacheTtl].
  static const Map<String, Duration> cacheTtlByFamily = <String, Duration>{
    'fireworks': Duration(minutes: 5),
    'runanywhere': Duration(minutes: 5),
    'deepinfra': Duration(minutes: 15),
    'together': Duration(minutes: 30),
    'groq': Duration(hours: 1),
    'deepseek': Duration(hours: 1),
    'cerebras': Duration(minutes: 5),
    'moonshotai': Duration(minutes: 5),
  };

  /// The TTL for a provider family that [cacheTtlByFamily] does not list.
  /// Most open-weight hosts run vLLM/SGLang prefix caches with LRU eviction
  /// and no fixed TTL; five minutes is what Fireworks shows and what the
  /// closed providers document.
  static const Duration defaultCacheTtl = Duration(minutes: 5);

  /// The cache TTL for [providerSlug].
  static Duration cacheTtlFor(String providerSlug) {
    final String family = providerSlug.split('/').first.toLowerCase();
    return cacheTtlByFamily[family] ?? defaultCacheTtl;
  }

  /// The record for [chatId] when it is about [modelId] and its provider's
  /// cache is still warm, else null.
  ProviderAffinity? warmFor(String? chatId, String modelId) {
    if (chatId == null || chatId.isEmpty) return null;
    final ProviderAffinity? record = _byChat[chatId];
    if (record == null || record.modelId != modelId) return null;
    final Duration age = now().difference(record.servedAt);
    if (age > cacheTtlFor(record.providerSlug)) return null;
    return record;
  }

  /// Stores a served request.
  void record({
    required String chatId,
    required String modelId,
    required String providerSlug,
    required int promptTokens,
    required int completionTokens,
  }) {
    if (chatId.isEmpty || modelId.isEmpty || providerSlug.isEmpty) return;
    _noteServing(modelId, providerSlug);
    _byChat[chatId] = ProviderAffinity(
      modelId: modelId,
      providerSlug: providerSlug,
      servedAt: now(),
      promptTokens: promptTokens,
      completionTokens: completionTokens,
    );
  }

  /// Wraps a send's event stream: notes the serving provider (from `meta`;
  /// a failover sends a second `meta`) and the token counts (from `usage`),
  /// and records them when the request finishes with `done`. The events
  /// pass through unchanged.
  Stream<ChatStreamEvent> observe(
    Stream<ChatStreamEvent> events, {
    required String? chatId,
    required String modelId,
    String? requestedProviderSlug,
  }) {
    if (chatId == null || chatId.isEmpty) return events;
    String? provider = requestedProviderSlug;
    int prompt = 0;
    int completion = 0;
    return events.map((ChatStreamEvent event) {
      if (event is MetaEvent) {
        final Object? p = event.meta['provider'];
        final Object? slug = p is Map ? p['slug'] : null;
        if (slug is String && slug.isNotEmpty) {
          provider = slug;
          _noteServing(modelId, slug);
        }
      } else if (event is UsageEvent) {
        prompt = _int(event.usage['prompt_tokens']) ?? prompt;
        completion = _int(event.usage['completion_tokens']) ?? completion;
      } else if (event is DoneEvent) {
        final String? served = provider;
        if (served != null && served.isNotEmpty && prompt > 0) {
          record(
            chatId: chatId,
            modelId: modelId,
            providerSlug: served,
            promptTokens: prompt,
            completionTokens: completion,
          );
        }
      }
      return event;
    });
  }

  @visibleForTesting
  void clearForTesting() {
    _byChat.clear();
    _servingByModel.clear();
    now = DateTime.now;
  }

  static int? _int(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }
}
