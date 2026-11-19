// lib/services/prompt_cache_lifetime.dart
//
// How long a provider keeps the prompt of the last reply in its cache, for
// the countdown in the chat stats row ("Cache 4:32 left"). After that time
// the next message pays the full prompt again.
//
// Only providers with a documented or measured lifetime are listed. For every
// other provider the row shows no countdown: a guessed number would be wrong.
//
// Sources (checked 2026-11-19):
// - Provider docs: Anthropic 5 min default, 1 h option, refreshed on every
//   hit (the API server marks interactive Anthropic chats 1 h,
//   api_server `chat/prompt_cache.py`); Groq "expires after 2 hours without
//   use"; Cerebras "guaranteed TTL is 5 minutes"; Amazon Bedrock 5 min, reset
//   on each hit; Alibaba explicit cache "5 minutes (resets on hit)"; Together
//   "about an hour, best effort"; DeepSeek "a few hours to a few days", best
//   effort; Venice "typically 5-10 minutes"; OpenAI in-memory "5 to 10
//   minutes of inactivity"; Moonshot 5 min or 1 h (which one OpenRouter picks
//   is not documented).
// - Our `usage_logs` (60 days, consecutive requests of one user, model and
//   provider, prompt >= 2048 tokens, share with cache_read_tokens > 0):
//   Fireworks 91 % at 1-5 min, 48 % at 5-10 min, 8 % at 10-15 min, 0 % after;
//   RunAnywhere 93 % at 1-5 min; DeepInfra 81 % at 1-5 min and still 67 % at
//   30-60 min (no fixed limit, LRU).
//
// Not documented and too little data, so no countdown: Novita, SiliconFlow,
// Baseten, Parasail, Nebius, Z.ai, Mistral, MiniMax, xAI, Google, and every
// provider not named here.
//
// `ProviderCacheAffinity.cacheTtlByFamily` is a separate, cautious table for
// Auto's routing choice; it is not what the user is shown.

import 'package:flutter/foundation.dart';

/// How sure a [PromptCacheLifetime] is.
enum CacheLifetimeKind {
  /// The provider documents this lifetime as fixed or guaranteed.
  exact,

  /// Best effort or measured: the cache usually lives about this long.
  approximate,
}

/// The cache lifetime of one provider family.
@immutable
class PromptCacheLifetime {
  const PromptCacheLifetime(this.duration, this.kind);

  final Duration duration;
  final CacheLifetimeKind kind;

  bool get isExact => kind == CacheLifetimeKind.exact;
}

/// The lifetimes by provider family (the provider slug before the first `/`).
const Map<String, PromptCacheLifetime> _lifetimeByFamily =
    <String, PromptCacheLifetime>{
      'groq': PromptCacheLifetime(Duration(hours: 2), CacheLifetimeKind.exact),
      'cerebras': PromptCacheLifetime(
        Duration(minutes: 5),
        CacheLifetimeKind.exact,
      ),
      'amazon-bedrock': PromptCacheLifetime(
        Duration(minutes: 5),
        CacheLifetimeKind.exact,
      ),
      'fireworks': PromptCacheLifetime(
        Duration(minutes: 5),
        CacheLifetimeKind.approximate,
      ),
      'runanywhere': PromptCacheLifetime(
        Duration(minutes: 5),
        CacheLifetimeKind.approximate,
      ),
      'venice': PromptCacheLifetime(
        Duration(minutes: 5),
        CacheLifetimeKind.approximate,
      ),
      'openai': PromptCacheLifetime(
        Duration(minutes: 5),
        CacheLifetimeKind.approximate,
      ),
      'moonshotai': PromptCacheLifetime(
        Duration(minutes: 5),
        CacheLifetimeKind.approximate,
      ),
      'deepinfra': PromptCacheLifetime(
        Duration(minutes: 30),
        CacheLifetimeKind.approximate,
      ),
      'together': PromptCacheLifetime(
        Duration(hours: 1),
        CacheLifetimeKind.approximate,
      ),
      'deepseek': PromptCacheLifetime(
        Duration(hours: 1),
        CacheLifetimeKind.approximate,
      ),
    };

/// The cache lifetime for a reply of [modelId] served by [providerSlug], or
/// null when it is not known.
PromptCacheLifetime? promptCacheLifetimeFor(
  String modelId,
  String providerSlug,
) {
  final String family = providerSlug.split('/').first.toLowerCase();
  final String model = modelId.toLowerCase();
  if (family == 'anthropic') {
    // The API server marks the system prompt and the history of an
    // interactive chat with the 1 h breakpoint.
    return model.startsWith('anthropic/')
        ? const PromptCacheLifetime(Duration(hours: 1), CacheLifetimeKind.exact)
        : null;
  }
  if (family == 'alibaba') {
    // Only Qwen on Alibaba gets explicit breakpoints (5 min, reset on hit).
    // The implicit cache of other models has no documented lifetime.
    return model.startsWith('qwen/')
        ? const PromptCacheLifetime(
            Duration(minutes: 5),
            CacheLifetimeKind.exact,
          )
        : null;
  }
  return _lifetimeByFamily[family];
}

/// `4:32` below ten minutes, `25 min` below an hour, `1 h 20 min` above.
/// [remaining] is clamped at zero.
String formatCacheRemaining(Duration remaining) {
  final int seconds = remaining.isNegative ? 0 : remaining.inSeconds;
  if (seconds < 600) {
    final int m = seconds ~/ 60;
    final int s = seconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
  final int minutes = (seconds / 60).ceil();
  if (minutes < 60) return '$minutes min';
  final int h = minutes ~/ 60;
  final int m = minutes % 60;
  return m == 0 ? '$h h' : '$h h $m min';
}

/// `5 min`, `1 h`, `1 h 20 min`. Whole minutes: rounded down, or up with
/// [roundUp] (a countdown that says "1 min" until it is over).
String formatCacheTtl(Duration value, {bool roundUp = false}) {
  final int seconds = value.isNegative ? 0 : value.inSeconds;
  int minutes = roundUp ? (seconds / 60).ceil() : seconds ~/ 60;
  if (minutes < 1) minutes = 1;
  if (minutes < 60) return '$minutes min';
  final int h = minutes ~/ 60;
  final int m = minutes % 60;
  return m == 0 ? '$h h' : '$h h $m min';
}
