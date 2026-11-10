import 'dart:convert';
import 'dart:math' as math;

import 'package:chuk_chat/utils/image_token_estimator.dart';

/// The last real prompt size of a chat: the provider's own count of the last
/// reply (prompt + completion tokens), and where in the message list it was
/// measured. The estimate adds only what came after it.
class UsageAnchor {
  const UsageAnchor({required this.tokens, required this.messageIndex});

  /// Prompt + completion tokens of the anchored reply.
  final int tokens;

  /// Index of that reply in the chat's message list.
  final int messageIndex;
}

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

  /// Tokens of one image block (`{type: image_url, image_url: {url}}`) on
  /// [modelId]: the model's formula over the image's pixel size when the
  /// data URL carries a readable header, else [kUnknownImageTokens].
  static int estimateImageBlockTokens(Map block, {String? modelId}) {
    final Object? imageUrl = block['image_url'];
    final Object? url = imageUrl is Map ? imageUrl['url'] : imageUrl;
    final Object? width = block['width'];
    final Object? height = block['height'];
    if (width is int && height is int) {
      return ImageTokenEstimator.tokensFor(modelId, width, height);
    }
    if (url is String) {
      final size = ImageTokenEstimator.dimensionsOfDataUrl(url);
      if (size != null) {
        return ImageTokenEstimator.tokensFor(modelId, size.$1, size.$2);
      }
    }
    return kUnknownImageTokens;
  }

  /// Tokens of one history entry (`{role, content, tool_calls?}`).
  static int estimateEntryTokens(
    Map<String, dynamic> entry, {
    String? modelId,
  }) {
    var total = 0;
    final content = entry['content'];
    if (content is String) {
      if (content.trim().isNotEmpty) {
        total += estimateTokens(content) + _perMessageOverhead;
      }
    } else if (content is List) {
      for (final block in content) {
        if (block is! Map) continue;
        if (block['type'] == 'text') {
          total +=
              estimateTokens(block['text'] as String? ?? '') +
              _perMessageOverhead;
        } else if (block['type'] == 'image_url') {
          total += estimateImageBlockTokens(block, modelId: modelId);
        }
      }
    }
    final calls = entry['tool_calls'];
    if (calls is List && calls.isNotEmpty) {
      total += estimateTokens(jsonEncode(calls)) + _perMessageOverhead;
    }
    return total;
  }

  static int estimatePromptTokens({
    required List<Map<String, dynamic>> history,
    required String currentMessage,
    String? systemPrompt,
    String? modelId,
  }) {
    int total = 0;

    if (systemPrompt != null && systemPrompt.trim().isNotEmpty) {
      total += estimateTokens(systemPrompt) + _systemPromptOverhead;
    }

    for (final Map<String, dynamic> entry in history) {
      total += estimateEntryTokens(entry, modelId: modelId);
    }

    if (currentMessage.trim().isNotEmpty) {
      total += estimateTokens(currentMessage) + _perMessageOverhead;
    }

    return total;
  }

  /// The last answer in [messages] (UI maps, `sender` + `usage`) that has a
  /// real usage count, at or after [notBefore]. Null when there is none: an
  /// answer before [notBefore] was measured on a history that has changed
  /// since (a compaction replaced its start).
  static UsageAnchor? usageAnchorOf(
    List<Map<String, String>> messages, {
    int notBefore = 0,
  }) {
    for (var i = messages.length - 1; i >= math.max(0, notBefore); i--) {
      final m = messages[i];
      final sender = m['sender'];
      if (sender == 'user') continue;
      final raw = m['usage'];
      if (raw == null || raw.isEmpty) continue;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is! Map) continue;
        int? read(String key) {
          final v = decoded[key];
          return v is num ? v.toInt() : null;
        }

        final prompt = read('prompt_tokens');
        final completion = read('completion_tokens') ?? 0;
        if (prompt == null || prompt <= 0) continue;
        return UsageAnchor(tokens: prompt + completion, messageIndex: i);
      } on FormatException {
        continue;
      }
    }
    return null;
  }

  /// The prompt size of the next request, anchored on the last real usage:
  /// [anchor]'s tokens plus an estimate of [messagesAfterAnchor] (the
  /// history entries added after the anchored reply) and [pendingMessage].
  /// Without an anchor it is the plain [estimatePromptTokens] over
  /// [fullHistory].
  static int anchoredPromptTokens({
    required UsageAnchor? anchor,
    required List<Map<String, dynamic>> messagesAfterAnchor,
    required List<Map<String, dynamic>> fullHistory,
    required String pendingMessage,
    String? systemPrompt,
    String? modelId,
  }) {
    if (anchor == null) {
      return estimatePromptTokens(
        history: fullHistory,
        currentMessage: pendingMessage,
        systemPrompt: systemPrompt,
        modelId: modelId,
      );
    }
    return anchor.tokens +
        estimatePromptTokens(
          history: messagesAfterAnchor,
          currentMessage: pendingMessage,
          modelId: modelId,
        );
  }
}
