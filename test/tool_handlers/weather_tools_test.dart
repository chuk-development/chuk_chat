import 'dart:convert';

import 'package:chuk_chat/tool_handlers/weather_tools.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('executeWeather (Brave rich callback)', () {
    test('returns error when no location or lat/lon given', () async {
      final result = await executeWeather(
        serverHttpUrl: 'https://api.example.com',
        serverHeaders: const {},
        args: const {},
      );
      expect(result, contains('Error'));
      expect(result, contains('location'));
    });

    test('returns error when server base URL missing', () async {
      final result = await executeWeather(
        serverHttpUrl: null,
        serverHeaders: const {},
        args: const {'location': 'Kiel'},
      );
      expect(result, contains('Not connected to server'));
    });

    test('maps 404 to no-rich-result message', () async {
      final client = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/v1/tools/brave/rich');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['query'], contains('Kiel'));
        return http.Response('{"error":"no_rich_result"}', 404);
      });

      final result = await executeWeather(
        serverHttpUrl: 'https://api.example.com',
        serverHeaders: const {},
        args: const {'location': 'Kiel'},
        client: client,
      );
      expect(result, contains('No weather data from Brave'));
    });

    test('formats rich payload fields when available', () async {
      final payload = {
        'vertical': 'weather',
        'query': 'weather Kiel',
        'data': {
          'location': 'Kiel, Germany',
          'current': {
            'temperature': '9 °C',
            'feels_like': '6 °C',
            'condition': 'Partly cloudy',
            'humidity': '72%',
            'wind_speed': '14 km/h',
            'wind_direction': 'W',
            'precipitation': '0 mm',
            'pressure': '1012 hPa',
            'uv_index': '2',
          },
        },
      };

      final client = MockClient((request) async {
        return http.Response(jsonEncode(payload), 200);
      });

      final result = await executeWeather(
        serverHttpUrl: 'https://api.example.com',
        serverHeaders: const {},
        args: const {'location': 'Kiel'},
        client: client,
      );

      expect(result, contains('Weather — Kiel, Germany'));
      expect(result, contains('Condition: Partly cloudy'));
      expect(result, contains('Temperature: 9 °C (feels 6 °C)'));
      expect(result, contains('Humidity: 72%'));
      expect(result, contains('Wind: 14 km/h W'));
    });

    test('formats forecast payload with daily entries', () async {
      final payload = {
        'vertical': 'weather',
        'query': '3 day weather forecast Berlin',
        'data': {
          'location': 'Berlin',
          'current': {
            'temperature': '12',
            'condition': 'Sunny',
          },
          'forecast': [
            {
              'date': '2026-04-25',
              'condition': 'Sunny',
              'high': '15',
              'low': '5',
              'precip': '0 mm',
            },
            {
              'date': '2026-04-26',
              'condition': 'Rain',
              'high': '13',
              'low': '7',
              'precip': '4 mm',
            },
          ],
        },
      };

      final client = MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['query'], contains('3 day weather forecast'));
        return http.Response(jsonEncode(payload), 200);
      });

      final result = await executeWeather(
        serverHttpUrl: 'https://api.example.com',
        serverHeaders: const {},
        args: const {
          'location': 'Berlin',
          'action': 'forecast',
          'days': 3,
        },
        client: client,
      );

      expect(result, contains('Weather — Berlin'));
      expect(result, contains('Forecast:'));
      expect(result, contains('2026-04-25'));
      expect(result, contains('Sunny'));
      expect(result, contains('2026-04-26'));
      expect(result, contains('Rain'));
    });

    test('forwards server auth headers', () async {
      String? capturedAuth;
      final client = MockClient((request) async {
        capturedAuth = request.headers['Authorization'];
        return http.Response('{"vertical":"weather","data":{}}', 200);
      });

      await executeWeather(
        serverHttpUrl: 'https://api.example.com',
        serverHeaders: const {'Authorization': 'Bearer xyz'},
        args: const {'location': 'Kiel'},
        client: client,
      );

      expect(capturedAuth, 'Bearer xyz');
    });
  });
}
