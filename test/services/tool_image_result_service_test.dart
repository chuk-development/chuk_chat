import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/services/tool_image_result_service.dart';

void main() {
  group('ToolImageResultService', () {
    test('parses IMAGE_DATA result with trailing text', () async {
      final payload = jsonEncode({
        'data_uri': 'data:image/png;base64,not-base64!',
        'mime_type': 'image/png',
        'size_bytes': 123,
      });

      final call = ToolCall(
        name: 'generate_qr',
        result:
            'IMAGE_DATA:$payload\n\n'
            'QR code generated locally for: https://chuk.chat\n'
            'Size: 400x400 pixels',
        status: ToolCallStatus.completed,
      );

      final processed = await ToolImageResultService.processToolCalls([call]);

      expect(processed.imagePaths, hasLength(1));
      expect(
        processed.imagePaths.first,
        equals('data:image/png;base64,not-base64!'),
      );

      final normalized = processed.toolCalls.first.result;
      expect(normalized, isNotNull);
      expect(normalized, startsWith('IMAGE_DATA:'));
      expect(normalized, isNot(contains('QR code generated locally')));

      final normalizedPayload =
          jsonDecode(normalized!.substring(11)) as Map<String, dynamic>;
      expect(
        normalizedPayload['data_uri'],
        equals('data:image/png;base64,not-base64!'),
      );
    });

    test('marks IMAGE_DATA entries as fetched with caption from args',
        () async {
      final payload = jsonEncode({
        'data_uri': 'data:image/png;base64,abc',
      });

      final call = ToolCall(
        name: 'fetch_image',
        arguments: const {
          'url': 'https://example.com/img.png',
          'caption': 'Sean Connery',
        },
        result: 'IMAGE_DATA:$payload',
        status: ToolCallStatus.completed,
      );

      final processed = await ToolImageResultService.processToolCalls([call]);

      expect(processed.imagePaths, hasLength(1));
      expect(processed.imageMetas, hasLength(1));
      expect(processed.imageMetas.first['source'], equals('fetched'));
      expect(processed.imageMetas.first['caption'], equals('Sean Connery'));
      expect(processed.imageCostEur, isNull);
    });

    test('marks IMAGE entries as generated and carries cost/caption',
        () async {
      final payload = jsonEncode({
        'data_uri': 'data:image/png;base64,xyz',
        'cost_eur': '0.01',
        'generated_at': '2026-04-24T12:00:00Z',
      });

      final call = ToolCall(
        name: 'generate_image',
        arguments: const {
          'prompt': 'cat',
          'caption': 'Cat sketch',
        },
        result: 'IMAGE:$payload',
        status: ToolCallStatus.completed,
      );

      final processed = await ToolImageResultService.processToolCalls([call]);

      expect(processed.imagePaths, hasLength(1));
      expect(processed.imageMetas, hasLength(1));
      expect(processed.imageMetas.first['source'], equals('generated'));
      expect(processed.imageMetas.first['caption'], equals('Cat sketch'));
      expect(processed.imageCostEur, equals('0.01'));
      expect(processed.imageGeneratedAt, equals('2026-04-24T12:00:00.000Z'));
    });

    test('carries generator model label from IMAGE payload', () async {
      final payload = jsonEncode({
        'data_uri': 'data:image/png;base64,xyz',
        'model': 'FLUX 2 Klein 9B',
      });

      final call = ToolCall(
        name: 'generate_image_flux',
        arguments: const {'prompt': 'cat'},
        result: 'IMAGE:$payload',
        status: ToolCallStatus.completed,
      );

      final processed = await ToolImageResultService.processToolCalls([call]);

      expect(processed.imageMetas, hasLength(1));
      expect(processed.imageMetas.first['model'], equals('FLUX 2 Klein 9B'));
    });

    test('omits model when IMAGE payload lacks it', () async {
      final call = ToolCall(
        name: 'generate_image',
        arguments: const {'prompt': 'cat'},
        result: 'IMAGE:${jsonEncode({'data_uri': 'data:image/png;base64,xyz'})}',
        status: ToolCallStatus.completed,
      );

      final processed = await ToolImageResultService.processToolCalls([call]);

      expect(processed.imageMetas, hasLength(1));
      expect(processed.imageMetas.first.containsKey('model'), isFalse);
    });

    test('preserves per-image metadata order across mixed tool calls',
        () async {
      final fetched = ToolCall(
        name: 'fetch_image',
        arguments: const {
          'url': 'https://example.com/a.png',
          'caption': 'Actor A',
        },
        result: 'IMAGE_DATA:${jsonEncode({'data_uri': 'data:image/png;base64,aa'})}',
        status: ToolCallStatus.completed,
      );
      final generated = ToolCall(
        name: 'generate_image',
        arguments: const {'prompt': 'b', 'caption': 'Art B'},
        result: 'IMAGE:${jsonEncode({'data_uri': 'data:image/png;base64,bb'})}',
        status: ToolCallStatus.completed,
      );

      final processed =
          await ToolImageResultService.processToolCalls([fetched, generated]);

      expect(processed.imagePaths, hasLength(2));
      expect(processed.imageMetas, hasLength(2));
      expect(processed.imageMetas[0]['source'], equals('fetched'));
      expect(processed.imageMetas[0]['caption'], equals('Actor A'));
      expect(processed.imageMetas[1]['source'], equals('generated'));
      expect(processed.imageMetas[1]['caption'], equals('Art B'));
    });

    test('omits caption when arg is missing', () async {
      final call = ToolCall(
        name: 'fetch_image',
        arguments: const {'url': 'https://example.com/x.png'},
        result: 'IMAGE_DATA:${jsonEncode({'data_uri': 'data:image/png;base64,zz'})}',
        status: ToolCallStatus.completed,
      );

      final processed = await ToolImageResultService.processToolCalls([call]);

      expect(processed.imageMetas, hasLength(1));
      expect(processed.imageMetas.first['source'], equals('fetched'));
      expect(processed.imageMetas.first.containsKey('caption'), isFalse);
    });
  });
}
