// The map card a places lookup produces on its own — no model turn spent
// copying coordinates into a <map> tag.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/tool_handlers/map_tools.dart';

Map<String, dynamic> _decodeTag(String tag) {
  expect(tag.startsWith('<map>'), isTrue);
  expect(tag.trimRight().endsWith('</map>'), isTrue);
  final body = tag
      .replaceFirst('<map>', '')
      .replaceFirst('</map>', '')
      .trim();
  return jsonDecode(body) as Map<String, dynamic>;
}

void main() {
  test('a place with coordinates becomes a card with its details', () {
    final tag = buildPlacesMapTag(
      title: 'pharmacy',
      places: [
        {
          'name': 'Example Pharmacy',
          'lat': 54.32,
          'lon': 10.13,
          'address': 'Example street 1',
          'opening_hours': 'Mo-Fr 08:00-18:00',
          'rating': 4.7,
          'review_count': 128,
          'price_range': '€€',
          'description': 'Corner pharmacy',
        },
      ],
    );

    final decoded = _decodeTag(tag!);
    expect(decoded['type'], 'places');
    expect(decoded['title'], 'pharmacy');

    final place = (decoded['places'] as List).single as Map<String, dynamic>;
    expect(place['name'], 'Example Pharmacy');
    expect(place['lat'], 54.32);
    expect(place['lon'], 10.13);
    expect(place['address'], 'Example street 1');
    expect(place['opening_hours'], 'Mo-Fr 08:00-18:00');
    expect(place['rating'], 4.7);
    expect(place['review_count'], 128);
  });

  test('coordinates arriving as strings still pin', () {
    final tag = buildPlacesMapTag(
      title: 'cafe',
      places: [
        {'name': 'Example Cafe', 'lat': '54.32', 'lon': '10.13'},
      ],
    );

    final place =
        ((_decodeTag(tag!)['places'] as List).single) as Map<String, dynamic>;
    expect(place['lat'], 54.32);
    expect(place['lon'], 10.13);
  });

  test('places without coordinates are skipped', () {
    final tag = buildPlacesMapTag(
      title: 'bakery',
      places: [
        {'name': 'No coordinates'},
        {'name': 'Pinned', 'lat': 1.0, 'lon': 2.0},
      ],
    );

    final places = _decodeTag(tag!)['places'] as List;
    expect(places, hasLength(1));
    expect((places.single as Map)['name'], 'Pinned');
  });

  test('no card at all when nothing can be pinned', () {
    expect(
      buildPlacesMapTag(
        title: 'bakery',
        places: [
          {'name': 'One'},
          {'name': 'Two'},
        ],
      ),
      isNull,
    );
    expect(buildPlacesMapTag(title: 'x', places: const []), isNull);
  });

  test('the card is capped so it stays a glance', () {
    final tag = buildPlacesMapTag(
      title: 'shops',
      places: List.generate(
        20,
        (i) => {'name': 'Shop $i', 'lat': 50.0 + i, 'lon': 10.0 + i},
      ),
    );

    expect(
      (_decodeTag(tag!)['places'] as List).length,
      kMaxPlacesOnMap,
    );
  });

  test('empty fields are left out instead of shipped as blanks', () {
    final tag = buildPlacesMapTag(
      title: 'shop',
      places: [
        {
          'name': 'Example',
          'lat': 1.0,
          'lon': 2.0,
          'address': '   ',
          'description': '',
        },
      ],
    );

    final place =
        ((_decodeTag(tag!)['places'] as List).single) as Map<String, dynamic>;
    expect(place.containsKey('address'), isFalse);
    expect(place.containsKey('description'), isFalse);
    // Only what the card renders — no stray payload fields.
    expect(place.keys.toSet(), {'name', 'lat', 'lon'});
  });

  test('an unnamed place falls back to the query as its label', () {
    final tag = buildPlacesMapTag(
      title: 'pharmacy',
      places: [
        {'lat': 1.0, 'lon': 2.0},
      ],
    );

    final place =
        ((_decodeTag(tag!)['places'] as List).single) as Map<String, dynamic>;
    expect(place['name'], 'pharmacy');
  });
}
