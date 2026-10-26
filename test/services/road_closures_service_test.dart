import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';

import 'package:chuk_chat/services/road_closures_service.dart';
import 'package:chuk_chat/utils/map_features.dart';

// Shapes copied from the live DANord MapServer (layer 8 lines, layer 0
// points, layer 1 Hamburg, layer 6 detours), trimmed.
Map<String, dynamic> _shLine(int id, {String header = 'B76 Plön - Trent'}) => {
  'attributes': {
    'objectid': id,
    'straßenname': 'B76',
    'header': header,
    'dauer_der_bauphase': '2026-02-02 23:00:00 bis 2027-12-31 22:59:00',
    'verkehrseinschränkung': 'Gewichtsbeschränkung',
    'umleitungsempfehlung': 'Schöne Aussicht - Am Döhl - Am See',
    'verbleibende_restbreite_in_m': 2.5,
    'gewichtsbeschränkung_in_t': 7.5,
    'höchstgeschwindigkeit_in_km_h': null,
  },
  'geometry': {
    'paths': [
      [
        [10.35, 54.21],
        [10.36, 54.20 + id / 10000],
      ],
    ],
  },
};

void main() {
  group('parseDateRange', () {
    test('ISO range in UTC becomes the local day', () {
      final r = parseDateRange(
        '2026-02-02 23:00:00 bis 2027-12-31 22:59:00',
        isoIsUtc: true,
      );
      expect(r.start, DateTime.utc(2026, 2, 2, 23).toLocal());
      expect(r.end, DateTime.utc(2027, 12, 31, 22, 59).toLocal());
    });

    test('German, "von … Uhr" and short ISO forms', () {
      final de = parseDateRange('20.03.2023 00:00:00 bis 31.08.2026 23:59:00');
      expect(de.start, DateTime(2023, 3, 20));
      expect(de.end, DateTime(2026, 8, 31, 23, 59));
      final uhr = parseDateRange(
        'von 01.07.2026 00:00 Uhr bis 01.01.2027 00:00 Uhr',
      );
      expect(uhr.end, DateTime(2027, 1, 1));
      final short = parseDateRange('2026-09-07 - 2026-10-31');
      expect(short.start, DateTime(2026, 9, 7));
      expect(short.end, DateTime(2026, 10, 31));
    });

    test('empty or dateless text', () {
      expect(parseDateRange(null).start, isNull);
      expect(parseDateRange('demnächst').end, isNull);
    });
  });

  group('classifyRestriction', () {
    test('full closure vs lane restriction', () {
      expect(classifyRestriction('Vollsperrung'), MapFeatureKind.closure);
      expect(
        classifyRestriction('in beiden Richtungen gesperrt'),
        MapFeatureKind.closure,
      );
      expect(
        classifyRestriction('Halbseitige Sperrung mit Lichtsignalanlage'),
        MapFeatureKind.roadworks,
      );
      expect(
        classifyRestriction('1 Fahrstreifen gesperrt'),
        MapFeatureKind.roadworks,
      );
      expect(classifyRestriction('Gewichtsbeschränkung'),
          MapFeatureKind.roadworks);
    });
  });

  group('parseRoadworksLayer + grouping', () {
    test('segments of one measure fold into one ref; point copies drop', () {
      final lines = parseRoadworksLayer(8, {
        'features': [_shLine(113), _shLine(117), _shLine(118)],
      });
      final points = parseRoadworksLayer(0, {
        'features': [
          {
            'attributes': {
              'objectid': 231,
              'straßenname': 'B76',
              'header': 'B76 Plön - Trent',
              'dauer_der_bauphase':
                  '2026-02-02 23:00:00 bis 2027-12-31 22:59:00',
              'verkehrseinschränkung': 'Gewichtsbeschränkung',
            },
            'geometry': {'x': 10.35, 'y': 54.21},
          },
        ],
      });
      final grouped = groupRoadClosures([...lines, ...points]);
      expect(grouped, hasLength(1));
      final c = grouped.single;
      expect(c.ref, 'sh:8:113,117,118');
      expect(c.geometry.lines, hasLength(3));
      expect(c.kind, MapFeatureKind.roadworks);
      expect(c.road, 'B76');
      expect(c.limits, contains('7.5 t'));
      expect(c.limits, contains('Restbreite 2.5 m'));
      expect(c.detour, 'Schöne Aussicht - Am Döhl - Am See');
    });

    test('Hamburg points: generic header takes the first info line', () {
      final c = parseRoadworksLayer(1, {
        'features': [
          {
            'attributes': {
              'objectid': 1,
              'header': 'Baustelle',
              'infos':
                  'Hamburg, Überseering\nzwischen New-York-Ring und Jahnring\n'
                  'in beiden Richtungen gesperrt, Bauarbeiten',
              'baubeginn': '2023-05-30, 06:00:00',
              'bauende': '2033-06-30, 21:59:00',
            },
            'geometry': {'x': 10.02, 'y': 53.6},
          },
        ],
      }).single;
      expect(c.title, 'Baustelle: Hamburg, Überseering');
      expect(c.kind, MapFeatureKind.closure);
      expect(c.start, DateTime(2023, 5, 30, 6));
      expect(c.end, DateTime(2033, 6, 30, 21, 59));
      expect(c.notes, contains('New-York-Ring'));
      expect(c.geometry.point, isNotNull);
    });

    test('detour layer is a detour with its route as text', () {
      final c = parseRoadworksLayer(6, {
        'features': [
          {
            'attributes': {
              'objectid': 1,
              'header': 'Umleitung für Kremsdorfer Weg',
              'gültigkeit': '2026-09-07 - 2026-10-31',
              'streckenführung': 'Kremsdorfer Weg - Ostlandstraße',
            },
            'geometry': {
              'paths': [
                [
                  [10.9, 54.29],
                  [10.91, 54.3],
                ],
              ],
            },
          },
        ],
      }).single;
      expect(c.kind, MapFeatureKind.detour);
      expect(c.detour, 'Kremsdorfer Weg - Ostlandstraße');
    });

    test('malformed responses give nothing, never throw', () {
      expect(parseRoadworksLayer(8, null), isEmpty);
      expect(parseRoadworksLayer(8, {'error': 'x'}), isEmpty);
      expect(
        parseRoadworksLayer(8, {
          'features': [
            'x',
            {'attributes': {'header': 'no id'}},
            {'attributes': {'objectid': 5}},
          ],
        }),
        isEmpty,
      );
    });
  });

  group('filterCurrentClosures', () {
    RoadClosure mk(int id, DateTime? start, DateTime? end, MapFeatureKind k) =>
        RoadClosure(
          layer: 8,
          ids: [id],
          kind: k,
          title: 't$id',
          start: start,
          end: end,
        );
    final now = DateTime(2026, 10, 24, 12);

    test('drops finished and far-future; active first', () {
      final kept = filterCurrentClosures([
        mk(1, DateTime(2026, 11, 6), DateTime(2027, 11, 4),
            MapFeatureKind.roadworks),
        mk(2, DateTime(2026, 1, 1), DateTime(2026, 10, 1),
            MapFeatureKind.closure),
        mk(3, DateTime(2027, 6, 1), null, MapFeatureKind.closure),
        mk(4, DateTime(2026, 2, 3), DateTime(2027, 12, 31),
            MapFeatureKind.roadworks),
        mk(5, null, null, MapFeatureKind.closure),
      ], now: now);
      expect(kept.map((c) => c.ids.single), [5, 4, 1]);
    });

    test('with a centre, the nearest active measure comes first', () {
      RoadClosure at(int id, double lat, MapFeatureKind k) => RoadClosure(
        layer: 8,
        ids: [id],
        kind: k,
        title: 't$id',
        start: DateTime(2026, 10, 1),
        geometry: ResolvedGeometry(
          lines: [
            [LatLng(lat, 10.0), LatLng(lat + 0.001, 10.0)],
          ],
        ),
      );
      final kept = filterCurrentClosures(
        [
          at(1, 54.5, MapFeatureKind.closure), // ~55 km away
          at(2, 54.01, MapFeatureKind.roadworks), // ~1 km away
          at(3, 54.2, MapFeatureKind.closure), // ~22 km away
        ],
        now: now,
        nearLat: 54.0,
        nearLon: 10.0,
      );
      expect(kept.map((c) => c.ids.single), [2, 3, 1]);
    });
  });

  group('model output', () {
    test('map feature JSON carries ref, dates and detour', () {
      final c = groupRoadClosures(
        parseRoadworksLayer(8, {
          'features': [_shLine(113)],
        }),
      ).single;
      final f = closureMapFeature(c);
      expect(f['kind'], 'roadworks');
      expect(f['ref'], 'sh:8:113');
      expect(f['dates'], isNotEmpty);
      expect(f['detour'], isNotNull);
      // The feature the model copies parses back into a resolvable spec.
      final spec = parseMapFeature(
        jsonDecode(jsonEncode(f)) as Map<String, dynamic>,
      )!;
      expect(spec.ref, 'sh:8:113');
      expect(spec.kind, MapFeatureKind.roadworks);
    });

    test('text lists entries and the municipal-street hint', () {
      final now = DateTime(2026, 10, 24);
      final c = groupRoadClosures(
        parseRoadworksLayer(8, {
          'features': [_shLine(113)],
        }),
      );
      final text = formatClosuresForModel(
        closures: c,
        placeLabel: 'Preetz',
        lat: 54.23,
        lon: 10.28,
        radiusKm: 5,
        now: now,
      );
      expect(text, contains('ROADWORKS · active · B76 Plön - Trent'));
      expect(text, contains('Map feature: {"kind":"roadworks"'));
      expect(text, contains('Gemeindestraßen'));
      final empty = formatClosuresForModel(
        closures: const [],
        placeLabel: 'Preetz',
        lat: 54.23,
        lon: 10.28,
        radiusKm: 5,
        now: now,
      );
      expect(empty, contains('No current or upcoming entries'));
    });

    test('refs parse; junk refs do not', () {
      final ref = parseRoadworksRef('sh:8:113, 117')!;
      expect(ref.$1, 8);
      expect(ref.$2, [113, 117]);
      expect(parseRoadworksRef('sh:x:1'), isNull);
      expect(parseRoadworksRef('osm:1'), isNull);
    });

    test('coverage box', () {
      expect(roadworksFeedCovers(54.23, 10.28), isTrue);
      expect(roadworksFeedCovers(48.14, 11.58), isFalse);
    });
  });
}
