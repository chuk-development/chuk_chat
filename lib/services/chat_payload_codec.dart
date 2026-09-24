// lib/services/chat_payload_codec.dart
//
// The plaintext format of a chat payload: the JSON that is compressed and
// encrypted into `encrypted_chats.encrypted_payload`, and that the SQLite
// cache keeps in its `payload` column.
//
// v1  {"messages": [...]}           legacy field names, normalised on read
// v2  {"v": 2, "messages": [...]}   every message is ChatMessage.toJson();
//                                   toolCalls, contentBlocks, images and the
//                                   other nested fields are JSON in a string
// v3  {"v": 3, "messages": [...]}   the same messages, stored without the
//                                   duplicates of v2 (see below)
//
// v3 is lossless: decoding a v3 payload gives exactly the message maps that
// the v2 payload of the same chat gives. The encoder checks every step it
// takes and keeps the v2 form of a field wherever it cannot prove that.
//
// What v3 changes, per message:
//
// * A nested field (toolCalls, contentBlocks, images, imageMetas,
//   attachments, attachedFilesJson, variants) is stored as real JSON, not as
//   JSON in a string. Only when `jsonEncode(jsonDecode(s)) == s` and the
//   value is a list or a map. Any other string stays a string, and a string
//   is always read back as it is.
// * A tool call inside a `toolCalls` content block that is byte-identical
//   to an entry of the message's `toolCalls` list is stored as that entry's
//   index (an int). In v2 each tool call, its result included, was stored
//   twice: 35 % of all bytes.
// * A tool call's `roundThinking` that repeats reasoning text the message
//   already holds is stored as a reference to that text: an int (the index
//   of the reasoning content block with exactly this text), `[start, length]`
//   (a slice of the message's `reasoning`) or `[start, length, 1]` (a slice
//   of the concatenated reasoning blocks).
// * The key `_ref` (a bit mask) says which references a message uses:
//   1 = tool-call indexes in contentBlocks, 2 = roundThinking references.
//   Without the bit the reader never resolves anything, so a value that only
//   looks like a reference is read as data.
//
// Pure Dart (only package:crypto), so it runs in an isolate.

import 'dart:convert';

import 'package:crypto/crypto.dart';

/// The payload version this app writes to `encrypted_chats` and the cache.
const int kChatPayloadVersion = 3;

/// The v2 version number. The Agents store (`cowork_chats`) still writes v2:
/// its payloads are read by Agents clients that know no v3.
const int kChatPayloadVersionV2 = 2;

/// Message fields that hold JSON in a string in v1/v2.
const List<String> _jsonFields = <String>[
  'toolCalls',
  'contentBlocks',
  'images',
  'imageMetas',
  'attachments',
  'attachedFilesJson',
  'variants',
];

const String _refKey = '_ref';
const int _refToolCalls = 1;
const int _refRoundThinking = 2;

/// A decoded chat payload: message maps in the v2 shape (the input of
/// `ChatMessage.fromJson`), the custom name and the version it was stored in.
class DecodedChatPayload {
  const DecodedChatPayload(this.messages, {this.customName, this.version = 2});

  final List<Map<String, dynamic>> messages;
  final String? customName;
  final int version;
}

/// Encode [messages] (each one `ChatMessage.toJson()`) as a v3 payload.
String encodeChatPayload(
  List<Map<String, dynamic>> messages, {
  String? customName,
}) {
  return jsonEncode(<String, dynamic>{
    'v': kChatPayloadVersion,
    'messages': [for (final m in messages) encodeMessageV3(m)],
    'customName': ?customName,
  });
}

/// Decode a payload of any version (v1, v2, v3).
///
/// Throws [FormatException] for JSON that is not a chat payload, and
/// [UnsupportedError] for a version newer than this app knows. A payload of
/// an unknown version is never read as a v1 payload: that would show the
/// user an empty or broken chat, and the next save would write it back.
DecodedChatPayload decodeChatPayload(String json) {
  final decoded = jsonDecode(json);
  if (decoded is! Map<String, dynamic>) {
    throw const FormatException('A chat payload must be a JSON object');
  }
  final rawVersion = decoded['v'];
  final version = rawVersion ?? 1;
  final customName = decoded['customName'] as String?;
  final rawMessages = decoded['messages'];
  if (rawMessages is! List) {
    throw const FormatException('A chat payload needs a messages list');
  }

  switch (version) {
    case 2:
      return DecodedChatPayload(
        [for (final m in rawMessages) m as Map<String, dynamic>],
        customName: customName,
        version: 2,
      );
    case 3:
      return DecodedChatPayload(
        [for (final m in rawMessages) decodeMessageV3(m as Map)],
        customName: customName,
        version: 3,
      );
    case 1:
      return DecodedChatPayload(
        [for (final m in rawMessages) _normalizeV1(m as Map<String, dynamic>)],
        customName: customName,
        version: 1,
      );
  }
  throw UnsupportedError('Unsupported chat payload version: $version');
}

/// The version of a payload JSON, read from its start without parsing the
/// whole string. Every writer puts `"v"` first; null means "not sure".
int? peekChatPayloadVersion(String json) {
  final match = _versionPrefix.firstMatch(
    json.length > 32 ? json.substring(0, 32) : json,
  );
  return match == null ? null : int.tryParse(match.group(1)!);
}

final RegExp _versionPrefix = RegExp(r'^\s*\{\s*"v"\s*:\s*(\d+)\s*[,}]');

/// Re-encode a payload JSON of any version as v3. A v3 input is returned as
/// it is.
String toChatPayloadV3(String json) {
  if (peekChatPayloadVersion(json) == kChatPayloadVersion) return json;
  final decoded = decodeChatPayload(json);
  if (decoded.version == kChatPayloadVersion) return json;
  return encodeChatPayload(decoded.messages, customName: decoded.customName);
}

/// [json] (any version) as v3, proven: null when the v3 JSON would not
/// decode to the same messages. A v3 input is returned as it is.
String? toChatPayloadV3Verified(String json) {
  final before = decodeChatPayload(json);
  if (before.version == kChatPayloadVersion) return json;
  final v3 = encodeChatPayload(before.messages, customName: before.customName);
  return chatPayloadsEquivalent(before, decodeChatPayload(v3)) ? v3 : null;
}

/// A fingerprint of the decoded messages and custom name: equal for two
/// payloads exactly when [chatPayloadsEquivalent] holds. Lets a caller check
/// a rewritten chat against its original without keeping the original.
String chatPayloadFingerprint(DecodedChatPayload p) {
  final canonical = jsonEncode(<String, dynamic>{
    'c': p.customName,
    'm': [for (final m in p.messages) _canonicalMessage(m)],
  });
  return sha256.convert(utf8.encode(canonical)).toString();
}

/// [json] (any version) as a proven v3 JSON plus the fingerprint of its
/// messages; null when the v3 form would not decode to the same messages.
/// A v3 input is returned as it is. For isolates.
({String v3, String fingerprint})? convertChatPayloadToV3WithFingerprint(
  String json,
) {
  final before = decodeChatPayload(json);
  final fingerprint = chatPayloadFingerprint(before);
  if (before.version == kChatPayloadVersion) {
    return (v3: json, fingerprint: fingerprint);
  }
  final v3 = encodeChatPayload(before.messages, customName: before.customName);
  if (chatPayloadFingerprint(decodeChatPayload(v3)) != fingerprint) return null;
  return (v3: v3, fingerprint: fingerprint);
}

/// The fingerprint of a payload JSON of any version. For isolates.
String chatPayloadJsonFingerprint(String json) =>
    chatPayloadFingerprint(decodeChatPayload(json));

/// Whether [a] and [b] decode to the same messages and custom name.
///
/// Compares what `ChatMessage.toJson()` would write for each message, that
/// is the in-memory messages, so a field the v2 encoder dropped (an empty
/// string) counts as equal to a missing one.
bool chatPayloadsEquivalent(DecodedChatPayload a, DecodedChatPayload b) {
  if (a.customName != b.customName) return false;
  if (a.messages.length != b.messages.length) return false;
  for (var i = 0; i < a.messages.length; i++) {
    if (jsonEncode(_canonicalMessage(a.messages[i])) !=
        jsonEncode(_canonicalMessage(b.messages[i]))) {
      return false;
    }
  }
  return true;
}

/// The message map as `ChatMessage.fromJson` followed by `toJson` would
/// produce it: known fields only, empty strings dropped, fixed key order.
Map<String, dynamic> _canonicalMessage(Map<String, dynamic> m) {
  final out = <String, dynamic>{
    'role': m['role'] as String? ?? m['sender'] as String? ?? 'user',
    'text': m['text'] as String? ?? '',
  };
  for (final key in _canonicalStringKeys) {
    final raw = m[key];
    final value = raw is String || raw == null ? raw as String? : '$raw';
    if (value != null && value.isNotEmpty) out[key] = value;
  }
  final status = m['status'];
  if (status is String &&
      const {'sent', 'pending', 'failed', 'interrupted'}.contains(status)) {
    out['status'] = status;
  }
  final active = m['activeVariant'];
  final activeInt = active is int
      ? active
      : active is num
      ? active.toInt()
      : int.tryParse('${active ?? ''}');
  if (activeInt != null) out['activeVariant'] = activeInt;
  return out;
}

const List<String> _canonicalStringKeys = <String>[
  'reasoning',
  'replyContext',
  'images',
  'imageMetas',
  'imageCostEur',
  'imageGeneratedAt',
  'attachments',
  'attachedFilesJson',
  'toolCalls',
  'contentBlocks',
  'modelId',
  'provider',
  'queueId',
  'messageId',
  'sentAt',
  'startedAt',
  'generationMs',
  'variants',
];

// ─── v3 message encoding ────────────────────────────────────────────────

/// One message (v2 shape) to its v3 form. Never changes [m].
Map<String, dynamic> encodeMessageV3(Map<String, dynamic> m) {
  final out = Map<String, dynamic>.of(m)..remove(_refKey);
  for (final field in _jsonFields) {
    final value = m[field];
    if (value is String) {
      final structured = _structured(value);
      if (structured != null) out[field] = structured;
    }
  }

  var refs = 0;
  final toolCalls = out['toolCalls'];
  final blocks = out['contentBlocks'];
  if (toolCalls is List && blocks is List) {
    final dedup = _dedupToolCalls(toolCalls, blocks);
    if (dedup != null) {
      out['contentBlocks'] = dedup;
      refs |= _refToolCalls;
    }
  }
  if (toolCalls is List) {
    final withRefs = _referenceRoundThinking(
      toolCalls,
      blocks is List ? blocks : const <dynamic>[],
      m['reasoning'] is String ? m['reasoning'] as String : null,
    );
    if (withRefs != null) {
      out['toolCalls'] = withRefs;
      refs |= _refRoundThinking;
    }
  }
  if (refs != 0) out[_refKey] = refs;

  // Proof per message: the reader must give back exactly [m]'s fields.
  // Anything else keeps the plain v2 form of this message.
  final back = decodeMessageV3(out);
  for (final field in _jsonFields) {
    if (back[field] != m[field]) return _plainV2(m);
  }
  return out;
}

/// [m] as it is, with only a stray `_ref` key removed.
Map<String, dynamic> _plainV2(Map<String, dynamic> m) =>
    m.containsKey(_refKey) ? (Map<String, dynamic>.of(m)..remove(_refKey)) : m;

/// The parsed value of [s] when it is a list or a map that encodes back to
/// exactly [s]; null otherwise.
Object? _structured(String s) {
  if (s.isEmpty) return null;
  final first = s.codeUnitAt(0);
  if (first != 0x5B && first != 0x7B) return null; // '[' or '{'
  final Object? parsed;
  try {
    parsed = jsonDecode(s);
  } on FormatException {
    return null;
  }
  if (parsed is! List && parsed is! Map) return null;
  if (jsonEncode(parsed) != s) return null;
  return parsed;
}

/// [blocks] with every tool call that equals an entry of [toolCalls] (same
/// id, same bytes) replaced by that entry's index. Null when nothing was
/// replaced, or when a block already holds an int (which would be read as a
/// reference).
List<dynamic>? _dedupToolCalls(List<dynamic> toolCalls, List<dynamic> blocks) {
  final indexById = <Object, int>{};
  final encoded = <int, String>{};
  for (var i = 0; i < toolCalls.length; i++) {
    final call = toolCalls[i];
    if (call is Map) {
      final id = call['id'];
      if (id != null && !indexById.containsKey(id)) indexById[id] = i;
    }
  }
  if (indexById.isEmpty) return null;

  var replaced = false;
  final out = <dynamic>[];
  for (final block in blocks) {
    if (block is Map && block['type'] == 'toolCalls') {
      final calls = block['toolCalls'];
      if (calls is List) {
        final newCalls = <dynamic>[];
        for (final call in calls) {
          if (call is int) return null;
          if (call is Map) {
            final index = indexById[call['id']];
            if (index != null &&
                jsonEncode(call) ==
                    (encoded[index] ??= jsonEncode(toolCalls[index]))) {
              newCalls.add(index);
              replaced = true;
              continue;
            }
          }
          newCalls.add(call);
        }
        out.add(
          Map<String, dynamic>.of(block.cast<String, dynamic>())
            ..['toolCalls'] = newCalls,
        );
        continue;
      }
    }
    out.add(block);
  }
  return replaced ? out : null;
}

/// [toolCalls] with each `roundThinking` that repeats reasoning text of the
/// message replaced by a reference. Null when nothing was replaced.
List<dynamic>? _referenceRoundThinking(
  List<dynamic> toolCalls,
  List<dynamic> blocks,
  String? reasoning,
) {
  final blockIndexByText = <String, int>{};
  final joined = StringBuffer();
  for (var i = 0; i < blocks.length; i++) {
    final block = blocks[i];
    if (block is Map && block['type'] == 'reasoning') {
      final text = block['text'];
      if (text is String) {
        blockIndexByText.putIfAbsent(text, () => i);
        joined.write(text);
      }
    }
  }
  final joinedText = joined.toString();

  // A value that is already an int or a list would be read as a reference.
  for (final call in toolCalls) {
    if (call is Map && _isThinkingRef(call['roundThinking'])) return null;
  }

  var replaced = false;
  final out = <dynamic>[];
  for (final call in toolCalls) {
    if (call is Map) {
      final thinking = call['roundThinking'];
      if (thinking is String && thinking.isNotEmpty) {
        Object? ref = blockIndexByText[thinking];
        if (ref == null && reasoning != null) {
          final start = reasoning.indexOf(thinking);
          if (start >= 0) ref = <int>[start, thinking.length];
        }
        if (ref == null && joinedText.isNotEmpty) {
          final start = joinedText.indexOf(thinking);
          if (start >= 0) ref = <int>[start, thinking.length, 1];
        }
        if (ref != null) {
          out.add(
            Map<String, dynamic>.of(call.cast<String, dynamic>())
              ..['roundThinking'] = ref,
          );
          replaced = true;
          continue;
        }
      }
    }
    out.add(call);
  }
  return replaced ? out : null;
}

// ─── v3 message decoding ────────────────────────────────────────────────

/// One v3 message to the v2 shape.
Map<String, dynamic> decodeMessageV3(Map<dynamic, dynamic> m) {
  final out = <String, dynamic>{};
  m.forEach((key, value) {
    if (key != _refKey) out[key as String] = value;
  });
  final refs = m[_refKey] is int ? m[_refKey] as int : 0;

  var toolCalls = out['toolCalls'];
  var blocks = out['contentBlocks'];
  if (refs & _refRoundThinking != 0 && toolCalls is List) {
    toolCalls = _resolveRoundThinking(
      toolCalls,
      blocks is List ? blocks : const <dynamic>[],
      out['reasoning'] as String?,
    );
  }
  if (refs & _refToolCalls != 0 && blocks is List && toolCalls is List) {
    blocks = _resolveToolCalls(blocks, toolCalls);
  }
  if (toolCalls != null) out['toolCalls'] = toolCalls;
  if (blocks != null) out['contentBlocks'] = blocks;

  for (final field in _jsonFields) {
    final value = out[field];
    if (value is List || value is Map) out[field] = jsonEncode(value);
  }
  return out;
}

List<dynamic> _resolveRoundThinking(
  List<dynamic> toolCalls,
  List<dynamic> blocks,
  String? reasoning,
) {
  String? joined;
  String joinedText() => joined ??= [
    for (final b in blocks)
      if (b is Map && b['type'] == 'reasoning' && b['text'] is String)
        b['text'] as String,
  ].join();

  return [
    for (final call in toolCalls)
      if (call is Map && _isThinkingRef(call['roundThinking']))
        _withThinking(
          call,
          call['roundThinking'],
          blocks,
          reasoning,
          joinedText,
        )
      else
        call,
  ];
}

bool _isThinkingRef(Object? value) => value is int || value is List;

Map<dynamic, dynamic> _withThinking(
  Map<dynamic, dynamic> call,
  Object? ref,
  List<dynamic> blocks,
  String? reasoning,
  String Function() joinedText,
) {
  String? text;
  if (ref is int && ref >= 0 && ref < blocks.length) {
    final block = blocks[ref];
    if (block is Map && block['text'] is String) text = block['text'] as String;
  } else if (ref is List && (ref.length == 2 || ref.length == 3)) {
    final source = ref.length == 2 ? reasoning : joinedText();
    final start = ref[0];
    final length = ref[1];
    if (source != null &&
        start is int &&
        length is int &&
        start >= 0 &&
        length >= 0 &&
        start + length <= source.length) {
      text = source.substring(start, start + length);
    }
  }
  if (text == null) {
    throw FormatException('Broken roundThinking reference: $ref');
  }
  return Map<dynamic, dynamic>.of(call)..['roundThinking'] = text;
}

List<dynamic> _resolveToolCalls(List<dynamic> blocks, List<dynamic> toolCalls) {
  return [
    for (final block in blocks)
      if (block is Map &&
          block['type'] == 'toolCalls' &&
          block['toolCalls'] is List)
        Map<dynamic, dynamic>.of(block)
          ..['toolCalls'] = [
            for (final call in block['toolCalls'] as List)
              if (call is int)
                (call >= 0 && call < toolCalls.length)
                    ? toolCalls[call]
                    : throw FormatException('Broken tool call reference: $call')
              else
                call,
          ]
      else
        block,
  ];
}

// ─── v1 ─────────────────────────────────────────────────────────────────

/// A v1 message with its field names normalised; all fields are kept.
Map<String, dynamic> _normalizeV1(Map<String, dynamic> msg) {
  return <String, dynamic>{
    'role': msg['role'] as String? ?? 'user',
    'text': msg['text'] as String? ?? '',
    if (msg['reasoning'] != null) 'reasoning': msg['reasoning'],
    if (msg['images'] != null) 'images': msg['images'],
    if (msg['imageCostEur'] != null) 'imageCostEur': msg['imageCostEur'],
    if (msg['imageGeneratedAt'] != null)
      'imageGeneratedAt': msg['imageGeneratedAt'],
    if (msg['attachments'] != null) 'attachments': msg['attachments'],
    if (msg['attachedFilesJson'] != null)
      'attachedFilesJson': msg['attachedFilesJson'],
    if (msg['toolCalls'] != null) 'toolCalls': msg['toolCalls'],
    if (msg['contentBlocks'] != null) 'contentBlocks': msg['contentBlocks'],
    if (msg['replyContext'] != null) 'replyContext': msg['replyContext'],
    if (msg['modelId'] != null) 'modelId': msg['modelId'],
    if (msg['provider'] != null) 'provider': msg['provider'],
  };
}
