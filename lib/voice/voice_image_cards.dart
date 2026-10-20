// lib/voice/voice_image_cards.dart
//
// Pictures that a chat turn produced, as VoiceCards for the call stage.
// generate_image / fetch_image leave `IMAGE:{…}` on the tool result; a
// real-photo answer leaves `<image>{…}</image>` in the text. The worker
// never sees those unless we lift them here.

import 'dart:convert';

import 'package:chuk_chat/services/api_config_base.dart' show getApiBaseUrl;
import 'package:chuk_chat/voice/voice_call_models.dart';

const Set<String> kVoiceImageToolNames = <String>{
  'generate_image',
  'fetch_image',
};

final RegExp _imageBlock = RegExp(
  r'<image>\s*(\{[\s\S]*?\})\s*</image>',
  caseSensitive: false,
);

/// Turns a relative `/v1/ai/image/file/…` path into the API URL the phone
/// can load. Absolute http(s) URLs pass through. Anything else is dropped.
String? resolveVoiceImageUrl(String? raw) {
  final String? value = raw?.trim();
  if (value == null || value.isEmpty) return null;
  final Uri? uri = Uri.tryParse(value);
  if (uri == null) return null;
  if (uri.hasScheme) {
    return (uri.scheme == 'https' || uri.scheme == 'http') ? value : null;
  }
  try {
    return Uri.parse(getApiBaseUrl()).resolve(value).toString();
  } catch (_) {
    return null;
  }
}

/// The URL inside an `IMAGE:{…}` tool result, or null.
String? imageUrlFromToolResult(String? result) {
  if (result == null || result.isEmpty) return null;
  if (!result.startsWith('IMAGE:') && !result.startsWith('IMAGE_DATA:')) {
    return null;
  }
  final int colon = result.indexOf(':');
  if (colon < 0 || colon + 1 >= result.length) return null;
  try {
    final Object? decoded = jsonDecode(result.substring(colon + 1));
    if (decoded is! Map) return null;
    final Object? url = decoded['url'] ?? decoded['image_url'];
    return url is String ? resolveVoiceImageUrl(url) : null;
  } catch (_) {
    return null;
  }
}

/// Cards for one chat row: running generators first, then finished pictures.
List<VoiceCard> voiceCardsFromChatMessage(
  Map<String, String> message, {
  DateTime? at,
}) {
  final DateTime when = at ?? DateTime.now();
  final List<VoiceCard> cards = <VoiceCard>[
    ...voiceCardsFromToolCallsJson(message['toolCalls'], at: when),
    ...voiceCardsFromImageBlocks(message['text'], at: when),
  ];
  if (cards.any((VoiceCard c) => c.kind == 'image' && c.text('url') != null)) {
    return cards;
  }
  cards.addAll(voiceCardsFromImagesJson(message['images'], at: when));
  return cards;
}

List<VoiceCard> voiceCardsFromToolCallsJson(String? raw, {DateTime? at}) {
  if (raw == null || raw.isEmpty) return const <VoiceCard>[];
  late final Object decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    return const <VoiceCard>[];
  }
  if (decoded is! List) return const <VoiceCard>[];
  final DateTime when = at ?? DateTime.now();
  final List<VoiceCard> cards = <VoiceCard>[];
  for (final Object? item in decoded) {
    if (item is! Map) continue;
    final Map<String, dynamic> call = item.cast<String, dynamic>();
    final String name = '${call['name'] ?? ''}';
    if (!kVoiceImageToolNames.contains(name)) continue;
    final String id = '${call['id'] ?? ''}'.trim();
    final String status = '${call['status'] ?? ''}';
    final String? result = call['result'] as String?;
    final String? url = imageUrlFromToolResult(result);
    if (url != null) {
      final String? caption = _captionOf(call);
      cards.add(
        VoiceCard(
          id: id.isEmpty ? 'image-$url' : id,
          kind: 'image',
          title: caption ?? 'Image',
          at: when,
          data: <String, dynamic>{
            'url': url,
            if (caption != null) 'caption': caption,
          },
        ),
      );
      continue;
    }
    if (status == 'running' || status == 'pending') {
      cards.add(
        VoiceCard(
          id: id.isEmpty ? 'generating-image' : id,
          kind: 'image',
          title: 'Generating image',
          at: when,
          data: const <String, dynamic>{'generating': true},
        ),
      );
    }
  }
  return cards;
}

List<VoiceCard> voiceCardsFromImageBlocks(String? text, {DateTime? at}) {
  if (text == null || text.isEmpty) return const <VoiceCard>[];
  final DateTime when = at ?? DateTime.now();
  final List<VoiceCard> cards = <VoiceCard>[];
  for (final Match match in _imageBlock.allMatches(text)) {
    try {
      final Object? decoded = jsonDecode(match.group(1)!);
      if (decoded is! Map) continue;
      final Map<String, dynamic> body = decoded.cast<String, dynamic>();
      final String? url = resolveVoiceImageUrl(
        '${body['url'] ?? body['image_url'] ?? body['src'] ?? ''}',
      );
      if (url == null) continue;
      final String caption = '${body['caption'] ?? ''}'.trim();
      cards.add(
        VoiceCard(
          id: 'block-$url',
          kind: 'image',
          title: caption.isEmpty ? 'Image' : caption,
          source: '${body['source'] ?? body['credit'] ?? ''}'.trim().isEmpty
              ? null
              : '${body['source'] ?? body['credit']}'.trim(),
          at: when,
          data: <String, dynamic>{
            'url': url,
            if (caption.isNotEmpty) 'caption': caption,
          },
        ),
      );
    } catch (_) {
      // Skip a broken block; the rest of the turn still counts.
    }
  }
  return cards;
}

List<VoiceCard> voiceCardsFromImagesJson(String? raw, {DateTime? at}) {
  if (raw == null || raw.isEmpty) return const <VoiceCard>[];
  late final Object decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (_) {
    return const <VoiceCard>[];
  }
  if (decoded is! List) return const <VoiceCard>[];
  final DateTime when = at ?? DateTime.now();
  final List<VoiceCard> cards = <VoiceCard>[];
  for (final Object? item in decoded) {
    final String? url = resolveVoiceImageUrl(item?.toString());
    if (url == null) continue;
    cards.add(
      VoiceCard(
        id: 'stored-$url',
        kind: 'image',
        title: 'Image',
        at: when,
        data: <String, dynamic>{'url': url},
      ),
    );
  }
  return cards;
}

String? _captionOf(Map<String, dynamic> call) {
  final Object? args = call['arguments'];
  if (args is Map) {
    final Object? caption = args['caption'];
    if (caption is String && caption.trim().isNotEmpty) return caption.trim();
  }
  final String? result = call['result'] as String?;
  if (result == null || !result.startsWith('IMAGE:')) return null;
  try {
    final Object? decoded = jsonDecode(result.substring(6));
    if (decoded is Map) {
      final Object? caption = decoded['caption'];
      if (caption is String && caption.trim().isNotEmpty) return caption.trim();
    }
  } catch (_) {}
  return null;
}
