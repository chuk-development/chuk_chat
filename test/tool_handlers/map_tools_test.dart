import 'dart:convert';

import 'package:chuk_chat/tool_handlers/map_tools.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('executeSearchPlaces (Brave local)', () {
    test('returns error when query missing', () async {
      final result = await executeSearchPlaces(
        serverHttpUrl: 'https://api.example.com',
        serverHeaders: const {},
        args: const {},
      );
      expect(result, contains('"query" parameter required'));
    });

    test('returns error when server base URL missing', () async {
      final result = await executeSearchPlaces(
        serverHttpUrl: null,
        serverHeaders: const {},
        args: const {'query': 'pharmacy'},
      );
      expect(result, contains('Not connected to server'));
    });

    test('formats place cards with rating and description', () async {
      final payload = {
        'query': 'pharmacy Kiel',
        'places': [
          {
            'id': 'poi_1',
            'name': 'Stern-Apotheke',
            'lat': 54.32,
            'lon': 10.14,
            'address': 'Holstenstr. 82, 24103 Kiel',
            'phone': '+49 431 123456',
            'website': 'https://stern-apotheke.de',
            'opening_hours': 'Mo-Fr 08-19',
            'cuisine': '',
            'rating': 4.5,
            'review_count': 120,
            'price_range': '',
            'description': 'Inner-city pharmacy with extended hours.',
          }
        ],
      };

      final client = MockClient((request) async {
        expect(request.method, 'POST');
        expect(request.url.path, '/v1/tools/brave/places');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        expect(body['query'], contains('pharmacy'));
        expect(body['query'], contains('Kiel'));
        return http.Response(jsonEncode(payload), 200);
      });

      final result = await executeSearchPlaces(
        serverHttpUrl: 'https://api.example.com',
        serverHeaders: const {},
        args: const {'query': 'pharmacy', 'city': 'Kiel'},
        client: client,
      );

      expect(result, contains('Found 1 places for "pharmacy":'));
      expect(result, contains('Stern-Apotheke'));
      expect(result, contains('[54.32, 10.14]'));
      expect(result, contains('Holstenstr. 82'));
      expect(result, contains('rating 4.5'));
      expect(result, contains('120 reviews'));
      expect(result, contains('About: Inner-city pharmacy'));
    });

    test('returns "No places found" when server sends empty list', () async {
      final client = MockClient((_) async {
        return http.Response('{"query":"x","places":[]}', 200);
      });

      final result = await executeSearchPlaces(
        serverHttpUrl: 'https://api.example.com',
        serverHeaders: const {},
        args: const {'query': 'zzz-unknown'},
        client: client,
      );
      expect(result, contains('No places found'));
    });
  });

  group('executeSearchRestaurants (Brave local)', () {
    test('builds cuisine-aware query and formats output', () async {
      String? capturedQuery;
      final payload = {
        'query': 'italian restaurants in Kiel',
        'places': [
          {
            'id': 'poi_r1',
            'name': 'La Tavola',
            'lat': 54.31,
            'lon': 10.13,
            'address': 'Hafenstr. 12, Kiel',
            'cuisine': 'Italian',
            'rating': 4.6,
            'review_count': 210,
            'price_range': 'EUR-EUR',
            'description': 'Wood-fired pizza and house-made pasta.',
          }
        ],
      };

      final client = MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        capturedQuery = body['query'] as String?;
        return http.Response(jsonEncode(payload), 200);
      });

      final result = await executeSearchRestaurants(
        serverHttpUrl: 'https://api.example.com',
        serverHeaders: const {},
        args: const {'cuisine': 'italian', 'city': 'Kiel'},
        client: client,
      );

      expect(capturedQuery, contains('italian'));
      expect(capturedQuery, contains('restaurants'));
      expect(capturedQuery, contains('in Kiel'));
      expect(result, contains('Found 1 restaurants for "italian":'));
      expect(result, contains('La Tavola'));
      expect(result, contains('price EUR-EUR'));
    });

    test('reports no restaurants when server returns empty', () async {
      final client = MockClient((_) async {
        return http.Response('{"query":"x","places":[]}', 200);
      });

      final result = await executeSearchRestaurants(
        serverHttpUrl: 'https://api.example.com',
        serverHeaders: const {},
        args: const {'cuisine': 'klingon'},
        client: client,
      );
      expect(result, contains('No restaurants found for "klingon"'));
    });
  });
}
