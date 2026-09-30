// The token request: https only (http only in a debug build), and the
// Supabase bearer only for the app's own API host.

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/voice/voice_call_service.dart';

void main() {
  group('tokenUri', () {
    test('takes https', () {
      expect(
        VoiceCallService.tokenUri(
          'https://api.chuk.chat/v1/voice/token',
          allowHttp: false,
        ).host,
        'api.chuk.chat',
      );
    });

    test('refuses plain http outside a debug build', () {
      expect(
        () => VoiceCallService.tokenUri(
          'http://token.example.test/token',
          allowHttp: false,
        ),
        throwsA(isA<VoiceCallException>()),
      );
    });

    test('takes plain http in a debug build', () {
      expect(
        VoiceCallService.tokenUri(
          'http://127.0.0.1:8080/token',
          allowHttp: true,
        ).scheme,
        'http',
      );
    });

    test('refuses other schemes and broken URLs', () {
      for (final String bad in <String>[
        'ftp://api.chuk.chat/token',
        'wss://api.chuk.chat/token',
        '',
        'not a url',
        '/v1/voice/token',
      ]) {
        expect(
          () => VoiceCallService.tokenUri(bad, allowHttp: true),
          throwsA(isA<VoiceCallException>()),
          reason: bad,
        );
      }
    });
  });

  group('tokenHeaders', () {
    const String api = 'https://api.chuk.chat';

    test('the bearer goes to the app API host', () {
      final Map<String, String> h = VoiceCallService.tokenHeaders(
        Uri.parse('https://api.chuk.chat/v1/voice/token'),
        accessToken: 'jwt',
        apiBaseUrl: api,
      );
      expect(h['Authorization'], 'Bearer jwt');
      expect(h['Content-Type'], 'application/json');
    });

    test('host match ignores case', () {
      final Map<String, String> h = VoiceCallService.tokenHeaders(
        Uri.parse('https://API.chuk.chat/v1/voice/token'),
        accessToken: 'jwt',
        apiBaseUrl: api,
      );
      expect(h['Authorization'], 'Bearer jwt');
    });

    test('never to another host, not even a sibling domain', () {
      for (final String other in <String>[
        'https://tokens.example.com/token',
        'https://chuk.chat/token',
        'https://voice.api.chuk.chat/token',
        'https://api.chuk.chat.evil.test/token',
      ]) {
        final Map<String, String> h = VoiceCallService.tokenHeaders(
          Uri.parse(other),
          accessToken: 'jwt',
          apiBaseUrl: api,
        );
        expect(h.containsKey('Authorization'), isFalse, reason: other);
      }
    });

    test('no session, no bearer', () {
      final Map<String, String> h = VoiceCallService.tokenHeaders(
        Uri.parse('https://api.chuk.chat/v1/voice/token'),
        apiBaseUrl: api,
      );
      expect(h.containsKey('Authorization'), isFalse);
    });

    test('defaults to the host the app uses for its API', () {
      final Map<String, String> h = VoiceCallService.tokenHeaders(
        Uri.parse('https://api.chuk.chat/v1/voice/token'),
        accessToken: 'jwt',
      );
      expect(h['Authorization'], 'Bearer jwt');
    });
  });
}
