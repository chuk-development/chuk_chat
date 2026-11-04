// lib/models/turn_usage.dart
//
// The token usage of one model reply, read from the server's `usage` frame.
// The server forwards the upstream's own object, so the field names vary by
// provider: OpenAI / OpenRouter (`prompt_tokens`, `prompt_tokens_details.
// cached_tokens`), Anthropic (`input_tokens`, `cache_read_input_tokens`) and
// DeepSeek (`prompt_cache_hit_tokens`). This class reads all of them.
//
// Rule (docs/GOTCHAS.md, "Usage"): a cache count the reply did not report
// stays null and is shown as "—", never as 0.

import 'dart:convert';

class TurnUsage {
  const TurnUsage({
    this.promptTokens,
    this.completionTokens,
    this.totalTokens,
    this.cachedTokens,
  });

  /// Tokens the model read, cached ones included. Null when unknown.
  final int? promptTokens;

  /// Tokens the model wrote. Null when unknown.
  final int? completionTokens;

  /// Total, as the server reported it, else prompt + completion.
  final int? totalTokens;

  /// Prompt tokens served from the provider's cache. Null when the reply did
  /// not say: that is "unknown", not "no hit".
  final int? cachedTokens;

  /// Read a server `usage` object. Returns null when it holds no count at all.
  static TurnUsage? fromServer(Map<String, dynamic>? raw) {
    if (raw == null || raw.isEmpty) return null;
    final int? input = _int(raw['input_tokens']);
    final int? cacheRead = _int(raw['cache_read_input_tokens']);
    final int? cacheWrite = _int(raw['cache_creation_input_tokens']);
    int? prompt = _int(raw['prompt_tokens']);
    // Anthropic counts cached input apart from `input_tokens`.
    if (prompt == null && input != null) {
      prompt = input + (cacheRead ?? 0) + (cacheWrite ?? 0);
    }
    final int? completion =
        _int(raw['completion_tokens']) ?? _int(raw['output_tokens']);
    int? cached;
    final Object? details = raw['prompt_tokens_details'];
    if (details is Map) cached = _int(details['cached_tokens']);
    cached ??= _int(raw['prompt_cache_hit_tokens']);
    cached ??= cacheRead;
    cached ??= _int(raw['cached_tokens']);
    final int? total =
        _int(raw['total_tokens']) ??
        (prompt != null && completion != null ? prompt + completion : null);
    if (prompt == null && completion == null && total == null) return null;
    return TurnUsage(
      promptTokens: prompt,
      completionTokens: completion,
      totalTokens: total,
      cachedTokens: cached,
    );
  }

  /// Cached / prompt tokens, 0..1. Null when either side is unknown or the
  /// prompt was empty.
  double? get cacheHitRatio {
    final int? prompt = promptTokens;
    final int? cached = cachedTokens;
    if (prompt == null || cached == null || prompt <= 0) return null;
    return (cached / prompt).clamp(0.0, 1.0);
  }

  Map<String, dynamic> toJson() => <String, dynamic>{
    if (promptTokens != null) 'prompt_tokens': promptTokens,
    if (completionTokens != null) 'completion_tokens': completionTokens,
    if (totalTokens != null) 'total_tokens': totalTokens,
    if (cachedTokens != null) 'cached_tokens': cachedTokens,
  };

  /// The form stored in a message map (`message['usage']`).
  String encode() => jsonEncode(toJson());

  /// Read [encode]'s output back. Null for null, empty or broken input.
  static TurnUsage? tryDecode(String? stored) {
    if (stored == null || stored.isEmpty) return null;
    try {
      final Object? decoded = jsonDecode(stored);
      if (decoded is Map<String, dynamic>) return fromServer(decoded);
    } catch (_) {}
    return null;
  }

  static int? _int(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }
}
