import 'dart:math' as math;

class TokenEstimator {
  const TokenEstimator._();

  static const int _perMessageOverhead = 8;
  static const int _systemPromptOverhead = 24;
  static final RegExp _tokenishPattern = RegExp(r'\w+|[^\s\w]');

  static int estimateTokens(String text) {
    if (text.isEmpty) return 0;
    final int characterEstimate = (text.length / 4).ceil();
    final int wordishCount = _tokenishPattern.allMatches(text).length;
    final int estimate = math.max(characterEstimate, wordishCount);
    return estimate == 0 ? 1 : estimate;
  }

  static int estimatePromptTokens({
    required List<Map<String, dynamic>> history,
    required String currentMessage,
    String? systemPrompt,
  }) {
    int total = 0;

    if (systemPrompt != null && systemPrompt.trim().isNotEmpty) {
      total += estimateTokens(systemPrompt) + _systemPromptOverhead;
    }

    for (final Map<String, dynamic> entry in history) {
      final content = entry['content'];
      if (content == null) continue;
      if (content is String) {
        if (content.trim().isEmpty) continue;
        total += estimateTokens(content) + _perMessageOverhead;
      } else if (content is List) {
        // Multimodal content blocks — estimate text portions, add ~1000 per image
        for (final block in content) {
          if (block is Map) {
            if (block['type'] == 'text') {
              total += estimateTokens(block['text'] as String? ?? '') + _perMessageOverhead;
            } else if (block['type'] == 'image_url') {
              total += 1000; // Rough estimate for image tokens
            }
          }
        }
      }
    }

    if (currentMessage.trim().isNotEmpty) {
      total += estimateTokens(currentMessage) + _perMessageOverhead;
    }

    return total;
  }
}
