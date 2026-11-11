// lib/services/prompt_cache/image_budget.dart
//
// Images in the chat history, kept byte-stable for the prompt cache.
//
// The history builder puts every image of every user turn into the history,
// as its storage path (or the data URL an old message stored). Right before
// the request goes out, [ImageBudget.apply] checks the provider's limits and
// turns the kept images into data URLs. Only when a request would exceed a
// limit are the OLDEST images replaced with `[image omitted: <name>]`, and
// then many at once (half the count limit per step), so the cut point moves
// rarely and the history before it stays the same from turn to turn. The
// old rule (the last 10 user turns keep their images, the newest dropped
// first when over budget) moved on every message and missed the cache on
// the whole history after the first image.

import 'dart:math' as math;

/// Image limits of one request.
class ImageLimits {
  const ImageLimits({required this.maxImages, required this.maxChars});

  /// Most images one request may carry.
  final int maxImages;

  /// Most data-URL characters (base64) of all images of one request.
  final int maxChars;

  /// Images freed per cut: half the count limit, at least one.
  int get step => math.max(1, maxImages ~/ 2);
}

class ImageBudget {
  ImageBudget._();

  /// Ceiling on image data per request whatever the provider allows: the
  /// whole request travels in one WebSocket message, and the server accepts
  /// 16 MB per message.
  static const int kTransportMaxChars = 12000000;

  /// Conservative per-family limits. The provider's own numbers are higher
  /// for some (Anthropic 100 images / ~32 MB, OpenAI 500, Google 3000); the
  /// data ceiling is [kTransportMaxChars] for all of them.
  static const ImageLimits anthropic = ImageLimits(
    maxImages: 100,
    maxChars: kTransportMaxChars,
  );
  static const ImageLimits openai = ImageLimits(
    maxImages: 500,
    maxChars: kTransportMaxChars,
  );
  static const ImageLimits google = ImageLimits(
    maxImages: 3000,
    maxChars: kTransportMaxChars,
  );

  /// DeepSeek and every model family not named above.
  static const ImageLimits fallback = ImageLimits(
    maxImages: 50,
    maxChars: kTransportMaxChars,
  );

  /// The limits for [modelId] (an OpenRouter-style id such as
  /// `anthropic/claude-sonnet-4.5`).
  static ImageLimits limitsFor(String modelId) {
    final id = modelId.toLowerCase();
    if (id.startsWith('anthropic/') || id.contains('claude')) return anthropic;
    if (id.startsWith('google/') || id.contains('gemini')) return google;
    if (id.startsWith('openai/') ||
        id.startsWith('gpt-') ||
        id.contains('/gpt-') ||
        RegExp(r'(^|/)o[134](-|$)').hasMatch(id)) {
      return openai;
    }
    return fallback;
  }

  /// The text part that stands for an image that is not sent.
  static Map<String, dynamic> placeholderPart(String name) => <String, dynamic>{
    'type': 'text',
    'text': '[image omitted: $name]',
  };

  /// The name of an image in a placeholder: the file name of its storage
  /// path, or `image <n>` (its place in the message) for a data URL. Never
  /// the whole path.
  static String imageNameFor(String url, int indexInMessage) {
    if (url.startsWith('data:')) return 'image ${indexInMessage + 1}';
    final slash = url.lastIndexOf('/');
    final name = slash >= 0 ? url.substring(slash + 1) : url;
    return name.isEmpty ? 'image ${indexInMessage + 1}' : name;
  }

  /// Applies the limits to the images of [history] and resolves the kept
  /// ones to data URLs with [resolve] (null when an image cannot be loaded:
  /// it becomes a placeholder). Returns a new list; [history] is not changed.
  ///
  /// [pendingCount] and [pendingChars] are the images of the turn being sent
  /// (they count against the same request). [textOnly] replaces every image
  /// (a model that takes no image input).
  ///
  /// Deterministic: the same history and limits always give the same bytes.
  /// The number of omitted oldest images is a multiple of
  /// [ImageLimits.step], the smallest one that fits both limits.
  static Future<List<Map<String, dynamic>>> apply(
    List<Map<String, dynamic>> history, {
    required ImageLimits limits,
    required Future<String?> Function(String url) resolve,
    bool textOnly = false,
    int pendingCount = 0,
    int pendingChars = 0,
  }) async {
    // Every image part, oldest first: (entry, part, url, name).
    final slots = <({int entry, int part, String url, String name})>[];
    for (var e = 0; e < history.length; e++) {
      final entry = history[e];
      if (entry['role'] != 'user') continue;
      final content = entry['content'];
      if (content is! List) continue;
      var inMessage = 0;
      for (var p = 0; p < content.length; p++) {
        final part = content[p];
        if (part is! Map || part['type'] != 'image_url') continue;
        final imageUrl = part['image_url'];
        final url = imageUrl is Map ? imageUrl['url']?.toString() ?? '' : '';
        slots.add((
          entry: e,
          part: p,
          url: url,
          name: imageNameFor(url, inMessage),
        ));
        inMessage++;
      }
    }
    if (slots.isEmpty) return history;

    final total = slots.length;
    var omit = 0;
    if (textOnly) {
      omit = total;
    } else if (total + pendingCount > limits.maxImages) {
      final over = total + pendingCount - limits.maxImages;
      omit = math.min(
        total,
        ((over + limits.step - 1) ~/ limits.step) * limits.step,
      );
    }

    // Resolve what is kept, then cut further (in the same steps) while the
    // image data is over the limit.
    final resolved = List<String?>.filled(total, null);
    for (var i = omit; i < total; i++) {
      final url = slots[i].url;
      resolved[i] = url.startsWith('data:') ? url : await resolve(url);
    }
    int keptChars() {
      var sum = pendingChars;
      for (var i = omit; i < total; i++) {
        sum += resolved[i]?.length ?? 0;
      }
      return sum;
    }

    while (omit < total && keptChars() > limits.maxChars) {
      omit = math.min(total, omit + limits.step);
    }

    final out = <Map<String, dynamic>>[for (final entry in history) entry];
    final newContent = <int, List<dynamic>>{};
    for (var i = 0; i < total; i++) {
      final slot = slots[i];
      final content = newContent.putIfAbsent(
        slot.entry,
        () => List<dynamic>.of(history[slot.entry]['content'] as List),
      );
      final dataUrl = i < omit ? null : resolved[i];
      content[slot.part] = dataUrl == null
          ? placeholderPart(slot.name)
          : <String, dynamic>{
              'type': 'image_url',
              'image_url': {'url': dataUrl},
            };
    }
    newContent.forEach((index, content) {
      out[index] = <String, dynamic>{...history[index], 'content': content};
    });
    return out;
  }
}
