// lib/platform_specific/chat/message_decode_cache.dart
import 'dart:convert';

import 'package:chuk_chat/models/content_block.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/widgets/message_bubble.dart' show DocumentAttachment;

/// Decodes the JSON side-cars a stored message carries — its images, its file
/// attachments, its tool calls, its content blocks — and remembers the result.
///
/// The chat list rebuilds on every stream tick, and each rebuild used to parse
/// the same JSON again for every visible row. The cache is keyed by message
/// index and holds the raw JSON it was built from, so a row whose JSON did not
/// change is served from memory and a row whose JSON did change is parsed once.
///
/// Bad JSON decodes to null and the null is cached too: a broken side-car is
/// not retried on every frame.
class MessageDecodeCache {
  final Map<int, (String, List<String>?)> _images = {};
  final Map<int, (String, List<DocumentAttachment>?)> _attachments = {};
  final Map<int, (String, List<ToolCall>?)> _toolCalls = {};
  final Map<int, (String, List<ContentBlock>?)> _contentBlocks = {};

  /// Drops everything. Call it whenever the message list itself is replaced —
  /// after that the indices mean different messages.
  void clear() {
    _images.clear();
    _attachments.clear();
    _toolCalls.clear();
    _contentBlocks.clear();
  }

  List<String>? images(int index, String? json) => _decode(
    _images,
    index,
    json,
    (raw) => raw is List ? raw.cast<String>() : null,
  );

  List<DocumentAttachment>? attachments(int index, String? json) => _decode(
    _attachments,
    index,
    json,
    (raw) => raw is List
        ? raw
              .map(
                (item) =>
                    DocumentAttachment.fromJson(item as Map<String, dynamic>),
              )
              .toList()
        : null,
  );

  List<ToolCall>? toolCalls(int index, String? json) => _decode(
    _toolCalls,
    index,
    json,
    (raw) => raw is List
        ? raw
              .whereType<Map>()
              .map((item) => ToolCall.fromJson(Map<String, dynamic>.from(item)))
              .toList()
        : null,
  );

  List<ContentBlock>? contentBlocks(int index, String? json) => _decode(
    _contentBlocks,
    index,
    json,
    (raw) => raw is List
        ? raw
              .whereType<Map>()
              .map(
                (item) =>
                    ContentBlock.fromJson(Map<String, dynamic>.from(item)),
              )
              .toList()
        : null,
  );

  /// The one caching rule, shared by all four side-cars: no JSON means no
  /// value and no cache entry; the same JSON as last time is served from the
  /// cache; anything else is parsed once and remembered, null included.
  static List<T>? _decode<T>(
    Map<int, (String, List<T>?)> cache,
    int index,
    String? json,
    List<T>? Function(Object? raw) parse,
  ) {
    if (json == null || json.isEmpty) {
      cache.remove(index);
      return null;
    }
    final cached = cache[index];
    if (cached != null && cached.$1 == json) return cached.$2;
    List<T>? decoded;
    try {
      decoded = parse(jsonDecode(json));
    } catch (_) {}
    cache[index] = (json, decoded);
    return decoded;
  }
}
