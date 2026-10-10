import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:chuk_chat/tool_handlers/map_tools.dart';

void main() {
  http.Client serverReturning(List<Map<String, dynamic>> places) {
    return MockClient(
      (_) async => http.Response(jsonEncode({'places': places}), 200),
    );
  }

  test('search_places gives the model text only, with the week hours', () async {
    final text = await executeSearchPlaces(
      serverHttpUrl: 'https://api.example',
      serverHeaders: const {},
      args: const {'query': 'JYSK', 'city': 'Kiel'},
      client: serverReturning([
        {
          'name': 'JYSK Mitte',
          'lat': 54.3044181,
          'lon': 10.1281215,
          'opening_hours': 'Sat 09:30-19:00',
          'opening_hours_week': 'Mon 09:30-19:00; Sat 09:30-19:00',
        },
      ]),
    );

    expect(text, contains('JYSK Mitte [54.3044181, 10.1281215]'));
    expect(text, contains('Hours: Sat 09:30-19:00'));
    expect(text, contains('Hours this week: Mon 09:30-19:00; Sat 09:30-19:00'));
    expect(text, isNot(contains('<map>')));
  });

  test('an older server without the week field still works', () async {
    final text = await executeSearchPlaces(
      serverHttpUrl: 'https://api.example',
      serverHeaders: const {},
      args: const {'query': 'JYSK'},
      client: serverReturning([
        {'name': 'JYSK', 'opening_hours': 'Sat 09:30-19:00'},
      ]),
    );

    expect(text, contains('Hours: Sat 09:30-19:00'));
    expect(text, isNot(contains('Hours this week')));
  });
}
