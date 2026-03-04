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
  });
}
