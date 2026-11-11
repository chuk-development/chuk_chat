import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/models/chat_message.dart';
import 'package:chuk_chat/services/media_provenance_service.dart';

const String _path = 'user-1/abc.enc';

String _imageResult(Map<String, dynamic> payload) =>
    'IMAGE:${jsonEncode(payload)}';

void main() {
  test('a generated picture yields prompt, model, seed and size', () {
    final message = ChatMessage(
      role: 'assistant',
      text: 'Here you go',
      images: jsonEncode([_path]),
      toolCalls: jsonEncode([
        {
          'name': 'generate_image',
          'arguments': {'prompt': 'a red fox'},
          'result': _imageResult({
            'storage_path': _path,
            'prompt': 'a red fox in snow',
            'model': 'Krea 2 Large',
            'seed': 42,
            'width': 1024,
            'height': 768,
            'cost_eur': 0.03,
          }),
          'completedAt': '2026-11-01T10:00:00Z',
        },
      ]),
    );
    final info = provenanceFromMessages(
      [message],
      _path,
      chatId: 'c1',
      chatTitle: 'Foxes',
    )!;
    expect(info.origin, ImageOrigin.generated);
    expect(info.prompt, 'a red fox in snow');
    expect(info.model, 'Krea 2 Large');
    expect(info.seed, '42');
    expect(info.width, 1024);
    expect(info.height, 768);
    expect(info.costEur, 0.03);
    expect(info.chatTitle, 'Foxes');
    expect(info.createdAt, DateTime.utc(2026, 11, 1, 10));
  });

  test('tool calls inside content blocks are found too', () {
    final message = ChatMessage(
      role: 'assistant',
      text: '',
      contentBlocks: jsonEncode([
        {
          'type': 'toolCalls',
          'toolCalls': [
            {
              'name': 'generate_image',
              'arguments': {'prompt': 'a cat'},
              'result': _imageResult({'storage_path': _path}),
            },
          ],
        },
      ]),
    );
    final info = provenanceFromMessages([message], _path)!;
    expect(info.origin, ImageOrigin.generated);
    // The prompt falls back to the tool call's arguments.
    expect(info.prompt, 'a cat');
  });

  test('a picture in a user message is an upload', () {
    final message = ChatMessage(
      role: 'user',
      text: 'look',
      images: jsonEncode([_path]),
      sentAt: '2026-10-05T08:30:00Z',
    );
    final info = provenanceFromMessages([message], _path)!;
    expect(info.origin, ImageOrigin.uploaded);
    expect(info.prompt, isNull);
    expect(info.createdAt, DateTime.utc(2026, 10, 5, 8, 30));
  });

  test('a fetched picture keeps its source address', () {
    final message = ChatMessage(
      role: 'assistant',
      text: '',
      toolCalls: jsonEncode([
        {
          'name': 'fetch_image',
          'arguments': {'url': 'https://example.com/a.png'},
          'result':
              'IMAGE_DATA:${jsonEncode({'storage_path': _path, 'url': 'https://example.com/a.png'})}',
        },
      ]),
    );
    final info = provenanceFromMessages([message], _path)!;
    expect(info.origin, ImageOrigin.fetched);
    expect(info.sourceUrl, 'https://example.com/a.png');
  });

  test('an older answer without tool result uses its image metadata', () {
    final message = ChatMessage(
      role: 'assistant',
      text: '',
      images: jsonEncode(['other.enc', _path]),
      imageMetas: jsonEncode([
        {'source': 'fetched'},
        {'source': 'generated', 'caption': 'sunset', 'model': 'Seedream'},
      ]),
    );
    final info = provenanceFromMessages([message], _path)!;
    expect(info.origin, ImageOrigin.generated);
    expect(info.prompt, 'sunset');
    expect(info.model, 'Seedream');
  });

  test('the tool result wins over an earlier upload of the same path', () {
    final upload = ChatMessage(
      role: 'user',
      text: '',
      images: jsonEncode([_path]),
    );
    final generated = ChatMessage(
      role: 'assistant',
      text: '',
      toolCalls: jsonEncode([
        {
          'name': 'generate_image',
          'arguments': {'prompt': 'p'},
          'result': _imageResult({'storage_path': _path, 'prompt': 'p'}),
        },
      ]),
    );
    final info = provenanceFromMessages([upload, generated], _path)!;
    expect(info.origin, ImageOrigin.generated);
  });

  test('a chat that does not mention the path gives null', () {
    final message = ChatMessage(
      role: 'user',
      text: 'hi',
      images: jsonEncode(['someone/else.enc']),
    );
    expect(provenanceFromMessages([message], _path), isNull);
  });

  test('provenance survives a JSON round trip', () {
    final info = ImageProvenance(
      origin: ImageOrigin.generated,
      prompt: 'x',
      model: 'm',
      seed: '1',
      width: 10,
      height: 20,
      costEur: 0.5,
      chatId: 'c',
      chatTitle: 't',
      createdAt: DateTime.utc(2026, 1, 2, 3, 4),
    );
    final back = ImageProvenance.fromJson(info.toJson());
    expect(back.toJson(), info.toJson());
  });
}
