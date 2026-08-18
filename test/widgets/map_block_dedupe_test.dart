import 'package:flutter_test/flutter_test.dart';
import 'package:chuk_chat/widgets/map_block_renderer.dart';

void main() {
  group('debugFilterAndDedupeCoordItems', () {
    test('drops a repeated place by name, case-insensitive', () {
      final out = debugFilterAndDedupeCoordItems([
        {'name': 'Baracca Zermatt', 'lat': 47.5497, 'lon': 7.5843},
        {'name': 'baracca zermatt', 'lat': 47.5497, 'lon': 7.5843},
      ]);
      expect(out, hasLength(1));
      expect(out.first['name'], 'Baracca Zermatt');
    });

    test('a later duplicate fills a field the first entry was missing', () {
      final out = debugFilterAndDedupeCoordItems([
        {'name': 'Löwenzorn', 'lat': 47.5567, 'lon': 7.5861},
        {
          'name': 'Löwenzorn',
          'lat': 47.5567,
          'lon': 7.5861,
          'phone': '+41 61 000 00 00',
        },
      ]);
      expect(out, hasLength(1));
      expect(out.first['phone'], '+41 61 000 00 00');
    });

    test('keeps two different places at the same coordinates', () {
      final out = debugFilterAndDedupeCoordItems([
        {'name': 'Cafe A', 'lat': 47.5, 'lon': 7.5},
        {'name': 'Bar B', 'lat': 47.5, 'lon': 7.5},
      ]);
      expect(out, hasLength(2));
    });

    test('dedupes unnamed markers by coordinates', () {
      final out = debugFilterAndDedupeCoordItems([
        {'label': '', 'lat': 47.500001, 'lon': 7.500001},
        {'label': '', 'lat': 47.500002, 'lon': 7.500002},
      ]);
      expect(out, hasLength(1));
    });

    test('drops entries with invalid coordinates before dedupe', () {
      final out = debugFilterAndDedupeCoordItems([
        {'name': 'Valid', 'lat': 47.5, 'lon': 7.5},
        {'name': 'Broken', 'lat': 999.0, 'lon': 7.5},
        {'name': 'NoCoords'},
      ]);
      expect(out, hasLength(1));
      expect(out.first['name'], 'Valid');
    });

    test('does not mutate the caller-supplied maps', () {
      final original = {'name': 'X', 'lat': 47.5, 'lon': 7.5};
      final dup = {'name': 'X', 'lat': 47.5, 'lon': 7.5, 'phone': '+410000000'};
      debugFilterAndDedupeCoordItems([original, dup]);
      expect(original.containsKey('phone'), isFalse);
    });
  });
}
