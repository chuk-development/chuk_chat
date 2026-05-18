import 'dart:convert';
import 'dart:typed_data';

import 'package:chuk_chat/services/excalidraw_share_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('ExcalidrawShareService.createShareLink', () {
    test('uploads binary payload and returns #json=id,key link', () async {
      late Uri requestUri;
      late String contentType;
      late Uint8List payload;

      final client = MockClient((request) async {
        requestUri = request.url;
        contentType = request.headers['content-type'] ?? '';
        payload = request.bodyBytes;
        return http.Response(jsonEncode({'id': 'abc123'}), 200);
      });

      final link = await ExcalidrawShareService.createShareLink(
        '{"type":"excalidraw","elements":[]}',
        client: client,
      );

      expect(requestUri.toString(), 'https://json.excalidraw.com/api/v2/post/');
      expect(contentType, 'application/octet-stream');
      expect(payload, isNotEmpty);

      final view = ByteData.sublistView(payload);
      expect(view.getUint32(0), 1);
      expect(link.host, 'excalidraw.com');
      expect(link.fragment, startsWith('json=abc123,'));
      final key = link.fragment.split(',').last;
      expect(key.length, 22);
      expect(key.contains('='), isFalse);
    });

    test('throws on non-success upload response', () async {
      final client = MockClient((_) async => http.Response('bad', 500));
      await expectLater(
        ExcalidrawShareService.createShareLink(
          '{"type":"excalidraw","elements":[]}',
          client: client,
        ),
        throwsA(isA<StateError>()),
      );
    });
  });
}
