import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/api_config_base.dart' show getApiBaseUrl;
import 'package:chuk_chat/voice/voice_image_cards.dart';

void main() {
  test('resolveVoiceImageUrl keeps http(s) and drops other schemes', () {
    expect(
      resolveVoiceImageUrl('https://cdn.example/a.png'),
      'https://cdn.example/a.png',
    );
    expect(resolveVoiceImageUrl('http://cdn.example/a.png'), isNotNull);
    expect(resolveVoiceImageUrl('data:image/png;base64,xx'), isNull);
    expect(resolveVoiceImageUrl(''), isNull);
    expect(resolveVoiceImageUrl(null), isNull);
  });

  test('resolveVoiceImageUrl prefixes a relative API path', () {
    final String? url = resolveVoiceImageUrl(
      '/v1/ai/image/file/UXC0ebVtrwOHaho7xlV5H433jcJeY-sSbSoSWqqsnY4',
    );
    expect(url, isNotNull);
    expect(url, startsWith(getApiBaseUrl()));
    expect(
      url,
      contains('/v1/ai/image/file/UXC0ebVtrwOHaho7xlV5H433jcJeY-sSbSoSWqqsnY4'),
    );
  });

  test('IMAGE tool result becomes a finished image card', () {
    final String toolCalls = jsonEncode(<Map<String, Object>>[
      <String, Object>{
        'id': 'call-1',
        'name': 'generate_image',
        'status': 'completed',
        'arguments': <String, String>{'prompt': 'a cat', 'model': 'flux'},
        'result':
            'IMAGE:${jsonEncode(<String, String>{'url': '/v1/ai/image/file/cat'})}',
      },
    ]);
    final cards = voiceCardsFromChatMessage(<String, String>{
      'text': 'Hier ist deine Katze.',
      'toolCalls': toolCalls,
    });
    expect(cards, hasLength(1));
    expect(cards.single.kind, 'image');
    expect(cards.single.id, 'call-1');
    expect(cards.single.text('url'), contains('/v1/ai/image/file/cat'));
    expect(cards.single.data['generating'], isNot(true));
  });

  test('a running generate_image is the loading card', () {
    final String toolCalls = jsonEncode(<Map<String, Object>>[
      <String, Object>{
        'id': 'pending-1',
        'name': 'generate_image',
        'status': 'running',
        'arguments': <String, String>{'prompt': 'a cat'},
      },
    ]);
    final cards = voiceCardsFromToolCallsJson(toolCalls);
    expect(cards, hasLength(1));
    expect(cards.single.data['generating'], true);
    expect(cards.single.text('url'), isNull);
  });

  test('an <image> block in the answer becomes a card', () {
    const String text =
        'Hab dir das Porträt geöffnet.\n'
        '<image>\n'
        '{"url":"https://upload.wikimedia.org/mozart.jpg","caption":"Mozart","source":"Barbara Krafft"}\n'
        '</image>';
    final cards = voiceCardsFromImageBlocks(text);
    expect(cards, hasLength(1));
    expect(cards.single.text('url'), 'https://upload.wikimedia.org/mozart.jpg');
    expect(cards.single.title, 'Mozart');
    expect(cards.single.source, 'Barbara Krafft');
  });

  test('imageUrlFromToolResult ignores a non-image result', () {
    expect(imageUrlFromToolResult('ok'), isNull);
    expect(imageUrlFromToolResult('IMAGE:not-json'), isNull);
  });
}
