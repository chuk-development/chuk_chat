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
          'current': {'temperature': '12', 'condition': 'Sunny'},
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
        args: const {'location': 'Berlin', 'action': 'forecast', 'days': 3},
        client: client,
      );

      expect(result, contains('Weather — Berlin'));
      expect(result, contains('Forecast:'));
      expect(result, contains('2026-04-25'));
      expect(result, contains('Sunny'));
      expect(result, contains('2026-04-26'));
      expect(result, contains('Rain'));
    });

    // The shape Brave really returns (keys taken from the owner's chat cache,
    // 2026-09-23; values made up). The generic reader never matched it, so
    // every call dumped ~16 kB of raw JSON, the same for current, forecast
    // and hourly, and the model called `weather` again and again.
    Map<String, dynamic> braveRichPayload() {
      Map<String, dynamic> day(int ts, int id, String description) => {
        'ts': ts,
        'date_i18n': 'Mittwoch, Sept. 23',
        'temperature': {'day': 17.53, 'min': 9.28, 'max': 17.91},
        'feels_like': {'day': 17.4},
        'humidity': 79,
        'wind': {'speed': 4.6, 'deg': 200, 'gust': 8.18},
        'pop': 1.0,
        'rain': 3.4,
        'weather': {'id': id, 'main': 'rain', 'description': description},
      };
      Map<String, dynamic> slot(int ts) => {
        'ts': ts,
        'temperature': {'temp': 14.76, 'feels_like': 14.51},
        'weather': {'id': 501, 'main': 'rain', 'description': 'moderate rain'},
        'wind': {'speed': 4.6, 'deg': 200},
        'pop': 0.35,
        'rain': 3.74,
      };
      // 2026-09-23 12:00 UTC; Kiel is UTC+2 in September.
      const noon = 1790164800;
      return {
        'vertical': 'weather',
        'data': {
          'type': 'rich',
          'results': [
            {
              'type': 'rich',
              'subtype': 'weather',
              'provider': {'name': 'OpenWeatherMap'},
              'weather': {
                'location': {
                  'name': 'Kiel',
                  'country': 'DE',
                  'tzoffset': 7200,
                  'coords': {'lat': 54.32, 'lon': 10.13},
                },
                'current_time_iso': '2026-09-23T20:53:42',
                'current_weather': {
                  'ts': noon,
                  'temp': 15.11,
                  'feels_like': 14.82,
                  'humidity': 82,
                  'uvi': 0.0,
                  'clouds': 38,
                  'wind': {'speed': 2.06, 'deg': 190},
                  'weather': {
                    'id': 802,
                    'main': 'clouds',
                    'description': 'scattered clouds',
                  },
                },
                'daily': [
                  for (var i = 0; i < 8; i++)
                    day(noon + i * 86400, 501, 'moderate rain'),
                ],
                'hours3': [for (var i = 0; i < 40; i++) slot(noon + i * 10800)],
                'alerts': [
                  {
                    'sender': 'Deutscher Wetterdienst',
                    'event': 'Wind gusts',
                    'start_relative_i18n': 'in 5 Stunden',
                    'description': 'long text',
                  },
                ],
              },
            },
          ],
          'response_callback_info': {'callback_key': 'abc'},
        },
      };
    }

    Future<String> runWeather(Map<String, dynamic> args) => executeWeather(
      serverHttpUrl: 'https://api.example.com',
      serverHeaders: const {},
      args: args,
      client: MockClient(
        (request) async => http.Response(jsonEncode(braveRichPayload()), 200),
      ),
    );

    test('reads the real Brave rich payload instead of dumping it', () async {
      final result = await runWeather(const {
        'location': 'Kiel',
        'action': 'current',
      });

      expect(result, isNot(contains('Raw payload')));
      expect(result, contains('Weather — Kiel, DE'));
      expect(result, contains(kWeatherCompleteNote));
      expect(result, contains('Local time: 2026-09-23 20:53'));
      expect(result, contains('scattered clouds (WMO 2)'));
      expect(result, contains('15.1 °C (feels 14.8 °C)'));
      expect(result, contains('humidity 82%'));
      expect(result, contains('wind 7 km/h S'));
      expect(result, contains('Wind gusts (Deutscher Wetterdienst)'));
      // Local ISO dates, precipitation probability and WMO codes: the fields
      // the weather card asks for.
      expect(result, contains('- 2026-09-23: moderate rain (WMO 63)'));
      expect(result, contains('max 17.9 / min 9.3 °C'));
      expect(result, contains('precip prob 100%'));
      expect(result, contains('- 2026-09-23 14:00: 14.8 °C'));
      expect(result, contains('precip prob 35%'));
      // A short result, not the 16 kB dump.
      expect(result.length, lessThan(3000));
    });

    test('action, days and hours now change the result', () async {
      final current = await runWeather(const {'location': 'Kiel'});
      final forecast = await runWeather(const {
        'location': 'Kiel',
        'action': 'forecast',
        'days': 7,
      });
      final hourly = await runWeather(const {
        'location': 'Kiel',
        'action': 'hourly',
        'hours': 48,
      });

      int dailyLines(String s) => RegExp(
        r'^- \d{4}-\d{2}-\d{2}: ',
        multiLine: true,
      ).allMatches(s).length;
      int hourlyLines(String s) => RegExp(
        r'^- \d{4}-\d{2}-\d{2} \d{2}:\d{2}: ',
        multiLine: true,
      ).allMatches(s).length;

      expect(dailyLines(current), 3);
      expect(dailyLines(forecast), 7);
      expect(hourlyLines(current), 8);
      expect(hourlyLines(hourly), 16);
    });

    test('maps OpenWeatherMap ids to WMO codes', () {
      expect(owmToWmoCode(800), 0);
      expect(owmToWmoCode(801), 1);
      expect(owmToWmoCode(802), 2);
      expect(owmToWmoCode(804), 3);
      expect(owmToWmoCode(500), 61);
      expect(owmToWmoCode(501), 63);
      expect(owmToWmoCode(502), 65);
      expect(owmToWmoCode(521), 81);
      expect(owmToWmoCode(601), 73);
      expect(owmToWmoCode(741), 45);
      expect(owmToWmoCode(211), 95);
      expect(owmToWmoCode(300), 51);
    });

    test('gives an eight-point compass direction', () {
      expect(compassPoint(0), 'N');
      expect(compassPoint(190), 'S');
      expect(compassPoint(225), 'SW');
      expect(compassPoint(200), 'S');
      expect(compassPoint(350), 'N');
      expect(compassPoint(90), 'E');
      expect(compassPoint(315), 'NW');
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
